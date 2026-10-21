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

    func testDepthPercentileSkipsInvalidAndLowConfidence() {
        let depths: [Float] = [0, .nan, 0.5, 1.0, 1.5, 2.0, 3.0, 9.0]
        let conf: [UInt8] = [2, 2, 0, 2, 2, 2, 2, 1]
        // Valid with confidence >= 1: 1.0, 1.5, 2.0, 3.0, 9.0; the 0.5 m sample is confidence 0.
        XCTAssertEqual(ARStillCaptureGates.depthPercentile(depths, confidences: conf, minConfidence: 1, percentile: 0, minSamples: 1), 1.0)
        XCTAssertEqual(ARStillCaptureGates.depthPercentile(depths, confidences: conf, minConfidence: 1, percentile: 0.5, minSamples: 1), 2.0)
        XCTAssertNil(ARStillCaptureGates.depthPercentile(depths, confidences: conf, minConfidence: 1, percentile: 0.5, minSamples: 6))
    }
}
