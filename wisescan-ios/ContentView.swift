import SwiftUI
import SwiftData
import ARKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var scanStore = ScanStore()
    @State private var selectedTab = 0
    @State private var showLiDARWarning = false
    @AppStorage(AppConstants.Key.developerMode) private var developerMode: Bool = AppConstants.developerMode
    @State private var showDevSettings = false

    private var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    /// The AR session runs whenever the Capture tab is up, relocalizing before any recording
    /// starts; control plane syncs wait it out (ControlPlaneSync).
    private var arSessionBusy: Bool {
        scanStore.isCaptureActive || selectedTab == 1
    }

    var body: some View {
        ZStack(alignment: .top) {
            TabView(selection: $selectedTab) {
                DashboardView()
                    .tabItem {
                        Label("Dashboard", systemImage: "square.grid.2x2")
                    }
                    .tag(0)

                CaptureView(selectedTab: $selectedTab)
                    .tabItem {
                        Label("Capture", systemImage: "camera.viewfinder")
                    }
                    .tag(1)

                ScansListView(selectedTab: $selectedTab)
                    .tabItem {
                        Label("Scans", systemImage: "folder")
                    }
                    .tag(2)
            }
            .environment(scanStore)
            // Stamp the moment the tab actually changes, so the capture view can report how
            // long it took to come up. Everything between here and CaptureView's .onAppear —
            // view construction, ARSession configure, RoomPlan start, ghost/world-map load —
            // runs before MainThreadWatchdog is armed and was completely unmeasured.
            .onChange(of: selectedTab) { _, tab in
                if tab == 1 { PerfDiag.mark("captureViewOpen") }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            DemoDataSeeder.seedIfNeeded(context: modelContext)
            if !hasLiDAR {
                showLiDARWarning = true
            }
        }
        .task {
            // One-time import of legacy stitching.json files into SwiftData. Runs after the
            // synchronous seedIfNeeded in onAppear (so endpoint scans exist) since this task body
            // only begins executing after appear. Idempotent + UserDefaults-guarded + re-entrancy
            // guarded, so it's a safe no-op on every launch after the first.
            await StitchLinkStore.migrateFromFilesIfNeeded(context: modelContext)
            // Sweep "Adjacent to …" locations orphaned with 0 scans when a freeze/crash hit the
            // extend flow's record→save (the location is persisted before its scan is recorded).
            StitchLinkStore.reconcileOrphanedAdjacentLocations(context: modelContext)
            // Control plane: report this phone's inventory now and after every save.
            ControlPlaneSync.shared.captureStateChanged(active: arSessionBusy)
            ControlPlaneSync.shared.start(container: modelContext.container)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                ControlPlaneSync.shared.requestSync(after: .seconds(1))
            }
        }
        .onChange(of: arSessionBusy) { _, busy in
            ControlPlaneSync.shared.captureStateChanged(active: busy)
        }
        .alert("Lite Mode — No LiDAR", isPresented: $showLiDARWarning) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("This device does not have a LiDAR sensor. You can still capture images and camera poses for server-side photogrammetry, but real-time 3D mesh, depth, and coverage overlay features are unavailable.")
        }
        // A focus region handed over by deep link (FocusRegionInbox): open its space, whose
        // detail view takes the region into the editor. Refusals surface as an alert.
        .onChange(of: FocusRegionInbox.shared.pending) { _, region in
            guard let region else { return }
            openSpace(for: region)
        }
        .alert("Focus region not opened", isPresented: Binding(
            get: { FocusRegionInbox.shared.lastError != nil },
            set: { if !$0 { FocusRegionInbox.shared.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(FocusRegionInbox.shared.lastError ?? "")
        }
        // The control plane asking for a focus scan (a task): Open takes the region into its
        // space's editor through the same inbox as a deep link.
        .alert("Focus scan requested", isPresented: Binding(
            get: { ControlPlaneSync.shared.taskToPrompt != nil },
            set: { if !$0 { ControlPlaneSync.shared.dismissPrompt() } }),
               presenting: ControlPlaneSync.shared.taskToPrompt) { task in
            Button("Open") { ControlPlaneSync.shared.open(task) }
            Button("Decline", role: .destructive) { ControlPlaneSync.shared.decline(task) }
            Button("Later", role: .cancel) { ControlPlaneSync.shared.dismissPrompt() }
        } message: { task in
            Text(taskPromptMessage(task))
        }
    }

    private func taskPromptMessage(_ task: ControlPlaneClient.ScanTask) -> String {
        let what = task.region.label.isEmpty ? "A region" : task.region.label
        let reason = task.reason.isEmpty ? "" : "\n\n\(task.reason)"
        return "\(what) in \(task.mapName), at \(task.region.detail.title) detail.\(reason)\n\nLater: Settings → Control plane."
    }

    /// The space a handed-over region names; without a known one the region is refused (a file
    /// picked inside a space's Rescan sheet needs no id).
    private func openSpace(for region: FocusRegion) {
        // Switching tabs mid-capture would end the capture (CaptureView's leave-tab teardown).
        guard !scanStore.isCaptureActive else {
            FocusRegionInbox.shared.pending = nil
            FocusRegionInbox.shared.lastError = "A scan is in progress. Finish it, then open the focus region link again."
            return
        }
        guard let locationId = region.locationId else {
            FocusRegionInbox.shared.pending = nil
            FocusRegionInbox.shared.lastError = "The focus region does not say which space it belongs to (location_id). Import it from that space's Rescan button instead."
            return
        }
        let descriptor = FetchDescriptor<ScanLocation>(predicate: #Predicate { $0.id == locationId })
        guard let location = try? modelContext.fetch(descriptor).first, location.latestRoomScan != nil else {
            FocusRegionInbox.shared.pending = nil
            FocusRegionInbox.shared.lastError = "The space this focus region names is not on this device, or has no room scan to draw it on."
            return
        }
        selectedTab = 2
        scanStore.navigationPath = NavigationPath()
        scanStore.navigationPath.append(location)
    }
}

#Preview {
    ContentView()
}
