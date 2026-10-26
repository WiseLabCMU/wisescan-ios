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
    /// Focus scans the server asked this device for, not yet declined or done: the to-do list
    /// (Dashboard), a worker's queue. Kept on the phone, so the list survives a relaunch while the
    /// control plane can't be reached; each sync replaces it.
    private(set) var openTasks: [ControlPlaneClient.ScanTask] = ControlPlaneSync.storedTasks()
    /// The urgent task ContentView alerts about now. Each urgent task alerts once, ever; after that,
    /// and for every normal one, the to-do list is where it waits.
    private(set) var taskToPrompt: ControlPlaneClient.ScanTask?
    /// Map-package files the server asked for that are waiting for Wi-Fi (large files go up only on
    /// an unmetered network), as of the last sync.
    private(set) var waitingForWiFi = 0

    /// The spaces this phone reports: the ones sent with Sync (a space, or a stitched map in the
    /// graph view) and, while new spaces sync on their own, those started after the phone joined.
    /// The rest stay off the server; an export's Upload is separate.
    private(set) var syncedSpaces: Set<UUID> = ControlPlaneSync.storedSpaces()

    /// To-dos not yet answered (the Dashboard tab's badge); none without a control plane.
    var unansweredTasks: Int { client == nil ? 0 : openTasks.filter { $0.status != "accepted" }.count }

    @ObservationIgnored private var captureActive = false
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var saveObserver: NSObjectProtocol?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var deferredForCapture = false
    @ObservationIgnored private var poller: Task<Void, Never>?

    private init() {}

    var host: String { UserDefaults.standard.string(forKey: AppConstants.Key.controlPlaneHost) ?? "" }
    var deviceLabel: String { UserDefaults.standard.string(forKey: AppConstants.Key.controlPlaneDeviceLabel) ?? "" }
    var sendPackages: Bool {
        UserDefaults.standard.object(forKey: AppConstants.Key.controlPlaneSendPackages) as? Bool
            ?? AppConstants.controlPlaneSendPackages
    }
    var client: ControlPlaneClient? { ControlPlaneClient.baseURL(fromHost: host).map { ControlPlaneClient(baseURL: $0) } }
    var syncNewSpaces: Bool {
        UserDefaults.standard.object(forKey: AppConstants.Key.controlPlaneSyncNewSpaces) as? Bool
            ?? AppConstants.controlPlaneSyncNewSpaces
    }
    /// The first successful sync: a space whose first scan comes after it is new.
    var joinedAt: Date? {
        (UserDefaults.standard.object(forKey: AppConstants.Key.controlPlaneJoinedAt) as? Double)
            .map(Date.init(timeIntervalSince1970:))
    }

    /// Once, at launch: watch SwiftData saves and sync now, then every few minutes while the app is
    /// open, so a request from the lab (a file it needs, a task) is picked up without a save. A
    /// suspended app suspends the loop; returning to the foreground syncs anyway.
    func start(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil,
                                                              queue: .main) { _ in
            Task { @MainActor in
                ControlPlaneSync.shared.requestSync(after: .seconds(AppConstants.controlPlaneSyncDebounceS))
            }
        }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AppConstants.controlPlanePollIntervalS))
                self?.requestSync(after: .zero)
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
            if !openTasks.isEmpty { setOpenTasks([]) }   // the host was cleared: its list goes with it
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
        let allLocations = (try? context.fetch(FetchDescriptor<ScanLocation>())) ?? []
        let allLinks = (try? context.fetch(FetchDescriptor<StitchLink>())) ?? []
        let locations = Self.spacesToReport(allLocations, synced: syncedSpaces,
                                            newSince: syncNewSpaces ? joinedAt : nil)
        let reported = Set(locations.map(\.id))
        if !reported.isSubset(of: syncedSpaces) {
            setSyncedSpaces(syncedSpaces.union(reported))   // a new space, once reported, stays synced
        }
        let links = Self.linksToReport(allLinks, spaces: reported)
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
            if joinedAt == nil {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: AppConstants.Key.controlPlaneJoinedAt)
            }
            uploadTarget = reply.uploadTarget
            applyLinkUpdates(reply.linkUpdates ?? [])
            receive(result.tasks)
            var summary = "\(reply.maps) spaces, \(reply.scans) scans, \(reply.links) links"
            PerfDiag.log("[ControlPlane] synced: \(summary), \(reply.markedGone) marked gone, "
                         + "\(reply.wanted?.count ?? 0) files wanted")
            let wanted = packages ? (reply.wanted ?? []) : []
            waitingForWiFi = 0
            if !wanted.isEmpty {
                let round = try await upload(wanted, from: local, with: client)
                waitingForWiFi = round.waitingForWiFi
                if round.stoppedForCapture {
                    // A capture began: the rest waits for it to end.
                    deferredForCapture = true
                    summary += "; map files wait for the scan to end"
                }
                if round.waitingForWiFi > 0 {
                    summary += "; \(round.waitingForWiFi) large map file(s) wait for Wi-Fi"
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

    private struct UploadRound {
        var sent = 0
        var waitingForWiFi = 0
        var stoppedForCapture = false
    }

    /// The map-package files the server asked for, one at a time, stopping if a capture begins.
    /// Small ones go on any network; a large one (a mesh, a world map) only on an unmetered one,
    /// and otherwise waits: the server keeps asking, and the next sync on Wi-Fi sends it. Any
    /// other failure ends the round; the next sync asks again.
    private func upload(_ wanted: [ControlPlaneClient.WantedFile], from local: [UUID: [String: ControlPlaneManifest.LocalFile]],
                        with client: ControlPlaneClient) async throws -> UploadRound {
        var round = UploadRound()
        for (index, want) in wanted.enumerated() {
            guard !captureActive else {
                round.stoppedForCapture = true
                return round
            }
            status = .uploading(done: index, total: wanted.count)
            // A file the server wants but the snapshot did not find (deleted since): skip it.
            guard let scanId = UUID(uuidString: want.scanId), let file = local[scanId]?[want.name] else { continue }
            do {
                _ = try await client.upload(file, scanId: want.scanId, name: want.name,
                                            unmeteredOnly: file.size >= AppConstants.controlPlaneLargeFileBytes)
                round.sent += 1
            } catch ControlPlaneClient.Failure.waitingForUnmeteredNetwork {
                round.waitingForWiFi += 1
            } catch {
                throw ControlPlaneClient.Failure.transport("Uploading \(want.name): \(error.localizedDescription)")
            }
        }
        PerfDiag.log("[ControlPlane] uploaded \(round.sent) map file(s), \(round.waitingForWiFi) waiting for Wi-Fi")
        return round
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

    // MARK: Spaces sent to the control plane

    /// A space's (or a stitched map's) standing with the control plane, for its Sync button.
    enum SpaceState: Equatable {
        case notSynced, partlySynced, syncing, synced, failed
    }

    /// Sync on a space or a stitched map, like Upload for an export: from now on these spaces are
    /// reported (rescans, focus scans and stitches with them), and a sync runs at once.
    func sync(spaces ids: [UUID]) {
        let all = syncedSpaces.union(ids)
        if all != syncedSpaces { setSyncedSpaces(all) }
        requestSync(after: .zero)
    }

    func state(of spaces: [UUID]) -> SpaceState {
        let synced = spaces.filter { syncedSpaces.contains($0) }.count
        if synced == 0 { return .notSynced }
        if synced < spaces.count { return .partlySynced }
        switch status {
        case .syncing, .uploading: return .syncing
        case .failed: return .failed
        default: return .synced
        }
    }

    /// The spaces a sync reports: the synced ones, and with `newSince` those whose first scan
    /// came after it (they join the synced set once reported).
    static func spacesToReport(_ locations: [ScanLocation], synced: Set<UUID>, newSince: Date?) -> [ScanLocation] {
        locations.filter { location in
            if synced.contains(location.id) { return true }
            guard let newSince, let first = location.scans.map(\.capturedAt).min() else { return false }
            return first >= newSince
        }
    }

    /// A stitch goes when both of its spaces do: Sync on the stitched map sends them together.
    static func linksToReport(_ links: [StitchLink], spaces: Set<UUID>) -> [StitchLink] {
        links.filter { link in
            guard let a = link.endpointAScan?.location?.id, let b = link.endpointBScan?.location?.id else { return false }
            return spaces.contains(a) && spaces.contains(b)
        }
    }

    private func setSyncedSpaces(_ ids: Set<UUID>) {
        syncedSpaces = ids
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: AppConstants.Key.controlPlaneSyncedSpaces)
    }

    nonisolated private static func storedSpaces() -> Set<UUID> {
        let ids = UserDefaults.standard.stringArray(forKey: AppConstants.Key.controlPlaneSyncedSpaces) ?? []
        return Set(ids.compactMap(UUID.init(uuidString:)))
    }

    // MARK: To-do list

    /// The to-do list from the server, with the answers it hasn't had yet applied (a request
    /// declined offline does not come back). Only an urgent task the device has never alerted
    /// about interrupts; it alerts once (remembered across launches), then waits in the list.
    private func receive(_ received: [ControlPlaneClient.ScanTask]) {
        let tasks = Self.applying(Self.unsentAnswers(), to: received)
        setOpenTasks(tasks)
        sendAnswers()
        let defaults = UserDefaults.standard
        var alerted = Set(defaults.stringArray(forKey: AppConstants.Key.controlPlanePromptedTasks) ?? [])
        guard taskToPrompt == nil,
              let next = tasks.first(where: { $0.isUrgent && $0.status != "accepted"
                                              && !alerted.contains($0.id.uuidString) }) else { return }
        alerted.insert(next.id.uuidString)
        // Only ids still open are worth remembering.
        let open = Set(tasks.map(\.id.uuidString))
        defaults.set(Array(alerted.intersection(open)), forKey: AppConstants.Key.controlPlanePromptedTasks)
        taskToPrompt = next
    }

    /// Opens the task's region in its space's editor (the deep-link path) and tells the server.
    /// The task stays in the list, marked opened, until the server has the focus scan.
    func open(_ task: ControlPlaneClient.ScanTask) {
        taskToPrompt = nil
        FocusRegionInbox.shared.pending = task.region
        answer(task.id, "accepted")
        setOpenTasks(Self.applying(Self.unsentAnswers(), to: openTasks))
    }

    func decline(_ task: ControlPlaneClient.ScanTask) {
        taskToPrompt = nil
        answer(task.id, "declined")
        setOpenTasks(Self.applying(Self.unsentAnswers(), to: openTasks))
    }

    func dismissPrompt() {
        taskToPrompt = nil
    }

    private func setOpenTasks(_ tasks: [ControlPlaneClient.ScanTask]) {
        openTasks = tasks
        UserDefaults.standard.set(try? JSONEncoder().encode(tasks), forKey: AppConstants.Key.controlPlaneOpenTasks)
    }

    nonisolated private static func storedTasks() -> [ControlPlaneClient.ScanTask] {
        guard let data = UserDefaults.standard.data(forKey: AppConstants.Key.controlPlaneOpenTasks) else { return [] }
        return (try? JSONDecoder().decode([ControlPlaneClient.ScanTask].self, from: data)) ?? []
    }

    // MARK: Answers to tasks, kept until the server has them

    /// Answers by task id ("accepted" / "declined"), on the phone until the server takes them.
    nonisolated private static func unsentAnswers() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: AppConstants.Key.controlPlaneTaskAnswers) as? [String: String] ?? [:]
    }

    /// The list as the device sees it: declined tasks gone, opened ones marked.
    nonisolated static func applying(_ answers: [String: String],
                                     to tasks: [ControlPlaneClient.ScanTask]) -> [ControlPlaneClient.ScanTask] {
        tasks.compactMap { task in
            guard let answer = answers[task.id.uuidString] else { return task }
            if answer == "declined" { return nil }
            var answered = task
            answered.status = answer
            return answered
        }
    }

    private func answer(_ taskId: UUID, _ status: String) {
        var unsent = Self.unsentAnswers()
        unsent[taskId.uuidString] = status
        UserDefaults.standard.set(unsent, forKey: AppConstants.Key.controlPlaneTaskAnswers)
        sendAnswers()
    }

    /// Sends the answers waiting on the phone. One the server took, or refused because the task is
    /// gone or finished (404/409), is forgotten; on any other failure the rest wait for the next sync.
    private func sendAnswers() {
        guard let client else { return }
        let unsent = Self.unsentAnswers()
        guard !unsent.isEmpty else { return }
        Task {
            for (id, status) in unsent {
                guard let taskId = UUID(uuidString: id) else { continue }
                do {
                    try await client.setTaskStatus(taskId, status: status)
                } catch ControlPlaneClient.Failure.server(let code, _) where (400..<500).contains(code) {
                    PerfDiag.log("[ControlPlane] task \(status) refused (\(code)); dropped")
                } catch {
                    PerfDiag.log("[ControlPlane] task \(status) not sent, kept for the next sync: \(error.localizedDescription)")
                    return
                }
                var left = Self.unsentAnswers()
                if left[id] == status { left[id] = nil }
                UserDefaults.standard.set(left, forKey: AppConstants.Key.controlPlaneTaskAnswers)
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
