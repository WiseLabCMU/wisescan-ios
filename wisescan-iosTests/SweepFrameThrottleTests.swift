import XCTest
@testable import wisescan_ios

/// Guards the sweep-coverage admission gate. The property that matters most is that nothing is
/// ever queued: a busy drop must neither backlog work nor shift the next admission window
/// (gen-8: a probe contending with ARKit corrupted the scan it measured).
final class SweepFrameThrottleTests: XCTestCase {
    private let interval: TimeInterval = 0.2 // 5 Hz

    func testFirstFrameIsAdmitted() {
        var t = SweepFrameThrottle(minInterval: interval)
        XCTAssertEqual(t.offer(timestamp: 0.0), .admitted)
        XCTAssertEqual(t.lastAccepted, 0.0)
        XCTAssertTrue(t.inFlight)
    }

    func testFrameWhileInFlightIsDroppedBusyWithoutAdvancingWindow() {
        var t = SweepFrameThrottle(minInterval: interval)
        XCTAssertEqual(t.offer(timestamp: 0.0), .admitted)
        XCTAssertEqual(t.offer(timestamp: 0.05), .droppedBusy)
        XCTAssertEqual(t.droppedBusy, 1)
        XCTAssertEqual(t.droppedRate, 0)
        XCTAssertEqual(t.lastAccepted, 0.0)
    }

    func testFrameInsideIntervalAfterFinishIsDroppedRate() {
        var t = SweepFrameThrottle(minInterval: interval)
        XCTAssertEqual(t.offer(timestamp: 0.0), .admitted)
        t.finish()
        XCTAssertFalse(t.inFlight)
        XCTAssertEqual(t.offer(timestamp: 0.1), .droppedRate)
        XCTAssertEqual(t.droppedRate, 1)
        XCTAssertEqual(t.droppedBusy, 0)
        XCTAssertEqual(t.lastAccepted, 0.0)
    }

    func testFrameAtIntervalIsAdmitted() {
        var t = SweepFrameThrottle(minInterval: interval)
        XCTAssertEqual(t.offer(timestamp: 0.0), .admitted)
        t.finish()
        XCTAssertEqual(t.offer(timestamp: 0.2), .admitted)
        XCTAssertEqual(t.lastAccepted, 0.2)
    }

    func testRapidOffersWhileInFlightQueueNothing() {
        var t = SweepFrameThrottle(minInterval: interval)
        var admitted = 0
        var busy = 0
        for i in 0..<100 {
            switch t.offer(timestamp: 0.0 + Double(i) * 0.001) {
            case .admitted: admitted += 1
            case .droppedBusy: busy += 1
            case .droppedRate: XCTFail("rate drop while in flight")
            }
        }
        XCTAssertEqual(admitted, 1)
        XCTAssertEqual(busy, 99)
        XCTAssertEqual(t.droppedBusy, 99)
        XCTAssertEqual(t.lastAccepted, 0.0)

        t.finish()
        // Nothing was queued: the next decision depends only on the original lastAccepted (0.0),
        // not on any of the 99 busy-dropped timestamps (up to 0.099).
        XCTAssertFalse(t.inFlight)
        XCTAssertEqual(t.offer(timestamp: 0.19), .droppedRate)
        XCTAssertFalse(t.inFlight)
        XCTAssertEqual(t.offer(timestamp: 0.2), .admitted)
        XCTAssertEqual(t.lastAccepted, 0.2)
    }

    func testResetReadmitsImmediately() {
        var t = SweepFrameThrottle(minInterval: interval)
        XCTAssertEqual(t.offer(timestamp: 0.0), .admitted)
        XCTAssertEqual(t.offer(timestamp: 0.01), .droppedBusy)
        t.reset()
        XCTAssertNil(t.lastAccepted)
        XCTAssertFalse(t.inFlight)
        XCTAssertEqual(t.droppedBusy, 0)
        XCTAssertEqual(t.droppedRate, 0)
        XCTAssertEqual(t.minInterval, interval)
        XCTAssertEqual(t.offer(timestamp: 0.02), .admitted)
    }

    func testBackwardsTimestampIsAdmittedAndRestartsWindow() {
        var t = SweepFrameThrottle(minInterval: interval)
        XCTAssertEqual(t.offer(timestamp: 100.0), .admitted)
        t.finish()
        XCTAssertEqual(t.offer(timestamp: 1.0), .admitted)
        XCTAssertEqual(t.lastAccepted, 1.0)
        t.finish()
        XCTAssertEqual(t.offer(timestamp: 1.1), .droppedRate)
    }
}
