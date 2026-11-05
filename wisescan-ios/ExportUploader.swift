import Foundation
import SwiftData

// MARK: - Export uploads that survive a locked screen

/// Sends export files in a background `URLSession`, so an upload keeps going with the screen
/// locked, the app in the background, or the app closed by iOS.
///
/// WHY: uploads used an ordinary session, which iOS cuts off seconds after the app leaves the
/// screen. A ten-minute upload failed unless the operator kept touching the screen. A background
/// session hands the transfer to the system, which finishes it and relaunches the app in the
/// background if needed to report the result. (`ScreenAwake` keeps the screen on during the zip
/// build, which still needs the app in front.)
///
/// HOW IT DIFFERS FROM A COMPLETION HANDLER: background sessions take no per-task closures, and
/// the app may not be the same process when a transfer ends. So each task carries a `Ticket` in
/// its `taskDescription` (scan id, control-plane export id, staged file), and this delegate looks
/// the scan up by id to set its status, progress and `lastUploadedAt`, deletes the staged file,
/// and reports the export to the control plane. A caller still running when the transfer ends
/// also gets its `onFinish` (bulk counters, the card's refresh).
///
/// THE FILE: exports are built in the temp folder, which iOS may purge while the app is not
/// running. Each one is moved to Application Support/PendingUploads (not backed up) and removed
/// when its transfer ends, or at the next launch if its transfer is gone.
///
/// AT LAUNCH (`start`): the session is re-created at once so iOS can deliver events for transfers
/// that ended while the app was closed. Scans the database still shows as converting, or as
/// uploading with no transfer left, are marked failed: before this, a killed app left them
/// "Uploading" forever, and the in-flight guard then refused every retry.
///
/// Scope: scan exports only. The control plane's map-package uploads (`ControlPlaneSync`) still
/// use its ordinary session.
@MainActor
final class ExportUploader: NSObject {
    static let shared = ExportUploader()

    /// What a task carries, so a relaunched app knows what the transfer was for.
    nonisolated struct Ticket: Codable, Equatable, Sendable {
        var scanId: UUID
        /// The control plane's export id, when it granted the destination (reported on success).
        var exportId: String?
        /// The staged file's name in the pending folder.
        var file: String

        var encoded: String? {
            (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
        }

        static func decode(_ description: String?) -> Ticket? {
            guard let data = description?.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(Ticket.self, from: data)
        }
    }

    nonisolated enum Outcome: Equatable, Sendable {
        case success
        case failed(String)

        /// An HTTP 2xx with no transport error is success; anything else is the reason.
        static func of(statusCode: Int?, error: Error?) -> Outcome {
            if let error { return .failed(error.localizedDescription) }
            guard let statusCode else { return .failed("No response") }
            return (200...299).contains(statusCode) ? .success : .failed("Server error (\(statusCode))")
        }
    }

    /// The status a scan shows when its export or upload died with the app.
    nonisolated static let interruptedMessage = "Interrupted, upload again"

    /// Scans to mark failed at launch: every one still converting (no process is building its zip
    /// any more), and every one uploading whose transfer the system no longer has.
    nonisolated static func interrupted(inFlight: [(id: UUID, status: String)], liveScanIds: Set<UUID>) -> [UUID] {
        inFlight.compactMap { scan in
            scan.status == "uploading" && liveScanIds.contains(scan.id) ? nil : scan.id
        }
    }

    private var session: URLSession!
    private var finishHandlers: [Int: @MainActor (Outcome) -> Void] = [:]
    private var lastProgress: [Int: Double] = [:]
    /// Handed over by the app delegate when iOS relaunches the app for this session's events;
    /// called once they have all been delivered and saved.
    var backgroundEventsCompletion: (() -> Void)?
    private var started = false

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: AppConstants.exportUploadSessionId)
        config.isDiscretionary = false            // the user is waiting: start now, not when convenient
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForResource = AppConstants.exportUploadResourceTimeoutS
        // Delegate calls on main: they only touch SwiftData's main context and small dictionaries.
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    // MARK: Launch

