import XCTest
import simd
@testable import wisescan_ios

/// The two pure pieces of the raw-capture spacing gate. The capture pipeline itself needs a
/// device (no `AVCaptureSession` in the Simulator), so this covers what can be checked here: the
/// block-matched shift estimator and the spacing verdict.
final class RawCaptureSpacingTests: XCTestCase {
    private let width = ImageShiftEstimator.width
    private let height = ImageShiftEstimator.height

    /// Deterministic, non-periodic texture defined on all of Z², so shifted views are consistent.
    private func texture(_ x: Int, _ y: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x &* 73_856_093) ^ UInt32(truncatingIfNeeded: y &* 19_349_663)
        h ^= h >> 13
        h = h &* 0x5bd1_e995
        h ^= h >> 15
        return Float(h % 251) - 125
    }

    /// The texture seen through a window moved so that content at (x, y) in the unshifted view
    /// sits at (x + offsetX, y + offsetY) here.
    private func thumbnail(offsetX: Int, offsetY: Int) -> [Float] {
        (0..<height).flatMap { y in (0..<width).map { x in texture(x - offsetX, y - offsetY) } }
    }

    func testRecoversKnownShift() {
        var estimator = ImageShiftEstimator()
        XCTAssertNil(estimator.update(thumbnail(offsetX: 0, offsetY: 0)), "nothing to compare the first thumbnail against")
        XCTAssertEqual(estimator.update(thumbnail(offsetX: 3, offsetY: -2)), SIMD2<Float>(3, -2))
        XCTAssertEqual(estimator.update(thumbnail(offsetX: 3, offsetY: -2)), SIMD2<Float>(0, 0), "the same view again is no motion")
        XCTAssertEqual(estimator.update(thumbnail(offsetX: -2, offsetY: -2)), SIMD2<Float>(-5, 0))
    }

    func testShiftAtTheSearchLimitIsStillFound() {
        var estimator = ImageShiftEstimator()
        _ = estimator.update(thumbnail(offsetX: 0, offsetY: 0))
        let limit = ImageShiftEstimator.search
        XCTAssertEqual(estimator.update(thumbnail(offsetX: limit, offsetY: -limit)), SIMD2<Float>(Float(limit), Float(-limit)))
    }

    func testFlatFrameIsNotMotion() {
        // Every shift scores alike on a featureless frame; the decisiveness guard must call it still
        // rather than report whichever shift the scan happened to visit first.
        var estimator = ImageShiftEstimator()
        let flat = [Float](repeating: 0, count: width * height)
        _ = estimator.update(flat)
        XCTAssertEqual(estimator.update(flat), SIMD2<Float>(0, 0))
    }

    func testMismatchedSizeIsIgnored() {
        var estimator = ImageShiftEstimator()
        _ = estimator.update(thumbnail(offsetX: 0, offsetY: 0))
        XCTAssertNil(estimator.update([Float](repeating: 0, count: 10)))
    }

    func testSpacingDecision() {
        typealias Knobs = (minInterval: Double, rotation: Double, shift: Double, maxInterval: Double)
        func decide(_ sinceLast: Double, _ rotation: Double, _ shift: Double, _ k: Knobs) -> String? {
            RawCaptureSession.spacingDecision(
                sinceLast: sinceLast, rotationDeg: rotation, shiftFraction: shift,
                minInterval: k.minInterval, rotationThresholdDeg: k.rotation, shiftThreshold: k.shift,
                maxInterval: k.maxInterval)
        }
        let spaced: Knobs = (0, 8, 0.12, 0)
        XCTAssertEqual(decide(.infinity, 0, 0, spaced), "first")
        XCTAssertNil(decide(0.5, 3, 0.05, spaced), "not enough viewpoint change")
        XCTAssertEqual(decide(0.5, 8, 0.05, spaced), "rotation")
        XCTAssertEqual(decide(0.5, 3, 0.12, spaced), "shift")
        XCTAssertNil(decide(10, 0, 0, spaced), "no max interval: holds for as long as the view does not change")

        let timed: Knobs = (0, 8, 0.12, 2)
        XCTAssertNil(decide(1.9, 0, 0, timed))
        XCTAssertEqual(decide(2, 0, 0, timed), "time")

        let unspaced: Knobs = (0, 0, 0, 0)
        XCTAssertEqual(decide(0.01, 0, 0, unspaced), "unspaced")

        let floored: Knobs = (0.5, 0, 0, 0)
        XCTAssertNil(decide(0.3, 90, 1, floored), "below the hard floor nothing fires")
        XCTAssertEqual(decide(0.5, 0, 0, floored), "unspaced")
        XCTAssertEqual(decide(.infinity, 0, 0, floored), "unspaced", "the floor cannot hold the first still")
    }
}
