import SwiftUI
import ARKit

struct ContentView: View {
    @State private var scanStore = ScanStore()
    @State private var selectedTab = 0
    @State private var showLiDARWarning = false
    @AppStorage(AppDefaults.Key.developerMode) private var developerMode: Bool = AppDefaults.developerMode
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

            // Persistent Developer Mode Banner
            if developerMode {
                Button(action: { showDevSettings = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "hammer.fill")
                            .font(.caption2)
                        Text("Developer Mode")
                            .font(.caption2)
                        Spacer()
                        Text("Tap to disable")
                            .font(.system(size: 9))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                }
                .sheet(isPresented: $showDevSettings) {
                    SettingsView(scrollToDevMode: true)
                }
            }
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
