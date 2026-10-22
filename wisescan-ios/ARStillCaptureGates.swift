// swiftlint:disable identifier_name
import Foundation
import simd

/// EXPERIMENT: still-capture gates for `ARStillCaptureSession`, driven by the ARKit pose and the
/// LiDAR depth rather than the raw IMU and optical flow the ARKit-free raw capture has to use.
/// Pure functions, so the decisions are unit tested.
///
/// Camera convention is ARKit's: the transform is camera-to-world, the camera looks down its -Z
/// axis, and positions are metres in the session's world frame.
nonisolated enum ARStillCaptureGates {

    /// Predicted motion smear of one still, in photo pixels, split by cause.
    struct Smear: Equatable {
        /// Rotation: angular rate x exposure x focal length.
        var rotationPx: Double
        /// Sideways translation: lateral speed x exposure x focal length / distance to the scene.
        var translationPx: Double
        var totalPx: Double { rotationPx + translationPx }
    }

    /// Smear for a still about to be exposed for `exposure` seconds. `focalPx` is the focal length
    /// in pixels of the still (not of the video stream); `depth` is the distance to the nearer part
    /// of the scene, since near content smears most under translation. Translation along the view
    /// axis is ignored: it scales the image about the centre and smears far less than a sidestep.
    static func smear(angularRate: Double, lateralSpeed: Double, depth: Double,
                      exposure: Double, focalPx: Double) -> Smear {
        guard exposure > 0, focalPx > 0 else { return Smear(rotationPx: 0, translationPx: 0) }
        let rotation = max(0, angularRate) * exposure * focalPx
        let translation = depth > 0 ? max(0, lateralSpeed) * exposure * focalPx / depth : 0
        return Smear(rotationPx: rotation, translationPx: translation)
    }

    /// Predicted smear of a still, in still pixels, from the camera's rigid motion between two
    /// ARKit poses `dt` seconds apart: the largest image velocity among the frame's centre and four
    /// points at ±`cornerFraction` of its half-extents, for scene content `depth` metres away, times
    /// the exposure. Rotation and translation enter as vectors, so they cancel where they should:
    /// orbiting a target while turning to keep it centred barely moves the target in the image,
    /// which the `smear` sum (rotation + sideways, both as magnitudes) cannot see.
    ///
    /// `halfWidthNorm` / `halfHeightNorm` are the image half-extents over the focal length (the
    /// same at any resolution with the same field of view); `focalPx` is the still's focal length.
    /// Replayed on a 94-still capture: the shipped 2 px sum fired every 2.05 s; this at 3 px every
    /// 1.37 s on the same motion, inside the 2.8 px p90 that the sharp stills actually moved.
    static func imageMotionSmear(from past: simd_float4x4, to now: simd_float4x4, dt: Double,
                                 depth: Double, exposure: Double, focalPx: Double,
                                 halfWidthNorm: Double, halfHeightNorm: Double,
                                 cornerFraction: Double = 0.8) -> Double {
        guard dt > 0, depth > 0, exposure > 0, focalPx > 0 else { return 0 }
        // OpenCV camera axes (x right, y down, z forward) from ARKit's (x right, y up, z back).
        let flip = simd_double3x3(diagonal: SIMD3<Double>(1, -1, -1))
        func double(_ m: simd_float3x3) -> simd_double3x3 {
            simd_double3x3(columns: (SIMD3<Double>(m.columns.0), SIMD3<Double>(m.columns.1), SIMD3<Double>(m.columns.2)))
        }
        let rPast = double(rotationPart(past)) * flip
        let rNow = double(rotationPart(now)) * flip
        let relative = simd_quatd(rPast.transpose * rNow)
        let angle = relative.angle
        let omega = angle > 1e-9 ? relative.axis * (angle / dt) : SIMD3<Double>(0, 0, 0)  // body frame
        let move = SIMD3<Double>(position(now) - position(past))
        let v = rNow.transpose * move / dt                                                  // camera frame
        let xs = halfWidthNorm * cornerFraction, ys = halfHeightNorm * cornerFraction
        let points: [(Double, Double)] = [(0, 0), (-xs, -ys), (xs, -ys), (-xs, ys), (xs, ys)]
        var fastest = 0.0
        for (x, y) in points {
            // Image Jacobian of a point at normalized (x, y), depth Z, under camera velocity (v, omega).
            let xd = (-v.x + x * v.z) / depth + x * y * omega.x - (1 + x * x) * omega.y + y * omega.z
            let yd = (-v.y + y * v.z) / depth + (1 + y * y) * omega.x - x * y * omega.y - x * omega.z
            fastest = max(fastest, (xd * xd + yd * yd).squareRoot())
        }
        return fastest * focalPx * exposure
    }

    /// Exposure cap for the short-exposure experiment: Auto ISO with a minimum shutter speed, run
    /// the other way round. Returns the shortest exposure the scene's light allows at `isoCeiling`,
    /// clamped to [`floor`, `cap`]. Light is exposure x ISO (auto exposure holds it constant for a
    /// given brightness, so the answer does not depend on the cap currently applied), corrected by
    /// auto exposure's own error: `targetOffsetEV` is how far the metered level sits from its
    /// target (negative = underexposed, so more light is needed). The offset is clamped to +-2 EV
    /// so a transient cannot swing the cap.
    static func shortExposureCap(exposure: Double, iso: Double, targetOffsetEV: Double,
                                 isoCeiling: Double, floor: Double, cap: Double) -> Double {
        guard exposure > 0, iso > 0, isoCeiling > 0, cap > 0 else { return cap }
        let offset = min(2, max(-2, targetOffsetEV.isFinite ? targetOffsetEV : 0))
        let light = exposure * iso * pow(2, -offset)
        return min(cap, max(min(floor, cap), light / isoCeiling))
    }

    /// Component of `velocity` perpendicular to the camera's viewing direction, m/s.
    static func lateralSpeed(velocity: SIMD3<Float>, cameraToWorld: simd_float4x4) -> Double {
        let forward = forwardAxis(cameraToWorld)
        let lateral = velocity - simd_dot(velocity, forward) * forward
        return Double(simd_length(lateral))
    }

    /// How far the viewpoint has moved since the previous still, in degrees, two ways:
    /// `rotationDeg` is the angle between the two camera orientations; `parallaxDeg` is the angle
    /// the sideways part of the translation subtends at the scene (`depth` metres away), which is
    /// how a sidestep or an orbit registers. A pure pan has rotation and no parallax.
    static func viewpointChange(from previous: simd_float4x4, to current: simd_float4x4,
                                depth: Double) -> (rotationDeg: Double, parallaxDeg: Double) {
        let qa = simd_quatf(rotationPart(previous)), qb = simd_quatf(rotationPart(current))
        let dot = min(1, abs(Double(simd_dot(qa.vector, qb.vector))))
        let rotationDeg = 2 * acos(dot) * 180 / .pi
        guard depth > 0 else { return (rotationDeg, 0) }
        let delta = position(current) - position(previous)
        let forward = forwardAxis(previous)
        let lateral = delta - simd_dot(delta, forward) * forward
        let parallaxDeg = atan2(Double(simd_length(lateral)), depth) * 180 / .pi
        return (rotationDeg, parallaxDeg)
    }

    /// Spacing verdict: why the next still may fire now, or nil to hold. `sinceLast` is `.infinity`
    /// before the first still. Thresholds at or below 0 are off; with the viewpoint threshold off
    /// the loop is unspaced and only the blur gate and the pipeline's latency set the rate.
    static func spacingDecision(sinceLast: Double, rotationDeg: Double, parallaxDeg: Double,
                                minInterval: Double, viewpointThresholdDeg: Double,
                                maxInterval: Double) -> String? {
        if sinceLast < minInterval { return nil }
        if viewpointThresholdDeg <= 0 { return "unspaced" }
        if sinceLast == .infinity { return "first" }
        if rotationDeg >= viewpointThresholdDeg { return "rotation" }
        if parallaxDeg >= viewpointThresholdDeg { return "parallax" }
        if maxInterval > 0 && sinceLast >= maxInterval { return "time" }
        return nil
    }

    // MARK: Pose helpers

    static func position(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// Unit viewing direction in world space (ARKit cameras look down -Z).
    static func forwardAxis(_ m: simd_float4x4) -> SIMD3<Float> {
        simd_normalize(-SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
    }

    static func rotationPart(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                      SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                      SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
    }

    /// A low percentile of valid depth samples (metres), ignoring zero, non-finite, and samples
    /// whose ARKit confidence is below `minConfidence`. nil when too few samples survive.
    static func depthPercentile(_ depths: [Float], confidences: [UInt8], minConfidence: UInt8,
                                percentile: Double, minSamples: Int = 16) -> Double? {
        var valid: [Float] = []
        valid.reserveCapacity(depths.count)
        for i in depths.indices where depths[i].isFinite && depths[i] > 0.05
            && (i >= confidences.count || confidences[i] >= minConfidence) {
            valid.append(depths[i])
        }
        guard valid.count >= minSamples else { return nil }
        valid.sort()
        let index = min(valid.count - 1, max(0, Int((Double(valid.count - 1) * percentile).rounded())))
        return Double(valid[index])
    }
}
