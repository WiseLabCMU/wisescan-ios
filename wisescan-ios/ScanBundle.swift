import CryptoKit
import Foundation
import Network
import Observation
import SwiftData

// MARK: - A scan's bundle: everything it holds, synced as one zip (docs/design/sync-bundle.md)

/// The version of a scan's bundle and where a built one waits. The bundle is the Scan4D export
/// (`ScanExportManager.prepareExport`, privacy passes included), so the Share file and what the
/// lab server holds are one thing.
nonisolated enum ScanBundle {
    /// Previews the app regenerates: never part of a bundle, so they don't make a new version.
    static let unversioned: Set<String> = ["thumbnail.jpg", "model_preview.jpg"]

    struct Version: Equatable, Sendable {
        /// 32 hex digits: the server takes 1 to 128 letters, digits, - or _.
        let fingerprint: String
        /// The source files' total, an estimate of the bundle's size before it is built.
        let size: Int64
    }

    /// Fingerprints every file under the scan's directory by its path, size and modification
    /// time, so any change to one makes a new version. Walks the directory: off main.
    static func version(scanDirectory: URL) -> Version? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let base = scanDirectory.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(at: scanDirectory, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return nil }
        var lines: [String] = []
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  !unversioned.contains(url.lastPathComponent) else { continue }
            let path = url.resolvingSymlinksInPath().path
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
            let size = Int64(values.fileSize ?? 0)
            let time = Int((values.contentModificationDate ?? .distantPast).timeIntervalSince1970)
            lines.append("\(relative)\t\(size)\t\(time)")
            total += size
        }
        guard !lines.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8))
        return Version(fingerprint: digest.prefix(16).map { String(format: "%02x", $0) }.joined(), size: total)
    }

    /// Built bundles waiting to go up, in Caches: iOS may purge them under storage pressure,
    /// which only means building again.
    static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("ScanBundles", isDirectory: true)
    }

    static func cachedZip(scanId: UUID, fingerprint: String) -> URL {
        cacheDirectory.appendingPathComponent("\(scanId.uuidString).\(fingerprint).zip")
    }

    /// Drops every cached bundle not in `keep` (file names), and any older than the cache's days.
    static func pruneCache(keep: Set<String>, now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let oldest = now.addingTimeInterval(-AppConstants.controlPlaneBundleCacheDays * 86_400)
        for url in files {
            let made = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if !keep.contains(url.lastPathComponent) || made < oldest {
                try? fm.removeItem(at: url)
            }
        }
    }
}

// MARK: - Sending bundles

/// Sends synced scans' bundles to the control plane, one at a time, and keeps what the server says
/// about each (`ControlPlaneSync` hands over every sync response's `bundles`).
///
/// - A scan offers its version once processed (`ControlPlaneManifest`); the server answers whether
///   it wants it. A wanted bundle the user hasn't deselected in the pending checklist is colored if
///   it can be (exports carry captured colors), built into the cache, and uploaded in a background
///   URLSession, so gigabytes keep going while the app is suspended.
/// - With **Upload data bundles only on Wi-Fi** (the default) the upload waits for Wi-Fi.
/// - A built bundle stays cached until the server holds it, its scan changes, or a week passes:
///   a failed upload retries without building again.
/// - Never during a capture: building runs the privacy passes, heavy work the AR session can't share.
/// - A bundle the server couldn't extract (`failed`) waits for **Retry**, which builds it afresh.
@Observable
@MainActor
final class BundleSync {
    static let shared = BundleSync()

    /// A scan's bundle as the server last reported it (scan4d-server README, "Bundles").
    nonisolated struct Remote: Codable, Equatable, Sendable {
        var state: String
        var wanted: Bool
        var error: String = ""
        var ingestedAt: String?
    }

    enum Activity: Equatable {
        case coloring
        case building(String)
        case uploading(Double)
    }

    struct Active: Equatable {
        let scanId: UUID
        var fingerprint: String?
        var activity: Activity
    }

    /// How much of a space the server holds (its sync badge).
    enum SpaceState: Equatable {
        /// Not synced, or no server set.
        case off
        /// The space's JSON and RoomPlan preview, not every scan's bundle.
        case map
        /// Every scan's current bundle, extracted.
        case everything
        case uploading
        case failed
    }

    private(set) var remote: [UUID: Remote] = BundleSync.storedRemote()
    private(set) var active: Active?
    /// This phone's own failures (a build, the upload), by scan: shown on its card, retried after a pause.
    private(set) var failures: [UUID: String] = [:]
    /// Deselected in the pending checklist: their bundles wait until selected again.
    private(set) var skipped: Set<UUID> = BundleSync.storedSkipped()
    /// On cellular or Low Data: a Wi-Fi-only upload waits.
    private(set) var onExpensiveNetwork = false

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var captureActive = false
    @ObservationIgnored private var retryAfter: [UUID: Date] = [:]
    /// Retry asked for a failed bundle: wanted again, built afresh.
    @ObservationIgnored private var retrying: Set<UUID> = []
    private let path = NWPathMonitor()

