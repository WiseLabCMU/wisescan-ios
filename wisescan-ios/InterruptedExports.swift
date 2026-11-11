import Foundation
import SwiftData

// MARK: - Exports a closed app left in flight

/// At launch no process is building an export any more, so a scan the database still shows as
/// converting is marked failed, and its card offers Share again. Before this sweep a killed app
/// left such a scan in flight forever, and the in-flight guard (`UploadStatus.isInFlight`) then
/// refused every retry.
///
/// Builds with the Upload button could also leave a scan "uploading", with the export staged in
/// Application Support/PendingUploads. Nothing sends those now (sync sends bundles in its own
/// background session, `BundleSync`), so they are failed too and the folder is deleted.
@MainActor
enum InterruptedExports {
    /// The status a scan shows when its export died with the app.
    static let message = "Interrupted, try again"

    /// The stored statuses of a scan an export or an older build's upload still owned.
    nonisolated static func isInterrupted(status: String) -> Bool {
        status == "zipping" || status == "uploading"
    }

    /// Marks every interrupted scan failed and removes the older builds' staged uploads. Call once
    /// at launch, before any UI starts an export.
    static func sweep(_ context: ModelContext) {
        let stale = ((try? context.fetch(FetchDescriptor<CapturedScan>(
            predicate: #Predicate { $0.uploadStatusStr == "zipping" || $0.uploadStatusStr == "uploading" }))) ?? [])
            .filter { isInterrupted(status: $0.uploadStatusStr) }
        for scan in stale {
            scan.uploadStatus = .failed(message)
        }
        if !stale.isEmpty {
            try? context.save()
            print("[Export] launch: \(stale.count) interrupted scan(s) marked failed")
        }
        let legacy = URL.applicationSupportDirectory.appending(path: AppConstants.legacyPendingUploadsDirectory)
        try? FileManager.default.removeItem(at: legacy)
    }
}
