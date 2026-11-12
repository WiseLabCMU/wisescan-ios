//
//  RigModel.swift
//
//  What remains of the edge-cost solver after the photometric port (v15) retired it:
//  the rig MODEL, which every consumer shares —
//    - composeRigTransform: phone pose + offsetPhone/yaw/pitch → 360° camera pose
//    - dirToEquirect: the one projection convention (chirality-verified 2026-07-31)
//    - SolveBounds: the tape-owned cylinder around the gravity-measured rod
//  plus RigProfile (persisted calibration) below. The edge machinery itself — mesh
//  edge extraction, equirect edge maps, chamfer cost, Nelder-Mead, elevation sweep,
//  the dev bench that drove it — was deleted 2026-08-20 after six field comparisons
//  against PhotometricRigSolver; history has the implementation if it is ever missed.
//

import Foundation
import simd
import CoreGraphics
import ImageIO
import UIKit

enum RigModel {

    // MARK: - Solve bounds

    /// Geometry search box for the solve, in the PHONE's frame. Yaw is ALWAYS global (a
    /// coarse circle scan, narrowed to the photometric basin) — only the
    /// offset and pitch are bounded, around either the mechanical prior (first solve) or a
    /// previously-solved profile (rolling refinement — run13/14 showed the geometry repeats
    /// across sessions within ~4 cm / 2°).
    ///
    /// The box is DELIBERATELY anisotropic. Along the rod (phone −x̂) the operator's tape
    /// pins the length, so that axis needs only tape and clamp slop. Across the rod the
    /// clamp geometry has never been measured at all, and the two half-ranges together also
    /// have to admit the rod not being exactly along −x̂: ±0.13 m at 0.72 m is a ~10° cone,
    /// which covers every inclinometer reading taken on this rig.
    struct SolveBounds {
        let anchorOffset: SIMD3<Float>
        /// Unit vector from the phone camera toward the 360° lens — the rod's direction in
        /// the phone's frame. A CYLINDER around this axis, not an axis-aligned box: the two
        /// uncertainties are physically different (tape slop along it, clamp geometry across
        /// it) and they stopped lining up with x/y/z the moment the direction became a
        /// measurement instead of the assumed −x̂.
        let rodDirection: SIMD3<Float>
        let alongHalf: Float
        let acrossHalf: Float

        /// Distance outside the box, 0 when inside — along and across the rod separately.
        func excursion(_ offset: SIMD3<Float>) -> (along: Float, across: Float) {
            let delta = offset - anchorOffset
            let along = simd_dot(delta, rodDirection)
            let across = simd_length(delta - along * rodDirection)
            return (abs(along), across)
        }

        func contains(_ offset: SIMD3<Float>) -> Bool {
            let e = excursion(offset)
            return e.along <= alongHalf && e.across <= acrossHalf
        }

        /// Measured rod length, and — when the camera's own accelerometer supplied one — a
        /// measured DIRECTION too, which lets the across-rod slop tighten from a ~10° cone
        /// of ignorance to real clamp geometry.
        static func measured(rodLengthM: Float, direction: SIMD3<Float>? = nil) -> SolveBounds {
            let axis = direction.map { simd_normalize($0) } ?? SIMD3<Float>(-1, 0, 0)
            return SolveBounds(
                anchorOffset: rodLengthM * axis,
                rodDirection: axis,
                alongHalf: AppConstants.calibrationMeasuredRodHalfM,
                acrossHalf: direction == nil ? AppConstants.calibrationBoundAcrossRodM
                                             : AppConstants.calibrationMeasuredAcrossRodM)
        }

        static let mechanical = SolveBounds(
            anchorOffset: RigProfile.mechanicalPrior.offsetPhone,
            rodDirection: SIMD3<Float>(-1, 0, 0),
            alongHalf: AppConstants.calibrationBoundRodM,
            acrossHalf: AppConstants.calibrationBoundAcrossRodM)

        static func refinement(around profile: RigProfile) -> SolveBounds {
            let length = simd_length(profile.offsetPhone)
            return SolveBounds(
                anchorOffset: profile.offsetPhone,
                rodDirection: length > 1e-3 ? profile.offsetPhone / length : SIMD3<Float>(-1, 0, 0),
                alongHalf: 0.15, acrossHalf: 0.15)
        }
    }

