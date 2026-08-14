import Foundation
import ImageIO
import simd

// Persistence for live-scan 360° stills: writes the equirect JPEG + a metadata sidecar
// into the scan's raw-data bundle. Split from ThetaCameraManager so the tens-of-MB file
// write is a `nonisolated static` helper that runs OFF the main actor (never block the
// capture thread), and to keep the manager file within the length limits.
//
// PRIVACY NOTE: these equirects are stored RAW (unblurred). A 360° still sees everything,
// including people behind the operator the phone's forward privacy stencil never saw.
// Per-face person blur for equirects is the design doc's P3 privacy invariant and is NOT
// applied here — so a scan exported while this spike is active includes unblurred 360°
// stills. Acceptable for on-device calibration testing on this branch ONLY; must land
// before any 360° source ships. See docs/design/still-source-360.md (Privacy).
extension ThetaCameraManager {

    /// Inputs for one live-scan still write, bundled so the writer keeps a small parameter list.
    struct ScanStillInput {
        let sequence: Int
        let phoneTransform: simd_float4x4
        /// ARKit frame timestamp at the trigger tap — BOOT-RELATIVE, same clock as
        /// transforms.json (pairs stills with keyframes). Not wall-clock.
        let frameTimestamp: TimeInterval
        /// Wall-clock capture moment, UTC epoch milliseconds (CONTRIBUTING → Units & time).
        let capturedAtEpochMs: Int64
        let sourceURL: String
        let sourceModel: String
        let format: StillFormat?
        let triggerMs: Int
        /// Max phone translation (m) / rotation (deg) observed across the trigger window
        /// vs the tap pose — the camera exposes ~0.3-1 s AFTER the tap, so rig motion in
        /// that window means blur AND a baked pose that doesn't match the exposure.
        let triggerMotionM: Float?
        let triggerMotionDeg: Float?
        /// Same measurement restricted to the exposure window (shutter-ack anchored,
        /// per-model length) — the sway that actually corrupts the pose.
        let exposureMotionM: Float?
        let exposureMotionDeg: Float?
        /// When the camera acknowledged the shutter command, ms after the tap — the
        /// exposure window's anchor (BLE write-ack on the X, OSC response on the Z1).
        let shutterAckMs: Int?
        /// Window length applied for the sway verdict, ms.
        let exposureWindowMs: Int?
        /// Raw probe samples (t vs tap, displacement) — lets the window be re-derived
        /// offline once the bench latency + EXIF exposure numbers land per model.
        let motionSamples: [MotionSample]?
    }