    var wifiOnly: Bool {
        UserDefaults.standard.object(forKey: AppConstants.Key.controlPlaneBundlesWifiOnly) as? Bool
            ?? AppConstants.controlPlaneBundlesWifiOnly
    }

    private init() {}

    /// Once, at launch (`ControlPlaneSync.start`): reattach to an upload the system carried on
    /// while the app was gone, and watch the network.
    func start(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        path.pathUpdateHandler = { update in
            let expensive = update.isExpensive || update.isConstrained
            Task { @MainActor in BundleSync.shared.onExpensiveNetwork = expensive }
        }
        path.start(queue: DispatchQueue(label: "scan4d.bundles.path"))
        BundleUploadSession.session.getAllTasks { tasks in
            let running = tasks.compactMap { task -> (UUID, String)? in
                guard task.state == .running || task.state == .suspended,
                      let parts = task.taskDescription?.split(separator: " "), parts.count == 2,
                      let id = UUID(uuidString: String(parts[0])) else { return nil }
                return (id, String(parts[1]))
            }
            Task { @MainActor in
                if let (id, fingerprint) = running.first, BundleSync.shared.active == nil {
                    BundleSync.shared.active = Active(scanId: id, fingerprint: fingerprint, activity: .uploading(0))
                }
            }
        }
    }

    /// Mirrors `ControlPlaneSync.captureStateChanged`: nothing new starts during a capture.
    func captureStateChanged(active: Bool) {
        captureActive = active
        if !active { next() }
    }

    // MARK: What the server said

    /// The sync response's `bundles`: kept (the badge reads them after a relaunch too), then the
    /// next wanted bundle starts.
    func received(_ states: [ControlPlaneClient.BundleState]) {
        var updated = remote
        for state in states {
            guard let id = UUID(uuidString: state.scanId) else { continue }
            updated[id] = Remote(state: state.state, wanted: state.wanted, error: state.error ?? "",
                                 ingestedAt: state.ingestedAt)
            if state.state == "current" || state.state == "queued" || state.state == "ingesting" {
                failures[id] = nil
                retryAfter[id] = nil
            }
        }
        if updated != remote {
            remote = updated
            UserDefaults.standard.set(try? JSONEncoder().encode(remote.mapKeys(\.uuidString)),
                                      forKey: AppConstants.Key.controlPlaneBundleStates)
        }
        // A cached bundle is kept while its scan's version is still wanted, or is being sent.
        var keep = Set<String>()
        for state in states where state.state != "current" {
            if let id = UUID(uuidString: state.scanId), let fingerprint = state.deviceFingerprint {
                keep.insert(ScanBundle.cachedZip(scanId: id, fingerprint: fingerprint).lastPathComponent)
            }
        }
        if let active, let fingerprint = active.fingerprint {
            keep.insert(ScanBundle.cachedZip(scanId: active.scanId, fingerprint: fingerprint).lastPathComponent)
        }
        let kept = keep
        DispatchQueue.global(qos: .utility).async { ScanBundle.pruneCache(keep: kept) }
        next()
    }

    // MARK: The checklist

    func isSelected(_ scanId: UUID) -> Bool { !skipped.contains(scanId) }

    func setSelected(_ scanId: UUID, _ selected: Bool) {
        if selected { skipped.remove(scanId) } else { skipped.insert(scanId) }
        UserDefaults.standard.set(skipped.map(\.uuidString), forKey: AppConstants.Key.controlPlaneBundlesSkipped)
        if selected { next() }
    }

