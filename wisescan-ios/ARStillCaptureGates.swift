// swiftlint:disable identifier_name
import Foundation
import simd

/// EXPERIMENT: still-capture gates for `ARStillCaptureSession`, driven by the ARKit pose and the
/// LiDAR depth (an earlier ARKit-free capture had only the raw IMU and optical flow to go on).
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

    /// Recent gyro rates (magnitude, rad/s) in a fixed ring, for the blur gate's peak and the
    /// per-still check of the rate at capture. Appending and reading cost a few float operations,
    /// so the gyro callback and the frame path stay as cheap as before.
    ///
    /// Why a peak: the pose term above averages rotation over `arStillVelocityWindowSeconds`, which
    /// smooths hand shake out, while a 2 ms exposure sees the shake at its peak. In the iPhone
    /// office capture 30% of the stills that pose term passed turned faster than the budget allows
    /// at capture; with a 50 ms gyro peak also required to pass, 7% did.
    nonisolated struct GyroHistory: Sendable {
        private var times: [Double]
        private var rates: [Double]
        private var head = 0
        private(set) var count = 0

        init(capacity: Int) {
            times = [Double](repeating: 0, count: max(1, capacity))
            rates = [Double](repeating: 0, count: max(1, capacity))
        }

        mutating func append(time: Double, rate: Double) {
            times[head] = time
            rates[head] = rate
            head = (head + 1) % times.count
            count = min(count + 1, times.count)
        }

        /// Ring slot of the `age`-th newest sample (0 = newest).
        private func slot(_ age: Int) -> Int { (head - 1 - age + 2 * times.count) % times.count }

        var latest: Double? { count > 0 ? rates[slot(0)] : nil }

        /// Highest rate among the samples within `window` seconds of the newest one (which is
        /// always included). 0 when empty.
        func peak(window: Double) -> Double {
            guard count > 0 else { return 0 }
            let newest = times[slot(0)]
            var highest = 0.0
            for age in 0..<count {
                let k = slot(age)
                if newest - times[k] > window { break }
                highest = max(highest, rates[k])
            }
            return highest
        }

        /// Rate at `time`, interpolated between the samples on either side. Past the newest sample
        /// it is the newest rate if that is within `maxGap`; nil when the history does not reach
        /// back to `time` or the nearest sample is further than `maxGap` away.
        func rate(at time: Double, maxGap: Double = 0.05) -> Double? {
            guard count > 0 else { return nil }
            var newer: Int?
            for age in 0..<count {
                let k = slot(age)
                if times[k] <= time {
                    guard let n = newer else { return time - times[k] <= maxGap ? rates[k] : nil }
                    let span = times[n] - times[k]
                    if span > 2 * maxGap { return nil }
                    let f = span > 0 ? (time - times[k]) / span : 0
                    return rates[k] + (rates[n] - rates[k]) * f
                }
                newer = k
            }
            return nil
        }
    }

    /// The short-exposure cap: Auto ISO with a minimum shutter speed, run
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

    // MARK: Focus region

    /// How a focus scan's region sits in one camera view.
    struct RegionView: Equatable {
        /// The box centre projects inside the image, `centreMargin` in from every edge.
        var centreInFrame: Bool
        /// Share of the image the box's projected bounding rectangle covers (clipped to the
        /// image), 0...1. 1 when the camera is inside or right up against the box.
        var frameCoverage: Double
        /// The camera is inside the box, or part of the box reaches behind the camera: up close,
        /// where the projection says little and "too far" does not apply.
        var upClose: Bool = false
        /// Camera to box centre, metres.
        var distance: Double
        /// Where the camera is, seen from the box centre in the box's own axes: azimuth 0...360
        /// degrees about +Y (0 = the box's +Z side), elevation -90...90 degrees above its middle.
        var azimuthDeg: Double
        var elevationDeg: Double
    }

    /// The region in one view. `boxToWorld` places the box (it spans +-`halfExtents`);
    /// `cameraToWorld` and the intrinsics are the frame's (ARKit: camera looks down -Z, +Y up;
    /// pixels in the sensor's landscape image, v down).
    static func regionView(boxToWorld: simd_float4x4, halfExtents: SIMD3<Float>,
                           cameraToWorld: simd_float4x4, fx: Double, fy: Double, cx: Double, cy: Double,
                           width: Double, height: Double, centreMargin: Double = 0.1) -> RegionView {
        let worldToCamera = cameraToWorld.inverse
        let centre = position(boxToWorld)
        let camera = position(cameraToWorld)
        func project(_ world: SIMD3<Float>) -> (u: Double, v: Double, depth: Double) {
            let p = worldToCamera * SIMD4<Float>(world, 1)
            let depth = Double(-p.z)
            guard depth > 1e-6 else { return (0, 0, depth) }
            return (cx + fx * Double(p.x) / depth, cy - fy * Double(p.y) / depth, depth)
        }
        let c = project(centre)
        let marginU = width * centreMargin, marginV = height * centreMargin
        let centreIn = c.depth > 0 && c.u >= marginU && c.u <= width - marginU && c.v >= marginV && c.v <= height - marginV

        var coverage = 0.0
        let projected = FocusRegion.corners(of: boxToWorld, halfExtents: halfExtents).map(project)
        let cameraLocal = boxToWorld.inverse * SIMD4<Float>(camera, 1)
        let inside = abs(cameraLocal.x) <= halfExtents.x && abs(cameraLocal.y) <= halfExtents.y
            && abs(cameraLocal.z) <= halfExtents.z
        let cornerBehind = projected.contains(where: { $0.depth <= AppConstants.focusRegionNearPlaneM })
        if inside {
            coverage = 1
        } else if cornerBehind {
            // A corner at or behind the camera: up against the box, or partly behind us. Seen
            // head-on that fills the frame; otherwise the projection says little.
            coverage = centreIn ? 1 : 0
        } else {
            let us = projected.map { $0.u }, vs = projected.map { $0.v }
            let left = max(0, us.min() ?? 0), right = min(width, us.max() ?? 0)
            let top = max(0, vs.min() ?? 0), bottom = min(height, vs.max() ?? 0)
            if right > left, bottom > top, width > 0, height > 0 {
                coverage = (right - left) * (bottom - top) / (width * height)
            }
        }

        let rotation = rotationPart(boxToWorld)
        let local = rotation.transpose * (camera - centre)
        let horizontal = (Double(local.x) * Double(local.x) + Double(local.z) * Double(local.z)).squareRoot()
        var azimuth = atan2(Double(local.x), Double(local.z)) * 180 / .pi
        if azimuth < 0 { azimuth += 360 }
        let elevation = atan2(Double(local.y), horizontal) * 180 / .pi
        return RegionView(centreInFrame: centreIn, frameCoverage: min(1, coverage), upClose: inside || cornerBehind,
                          distance: Double(simd_length(camera - centre)),
                          azimuthDeg: azimuth, elevationDeg: elevation)
    }

    /// How many of `points` (world positions the LiDAR depth puts along a few image rays: what the
    /// camera is actually looking at) lie inside the box grown by `margin` on every side. The
    /// robust "is the camera on the region" test: unlike the box centre being in frame, it holds
    /// for a large box seen in part, from inside it, or from under a desk.
    static func pointsInRegion(_ points: [SIMD3<Float>], boxToWorld: simd_float4x4,
                               halfExtents: SIMD3<Float>, margin: Float) -> Int {
        let toBox = boxToWorld.inverse
        let h = halfExtents + SIMD3<Float>(repeating: max(0, margin))
        return points.filter { point in
            let l = toBox * SIMD4<Float>(point, 1)
            return abs(l.x) <= h.x && abs(l.y) <= h.y && abs(l.z) <= h.z
        }.count
    }

    /// World position of the scene at image pixel (u, v) and camera-space `depth` (ARKit scene
    /// depth is along the view axis): the camera looks down -Z with +Y up, pixel v runs down.
    static func unproject(u: Double, v: Double, depth: Double, fx: Double, fy: Double, cx: Double, cy: Double,
                          cameraToWorld: simd_float4x4) -> SIMD3<Float> {
        let x = (u - cx) / fx * depth
        let y = -(v - cy) / fy * depth
        let world = cameraToWorld * SIMD4<Float>(Float(x), Float(y), Float(-depth), 1)
        return SIMD3<Float>(world.x, world.y, world.z)
    }

    /// Coverage-dial cell for a view direction: `azimuthBins` sectors per ring, rings split at
    /// `elevationEdgesDeg` (ascending; below the first edge is ring 0). Index = ring * bins + sector.
    static func coverageBin(azimuthDeg: Double, elevationDeg: Double, azimuthBins: Int,
                            elevationEdgesDeg: [Double]) -> Int {
        let bins = max(1, azimuthBins)
        var az = azimuthDeg.truncatingRemainder(dividingBy: 360)
        if az < 0 { az += 360 }
        let sector = min(bins - 1, Int(az / (360 / Double(bins))))
        let ring = elevationEdgesDeg.filter { elevationDeg >= $0 }.count
        return ring * bins + sector
    }

    /// Angle at the region centre between two camera positions, degrees: how far the view of the
    /// region has moved, whether by orbiting or by a sidestep.
    static func regionViewAngleDeg(from a: SIMD3<Float>, to b: SIMD3<Float>, centre: SIMD3<Float>) -> Double {
        let da = a - centre, db = b - centre
        let la = simd_length(da), lb = simd_length(db)
        guard la > 1e-6, lb > 1e-6 else { return 0 }
        let cosine = Double(simd_dot(da, db) / (la * lb))
        return acos(min(1, max(-1, cosine))) * 180 / .pi
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
