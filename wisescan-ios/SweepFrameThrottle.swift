import Foundation

/// Admission gate for the sweep-coverage recorder: decides, per ARKit frame, whether the frame is
/// handed to coverage processing or dropped.
///
/// Two drop reasons, counted separately so a diagnostic can tell "the device is too slow" from
/// "the rate cap is doing its job":
///   - `droppedBusy` — the previous admitted frame is still being processed. The frame is dropped
///     and the admission window is NOT advanced, so a busy drop never shifts when the next frame
///     can be admitted.
///   - `droppedRate` — the frame arrived sooner than `minInterval` after the last admitted one.
///
/// Nothing is ever queued. The gen-8 lesson applies here: a log-only probe that contended with
/// ARKit for CPU corrupted the very scan it was measuring (ICP stall), so coverage work must drop
/// frames rather than backlog them behind the capture pipeline.
///
/// This type is a plain value with no synchronization of its own. `offer(timestamp:)` runs on the
/// ARSession delegate queue and `finish()` runs on the coverage queue, so the recorder wraps it in
/// an `OSAllocatedUnfairLock` and performs every call under that lock.
struct SweepFrameThrottle: Equatable {
    enum Decision: Equatable {
        case admitted
        case droppedBusy
        case droppedRate
    }

    let minInterval: TimeInterval
    private(set) var lastAccepted: TimeInterval?
    private(set) var inFlight: Bool = false
    private(set) var droppedBusy: UInt32 = 0
    private(set) var droppedRate: UInt32 = 0

    init(minInterval: TimeInterval = 1.0 / AppConstants.sweepCoverageMaxHz) {
        self.minInterval = minInterval
    }

    /// Offers a frame at `timestamp` (ARFrame.timestamp, seconds). On `.admitted` the caller owns
    /// the in-flight slot and must call `finish()` when processing completes.
    ///
    /// A timestamp earlier than the last admitted one means the session restarted (the clock
    /// base moved); it is admitted and restarts the window rather than being rate-dropped forever.
    mutating func offer(timestamp: TimeInterval) -> Decision {
        if inFlight {
            droppedBusy &+= 1
            return .droppedBusy
        }
        if let last = lastAccepted, timestamp >= last, timestamp - last < minInterval {
            droppedRate &+= 1
            return .droppedRate
        }
        lastAccepted = timestamp
        inFlight = true
        return .admitted
    }

    /// Releases the in-flight slot taken by the last `.admitted` offer.
    mutating func finish() {
        inFlight = false
    }

    /// Clears all state (window, in-flight slot, drop counters); `minInterval` is kept.
    mutating func reset() {
        lastAccepted = nil
        inFlight = false
        droppedBusy = 0
        droppedRate = 0
    }
}
