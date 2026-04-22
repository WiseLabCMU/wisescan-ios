import SwiftUI
import ARKit

struct ContentView: View {
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
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if !hasLiDAR {
                showLiDARWarning = true
            }
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