    /// Retry on a failed bundle: built afresh (the cached one may be what broke) and sent.
    func retry(_ scanId: UUID) {
        failures[scanId] = nil
        retryAfter[scanId] = nil
        retrying.insert(scanId)
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            let prefix = scanId.uuidString + "."
            for url in (try? fm.contentsOfDirectory(at: ScanBundle.cacheDirectory, includingPropertiesForKeys: nil)) ?? []
            where url.lastPathComponent.hasPrefix(prefix) {
                try? fm.removeItem(at: url)
            }
            Task { @MainActor in BundleSync.shared.next() }
        }
    }

    /// The Wi-Fi switch moved: an upload still waiting starts again under the new rule.
    func wifiOnlyChanged() {
        guard case .uploading(let fraction)? = active?.activity, fraction == 0 else {
            next()
            return
        }
        BundleUploadSession.session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    // MARK: Sending

    /// Starts the next wanted, selected bundle, if none is going and nothing forbids it.
    func next() {
        guard active == nil, !captureActive, let client = ControlPlaneSync.shared.client,
              let context = container?.mainContext else { return }
        let now = Date()
        let due = remote.filter { id, state in
            (state.wanted || retrying.contains(id)) && !skipped.contains(id) && (retryAfter[id].map { $0 <= now } ?? true)
        }.map(\.key)
        guard !due.isEmpty else { return }
        let scans = (try? context.fetch(FetchDescriptor<CapturedScan>())) ?? []
        guard let scan = scans.filter({ due.contains($0.id) }).sorted(by: CapturedScan.canonicalOrder).first else { return }
        active = Active(scanId: scan.id, fingerprint: nil, activity: .building("Preparing…"))
        Task { await send(scan, client: client, context: context) }
    }

    private func send(_ scan: CapturedScan, client: ControlPlaneClient, context: ModelContext) async {
        let id = scan.id
        retrying.remove(id)
        // Bundles carry captured colors, as every export does.
        if !scan.isColored && !scan.isFocusScan {
            active?.activity = .coloring
            await ScanExportManager.colorizeForExport([scan], modelContext: context)
        }
        let directory = scan.scanDirectory
        let colored = scan.isColored
        let filename = scan.makeExportFilename(format: .scan4d)
        guard let version = await Self.offMain({ ScanBundle.version(scanDirectory: directory) }) else {
            finish(id, failure: "The scan has no files")
            return
        }
        active?.fingerprint = version.fingerprint
        let zip = ScanBundle.cachedZip(scanId: id, fingerprint: version.fingerprint)
        if !FileManager.default.fileExists(atPath: zip.path) {
            active?.activity = .building("Preparing…")
            let built = await Self.offMain {
                ScanExportManager.prepareExport(filename: filename, scanDir: directory, format: .scan4d,
                                                vertexColorsFromCapture: colored,
                                                phase: { step in
                                                    Task { @MainActor in
                                                        if BundleSync.shared.active?.scanId == id {
                                                            BundleSync.shared.active?.activity = .building(step.label)
                                                        }
                                                    }
                                                })
            }
            guard let built, Self.move(built, to: zip) else {
                finish(id, failure: "The bundle couldn't be built")
                return
            }
        }
        guard !captureActive else {
            // A capture began while it was built: the upload waits for it to end (the bundle is cached).
            finish(id, failure: nil)
            return
        }
        let request = client.bundleRequest(scanId: id, fingerprint: version.fingerprint, wifiOnly: wifiOnly)
        let task = BundleUploadSession.session.uploadTask(with: request, fromFile: zip)
        task.taskDescription = "\(id.uuidString) \(version.fingerprint)"
        active?.activity = .uploading(0)
        task.resume()
    }

    /// From the upload session's delegate.
    func uploadProgress(_ scanId: UUID, fraction: Double) {
        guard active?.scanId == scanId else { return }
        if case .uploading(let shown) = active?.activity, fraction - shown < 0.01, fraction < 1 { return }
        active?.activity = .uploading(fraction)
    }

    /// From the upload session's delegate: the server took it (and queued the ingest), or not.
    func uploadFinished(_ scanId: UUID, status: Int?, error: Error?, detail: String) {
        if let error = error as? URLError, error.code == .cancelled {
            finish(scanId, failure: nil)    // the Wi-Fi switch moved: next() starts it again
            return
        }
        if let status, (200..<300).contains(status) {
            remote[scanId] = Remote(state: "queued", wanted: false)
            finish(scanId, failure: nil)
            // The extraction takes seconds to minutes: the next sync shows it current.
            ControlPlaneSync.shared.requestSync(after: .seconds(15))
            return
        }
        let reason: String
        if status == 403 {
            reason = "Uploads are turned off for this device on the control plane"
        } else if let status {
            reason = detail.isEmpty ? "The server answered \(status)" : "The server answered \(status): \(detail)"
        } else {
            reason = error?.localizedDescription ?? "The upload stopped"
        }
        finish(scanId, failure: reason)
    }

    private func finish(_ scanId: UUID, failure: String?) {
        if let failure {
            failures[scanId] = failure
            retryAfter[scanId] = Date().addingTimeInterval(AppConstants.controlPlanePollIntervalS * 3)
            PerfDiag.log("[Bundles] \(scanId.uuidString.prefix(8)) failed: \(failure)")
        } else {
            failures[scanId] = nil
        }
        if active?.scanId == scanId { active = nil }
        next()
    }
}

// MARK: - What the badge and the card show

extension BundleSync {
    func spaceState(_ location: ScanLocation) -> SpaceState {
        let sync = ControlPlaneSync.shared
        guard sync.client != nil, sync.confirmedSpaces.contains(location.id) else { return .off }
        let ids: [UUID] = location.scans.map { $0.id }
        if let active, ids.contains(active.scanId) { return .uploading }
        let states = ids.map { remote[$0]?.state }
        if states.contains(where: { $0 == "queued" || $0 == "ingesting" }) { return .uploading }
        if states.contains("failed") || ids.contains(where: { failures[$0] != nil }) { return .failed }
        if !ids.isEmpty && states.allSatisfy({ $0 == "current" }) { return .everything }
        return .map
    }

