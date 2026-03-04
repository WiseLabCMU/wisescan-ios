import SwiftUI
import ARKit

struct ContentView: View {
    @State private var scanStore = ScanStore()
    @State private var selectedTab = 0
    @State private var showLiDARWarning = false

    private var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    var body: some View {
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

            WorkflowsView()
                .tabItem {
                    Label("Workflows", systemImage: "arrow.triangle.2.circlepath")
                }
                .tag(2)
        }
        .environment(scanStore)
        .preferredColorScheme(.dark)
        .onAppear {
            if !hasLiDAR {
                showLiDARWarning = true
            }
        }
        .alert("LiDAR Not Available", isPresented: $showLiDARWarning) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device does not have a LiDAR sensor. 3D scanning and mesh capture features require a LiDAR-equipped device (iPhone Pro or iPad Pro).")
        }
    }
}

#Preview {
    ContentView()
}