    // MARK: - Rig transform composition

    /// Compose the world→360cam transform from the phone pose and rig parameters.
    /// Returns a 4×4 camera-to-world matrix for the 360° camera.
    ///
    /// POSITION is a rigid-body offset in the PHONE's frame, rotated into the world by the
    /// phone's own orientation — the rig is bolted to the phone, so that is what "rigid"
    /// means. ORIENTATION is separate and stays gravity-levelled: the Theta's zenith
    /// correction keeps the pano level regardless of how the rig is held, so only yaw (and
    /// a small pitch residual for imperfect zenith correction) are free.
    static func composeRigTransform(
        phoneToWorld: simd_float4x4,
        offsetPhone: SIMD3<Float>,
        yaw: Float
    ) -> simd_float4x4 {
        // Phone position in world
        let phonePos = SIMD3<Float>(phoneToWorld.columns.3.x,
                                   phoneToWorld.columns.3.y,
                                   phoneToWorld.columns.3.z)
        let phoneRot = simd_float3x3(columns: (
            SIMD3<Float>(phoneToWorld.columns.0.x, phoneToWorld.columns.0.y, phoneToWorld.columns.0.z),
            SIMD3<Float>(phoneToWorld.columns.1.x, phoneToWorld.columns.1.y, phoneToWorld.columns.1.z),
            SIMD3<Float>(phoneToWorld.columns.2.x, phoneToWorld.columns.2.y, phoneToWorld.columns.2.z)
        ))
        let camPos = phonePos + phoneRot * offsetPhone

        // Phone's horizontal forward (gravity-projected) — orientation only.
        let phoneFwd = -SIMD3<Float>(phoneToWorld.columns.2.x,
                                     phoneToWorld.columns.2.y,
                                     phoneToWorld.columns.2.z)
        var horiz = SIMD3<Float>(phoneFwd.x, 0, phoneFwd.z)
        if simd_length(horiz) < 1e-3 {
            let phoneUp = SIMD3<Float>(phoneToWorld.columns.1.x, 0, phoneToWorld.columns.1.z)
            horiz = simd_length(phoneUp) > 1e-3 ? phoneUp : SIMD3<Float>(0, 0, -1)
        }
        let fwdNorm = simd_normalize(horiz)

        // Camera orientation: level, rotated by yaw from phone forward, with pitch residual
        var fwd = fwdNorm
        if yaw != 0 {
            let yawRot = simd_float3x3(simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)))
            fwd = yawRot * fwd
        }

        // Apply pitch residual around the camera's right axis
        let camRight = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), -fwd))

        let camUp = simd_normalize(simd_cross(-fwd, camRight))
        let back = -fwd

        // Camera-to-world: columns are (right, up, back, position) in OpenGL/ARKit convention
        return simd_float4x4(columns: (
            SIMD4<Float>(camRight.x, camRight.y, camRight.z, 0),
            SIMD4<Float>(camUp.x, camUp.y, camUp.z, 0),
            SIMD4<Float>(back.x, back.y, back.z, 0),
            SIMD4<Float>(camPos.x, camPos.y, camPos.z, 1)
        ))
    }

    // MARK: - Sphere math

    /// Convert a direction to equirect pixel coordinates.
    /// Convention: lon 0 = +Z (equirect center), lat +90° = +Y (north pole).
    static func dirToEquirect(dir: SIMD3<Float>, width: Int, height: Int) -> (Float, Float) {
        let lat = asin(max(-1, min(1, dir.y)))
        // atan2(x, −z): PROPER chirality (device-verified 2026-07-31 — the old
        // atan2(x, z) sampled the equirect MIRRORED: whiteboard text read backwards in
        // pinhole re-renders; a rotation can never mirror, so every solve was matching
        // flipped geometry) AND front-centered, matching EquirectFaceExport's sampler —
        // the solver and the face cut now share one convention, closing the 180°
        // solver-vs-export yaw question.
        let lon = atan2(dir.x, -dir.z)
        let eqX = (lon + .pi) / (2 * .pi) * Float(width)
        let eqY = (.pi / 2 - lat) / .pi * Float(height)
        return (eqX, eqY)
    }

}

// MARK: - Rig Profile (persistable calibration)

