// swiftlint:disable identifier_name
import XCTest
import simd
@testable import wisescan_ios

/// The pure gate math behind the stripped AR still capture. The session itself needs a device
/// (no ARKit world tracking in the Simulator); these lock the decisions it makes per frame.
final class ARStillCaptureGatesTests: XCTestCase {

    /// Camera-to-world transform at `position`, yawed `yawDeg` about world +Y. At yaw 0 the camera
    /// looks down world -Z (ARKit convention).
    private func pose(_ position: SIMD3<Float>, yawDeg: Float = 0) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: yawDeg * .pi / 180, axis: SIMD3(0, 1, 0)))
        m.columns.3 = SIMD4(position, 1)
        return m
    }

    func testSmearSplitsRotationAndTranslation() {
        // 0.1 rad/s at 1/120 s and 3000 px focal: 2.5 px of rotation smear.
        // 0.3 m/s sideways at 1 m: 0.3 * (1/120) * 3000 / 1 = 7.5 px of translation smear.
        let s = ARStillCaptureGates.smear(angularRate: 0.1, lateralSpeed: 0.3, depth: 1.0,
                                          exposure: 1.0 / 120, focalPx: 3000)
        XCTAssertEqual(s.rotationPx, 2.5, accuracy: 1e-9)
        XCTAssertEqual(s.translationPx, 7.5, accuracy: 1e-9)
        XCTAssertEqual(s.totalPx, 10, accuracy: 1e-9)
        // Twice as far, half the translation smear; rotation unchanged.
        let far = ARStillCaptureGates.smear(angularRate: 0.1, lateralSpeed: 0.3, depth: 2.0,
                                            exposure: 1.0 / 120, focalPx: 3000)
        XCTAssertEqual(far.translationPx, 3.75, accuracy: 1e-9)
        XCTAssertEqual(far.rotationPx, 2.5, accuracy: 1e-9)
    }

    func testSmearWithoutDepthOrExposureIsRotationOnlyOrZero() {
        let noDepth = ARStillCaptureGates.smear(angularRate: 0.1, lateralSpeed: 1, depth: 0, exposure: 0.01, focalPx: 1000)
        XCTAssertEqual(noDepth.translationPx, 0)
        XCTAssertEqual(noDepth.rotationPx, 1, accuracy: 1e-9)
        let noExposure = ARStillCaptureGates.smear(angularRate: 1, lateralSpeed: 1, depth: 1, exposure: 0, focalPx: 1000)
        XCTAssertEqual(noExposure.totalPx, 0)
    }

    func testLateralSpeedIgnoresMotionAlongTheView() {
        let camera = pose(.zero)                       // looks down -Z
        XCTAssertEqual(ARStillCaptureGates.lateralSpeed(velocity: SIMD3(0, 0, -0.5), cameraToWorld: camera), 0, accuracy: 1e-6)
        XCTAssertEqual(ARStillCaptureGates.lateralSpeed(velocity: SIMD3(0.3, 0, -0.5), cameraToWorld: camera), 0.3, accuracy: 1e-6)
        XCTAssertEqual(ARStillCaptureGates.lateralSpeed(velocity: SIMD3(0.3, 0.4, 0), cameraToWorld: camera), 0.5, accuracy: 1e-6)
    }

    func testViewpointChangeSeparatesPanFromSidestep() {
        let start = pose(.zero)
        // Pure pan: 10 degrees of rotation, no parallax.
        let pan = ARStillCaptureGates.viewpointChange(from: start, to: pose(.zero, yawDeg: 10), depth: 1)
        XCTAssertEqual(pan.rotationDeg, 10, accuracy: 0.01)
        XCTAssertEqual(pan.parallaxDeg, 0, accuracy: 1e-6)
        // Pure sidestep of 0.1 m with the scene 1 m away: atan(0.1) = 5.71 degrees of parallax.
        let side = ARStillCaptureGates.viewpointChange(from: start, to: pose(SIMD3(0.1, 0, 0)), depth: 1)
        XCTAssertEqual(side.rotationDeg, 0, accuracy: 0.01)
        XCTAssertEqual(side.parallaxDeg, atan(0.1) * 180 / .pi, accuracy: 0.01)
        // Walking straight at the scene is not parallax.
        let forward = ARStillCaptureGates.viewpointChange(from: start, to: pose(SIMD3(0, 0, -0.3)), depth: 1)
        XCTAssertEqual(forward.parallaxDeg, 0, accuracy: 1e-6)
    }

    func testImageMotionSmearPanSidestepAndOrbit() {
        let f = 3000.0, exposure = 1.0 / 120, half = (w: 0.6, h: 0.45)
        func smear(_ a: simd_float4x4, _ b: simd_float4x4, depth: Double = 1, corner: Double = 0) -> Double {
            ARStillCaptureGates.imageMotionSmear(from: a, to: b, dt: 0.1, depth: depth, exposure: exposure,
                                                 focalPx: f, halfWidthNorm: half.w, halfHeightNorm: half.h,
                                                 cornerFraction: corner)
        }
        // Standing still: nothing moves.
        XCTAssertEqual(smear(pose(.zero), pose(.zero)), 0, accuracy: 1e-9)
        // Pan 1 degree in 0.1 s (10 deg/s) at the centre: omega * f * t = 0.1745 * 3000 / 120.
        let pan = smear(pose(.zero), pose(.zero, yawDeg: 1))
        XCTAssertEqual(pan, (10 * Double.pi / 180) * f * exposure, accuracy: 0.05)
        // Sidestep 1 cm in 0.1 s (0.1 m/s) with the scene 1 m away: v / Z * f * t = 2.5 px.
        XCTAssertEqual(smear(pose(.zero), pose(SIMD3(0.01, 0, 0))), 0.1 * f * exposure, accuracy: 0.01)
        // Orbit: step sideways while turning to keep a point 1 m ahead centred; at that depth the
        // two motions cancel and the centre barely moves, while the magnitude sum would not.
        let step: Float = 0.01
        let orbitYaw = atan(step / 1) * 180 / .pi     // turn toward the target by the parallax angle
        let orbit = smear(pose(.zero), pose(SIMD3(step, 0, 0), yawDeg: orbitYaw), depth: 1)
        XCTAssertLessThan(orbit, 0.1 * pan, "orbiting a point at the gate depth should nearly cancel")
        // Corners see more than the centre under roll.
        let roll = simd_float4x4(simd_quatf(angle: 1 * .pi / 180, axis: SIMD3(0, 0, 1)))
        XCTAssertGreaterThan(smear(pose(.zero), roll, corner: 0.8), smear(pose(.zero), roll, corner: 0) + 1)
    }

    func testShortExposureCap() {
        func cap(_ e: Double, _ iso: Double, offset: Double = 0) -> Double {
            ARStillCaptureGates.shortExposureCap(exposure: e, iso: iso, targetOffsetEV: offset,
                                                 isoCeiling: 800, floor: 1.0 / 500, cap: 1.0 / 120)
        }
        // The first AR capture's median light: 1/120 s at ISO 157 -> ISO 800 reached at 1/611 s,
        // which is past the floor, so the floor wins.
        XCTAssertEqual(cap(1.0 / 120, 157), 1.0 / 500, accuracy: 1e-9)
        // Its 90th-percentile dim still: 1/120 at ISO 501 -> 1/192 s.
        XCTAssertEqual(cap(1.0 / 120, 501), 501.0 / 120 / 800, accuracy: 1e-9)
        // Too dark to go shorter than the cap: stays at 1/120 (ISO above the ceiling is accepted).
        XCTAssertEqual(cap(1.0 / 120, 2000), 1.0 / 120, accuracy: 1e-9)
        // The same light measured after a shorter cap was applied gives the same answer.
        XCTAssertEqual(cap(1.0 / 240, 1002), cap(1.0 / 120, 501), accuracy: 1e-9)
        // Underexposed by 1 EV (ISO pinned): twice the light is needed, so the cap lengthens.
        XCTAssertEqual(cap(1.0 / 300, 800, offset: -1), 2.0 / 300, accuracy: 1e-9)
        // A wild offset is clamped to 2 EV.
        XCTAssertEqual(cap(1.0 / 400, 200, offset: -10), cap(1.0 / 400, 200, offset: -2), accuracy: 1e-12)
        // Bad readings fall back to the cap.
        XCTAssertEqual(cap(0, 100), 1.0 / 120, accuracy: 1e-12)
    }

    func testSpacingDecision() {
        func decide(_ since: Double, _ rot: Double, _ par: Double,
                    min: Double = 0, threshold: Double = 6, max: Double = 0) -> String? {
            ARStillCaptureGates.spacingDecision(sinceLast: since, rotationDeg: rot, parallaxDeg: par,
                                                minInterval: min, viewpointThresholdDeg: threshold, maxInterval: max)
        }
        XCTAssertEqual(decide(.infinity, 0, 0), "first")
        XCTAssertNil(decide(0.5, 3, 3), "not enough change either way")
        XCTAssertEqual(decide(0.5, 6, 0), "rotation")
        XCTAssertEqual(decide(0.5, 0, 6), "parallax")
        XCTAssertNil(decide(10, 0, 0), "no timeout: a long pause yields one still")
        XCTAssertEqual(decide(1.0, 0, 0, max: 1), "time")
        XCTAssertEqual(decide(0.01, 0, 0, threshold: 0), "unspaced")
        XCTAssertNil(decide(0.2, 90, 90, min: 0.5), "below the floor nothing fires")
    }

    func testGyroHistoryPeakAndRateAtTime() {
        var history = ARStillCaptureGates.GyroHistory(capacity: 4)
        XCTAssertNil(history.latest)
        XCTAssertEqual(history.peak(window: 0.05), 0)
        XCTAssertNil(history.rate(at: 1))
        // 100 Hz: 0.1, 0.5 (a shake peak), 0.2, 0.3 rad/s.
        for (i, rate) in [0.1, 0.5, 0.2, 0.3].enumerated() { history.append(time: 1 + Double(i) * 0.01, rate: rate) }
        XCTAssertEqual(history.latest, 0.3)
        XCTAssertEqual(history.peak(window: 0), 0.3, "the newest sample is always in the window")
        XCTAssertEqual(history.peak(window: 0.015), 0.3)
        XCTAssertEqual(history.peak(window: 0.025), 0.5, "the peak 20 ms back is caught")
        // Interpolated between neighbours; past the newest within the gap; too old is unknown.
        XCTAssertEqual(history.rate(at: 1.005)!, 0.3, accuracy: 1e-9)
        XCTAssertEqual(history.rate(at: 1.04)!, 0.3, accuracy: 1e-9)
        XCTAssertNil(history.rate(at: 1.2))
        XCTAssertNil(history.rate(at: 0.9))
        // The ring drops the oldest: 0.1 at t=1.00 is gone, so t=1.00 is no longer covered.
        history.append(time: 1.04, rate: 0.4)
        XCTAssertNil(history.rate(at: 0.99))
        XCTAssertEqual(history.peak(window: 1), 0.5)
        history.append(time: 1.05, rate: 0.1)
        XCTAssertEqual(history.peak(window: 1), 0.4, "0.5 fell out of the ring")
    }

    func testRegionViewInFrameCoverageAndDirection() {
        // A 0.5 m box 2 m in front of a camera at the origin looking down -Z.
        var box = matrix_identity_float4x4
        box.columns.3 = SIMD4(0, 0, -2, 1)
        let half = SIMD3<Float>(0.25, 0.25, 0.25)
        func view(_ camera: simd_float4x4) -> ARStillCaptureGates.RegionView {
            ARStillCaptureGates.regionView(boxToWorld: box, halfExtents: half, cameraToWorld: camera,
                                           fx: 1000, fy: 1000, cx: 960, cy: 720, width: 1920, height: 1440)
        }
        let ahead = view(pose(.zero))
        XCTAssertTrue(ahead.centreInFrame)
        XCTAssertEqual(ahead.distance, 2, accuracy: 1e-5)
        // Near face at 1.75 m spans 500 px / 1.75 = 286 px each way: about 3% of the frame.
        XCTAssertEqual(ahead.frameCoverage, (500 / 1.75) * (500 / 1.75) / (1920 * 1440), accuracy: 1e-3)
        // The camera sits on the box's +Z side, level with it.
        XCTAssertEqual(ahead.azimuthDeg, 0, accuracy: 1e-3)
        XCTAssertEqual(ahead.elevationDeg, 0, accuracy: 1e-3)
        // Turned 90 degrees away: out of view.
        XCTAssertFalse(view(pose(.zero, yawDeg: 90)).centreInFrame)
        // Behind the camera entirely.
        var behind = box
        behind.columns.3 = SIMD4(0, 0, 2, 1)
        let back = ARStillCaptureGates.regionView(boxToWorld: behind, halfExtents: half, cameraToWorld: pose(.zero),
                                                  fx: 1000, fy: 1000, cx: 960, cy: 720, width: 1920, height: 1440)
        XCTAssertFalse(back.centreInFrame)
        XCTAssertEqual(back.frameCoverage, 0)
        // From above: 2 m up and 2 m back, the camera is 45 degrees above the box.
        XCTAssertEqual(view(pose(SIMD3(0, 2, 0))).elevationDeg, 45, accuracy: 1e-3)
    }

    func testCoverageBinsAndRegionViewAngle() {
        let edges = [20.0, 50.0]
        XCTAssertEqual(ARStillCaptureGates.coverageBin(azimuthDeg: 0, elevationDeg: 0, azimuthBins: 12, elevationEdgesDeg: edges), 0)
        XCTAssertEqual(ARStillCaptureGates.coverageBin(azimuthDeg: 359, elevationDeg: 10, azimuthBins: 12, elevationEdgesDeg: edges), 11)
        XCTAssertEqual(ARStillCaptureGates.coverageBin(azimuthDeg: 45, elevationDeg: 30, azimuthBins: 12, elevationEdgesDeg: edges), 12 + 1)
        XCTAssertEqual(ARStillCaptureGates.coverageBin(azimuthDeg: -15, elevationDeg: 80, azimuthBins: 12, elevationEdgesDeg: edges), 24 + 11)
        let centre = SIMD3<Float>(0, 0, 0)
        XCTAssertEqual(ARStillCaptureGates.regionViewAngleDeg(from: SIMD3(1, 0, 0), to: SIMD3(0, 0, 1), centre: centre), 90, accuracy: 1e-4)
        XCTAssertEqual(ARStillCaptureGates.regionViewAngleDeg(from: SIMD3(1, 0, 0), to: SIMD3(2, 0, 0), centre: centre), 0, accuracy: 1e-4,
                       "walking straight at the region does not change the view of it")
    }

    func testDepthPercentileSkipsInvalidAndLowConfidence() {
        let depths: [Float] = [0, .nan, 0.5, 1.0, 1.5, 2.0, 3.0, 9.0]
        let conf: [UInt8] = [2, 2, 0, 2, 2, 2, 2, 1]
        // Valid with confidence >= 1: 1.0, 1.5, 2.0, 3.0, 9.0; the 0.5 m sample is confidence 0.
        XCTAssertEqual(ARStillCaptureGates.depthPercentile(depths, confidences: conf, minConfidence: 1, percentile: 0, minSamples: 1), 1.0)
        XCTAssertEqual(ARStillCaptureGates.depthPercentile(depths, confidences: conf, minConfidence: 1, percentile: 0.5, minSamples: 1), 2.0)
        XCTAssertNil(ARStillCaptureGates.depthPercentile(depths, confidences: conf, minConfidence: 1, percentile: 0.5, minSamples: 6))
    }
}