    /// The scan card's sync line; nil when its space isn't synced.
    func line(for scan: CapturedScan) -> (text: String, failed: Bool)? {
        let sync = ControlPlaneSync.shared
        guard sync.client != nil, let space: UUID = scan.location?.id, sync.confirmedSpaces.contains(space) else { return nil }
        if let active, active.scanId == scan.id {
            switch active.activity {
            case .coloring: return ("Coloring for sync…", false)
            case .building: return ("Preparing its bundle…", false)
            case .uploading(let fraction):
                if fraction == 0 && wifiOnly && onExpensiveNetwork { return ("Map only · waiting for Wi-Fi", false) }
                return ("Uploading \(Int((fraction * 100).rounded()))%", false)
            }
        }
        if let failure = failures[scan.id] { return ("Sync failed: \(failure)", true) }
        switch remote[scan.id]?.state {
        case "current": return ("Everything" + (remote[scan.id]?.ingestedAt.flatMap(Self.shortDate).map { " · \($0)" } ?? ""), false)
        case "queued", "ingesting": return ("Uploaded, the server is unpacking it", false)
        case "failed": return ("The server couldn't unpack it: \(remote[scan.id]?.error ?? "")", true)
        case "missing", "stale":
            if skipped.contains(scan.id) { return ("Map only · not selected", false) }
            if wifiOnly && onExpensiveNetwork { return ("Map only · waiting for Wi-Fi", false) }
            return ("Map only · waiting to upload", false)
        default: return ("Map only", false)
        }
    }

    // MARK: Helpers

    /// Runs `work` on a background queue, as the export paths do (`prepareExport` blocks on the
    /// main actor for the stitch artifacts, so it must never run there).
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async { done.resume(returning: work()) }
        }
    }

    private static func move(_ built: URL, to cached: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: cached.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: cached)
        do {
            try fm.moveItem(at: built, to: cached)
            return true
        } catch {
            PerfDiag.log("[Bundles] couldn't cache \(built.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }

    private static func shortDate(_ iso: String) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    nonisolated private static func storedRemote() -> [UUID: Remote] {
        guard let data = UserDefaults.standard.data(forKey: AppConstants.Key.controlPlaneBundleStates),
              let stored = try? JSONDecoder().decode([String: Remote].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    nonisolated private static func storedSkipped() -> Set<UUID> {
        Set((UserDefaults.standard.stringArray(forKey: AppConstants.Key.controlPlaneBundlesSkipped) ?? [])
            .compactMap(UUID.init(uuidString:)))
    }
}

private extension Dictionary {
    func mapKeys<K: Hashable>(_ transform: (Key) -> K) -> [K: Value] {
        Dictionary<K, Value>(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}

// MARK: - The background upload session

/// One background URLSession for bundle uploads: the system carries an upload on while the app is
/// suspended, and relaunches the app when it ends (`AppDelegate` hands over the completion).
nonisolated enum BundleUploadSession {
    static let identifier = "edu.cmu.wiselab.scan4d.bundles"
    private static let delegate = BundleUploadDelegate()

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForResource = AppConstants.controlPlaneBundleResourceTimeoutS
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }()

    /// The system's completion for events delivered while the app was in the background.
    static let completion = LockedBox<(() -> Void)?>(nil)
}

/// A value behind a lock, for state the session's delegate queue and the app share.
nonisolated final class LockedBox<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

nonisolated final class BundleUploadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    /// Each upload's response body, for the reason when the server refuses it.
    private let bodies = LockedBox<[Int: Data]>([:])

    private func scanId(_ task: URLSessionTask) -> UUID? {
        task.taskDescription?.split(separator: " ").first.flatMap { UUID(uuidString: String($0)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let id = scanId(task), totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor in BundleSync.shared.uploadProgress(id, fraction: fraction) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bodies.withLock { $0[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = bodies.withLock { $0.removeValue(forKey: task.taskIdentifier) } ?? Data()
        guard let id = scanId(task) else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let detail = ControlPlaneClient.detail(from: body)
        Task { @MainActor in BundleSync.shared.uploadFinished(id, status: status, error: error, detail: detail) }
    }

    /// The control plane's certificate rule: its own host may be self-signed when Settings allows it.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ControlPlaneSession.disposition(for: challenge)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let done = BundleUploadSession.completion.withLock { value -> (() -> Void)? in
            defer { value = nil }
            return value
        }
        if let done { DispatchQueue.main.async { done() } }
    }
}
