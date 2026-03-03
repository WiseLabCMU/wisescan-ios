import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "square.grid.2x2")
                }

            CaptureView()
                .tabItem {
                    Label("Capture", systemImage: "camera.viewfinder")
                }

            WorkflowsView()
                .tabItem {
                    Label("Workflows", systemImage: "arrow.triangle.2.circlepath")
                }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
}
