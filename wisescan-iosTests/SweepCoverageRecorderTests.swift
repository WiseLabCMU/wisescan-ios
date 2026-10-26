import XCTest
import ARKit
import simd
import os
@testable import wisescan_ios

/// Guards `SweepCoverageRecorder.liveStats()`, the non-freezing read behind the live coverage
/// readout: zero at `begin()`, tracks processed updates, keeps answering after the Stop-tap
/// freeze, and is safe to read while the coverage queue is integrating.
///
/// Frames go in through `offer(sample:timestamp:)` — the same accepting check, throttle and
/// queue as `offer(_:)`, minus the ARFrame, which cannot be built outside a running session.
final class SweepCoverageRecorderTests: XCTestCase {

    /// A sample whose rays all go through the principal point: straight down -Z from `origin`.
    /// From the default origin (cell 0,0,0) a 2 m ray frees z = 0…-3 and hits z = -4; a 1 m ray
    /// frees z = 0,-1 and hits z = -2.
    private func sample(depths: [Float],
                        origin: SIMD3<Float> = SIMD3(0.25, 0.25, 0.25)) -> SweepCoverageRecorder.FrameSample {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(origin, 1)
        return SweepCoverageRecorder.FrameSample(
            transform: transform, focalX: 100, focalY: 100, centerX: 10, centerY: 10,
            depths: depths,
            confidences: Array(repeating: UInt8(ARConfidenceLevel.high.rawValue), count: depths.count),
            pixels: Array(repeating: SIMD2<Int32>(10, 10), count: depths.count))
    }

