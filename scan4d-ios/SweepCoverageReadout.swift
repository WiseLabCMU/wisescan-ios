import SwiftUI

/// Developer readout of the live sweep-coverage counters (Developer Mode › Perf Diagnostics ›
/// Live Coverage Readout), so a device run can watch coverage accrue instead of reading
/// [Coverage] log lines afterwards. Numbers only: no per-cell rendering of any kind.
///
/// Cost: the caller inserts this view only while recording with both switches on, so when it
/// is absent there is no timer and no read. While present, a 1 Hz `TimelineView` drives one
/// `liveStats()` per tick — a few lock-guarded struct copies, never the recorder's queue and
/// never `freezeAndSnapshot()`, which would stop the sweep.
///
/// Holds the store (a reference, compared by identity) rather than a closure, so a parent
/// re-render does not re-run this body and add reads between ticks. The hook it calls is
/// `@ObservationIgnored`, so reading it subscribes to nothing.
struct SweepCoverageReadout: View {
    let scanStore: ScanStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(verbatim: Self.lines(scanStore.sweepCoverageLiveStats?()))
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.45))
                .cornerRadius(8)
        }
        .allowsHitTesting(false)
    }

    /// The three readout lines. `nil` means the capture view's hook is gone.
    static func lines(_ stats: SweepCoverageLiveStats?) -> String {
        guard let stats else { return "cov --" }
        let millis = { (nanos: UInt64) in String(format: "%.1f", Double(nanos) / 1_000_000) }
        let depth = stats.depthEverAvailable ? "" : " nodepth"
        return """
            cov surf \(stats.surfaceCells) free \(stats.freeCells)\(depth)
            upd \(stats.updates) drop \(stats.framesDroppedBusy)/\(stats.framesDroppedRate) skip \(stats.framesSkippedTracking)/\(stats.framesSkippedNoDepth)
            cpu \(millis(stats.lastUpdateCPUNs))ms avg \(millis(stats.meanUpdateCPUNs)) max \(millis(stats.maxUpdateCPUNs))
            """
    }
}
