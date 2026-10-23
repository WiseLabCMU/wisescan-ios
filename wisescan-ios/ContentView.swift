import SwiftUI
import SwiftData
import ARKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var scanStore = ScanStore()
    @State private var selectedTab = 0
    @State private var showLiDARWarning = false
    @AppStorage(AppConstants.Key.developerMode) private var developerMode: Bool = AppConstants.developerMode
    @State private var showDevSettings = false

    private var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
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
    }

    /// The space a handed-over region names; without a known one the region is refused (a file
    /// picked inside a space's Rescan sheet needs no id).
    private func openSpace(for region: FocusRegion) {
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