    /// Polls until the mirror shows `updates` (bounded; no fixed sleeps). An update is published
    /// only after its in-flight slot is released, so the next offer is never a busy drop.
    private func waitForUpdates(_ recorder: SweepCoverageRecorder, _ updates: Int,
                                file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while recorder.liveStats().updates < updates {
            guard Date() < deadline else {
                XCTFail("timed out waiting for update \(updates)", file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    func testZeroBeforeAndImmediatelyAfterBegin() {
        let recorder = SweepCoverageRecorder()
        XCTAssertEqual(recorder.liveStats(), SweepCoverageLiveStats())
        recorder.begin()
        XCTAssertEqual(recorder.liveStats(), SweepCoverageLiveStats())
    }

    func testBeginZeroesThePreviousRecording() {
        let recorder = SweepCoverageRecorder()
        recorder.begin()
        recorder.offer(sample: sample(depths: [2]), timestamp: 0)
        waitForUpdates(recorder, 1)
        XCTAssertNotEqual(recorder.liveStats(), SweepCoverageLiveStats())
        _ = recorder.freezeAndSnapshot()
        recorder.begin()
        XCTAssertEqual(recorder.liveStats(), SweepCoverageLiveStats())
    }

    func testReflectsProcessedUpdates() {
        let recorder = SweepCoverageRecorder()
        recorder.begin()

        recorder.offer(sample: sample(depths: [2]), timestamp: 0)
        waitForUpdates(recorder, 1)
        var live = recorder.liveStats()
        XCTAssertEqual(live.updates, 1)
        XCTAssertEqual(live.freeCells, 4)
        XCTAssertEqual(live.surfaceCells, 1)
        XCTAssertTrue(live.depthEverAvailable)
        XCTAssertEqual(live.framesDroppedBusy, 0)
        XCTAssertEqual(live.framesDroppedRate, 0)
        XCTAssertEqual(live.framesSkippedTracking, 0)
        XCTAssertEqual(live.framesSkippedNoDepth, 0)
        // One update: last, mean and max are the same measurement.
        XCTAssertEqual(live.lastUpdateCPUNs, live.maxUpdateCPUNs)
        XCTAssertEqual(live.meanUpdateCPUNs, live.maxUpdateCPUNs)

        // Inside the 5 Hz window with nothing in flight: a rate drop, reported live.
        recorder.offer(sample: sample(depths: [1]), timestamp: 0.05)
        live = recorder.liveStats()
        XCTAssertEqual(live.framesDroppedRate, 1)
        XCTAssertEqual(live.framesDroppedBusy, 0)
        XCTAssertEqual(live.updates, 1)

        // z = -2 was free; now it is a surface too. Free count unchanged, surface count grows.
        recorder.offer(sample: sample(depths: [1]), timestamp: 1)
        waitForUpdates(recorder, 2)
        live = recorder.liveStats()
        XCTAssertEqual(live.updates, 2)
        XCTAssertEqual(live.freeCells, 4)
        XCTAssertEqual(live.surfaceCells, 2)
        XCTAssertGreaterThanOrEqual(live.maxUpdateCPUNs, live.lastUpdateCPUNs)
        XCTAssertGreaterThanOrEqual(live.maxUpdateCPUNs, live.meanUpdateCPUNs)

        // The live counts agree with the frozen record and a full recount of its cells.
        let snapshot = recorder.freezeAndSnapshot()
        XCTAssertEqual(Int(snapshot.stats.framesProcessed), live.updates)
        XCTAssertEqual(snapshot.stats.framesDroppedRate, live.framesDroppedRate)
        XCTAssertEqual(snapshot.cells.values.filter { $0.free > 0 }.count, live.freeCells)
        XCTAssertEqual(snapshot.cells.values.filter { $0.surface > 0 }.count, live.surfaceCells)
    }

    func testKeepsAnsweringUnchangedAfterFreeze() {
        let recorder = SweepCoverageRecorder()
        recorder.begin()
        recorder.offer(sample: sample(depths: [2]), timestamp: 0)
        waitForUpdates(recorder, 1)
        let before = recorder.liveStats()

        _ = recorder.freezeAndSnapshot()
        XCTAssertEqual(recorder.liveStats(), before)

        // A frozen recorder takes no more frames, so the readout stays put — even after a
        // second freeze has drained the queue.
        recorder.offer(sample: sample(depths: [1]), timestamp: 5)
        XCTAssertEqual(recorder.liveStats(), before)
        _ = recorder.freezeAndSnapshot()
        XCTAssertEqual(recorder.liveStats(), before)
    }

    func testConcurrentReadsDuringProcessing() {
        let recorder = SweepCoverageRecorder()
        recorder.begin()

        let stop = OSAllocatedUnfairLock(initialState: false)
        let tally = OSAllocatedUnfairLock(initialState: (reads: 0, regressions: 0))
        let readerStarted = DispatchSemaphore(value: 0)
        let readerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var previous = SweepCoverageLiveStats()
            readerStarted.signal()
            while !stop.withLock({ $0 }) {
                let live = recorder.liveStats()
                // Within one recording every counter only grows.
                let regressed = live.updates < previous.updates
                    || live.freeCells < previous.freeCells
                    || live.surfaceCells < previous.surfaceCells
                    || live.framesDroppedBusy < previous.framesDroppedBusy
                    || live.maxUpdateCPUNs < previous.maxUpdateCPUNs
                tally.withLock {
                    $0.reads += 1
                    if regressed { $0.regressions += 1 }
                }
                previous = live
            }
            readerDone.signal()
        }

        XCTAssertEqual(readerStarted.wait(timeout: .now() + 5), .success)

        // Offered back to back, far faster than the queue drains, until 30 updates have landed
        // (this thread reading `liveStats()` too, as main would). Timestamps 1 s apart, so each
        // frame is either admitted or busy-dropped: never rate-dropped, never queued.
        let targetUpdates = 30
        var offered = 0
        let deadline = Date().addingTimeInterval(20)
        while recorder.liveStats().updates < targetUpdates, Date() < deadline {
            let origin = SIMD3<Float>(Float(offered % 20) * 0.5 + 0.25, 0.25, Float(offered % 7) * 0.5 + 0.25)
            recorder.offer(sample: sample(depths: Array(repeating: 1.5 + Float(offered % 5), count: 40),
                                          origin: origin),
                           timestamp: TimeInterval(offered))
            offered += 1
        }
        let snapshot = recorder.freezeAndSnapshot()   // drains the last in-flight update
        let final = recorder.liveStats()

        stop.withLock { $0 = true }
        XCTAssertEqual(readerDone.wait(timeout: .now() + 5), .success)
        let result = tally.withLock { $0 }
        XCTAssertGreaterThan(result.reads, 0)
        XCTAssertEqual(result.regressions, 0)

        XCTAssertGreaterThanOrEqual(final.updates, targetUpdates)
        XCTAssertEqual(final.framesDroppedRate, 0)
        XCTAssertEqual(final.updates + Int(final.framesDroppedBusy), offered)
        XCTAssertEqual(final.updates, Int(snapshot.stats.framesProcessed))
        XCTAssertEqual(final.framesDroppedBusy, snapshot.stats.framesDroppedBusy)
        XCTAssertEqual(snapshot.cells.values.filter { $0.free > 0 }.count, final.freeCells)
        XCTAssertEqual(snapshot.cells.values.filter { $0.surface > 0 }.count, final.surfaceCells)
    }
}
