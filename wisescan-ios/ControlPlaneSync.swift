import Foundation
import Observation
import SwiftData

// MARK: - When and how the app syncs with the control plane (scan4d-server README, "Sync")

/// Sends the whole local inventory (`ControlPlaneManifest`) to the control plane: on launch and
/// return to the foreground, a few seconds after SwiftData saves (coalesced), and from Settings.
/// Then uploads the map-package files the server answers that it wants, one at a time (Settings →
/// Send map packages). Never during a capture: a request then waits for the capture to end, so
/// the network and the file reads stay off the AR session's back. Does nothing while no server
/// host is set.
@Observable
@MainActor
final class ControlPlaneSync {
    static let shared = ControlPlaneSync()

    enum Status: Equatable {
        case off
        case idle
        case syncing
        case uploading(done: Int, total: Int)
        case synced(Date, summary: String)
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// Whether exports go through the server's grants (from the last sync).
    private(set) var uploadTarget: ControlPlaneClient.UploadTarget?
    /// Focus scans the server asked this device for, not yet answered or done.
    private(set) var openTasks: [ControlPlaneClient.ScanTask] = []
    /// The task ContentView asks about now (each once per launch).
    private(set) var taskToPrompt: ControlPlaneClient.ScanTask?

    @ObservationIgnored private var captureActive = false
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var saveObserver: NSObjectProtocol?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var deferredForCapture = false
    @ObservationIgnored private var promptedTasks: Set<UUID> = []

    private init() {}

    var host: String { UserDefaults.standard.string(forKey: AppConstants.Key.controlPlaneHost) ?? "" }
    var deviceLabel: String { UserDefaults.standard.string(forKey: AppConstants.Key.controlPlaneDeviceLabel) ?? "" }
    var sendPackages: Bool {
        UserDefaults.standard.object(forKey: AppConstants.Key.controlPlaneSendPackages) as? Bool
            ?? AppConstants.controlPlaneSendPackages
    }
    var client: ControlPlaneClient? { ControlPlaneClient.baseURL(fromHost: host).map { ControlPlaneClient(baseURL: $0) } }

    /// Once, at launch: watch SwiftData saves and sync now.
    func start(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil,
                                                              queue: .main) { _ in
            Task { @MainActor in
                ControlPlaneSync.shared.requestSync(after: .seconds(AppConstants.controlPlaneSyncDebounceS))
            }
        }
        requestSync(after: .zero)
    }

    /// Mirrors `ScanStore.isCaptureActive` (ContentView). A sync asked for during the capture
    /// runs once it ends.
    func captureStateChanged(active: Bool) {
        captureActive = active
        if !active && deferredForCapture {
            deferredForCapture = false
            requestSync(after: .seconds(AppConstants.controlPlaneSyncDebounceS))
        }
    }

    /// Coalesces: a newer request replaces a pending one.
    func requestSync(after delay: Duration) {
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard let client else {
            status = .off
            return
        }
        guard !captureActive else {
            deferredForCapture = true
            return
        }
        guard !running else {
            rerun = true
            return
        }
        guard let container else { return }
        running = true
        status = .syncing

        let context = container.mainContext
        let locations = (try? context.fetch(FetchDescriptor<ScanLocation>())) ?? []
        let links = (try? context.fetch(FetchDescriptor<StitchLink>())) ?? []
        let snapshot = ControlPlaneManifest.snapshot(locations: locations, links: links,
                                                     device: DeviceIdentity.manifestDevice(label: deviceLabel))
        let draft = snapshot.manifest
        let files = snapshot.files
        let packages = sendPackages
        do {
            // Encoding and the file reads off main (an async call from here would stay on it).
            let (result, local) = try await Task.detached(priority: .utility) {
                var manifest = draft
                let local = manifest.readScanFiles(files, packages: packages)
                let result = try await client.sync(manifest)
                return (result, local)
            }.value
            let reply = result.reply
            uploadTarget = reply.uploadTarget
            applyLinkUpdates(reply.linkUpdates ?? [])
            receive(result.tasks)
            var summary = "\(reply.maps) spaces, \(reply.scans) scans, \(reply.links) links"
            PerfDiag.log("[ControlPlane] synced: \(summary), \(reply.markedGone) marked gone, "
                         + "\(reply.wanted?.count ?? 0) files wanted")
            let wanted = packages ? (reply.wanted ?? []) : []
            if !wanted.isEmpty {
                let sent = try await upload(wanted, from: local, with: client)
                if sent < wanted.count {
                    // A capture began: the rest waits for it to end.
                    deferredForCapture = true
                    summary += "; \(wanted.count - sent) map files waiting for the scan to end"
                }
            }
            status = .synced(Date(), summary: summary)
        } catch {
            status = .failed(error.localizedDescription)
            PerfDiag.log("[ControlPlane] sync failed: \(error.localizedDescription)")
        }
        running = false
        if rerun {
            rerun = false
            requestSync(after: .seconds(AppConstants.controlPlaneSyncDebounceS))
        }
    }

