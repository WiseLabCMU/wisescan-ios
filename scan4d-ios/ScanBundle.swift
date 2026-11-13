import CryptoKit
import Foundation
import Network
import Observation
import SwiftData

// MARK: - A scan's bundle: everything it holds, synced as one zip (docs/design/sync-bundle.md)

/// The version of a scan's bundle and where a built one waits. The bundle is the Scan4D export
/// (`ScanExportManager.prepareExport`, privacy passes included), so the Share file and what the
/// Scan4D server holds are one thing.
nonisolated enum ScanBundle {
    struct Version: Equatable, Sendable {
        /// 32 hex digits: the server takes 1 to 128 letters, digits, - or _.
        let fingerprint: String
        /// The source files' total, an estimate of the bundle's size before it is built.
        let size: Int64
    }

    /// What the bundle is built from, and so what its version follows: the files and folders the
    /// Scan4D export reads (`ScanExportManager.scan4dSources`), or a focus scan's capture folder
    /// and region. Caches the app regenerates and files that never ship don't count.
    static func sources(scanDirectory: URL) -> [URL] {
        let focus = scanDirectory.appendingPathComponent(AppConstants.focusCaptureFolder)
        if FileManager.default.fileExists(atPath: focus.path) {
            return [focus, scanDirectory.appendingPathComponent(AppConstants.focusRegionFilename)]
        }
        return ScanExportManager.scan4dSources.map { scanDirectory.appendingPathComponent($0) }
    }

    /// Fingerprints every source file by its path, size and modification time, so a change to any
    /// of them makes a new version. Walks the sources: off main, and not on every sync
    /// (`cachedVersion`).
    static func version(scanDirectory: URL) -> Version? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let base = scanDirectory.resolvingSymlinksInPath().path
        var lines: [String] = []
        var total: Int64 = 0
        func add(_ url: URL, _ values: URLResourceValues) {
            let path = url.resolvingSymlinksInPath().path
            let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
            let size = Int64(values.fileSize ?? 0)
            let time = Int((values.contentModificationDate ?? .distantPast).timeIntervalSince1970)
            lines.append("\(relative)\t\(size)\t\(time)")
            total += size
        }
        for source in sources(scanDirectory: scanDirectory) {
            guard let values = try? source.resourceValues(forKeys: Set(keys)) else { continue }   // absent
            if values.isRegularFile == true {
                add(source, values)
                continue
            }
            guard values.isDirectory == true,
                  let walker = FileManager.default.enumerator(at: source, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                guard let inner = try? url.resourceValues(forKeys: Set(keys)), inner.isRegularFile == true else { continue }
                add(url, inner)
            }
        }
        guard !lines.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8))
        return Version(fingerprint: digest.prefix(16).map { String(format: "%02x", $0) }.joined(), size: total)
    }

    /// A cheap look at the sources: each file's size and time, each folder's time (which moves when
    /// an entry is added, removed or replaced, as every atomic write does), and for a focus scan
    /// the same one level into its capture folder. A file rewritten in place inside a folder
    /// doesn't show; the cache's age bound covers that.
    static func stamp(scanDirectory: URL) -> String {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        func look(_ url: URL) -> String {
            guard let values = try? url.resourceValues(forKeys: keys) else { return "-" }
            let time = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            return values.isDirectory == true ? "d\(time)" : "f\(values.fileSize ?? 0)@\(time)"
        }
        var parts: [String] = []
        let focus = scanDirectory.appendingPathComponent(AppConstants.focusCaptureFolder)
        for source in sources(scanDirectory: scanDirectory) {
            parts.append(look(source))
            if source == focus {
                let entries = (try? FileManager.default.contentsOfDirectory(
                    at: source, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
                parts += entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
                    .map { "\($0.lastPathComponent):\(look($0))" }
            }
        }
        return parts.joined(separator: "|")
    }

    private struct CachedVersion {
        let stamp: String
        let version: Version?
        let at: Date
    }

    private static let versions = LockedBox<[String: CachedVersion]>([:])

    /// The version as `version` gives it, re-read only when the sources' stamp moved or the last
    /// read is older than `AppConstants.controlPlaneBundleVersionMaxAgeS`: every sync offers every
    /// settled scan's version, and walking thousands of files per scan each time is what this
    /// avoids. A bundle's build reads it afresh (`version`) and syncs again on a mismatch.
    static func cachedVersion(scanDirectory: URL, now: Date = Date()) -> Version? {
        let key = scanDirectory.path
        let current = stamp(scanDirectory: scanDirectory)
        if let hit = versions.withLock({ $0[key] }), hit.stamp == current,
           now.timeIntervalSince(hit.at) < AppConstants.controlPlaneBundleVersionMaxAgeS {
            return hit.version
        }
        let fresh = version(scanDirectory: scanDirectory)
        versions.withLock { $0[key] = CachedVersion(stamp: current, version: fresh, at: now) }
        return fresh
    }

    static func forgetVersion(scanDirectory: URL) {
        versions.withLock { $0[scanDirectory.path] = nil }
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

    /// The name a bundle is built under, in the temporary folder: its own, never the Share file's
    /// (`makeExportFilename`), so a sync and a Share of one scan never touch each other's zip.
    static func buildFilename(scanId: UUID, fingerprint: String) -> String {
        "bundle-\(scanId.uuidString)-\(fingerprint).zip"
    }

    /// Drops every cached bundle not in `keep` (file names), and any older than the cache's limit.
    static func pruneCache(keep: Set<String>, now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let oldest = now.addingTimeInterval(-AppConstants.controlPlaneBundleCacheMaxAgeS)
        for url in files {
            let made = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if !keep.contains(url.lastPathComponent) || made < oldest {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Answers that sending the same bundle again can't change: uploads revoked for this device
    /// (403), a scan the server doesn't know (404), a bundle over its size limit (413). They wait
    /// for a new version of the scan or the user's Retry.
    static func isPermanentRefusal(status: Int) -> Bool {
        [403, 404, 413].contains(status)
    }

    /// How long a bundle waits after `failuresInARow` failed uploads: the base, doubling with each
    /// failure in a row, up to the cap.
    static func retryDelay(failuresInARow: Int) -> TimeInterval {
        let doublings = Double(max(0, failuresInARow - 1))
        return min(AppConstants.controlPlaneBundleRetryBaseS * pow(2, doublings), AppConstants.controlPlaneBundleRetryMaxS)
    }
}

// MARK: - Share exports and bundles

/// Share exports building now. A sync bundle never builds beside one: two privacy passes at once
/// are the OOM class behind `UploadStatus.isInFlight` (2026-07-23 field report). Every Share path
/// calls `begin` before its colorize and `end` once its zips are built, on every exit.
@MainActor
enum ShareExports {
    private(set) static var running = 0

    /// Stops a bundle build under way (it starts again after), and waits out a bundle's coloring,
    /// which can't stop midway and holds its scan's claim: Share's own colorize would skip that
    /// scan and export it uncolored.
    static func begin() async {
        running += 1
        BundleSync.shared.yieldToShare()
        while BundleSync.shared.isColoring {
            try? await Task.sleep(for: .seconds(AppConstants.shareWaitForBundleColoringPollS))
        }
    }

    static func end() {
        running = max(0, running - 1)
        if running == 0 { BundleSync.shared.next() }
    }
}

// MARK: - Sending bundles

/// Sends synced scans' bundles to the control plane, one at a time, and keeps what the server says
/// about each (`ControlPlaneSync` hands over every sync response's `bundles`).
///
/// - A scan offers its version once processed (`ControlPlaneManifest`); the server answers whether
///   it wants it. A wanted bundle that is selected in the pending checklist is colored if it can
///   be (exports carry captured colors), built into the cache, and uploaded in a background
///   URLSession, so gigabytes keep going while the app is suspended.
/// - Selected by default, except a scan captured with the Privacy Filter off: its photos show
///   people unblurred, so it waits until the user selects it.
/// - With **Upload data bundles only on Wi-Fi** (the default) the upload waits for Wi-Fi.
/// - A built bundle stays cached until the server holds it, its scan changes, or a week passes:
///   a failed upload retries without building again, later after each failure in a row.
/// - Never built during a capture, a Share export, or Process or Color on the scan: a capture or
///   a Share stops a build under way, and it starts again after.
/// - A bundle the server couldn't extract (`failed`) or refused for good (403, 404, 413) waits
///   for a new version of the scan or **Retry**.
/// - The state belongs to one server: another one starts it afresh (`serverChanged`).
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
        /// The version this device offered, as the server echoes it.
        var deviceFingerprint: String?
    }

    /// A bundle the server refused for good, and the version it refused.
    nonisolated struct Refusal: Codable, Equatable, Sendable {
        var fingerprint: String
        var reason: String
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
        /// The upload task's identifier in the background session, once it is sending.
        var task: Int?
        /// The Wi-Fi rule its upload request was made under (nil for one reattached at launch).
        var wifiOnly: Bool?
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

    /// Why a build ended without an upload.
    fileprivate enum Outcome {
        case uploading
        /// A capture, a Share, a deselection or a reset stopped it: it starts again when allowed.
        case stopped
        /// Process or Color is working on the scan, or its steps are due: tried again shortly.
        case busy
        /// The scan's files changed since the version the server saw: the next sync offers the
        /// new one first.
        case resync
        case failed(String)
    }

    private(set) var remote: [UUID: Remote] = BundleSync.storedRemote()
    private(set) var active: Active?
    /// This phone's own failures (a build, the upload), by scan: shown on its card, retried after a pause.
    private(set) var failures: [UUID: String] = [:]
    /// Refused for good: not sent again while the device offers the version refused.
    private(set) var refused: [UUID: Refusal] = BundleSync.storedRefused()
    /// Deselected in the pending checklist: their bundles wait until selected again.
    private(set) var skipped: Set<UUID> = BundleSync.storedIds(AppConstants.Key.controlPlaneBundlesSkipped)
    /// Captured with the Privacy Filter off (as the last sync read them): held back unless chosen.
    private(set) var filterOff: Set<UUID> = BundleSync.storedIds(AppConstants.Key.controlPlaneBundlesFilterOff)
    /// Filter-off scans the user selected in the checklist.
    private(set) var chosen: Set<UUID> = BundleSync.storedIds(AppConstants.Key.controlPlaneBundlesChosen)
    /// Whether filter-off scans are held back (the default); Always Send turns it off.
    private(set) var holdsBackFilterOff: Bool =
        UserDefaults.standard.object(forKey: AppConstants.Key.controlPlaneHoldBackFilterOff) as? Bool
            ?? AppConstants.controlPlaneHoldBackFilterOff
    /// On cellular or Low Data: a Wi-Fi-only upload waits.
    private(set) var onExpensiveNetwork = false

    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var captureActive = false
    @ObservationIgnored private var retryAfter: [UUID: Date] = [:]
    @ObservationIgnored private var failuresInARow: [UUID: Int] = [:]
    /// Retry asked for a failed bundle: wanted again, built afresh.
    @ObservationIgnored private var retrying: Set<UUID> = []
    /// Found changed since the last sync: wait for the next one to offer the new version.
    @ObservationIgnored private var awaitingSync: Set<UUID> = []
    /// Nothing starts until the uploads the system carried on while the app was gone are known.
    @ObservationIgnored private var reattached = false
    /// Uploads that ended before they were reattached, by task identifier.
    @ObservationIgnored private var endedBeforeReattach: Set<Int> = []
    @ObservationIgnored private var buildStop: ExportStop?
    /// Bumped when the server changes: a build or reply from before it is dropped.
    @ObservationIgnored private var generation = 0
    private let path = NWPathMonitor()

    var wifiOnly: Bool {
        UserDefaults.standard.object(forKey: AppConstants.Key.controlPlaneBundlesWifiOnly) as? Bool
            ?? AppConstants.controlPlaneBundlesWifiOnly
    }

    /// A bundle is being colored for sync (Share waits for it: `ShareExports.begin`).
    var isColoring: Bool {
        if case .coloring? = active?.activity { return true }
        return false
    }

    private init() {}

    /// Once, at launch (`ControlPlaneSync.start`): carry over an older build's opt-out, watch the
    /// network, and reattach to an upload the system carried on while the app was gone.
    func start(container: ModelContainer) {
        guard self.container == nil else { return }
        self.container = container
        migrateSendPackagesOptOut(container.mainContext)
        path.pathUpdateHandler = { update in
            let expensive = update.isExpensive || update.isConstrained
            Task { @MainActor in BundleSync.shared.onExpensiveNetwork = expensive }
        }
        path.start(queue: DispatchQueue(label: "scan4d.bundles.path"))
        BundleUploadSession.session.getAllTasks { tasks in
            let running = tasks.compactMap { task -> Reattached? in
                guard task.state == .running || task.state == .suspended,
                      let parts = task.taskDescription?.split(separator: " "), parts.count == 2,
                      let id = UUID(uuidString: String(parts[0])) else { return nil }
                return Reattached(scanId: id, fingerprint: String(parts[1]), task: task.taskIdentifier)
            }
            Task { @MainActor in BundleSync.shared.reattach(running) }
        }
    }

    nonisolated struct Reattached: Sendable {
        let scanId: UUID
        let fingerprint: String
        let task: Int
    }

    private func reattach(_ running: [Reattached]) {
        if active == nil, let upload = running.first(where: { !endedBeforeReattach.contains($0.task) }) {
            active = Active(scanId: upload.scanId, fingerprint: upload.fingerprint, activity: .uploading(0),
                            task: upload.task, wifiOnly: nil)
        }
        endedBeforeReattach = []
        reattached = true
        next()
    }

    /// Builds before bundles had Send map packages; off meant only the JSON went. Bundles carry far
    /// more (photos, depth, the world map), so a phone that had it off starts with every scan it
    /// holds deselected. Once.
    private func migrateSendPackagesOptOut(_ context: ModelContext) {
        let defaults = UserDefaults.standard
        let key = AppConstants.Key.legacyControlPlaneSendPackages
        guard let sent = defaults.object(forKey: key) as? Bool else { return }
        defaults.removeObject(forKey: key)
        guard !sent else { return }
        let ids: [UUID] = ((try? context.fetch(FetchDescriptor<CapturedScan>())) ?? []).map { $0.id }
        skipped.formUnion(ids)
        store(skipped, AppConstants.Key.controlPlaneBundlesSkipped)
        PerfDiag.log("[Bundles] Send map packages was off: \(ids.count) scan(s) start deselected")
    }

    /// Mirrors `ControlPlaneSync.captureStateChanged`: a build under way stops, and nothing starts
    /// until the capture ends.
    func captureStateChanged(active: Bool) {
        captureActive = active
        if active {
            buildStop?.stop()
        } else {
            next()
        }
    }

    /// A Share export is starting (`ShareExports`): a build under way stops and starts again after.
    func yieldToShare() {
        buildStop?.stop()
    }

    /// The control plane is another server: its own state starts afresh. The checklist's choices
    /// stay (they are the user's, not the server's), and so do built bundles (their content is
    /// the same whichever server takes them).
    func serverChanged() {
        generation += 1
        buildStop?.stop()
        buildStop = nil
        if active?.task != nil { cancelUpload() }
        active = nil
        remote = [:]
        failures = [:]
        refused = [:]
        retryAfter = [:]
        failuresInARow = [:]
        retrying = []
        awaitingSync = []
        storeRemote()
        storeRefused()
    }

}

// MARK: - What the server said, the checklist, sending

extension BundleSync {
    // MARK: What the server said

    /// The sync response's `bundles`, which cover every reported scan (so a scan it leaves out is
    /// gone), and which reported scans were captured with the Privacy Filter off. Kept (the badge
    /// reads them after a relaunch too), then the next wanted bundle starts.
    func received(_ states: [ControlPlaneClient.BundleState], filterOff readFilterOff: Set<UUID>) {
        var updated: [UUID: Remote] = [:]
        var refusals = refused
        for state in states {
            guard let id = UUID(uuidString: state.scanId) else { continue }
            updated[id] = Remote(state: state.state, wanted: state.wanted, error: state.error ?? "",
                                 ingestedAt: state.ingestedAt, deviceFingerprint: state.deviceFingerprint)
            if state.state == "current" || state.state == "queued" || state.state == "ingesting" {
                failures[id] = nil
                retryAfter[id] = nil
                failuresInARow[id] = nil
            }
            // A new version of the scan: what was refused was another bundle.
            if let refusal = refusals[id], refusal.fingerprint != state.deviceFingerprint {
                refusals[id] = nil
                failures[id] = nil
            }
        }
        refusals = refusals.filter { updated[$0.key] != nil }
        failures = failures.filter { updated[$0.key] != nil }
        awaitingSync = []
        if updated != remote {
            remote = updated
            storeRemote()
        }
        if refusals != refused {
            refused = refusals
            storeRefused()
        }
        if readFilterOff != filterOff {
            filterOff = readFilterOff
            store(filterOff, AppConstants.Key.controlPlaneBundlesFilterOff)
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

    /// Captured with the Privacy Filter off, and such scans are held back (the default): it waits
    /// until the user selects it, which asks first. With Always Send, it goes like any other.
    func isHeldBack(_ scanId: UUID) -> Bool {
        holdsBackFilterOff && filterOff.contains(scanId)
    }

    /// Scans the Privacy Filter was just applied to (`PrivacyFilterReapply`): no longer held back
    /// as captured with it off, and a selection made for them as unblurred is moot. One being
    /// built or sent unblurred right now stops. The next sync reads them filtered too.
    func filterApplied(_ scanIds: [UUID]) {
        let ids = Set(scanIds)
        filterOff.subtract(ids)
        chosen.subtract(ids)
        store(filterOff, AppConstants.Key.controlPlaneBundlesFilterOff)
        store(chosen, AppConstants.Key.controlPlaneBundlesChosen)
        if let active, ids.contains(active.scanId) {
            if active.task != nil { cancelUpload() } else { buildStop?.stop() }
        }
    }

    /// Scans waiting to upload that are held back as captured with the Privacy Filter off: the
    /// server wants them and the user hasn't selected them. One confirmation covers them all.
    var waitingUnblurred: [UUID] {
        remote.keys.filter { isHeldBack($0) && awaitsSelection($0) }.sorted { $0.uuidString < $1.uuidString }
    }

    /// The Server tab's "Ask before sending unblurred scans", and the consent's Always Send (off).
    func setHoldsBackFilterOff(_ on: Bool) {
        guard on != holdsBackFilterOff else { return }
        holdsBackFilterOff = on
        UserDefaults.standard.set(on, forKey: AppConstants.Key.controlPlaneHoldBackFilterOff)
        if !on { next() }
    }

    func isSelected(_ scanId: UUID) -> Bool {
        isHeldBack(scanId) ? chosen.contains(scanId) : !skipped.contains(scanId)
    }

    func setSelected(_ scanId: UUID, _ selected: Bool) {
        if isHeldBack(scanId) {
            if selected { chosen.insert(scanId) } else { chosen.remove(scanId) }
            store(chosen, AppConstants.Key.controlPlaneBundlesChosen)
        } else {
            if selected { skipped.remove(scanId) } else { skipped.insert(scanId) }
            store(skipped, AppConstants.Key.controlPlaneBundlesSkipped)
        }
        if selected {
            next()
        } else if active?.scanId == scanId {
            // Deselected while it was being built or sent: it stops.
            if active?.task != nil { cancelUpload() } else { buildStop?.stop() }
        }
    }

    /// Whether the scan's bundle is being built or sent now (its Retry waits for that to end).
    func isActive(_ scanId: UUID) -> Bool { active?.scanId == scanId }

    /// The server wants the scan's bundle, but the checklist holds it back: its card offers Select.
    func awaitsSelection(_ scanId: UUID) -> Bool {
        !isSelected(scanId) && remote[scanId]?.wanted == true
    }

    /// Bundles only the user can move on: one the server couldn't unpack, or refused for good
    /// (both wait for Retry). The Server tab's badge. Failures the app retries itself don't count.
    var needingAttention: Int {
        guard ControlPlaneSync.shared.stateIsCurrent else { return 0 }
        return remote.keys.filter { remote[$0]?.state == "failed" || refusal($0) != nil }.count
    }

    /// The refusal that still applies: the server refused the version the device offers now.
    func refusal(_ scanId: UUID) -> Refusal? {
        guard let refusal = refused[scanId], refusal.fingerprint == remote[scanId]?.deviceFingerprint else { return nil }
        return refusal
    }

    /// Retry on a failed or refused bundle: built afresh (the cached one may be what broke) and
    /// sent. Not while its build or upload is under way: that would delete the zip being sent.
    func retry(_ scanId: UUID) {
        guard !isActive(scanId) else { return }
        failures[scanId] = nil
        retryAfter[scanId] = nil
        failuresInARow[scanId] = nil
        if refused.removeValue(forKey: scanId) != nil { storeRefused() }
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

    /// The Wi-Fi switch moved. Now Wi-Fi only: an upload made to use any network may be on
    /// cellular, at any progress, so it starts again under the rule (from the cached zip). Now
    /// any network: one still waiting for Wi-Fi starts again so it can go; one already sending
    /// carries on.
    func wifiOnlyChanged() {
        guard let active, case .uploading(let fraction) = active.activity else {
            next()
            return
        }
        let rule = wifiOnly
        guard active.wifiOnly != rule else { return }
        if rule || fraction == 0 { cancelUpload() }
    }

    // MARK: Sending

    /// Starts the next wanted, selected bundle, if none is going and nothing forbids it.
    func next() {
        guard reattached, active == nil, !captureActive, ShareExports.running == 0,
              ControlPlaneSync.shared.stateIsCurrent, let client = ControlPlaneSync.shared.client,
              let context = container?.mainContext else { return }
        let now = Date()
        let due = remote.filter { id, state in
            (state.wanted || retrying.contains(id)) && isSelected(id) && refusal(id) == nil
                && !awaitingSync.contains(id) && (retryAfter[id].map { $0 <= now } ?? true)
        }.map(\.key)
        guard !due.isEmpty else { return }
        let scans = (try? context.fetch(FetchDescriptor<CapturedScan>())) ?? []
        guard let scan = scans.filter({ due.contains($0.id) }).sorted(by: CapturedScan.canonicalOrder).first else { return }
        let stop = ExportStop()
        buildStop = stop
        active = Active(scanId: scan.id, fingerprint: nil, activity: .building("Preparing…"))
        let generation = self.generation
        Task { await send(scan, client: client, context: context, stop: stop, generation: generation) }
    }

    private func send(_ scan: CapturedScan, client: ControlPlaneClient, context: ModelContext,
                      stop: ExportStop, generation: Int) async {
        let id: UUID = scan.id
        retrying.remove(id)
        let outcome = await build(scan, client: client, context: context, stop: stop, generation: generation)
        // The server changed meanwhile: serverChanged() already cleared everything.
        guard generation == self.generation else { return }
        if buildStop === stop { buildStop = nil }
        switch outcome {
        case .uploading:
            return
        case .stopped:
            finish(id, failure: nil)
        case .busy:
            retryAfter[id] = Date().addingTimeInterval(AppConstants.controlPlaneBundleBusyRetryS)
            if active?.scanId == id { active = nil }
            Task {
                try? await Task.sleep(for: .seconds(AppConstants.controlPlaneBundleBusyRetryS))
                BundleSync.shared.next()
            }
            next()
        case .resync:
            awaitingSync.insert(id)
            if active?.scanId == id { active = nil }
            ControlPlaneSync.shared.requestSync(after: .seconds(AppConstants.controlPlaneSyncDebounceS))
            next()
        case .failed(let reason):
            finish(id, failure: reason)
        }
    }

    /// Colors, checks, builds and starts the upload of one scan's bundle.
    private func build(_ scan: CapturedScan, client: ControlPlaneClient, context: ModelContext,
                       stop: ExportStop, generation: Int) async -> Outcome {
        let id: UUID = scan.id
        func interrupted() -> Bool {
            generation != self.generation || stop.isStopped || captureActive || ShareExports.running > 0
        }
        if interrupted() { return .stopped }
        // Share of this scan running (its status, set a moment before it registers): try again shortly.
        guard !scan.uploadStatus.isInFlight else { return .busy }

        // Captured with the Privacy Filter off: held back unless the user chose it (or chose
        // Always Send), read from the scan itself in case no sync has said so yet.
        let record: ControlPlaneManifest.PrivacyRecord = scan.isFocusScan
            ? .focus(captureFolder: scan.focusCaptureURL) : .room(rawData: scan.rawDataPath)
        let filterWasOff = await Self.offMain { ControlPlaneManifest.readPrivacyFilter(record) == false }
        if filterWasOff && !filterOff.contains(id) {
            filterOff.insert(id)
            store(filterOff, AppConstants.Key.controlPlaneBundlesFilterOff)
        }
        if filterWasOff && holdsBackFilterOff && !chosen.contains(id) { return .stopped }

        // Bundles carry captured colors, as every export does.
        if !scan.isColored && !scan.isFocusScan {
            active?.activity = .coloring
            await ScanExportManager.colorizeForExport([scan], modelContext: context)
            active?.activity = .building("Preparing…")
            if interrupted() { return .stopped }
        }

        // Process or Color working on the scan (they hold its claim), or structural steps due: its
        // files are in flux. Taken and given back at once, on main where they take it too.
        guard ScanPostprocessor.claimInFlight(id) else { return .busy }
        ScanPostprocessor.releaseInFlight(id)
        guard !ScanPostprocessor.needsPostprocess(scan) else { return .busy }

        let directory = scan.scanDirectory
        let colored = scan.isColored
        guard let before = await Self.offMain({ ScanBundle.version(scanDirectory: directory) }) else {
            return .failed("The scan has no files")
        }
        if interrupted() { return .stopped }
        // The files changed since the version the server saw: a bundle of these would be
        // recorded under another version and wanted again. The next sync offers this one.
        if let offered = remote[id]?.deviceFingerprint, offered != before.fingerprint {
            ScanBundle.forgetVersion(scanDirectory: directory)
            return .resync
        }
        active?.fingerprint = before.fingerprint
        let zip = ScanBundle.cachedZip(scanId: id, fingerprint: before.fingerprint)
        if !FileManager.default.fileExists(atPath: zip.path) {
            let filename = ScanBundle.buildFilename(scanId: id, fingerprint: before.fingerprint)
            let built = await Self.offMain {
                ScanExportManager.prepareExport(filename: filename, scanDir: directory, format: .scan4d,
                                                vertexColorsFromCapture: colored,
                                                phase: { step in
                                                    Task { @MainActor in
                                                        if BundleSync.shared.active?.scanId == id {
                                                            BundleSync.shared.active?.activity = .building(step.label)
                                                        }
                                                    }
                                                },
                                                stop: stop)
            }
            if interrupted() {
                if let built { try? FileManager.default.removeItem(at: built) }
                return .stopped
            }
            guard let built else { return .failed("The bundle couldn't be built") }
            // Process or Color touched the scan while it was built (or is about to): a torn copy,
            // never sent.
            let after = await Self.offMain { ScanBundle.version(scanDirectory: directory) }
            let unclaimed = ScanPostprocessor.claimInFlight(id)
            if unclaimed { ScanPostprocessor.releaseInFlight(id) }
            guard after == before, unclaimed else {
                try? FileManager.default.removeItem(at: built)
                return .busy
            }
            guard Self.move(built, to: zip) else { return .failed("The bundle couldn't be cached") }
        }
        // A capture began while it was built: the upload waits for it to end (the bundle is cached).
        if interrupted() { return .stopped }
        let rule = wifiOnly
        let request = client.bundleRequest(scanId: id, fingerprint: before.fingerprint, wifiOnly: rule)
        let task = BundleUploadSession.session.uploadTask(with: request, fromFile: zip)
        task.taskDescription = "\(id.uuidString) \(before.fingerprint)"
        active?.activity = .uploading(0)
        active?.task = task.taskIdentifier
        active?.wifiOnly = rule
        task.resume()
        return .uploading
    }

    /// From the upload session's delegate.
    func uploadProgress(_ scanId: UUID, task: Int, fraction: Double) {
        guard let active, active.scanId == scanId, active.task == nil || active.task == task else { return }
        if case .uploading(let shown) = active.activity,
           fraction - shown < AppConstants.controlPlaneBundleProgressStep, fraction < 1 { return }
        self.active?.activity = .uploading(fraction)
        if active.task == nil { self.active?.task = task }
    }

    /// From the upload session's delegate: the server took it (and queued the ingest), or not.
    func uploadFinished(_ scanId: UUID, fingerprint: String, task: Int, status: Int?, error: Error?, detail: String) {
        if !reattached { endedBeforeReattach.insert(task) }
        // An upload this one replaced (a cancelled one, or one from before a server change).
        if let active, active.scanId == scanId, let current = active.task, current != task { return }
        if let error = error as? URLError, error.code == .cancelled {
            finish(scanId, failure: nil)    // the Wi-Fi switch moved, a deselection, a new server
            return
        }
        if let status, (200..<300).contains(status) {
            remote[scanId] = Remote(state: "queued", wanted: false, deviceFingerprint: fingerprint)
            failuresInARow[scanId] = nil
            finish(scanId, failure: nil)
            // The extraction takes seconds to minutes: the next sync shows it current.
            ControlPlaneSync.shared.requestSync(after: .seconds(AppConstants.controlPlaneBundleIngestCheckS))
            return
        }
        let reason: String
        switch status {
        case 403?: reason = "Uploads are turned off for this device on the control plane"
        case 404?: reason = "The server doesn't know this scan"
        case 413?: reason = "The bundle is larger than the server takes"
        case let status?: reason = detail.isEmpty ? "The server answered \(status)" : "The server answered \(status): \(detail)"
        case nil: reason = error?.localizedDescription ?? "The upload stopped"
        }
        if let status, ScanBundle.isPermanentRefusal(status: status) {
            refused[scanId] = Refusal(fingerprint: fingerprint, reason: reason)
            storeRefused()
            failures[scanId] = reason
            PerfDiag.log("[Bundles] \(scanId.uuidString.prefix(8)) refused (\(status)): \(reason)")
            if active?.scanId == scanId { active = nil }
            next()
            return
        }
        finish(scanId, failure: reason)
    }

    private func finish(_ scanId: UUID, failure: String?) {
        if let failure {
            failures[scanId] = failure
            let inARow = (failuresInARow[scanId] ?? 0) + 1
            failuresInARow[scanId] = inARow
            retryAfter[scanId] = Date().addingTimeInterval(ScanBundle.retryDelay(failuresInARow: inARow))
            PerfDiag.log("[Bundles] \(scanId.uuidString.prefix(8)) failed (\(inARow) in a row): \(failure)")
        } else {
            failures[scanId] = nil
        }
        if active?.scanId == scanId { active = nil }
        next()
    }

    private func cancelUpload() {
        BundleUploadSession.session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }
}

// MARK: - What the badge and the card show

extension BundleSync {
    func spaceState(_ location: ScanLocation) -> SpaceState {
        let sync = ControlPlaneSync.shared
        guard sync.client != nil, sync.stateIsCurrent, sync.confirmedSpaces.contains(location.id) else { return .off }
        let ids: [UUID] = location.scans.map { $0.id }
        if let active, ids.contains(active.scanId) { return .uploading }
        let states = ids.map { remote[$0]?.state }
        if states.contains(where: { $0 == "queued" || $0 == "ingesting" }) { return .uploading }
        if states.contains("failed") || ids.contains(where: { failures[$0] != nil || refusal($0) != nil }) { return .failed }
        if !ids.isEmpty && states.allSatisfy({ $0 == "current" }) { return .everything }
        return .map
    }

    /// The scan card's sync line; nil when its space isn't synced.
    func line(for scan: CapturedScan) -> (text: String, failed: Bool)? {
        let sync = ControlPlaneSync.shared
        guard sync.client != nil, sync.stateIsCurrent, let space: UUID = scan.location?.id,
              sync.confirmedSpaces.contains(space) else { return nil }
        let id: UUID = scan.id
        if let active, active.scanId == id {
            switch active.activity {
            case .coloring: return ("Coloring for sync…", false)
            case .building: return ("Preparing its bundle…", false)
            case .uploading(let fraction):
                if fraction == 0 && wifiOnly && onExpensiveNetwork { return ("Map only · waiting for Wi-Fi", false) }
                return ("Uploading \(Int((fraction * 100).rounded()))%", false)
            }
        }
        if let refusal = refusal(id) { return ("Sync stopped: \(refusal.reason)", true) }
        if let failure = failures[id] { return ("Sync failed: \(failure)", true) }
        switch remote[id]?.state {
        case "current": return ("Everything" + (remote[id]?.ingestedAt.flatMap(Self.shortDate).map { " · \($0)" } ?? ""), false)
        case "queued", "ingesting": return ("Uploaded, the server is unpacking it", false)
        case "failed": return ("The server couldn't unpack it: \(remote[id]?.error ?? "")", true)
        case "missing", "stale":
            if !isSelected(id) {
                return (isHeldBack(id) ? "Map only · Privacy Filter was off, not selected" : "Map only · not selected", false)
            }
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

    private func storeRemote() {
        UserDefaults.standard.set(try? JSONEncoder().encode(remote.mapKeys(\.uuidString)),
                                  forKey: AppConstants.Key.controlPlaneBundleStates)
    }

    private func storeRefused() {
        UserDefaults.standard.set(try? JSONEncoder().encode(refused.mapKeys(\.uuidString)),
                                  forKey: AppConstants.Key.controlPlaneBundlesRefused)
    }

    private func store(_ ids: Set<UUID>, _ key: String) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: key)
    }

    nonisolated private static func storedRemote() -> [UUID: Remote] {
        storedMap(AppConstants.Key.controlPlaneBundleStates)
    }

    nonisolated private static func storedRefused() -> [UUID: Refusal] {
        storedMap(AppConstants.Key.controlPlaneBundlesRefused)
    }

    nonisolated private static func storedMap<Value: Decodable>(_ key: String) -> [UUID: Value] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: Value].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
    }

    nonisolated private static func storedIds(_ key: String) -> Set<UUID> {
        Set((UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
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

    /// The scan and the version a task sends, from its description ("<scan id> <fingerprint>").
    private func describe(_ task: URLSessionTask) -> (scanId: UUID, fingerprint: String)? {
        guard let parts = task.taskDescription?.split(separator: " "), parts.count == 2,
              let id = UUID(uuidString: String(parts[0])) else { return nil }
        return (id, String(parts[1]))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let id = describe(task)?.scanId, totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        let taskId = task.taskIdentifier
        Task { @MainActor in BundleSync.shared.uploadProgress(id, task: taskId, fraction: fraction) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        bodies.withLock { $0[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = bodies.withLock { $0.removeValue(forKey: task.taskIdentifier) } ?? Data()
        guard let described = describe(task) else { return }
        let id = described.scanId
        let fingerprint = described.fingerprint
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let detail = ControlPlaneClient.detail(from: body)
        let taskId = task.taskIdentifier
        Task { @MainActor in
            BundleSync.shared.uploadFinished(id, fingerprint: fingerprint, task: taskId, status: status,
                                             error: error, detail: detail)
        }
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
