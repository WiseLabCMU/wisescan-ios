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
            // Auto-navigate tabs for the rig calibration flow:
            //   Dashboard "Calibrate" → Capture tab (AR mesh + stills) → Dashboard (review results)
            // The calibration overlay and AR session (mesh) live on the capture tab;
            // the review/accept UI lives on the Dashboard card.
            .onChange(of: RigCalibrationManager.shared.state) { _, newState in
                switch newState {
                case .capturing, .solving:
                    // Stills + solver run on the Capture tab (needs AR session)
                    if selectedTab != 1 { selectedTab = 1 }
                case .review, .failed:
                    // Review/accept (or failure/retry) lives on the Dashboard card
                    if selectedTab != 0 { selectedTab = 0 }
                case .idle:
                    break // stay wherever the user is
                }
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
        }
        .alert("Lite Mode — No LiDAR", isPresented: $showLiDARWarning) {
            Button("Got it", role: .cancel) {}
        } message: {
            Text("This device does not have a LiDAR sensor. You can still capture images and camera poses for server-side photogrammetry, but real-time 3D mesh, depth, and coverage overlay features are unavailable.")
        }
    }
}

#Preview {
    ContentView()
}