    /// Writes the equirect + sidecar to `<rawDataDir>/equirect_stills/still_NNNN.{JPG,json}`
    /// — the camera-agnostic 360° contract (any equirectangular source writes here; the
    /// device identity travels in the sidecar's `still_source`, not in path names).
    /// Nonisolated so the file write runs off the main actor.
    /// Writes the metadata SIDECAR at trigger time — phone pose, timing, and the camera
    /// file URL; NO cam_transform and no JPEG yet (post-process pivot, 2026-07-30: poses
    /// are baked by the Process step's calibration solve, and the equirect bytes drain
    /// through the download queue / Process sweep). Download state is derived from disk:
    /// sidecar present + JPG missing ⇒ pending.
    /// Retro-annotates a still's sidecar with the EXIF exposure time parsed from the
    /// downloaded equirect bytes, and feeds the value back into the per-model estimate
    /// the live sway window uses — so a dim room widens the guard by itself instead of
    /// waiting on a constant. Both download paths call it: the live drain and the
    /// Process sweep.
    nonisolated static func annotateExifExposure(jpegData: Data, sidecarURL: URL,
                                                 model: String? = nil) {
        guard let src = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let exposure = exif[kCGImagePropertyExifExposureTime] as? Double,
              let data = try? Data(contentsOf: sidecarURL),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["exif_exposure_time_s"] == nil
        else { return }
        obj["exif_exposure_time_s"] = exposure

        // Learn the model's worst-case exposure (the sidecar names the source camera
        // when the caller didn't). Monotonic: only ever widens, so one bright frame
        // can't narrow the guard back under a dim room's real exposure.
        if let model = model ?? (obj["still_source"] as? String) {
            let key = "\(AppConstants.Key.thetaObservedExposurePrefix).\(model)"
            let known = UserDefaults.standard.double(forKey: key)
            if exposure > known { UserDefaults.standard.set(exposure, forKey: key) }
        }

        if let out = try? JSONSerialization.data(withJSONObject: obj,
                                                 options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: sidecarURL, options: .atomic)
        }
    }

    nonisolated static func writeScanStillSidecar(input: ScanStillInput, into rawDataDir: URL) throws {
        let dir = rawDataDir.appendingPathComponent("equirect_stills")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Column-major 4×4 (matches the transforms.json convention used elsewhere).
        let matrix = input.phoneTransform
        let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
        let flatTransform = columns.flatMap { [$0.x, $0.y, $0.z, $0.w] }

        let metadata = EquirectStillMetadata(
            sequence: input.sequence,
            frameTimestamp: input.frameTimestamp,
            capturedAtEpochMs: input.capturedAtEpochMs,
            stillSource: input.sourceModel,
            cameraModel: "equirectangular",
            width: input.format?.width,
            height: input.format?.height,
            phoneTransform: flatTransform,
            camTransform: nil,
            cameraFileURL: input.sourceURL,
            triggerMs: input.triggerMs,
            transferMs: nil,
            bytes: nil,
            rigCalibrationSource: nil,
            rigCalibrationResidualPx: nil,
            triggerMotionM: input.triggerMotionM,
            triggerMotionDeg: input.triggerMotionDeg,
            exposureMotionM: input.exposureMotionM,
            exposureMotionDeg: input.exposureMotionDeg,
            shutterAckMs: input.shutterAckMs,
            exposureWindowMs: input.exposureWindowMs,
            motionSamples: input.motionSamples.map { samples in
                samples.map { [Double(Int($0.sinceTap * 1000)), Double($0.meters), Double($0.deg)] }
            }
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: dir.appendingPathComponent(String(format: "still_%04d.json", input.sequence)))
    }
}

/// Sidecar written next to each live-scan 360° still. Records the **phone** pose (not the
/// camera pose — rig-extrinsic composition is the deferred P3 calibration) so downstream can
/// solve the hand–eye calibration from phone-pose ↔ equirect pairs. Snake_case keys match
/// the project's JSON conventions; kept separate from `transforms.json` for now (the design
/// doc's export section folds cube-faces into transforms once calibration + export land).
private struct EquirectStillMetadata: Encodable {
    let sequence: Int
    let frameTimestamp: TimeInterval
    let capturedAtEpochMs: Int64
    let stillSource: String
    let cameraModel: String
    let width: Int?
    let height: Int?
    let phoneTransform: [Float]
    let camTransform: [Float]?
    let cameraFileURL: String
    let triggerMs: Int
    let transferMs: Int?
    let bytes: Int?
    let rigCalibrationSource: String?
    let rigCalibrationResidualPx: Float?
    let triggerMotionM: Float?
    let triggerMotionDeg: Float?
    let exposureMotionM: Float?
    let exposureMotionDeg: Float?
    let shutterAckMs: Int?
    let exposureWindowMs: Int?
    /// [t_ms, m, deg] triples from the trigger-window motion probe.
    let motionSamples: [[Double]]?

    enum CodingKeys: String, CodingKey {
        case sequence
        case frameTimestamp = "frame_timestamp"
        case capturedAtEpochMs = "captured_at_epoch_ms"
        case stillSource = "still_source"
        case cameraModel = "camera_model"
        case width
        case height
        case phoneTransform = "phone_transform"
        case camTransform = "cam_transform"
        case cameraFileURL = "camera_file_url"
        case triggerMs = "trigger_ms"
        case transferMs = "transfer_ms"
        case bytes
        case rigCalibrationSource = "rig_calibration_source"
        case rigCalibrationResidualPx = "rig_calibration_residual_px_rms"
        case triggerMotionM = "trigger_motion_m"
        case triggerMotionDeg = "trigger_motion_deg"
        case exposureMotionM = "exposure_motion_m"
        case exposureMotionDeg = "exposure_motion_deg"
        case shutterAckMs = "shutter_ack_ms"
        case exposureWindowMs = "exposure_window_ms"
        case motionSamples = "motion_samples"
    }
}
