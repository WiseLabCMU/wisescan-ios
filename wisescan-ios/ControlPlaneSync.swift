import Foundation
import Observation
import SwiftData

// MARK: - When and how the app syncs with the control plane (scan4d-server README, "Sync")

/// Sends the whole local inventory (`ControlPlaneManifest`) to the control plane: on launch and
/// return to the foreground, a few seconds after SwiftData saves (coalesced), and from Settings.
/// Never during a capture: a request then waits for the capture to end, so the network and the
/// file reads stay off the AR session's back. Does nothing while no server host is set.
@Observable
@MainActor
final class ControlPlaneSync {
    static let shared = ControlPlaneSync()

    enum Status: Equatable {
        case off
        case idle
        case syncing
        case synced(Date, summary: String)
        case failed(String)
    }

    private(set) var status: Status = .idle

    @ObservationIgnored private var captureActive = false
    @ObservationIgnored private var container: ModelContainer?
    @ObservationIgnored private var saveObserver: NSObjectProtocol?
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var deferredForCapture = false

    private init() {}

    var host: String { UserDefaults.standard.string(forKey: AppConstants.Key.controlPlaneHost) ?? "" }
    var deviceLabel: String { UserDefaults.standard.string(forKey: AppConstants.Key.controlPlaneDeviceLabel) ?? "" }
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
        do {
            let reply = try await Task.detached(priority: .utility) {
                var manifest = draft
                manifest.readScanFiles(files)
                return try await client.sync(manifest)
            }.value
            let summary = "\(reply.maps) spaces, \(reply.scans) scans, \(reply.links) links"
            status = .synced(Date(), summary: summary)
            PerfDiag.log("[ControlPlane] synced: \(summary), \(reply.markedGone) marked gone")
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