    /// Re-attaches to transfers from an earlier run and clears what died with it. Call once, early.
    func start() {
        guard !started else { return }
        started = true
        // Snapshots taken before the UI exists, so nothing started in this run is swept up.
        let stagedAtLaunch = (try? FileManager.default.contentsOfDirectory(
            at: Self.pendingDirectory, includingPropertiesForKeys: nil)) ?? []
        let inFlightAtLaunch = ((try? Scan4DApp.sharedModelContainer.mainContext.fetch(FetchDescriptor<CapturedScan>(
            predicate: #Predicate { $0.uploadStatusStr == "uploading" || $0.uploadStatusStr == "zipping" }))) ?? [])
            .map { (id: $0.id, status: $0.uploadStatusStr) }
        session.getAllTasks { tasks in
            let tickets = tasks.compactMap { task -> (ticket: Ticket, host: String?)? in
                Ticket.decode(task.taskDescription).map { (ticket: $0, host: task.originalRequest?.url?.host()) }
            }
            Task { @MainActor in
                ExportUploader.shared.sweep(inFlightAtLaunch: inFlightAtLaunch, stagedAtLaunch: stagedAtLaunch,
                                            tickets: tickets)
            }
        }
    }

    private func sweep(inFlightAtLaunch: [(id: UUID, status: String)], stagedAtLaunch: [URL],
                       tickets: [(ticket: Ticket, host: String?)]) {
        // A self-signed grant host is only trusted once the control plane names it; after a
        // relaunch that list is empty, so restore it for transfers the control plane granted.
        for entry in tickets where entry.ticket.exportId != nil {
            ControlPlaneSession.allow(host: entry.host)
        }
        let stale = Self.interrupted(inFlight: inFlightAtLaunch, liveScanIds: Set(tickets.map(\.ticket.scanId)))
        for id in stale {
            scan(id)?.uploadStatus = .failed(Self.interruptedMessage)
        }
        let liveFiles = Set(tickets.map(\.ticket.file))
        for file in stagedAtLaunch where !liveFiles.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
        if !stale.isEmpty { try? Scan4DApp.sharedModelContainer.mainContext.save() }
        if !stale.isEmpty || !tickets.isEmpty {
            print("[Upload] launch: \(tickets.count) transfer(s) still running, \(stale.count) interrupted scan(s) marked failed")
        }
    }

    // MARK: Uploading

    /// Sends `file`, an export just built, with `request` (the PUT from `ExportUploadTarget`).
    /// The scan should already show `.uploading`; from here this updates its progress and final
    /// status itself. `onFinish` runs on main if this process is still alive when the transfer ends.
    func upload(_ file: URL, request: URLRequest, scanId: UUID, exportId: String?,
                onFinish: (@MainActor (Outcome) -> Void)? = nil) {
        let staged = Self.stage(file)
        let ticket = Ticket(scanId: scanId, exportId: exportId, file: staged.lastPathComponent)
        let task = session.uploadTask(with: request, fromFile: staged)
        task.taskDescription = ticket.encoded
        if let onFinish { finishHandlers[task.taskIdentifier] = onFinish }
        task.resume()
    }

    /// Moves the export out of the temp folder into the pending folder, under a unique name.
    /// Falls back to the original location (fine while the app runs) if the move fails.
    private static func stage(_ file: URL) -> URL {
        let files = FileManager.default
        var folder = pendingDirectory
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            let target = folder.appendingPathComponent("\(UUID().uuidString)-\(file.lastPathComponent)")
            try files.moveItem(at: file, to: target)
            return target
        } catch {
            print("[Upload] could not stage \(file.lastPathComponent) (\(error.localizedDescription)); sending it from the temp folder")
            return file
        }
    }

    static var pendingDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(AppConstants.exportUploadPendingDirectory, isDirectory: true)
    }

    // MARK: Bookkeeping (main)

    private func scan(_ id: UUID) -> CapturedScan? {
        var descriptor = FetchDescriptor<CapturedScan>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? Scan4DApp.sharedModelContainer.mainContext.fetch(descriptor).first
    }

    private func noteProgress(_ fraction: Double, taskId: Int, description: String?) {
        let last = lastProgress[taskId] ?? 0
        guard fraction - last >= AppConstants.exportUploadProgressStep else { return }
        lastProgress[taskId] = fraction
        guard let ticket = Ticket.decode(description), let scan = scan(ticket.scanId),
              case .uploading = scan.uploadStatus else { return }
        scan.uploadStatus = .uploading(progress: fraction)
    }

    private func finish(taskId: Int, description: String?, outcome: Outcome) {
        lastProgress[taskId] = nil
        let handler = finishHandlers.removeValue(forKey: taskId)
        guard let ticket = Ticket.decode(description) else {
            handler?(outcome)
            return
        }
        try? FileManager.default.removeItem(at: Self.pendingDirectory.appendingPathComponent(ticket.file))
        if let scan = scan(ticket.scanId) {
            switch outcome {
            case .success:
                scan.uploadStatus = .success
                scan.lastUploadedAt = Date()
            case .failed(let reason):
                scan.uploadStatus = .failed(reason)
            }
            try? Scan4DApp.sharedModelContainer.mainContext.save()
        }
        if outcome == .success, let exportId = ticket.exportId {
            reportCompleted(exportId)
        }
        handler?(outcome)
    }

    /// After a successful PUT the server checks the object and announces `export.completed`.
    /// Best effort: a missed report leaves the export uploaded but unannounced.
    private func reportCompleted(_ exportId: String) {
        guard let client = ControlPlaneSync.shared.client else { return }
        Task {
            do {
                try await client.completeExport(exportId)
            } catch {
                print("[ControlPlane] export \(exportId) completion not reported: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - URLSession delegate
// URLSession calls these from outside the main actor's view, but on the main queue (the
// session's delegate queue is .main), so each one asserts that and runs its work there.

extension ExportUploader: URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                                totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        let taskId = task.taskIdentifier, description = task.taskDescription
        MainActor.assumeIsolated { noteProgress(fraction, taskId: taskId, description: description) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome = Outcome.of(statusCode: (task.response as? HTTPURLResponse)?.statusCode, error: error)
        let taskId = task.taskIdentifier, description = task.taskDescription
        MainActor.assumeIsolated { finish(taskId: taskId, description: description, outcome: outcome) }
    }

    /// The same certificate rule as the control plane's own session: the override applies only
    /// to hosts it named, and only with Allow untrusted certificates on.
    nonisolated func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = ControlPlaneSession.disposition(for: challenge)
        completionHandler(disposition, credential)
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated {
            try? Scan4DApp.sharedModelContainer.mainContext.save()
            backgroundEventsCompletion?()
            backgroundEventsCompletion = nil
        }
    }
}