/// Solved rig calibration profile: the rig offset, yaw, residual, and provenance.
/// Persisted to UserDefaults as JSON so the calibration survives app restarts.
struct RigProfile: Codable, Equatable {
    /// Rig offset from the phone's camera to the 360° lens, expressed IN THE PHONE'S
    /// OWN FRAME (ARKit camera axes: +x right, +y up, −z view direction). The rod runs
    /// along −x̂, so a 0.72 m rig is roughly `(-0.72, 0, 0)`.
    ///
    /// THIS IS THE WHOLE POINT OF THE PARAMETERISATION. The rig is rigid *to the phone*,
    /// so its offset is constant in the phone's frame and rotates with it. The previous
    /// model stored a world-frame pair (dy along gravity + dLateral across phone-horizontal),
    /// whose reachable set is a 2-plane: when the phone tilts, the 360° lens genuinely
    /// swings FORWARD, and no (dy, dLateral) could express that. On the field archive's
    /// 5–13° tilts and 0.72 m rod that is an unrepresentable 6–17 cm on every still, and
    /// the solve absorbed it into whatever else would move — dy rode its bound, pitch went
    /// to 77% of its own, and `elevation_offset_deg` pinned at the end of its sweep on all
    /// five stills of the 2026-08-18 19:19 scan.
    ///
    /// Consequences worth keeping: the operator's tape measures ‖offsetPhone‖ DIRECTLY
    /// (no cosine, no per-scan tilt correction), and the retired pitch/elevation nuisance terms /
    /// `elevation_offset_deg` no longer have a systematic error to soak up, so their
    /// collapsing toward zero is a falsifiable check on this model rather than a hope.
    let offsetPhone: SIMD3<Float>
    /// Yaw offset — rotation around the vertical axis (radians).
    let yaw: Float
    /// Calibration residual — RMS reprojection error in equirect pixels (512-wide).
    /// NOTE: renamed from residualCm (which was actually mean-SQUARED px, finding #3).
    /// The Codable key change deliberately invalidates previously-persisted profiles —
    /// a stored squared-px value must not be reinterpreted as RMS px. Recalibrate.
    let residualPx: Float
    /// When this calibration was performed.
    let timestamp: Date
    /// Camera model string (e.g. "RICOH THETA X") for provenance.
    let cameraModel: String?
    /// Camera serial number for binding a calibration to a specific hardware device.
    let cameraSerialNumber: String?

    /// Distance from the phone camera to the 360° lens — the number the operator tapes.
    var rodLengthM: Float { simd_length(offsetPhone) }

    /// The mechanical prior: `AppConstants` defaults, no calibration. Straight up the rod.
    static var mechanicalPrior: RigProfile {
        RigProfile(
            offsetPhone: SIMD3<Float>(-AppConstants.rigRodHeightMeters, 0, 0),
            yaw: AppConstants.rigYawOffsetDegrees * .pi / 180,
            residualPx: -1,  // sentinel: not calibrated
            timestamp: .distantPast,
            cameraModel: nil,
            cameraSerialNumber: nil
        )
    }

    var isSolved: Bool { residualPx >= 0 && residualPx.isFinite }

    /// Same geometry with a substituted (per-session) yaw.
    func replacingYaw(_ yaw: Float) -> RigProfile {
        RigProfile(offsetPhone: offsetPhone, yaw: yaw,
                   residualPx: residualPx, timestamp: timestamp,
                   cameraModel: cameraModel, cameraSerialNumber: cameraSerialNumber)
    }

    func with(cameraModel: String?, cameraSerialNumber: String?) -> RigProfile {
        RigProfile(
            offsetPhone: offsetPhone,
            yaw: yaw,
            residualPx: residualPx,
            timestamp: timestamp,
            cameraModel: cameraModel ?? self.cameraModel,
            cameraSerialNumber: cameraSerialNumber ?? self.cameraSerialNumber
        )
    }

    // MARK: - Persistence

    private static let userDefaultsKey = "rig_calibration_profile"

    static func load() -> RigProfile? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970   // CONTRIBUTING → Units & time
        return try? decoder.decode(RigProfile.self, from: data)
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970   // CONTRIBUTING → Units & time
        guard let data = try? encoder.encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}
