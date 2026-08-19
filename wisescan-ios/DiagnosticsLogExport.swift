import Foundation
import OSLog
import UIKit

/// Pulls this app's own unified-log entries back out on-device, so a field run can be
/// diagnosed with no Mac, no cable, and no debug session attached.
///
/// WHY THIS EXISTS: everything worth reading after an untethered run — the sway
/// measurements, the shutter probe, per-face mask verdicts, export outcomes — goes
/// through `Logger`/`PerfDiag`, which writes to the unified log. Without a host, that log
/// is only reachable through a full sysdiagnose, which is a large archive and awkward to
/// share. `OSLogStore` lets the app read its own entries and hand back a plain text file.
///
/// TWO LIMITS, both worth knowing before relying on it:
///  1. iOS permits only `.currentProcessIdentifier` scope, so this captures THIS LAUNCH
///     ONLY. If the app was killed or relaunched since the run you care about, its
///     entries are out of reach here — sysdiagnose (hold both volume buttons + power
///     briefly, then Settings → Privacy & Security → Analytics & Improvements →
///     Analytics Data) is the fallback, and it does span launches.
///  2. `print()` does NOT go to the unified log, so it cannot be recovered this way at
///     all — only `Logger` and `PerfDiag.log`. That is the practical argument for
///     promoting anything field-diagnostic off `print`.
enum DiagnosticsLogExport {

    static let subsystem = "org.arenaxr.scan4d"

    /// Formatted log text for this launch, newest last. `since` defaults to process
    /// start. Runs off-main by contract: `getEntries` walks the whole store.
    nonisolated static func collect(since: Date? = nil) throws -> String {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let start = since ?? Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime)
        let position = store.position(date: start)
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        var lines: [String] = []
        for case let entry as OSLogEntryLog in try store.getEntries(at: position)
        where entry.subsystem == subsystem {
            lines.append("\(formatter.string(from: entry.date)) [\(entry.category)] \(entry.composedMessage)")
        }
        guard !lines.isEmpty else {
            return "No \(subsystem) entries in this launch.\n\n"
                + "If the run you want predates this launch, use sysdiagnose instead — "
                + "OSLogStore on iOS can only read the current process.\n"
        }
        let header = """
        Scan4D diagnostics — \(lines.count) entries
        device: \(UIDevice.current.model) · iOS \(UIDevice.current.systemVersion)
        performance diagnostics: \(PerfDiag.enabled ? "ON" : "OFF — most tuning lines are suppressed")

        """
        return header + lines.joined(separator: "\n") + "\n"
    }

    /// Writes the collected log to a shareable file and returns its URL.
    nonisolated static func writeToFile(since: Date? = nil) -> URL? {
        guard let text = try? collect(since: since) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan4d-diagnostics-\(stamp).txt")
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url
    }
}

///  needs Identifiable; a file URL is its own identity here.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