    /// The map-package files the server asked for, one at a time, stopping if a capture begins.
    /// Returns how many went up. A failure ends the round; the next sync asks again.
    private func upload(_ wanted: [ControlPlaneClient.WantedFile], from local: [UUID: [String: ControlPlaneManifest.LocalFile]],
                        with client: ControlPlaneClient) async throws -> Int {
        for (index, want) in wanted.enumerated() {
            guard !captureActive else { return index }
            status = .uploading(done: index, total: wanted.count)
            // A file the server wants but the snapshot did not find (deleted since): skip it.
            guard let scanId = UUID(uuidString: want.scanId), let file = local[scanId]?[want.name] else { continue }
            do {
                _ = try await client.upload(file, scanId: want.scanId, name: want.name)
            } catch {
                throw ControlPlaneClient.Failure.transport("Uploading \(want.name): \(error.localizedDescription)")
            }
        }
        PerfDiag.log("[ControlPlane] uploaded \(wanted.count) map files")
        return wanted.count
    }

    /// Fine-tunes the server resolved for this device's links: the web's edits, or the revision
    /// number its own edit became (scan4d-server README, "Shared edits"). Saving prompts the
    /// next sync, which then reports them in step.
    private func applyLinkUpdates(_ updates: [ControlPlaneClient.LinkUpdate]) {
        guard !updates.isEmpty, let context = container?.mainContext else { return }
        var applied = 0
        for update in updates {
            guard let id = UUID(uuidString: update.linkId) else { continue }
            let descriptor = FetchDescriptor<StitchLink>(predicate: #Predicate { $0.id == id })
            guard let link = try? context.fetch(descriptor).first else { continue }
            link.manualYawDeg = update.manual.yawDeg
            link.manualDX = update.manual.dx
            link.manualDY = update.manual.dy
            link.manualDZ = update.manual.dz
            link.manualRevision = update.revision
            applied += 1
        }
        if applied > 0 {
            try? context.save()
            PerfDiag.log("[ControlPlane] applied \(applied) join fine-tune update(s)")
        }
    }

    private func receive(_ tasks: [ControlPlaneClient.ScanTask]) {
        openTasks = tasks
        guard taskToPrompt == nil,
              let next = tasks.first(where: { $0.status != "accepted" && !promptedTasks.contains($0.id) }) else { return }
        promptedTasks.insert(next.id)
        taskToPrompt = next
    }

    /// Opens the task's region in its space's editor (the deep-link path) and tells the server.
    func open(_ task: ControlPlaneClient.ScanTask) {
        taskToPrompt = nil
        FocusRegionInbox.shared.pending = task.region
        answer(task, "accepted")
    }

    func decline(_ task: ControlPlaneClient.ScanTask) {
        taskToPrompt = nil
        openTasks.removeAll { $0.id == task.id }
        answer(task, "declined")
    }

    func dismissPrompt() {
        taskToPrompt = nil
    }

    private func answer(_ task: ControlPlaneClient.ScanTask, _ status: String) {
        guard let client else { return }
        Task {
            do {
                try await client.setTaskStatus(task.id, status: status)
            } catch {
                PerfDiag.log("[ControlPlane] task \(status) not sent: \(error.localizedDescription)")
            }
        }
    }

    /// The Dashboard's check: is the control plane up?
    func isReachable() async -> Bool {
        guard let client else { return false }
        return (try? await client.health()) != nil
    }

    /// Settings' Test connection: the server's health, as a line to show.
    func testConnection() async -> String {
        guard let client else { return "Enter the server's host first." }
        do {
            let health = try await client.health()
            return "Connected: Scan4D control plane \(health.version) (API v\(health.api))."
        } catch {
            return error.localizedDescription
        }
    }
}
