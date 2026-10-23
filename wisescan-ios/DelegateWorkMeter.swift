import Foundation
import Synchronization
import os

/// Times the AR view's per-frame delegate handler while a room scan records, the same measure the
/// focus scan's engine keeps (`ARStillCaptureSession.noteDelegateWork`): the handler runs on the
/// session's delegate queue, and a slow one holds ARKit's frames back. Owned by
/// FrameCaptureSession; the AR view's coordinator calls `note(since:)` from the delegate queue.
nonisolated final class DelegateWorkMeter: @unchecked Sendable {
    private let active = Atomic<Bool>(false)
    private let timing = OSAllocatedUnfairLock(initialState: ARStillCaptureSession.WorkTiming())

    /// Starts a fresh measurement (record start).
    func begin() {
        timing.withLock { $0 = ARStillCaptureSession.WorkTiming() }
        active.store(true, ordering: .releasing)
    }

    /// Stops measuring (record stop); the summary stays readable.
    func end() {
        active.store(false, ordering: .releasing)
    }

    /// One handler run, timed from `start` (`DispatchTime.now().uptimeNanoseconds` at its entry).
    /// No-op unless measuring.
    func note(since start: UInt64) {
        guard active.load(ordering: .acquiring) else { return }
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
        timing.withLock { $0.record(ms: ms) }
    }

    var snapshot: ARStillCaptureSession.WorkTiming { timing.withLock { $0 } }
}
