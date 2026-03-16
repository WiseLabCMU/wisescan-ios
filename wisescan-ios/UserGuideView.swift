import SwiftUI

struct UserGuideView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LinearGradient(colors: [Color(white: 0.1), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            List {
                // MARK: - Workflow Guide
                Section {
                    guideRow(
                        icon: "1.circle.fill",
                        title: "Capture",
                        text: "Point your device at a scene. Toggle Privacy Filter to exclude people from the scan. Tap the capture button to start recording — the mesh overlay shows scanning progress in real-time."
                    )
                    guideRow(
                        icon: "2.circle.fill",
                        title: "Name & Save",
                        text: "Tap stop when done. Name your space to save it. Your scan appears on the Workflows tab under its specific Location."
                    )
                    guideRow(
                        icon: "3.circle.fill",
                        title: "Scan4D (Scan Again)",
                        text: "Tap 'Scan Again' on any Location to perform a time-series rescan. The app will relocalize using the previous scan's spatial anchors to perfectly align the new data."
                    )
                    guideRow(
                        icon: "4.circle.fill",
                        title: "Choose Format",
                        text: "Select an export format (Scan4D, Polycam, OBJ, PLY, USDZ, or RAW) using the format picker on each scan card."
                    )
                    guideRow(
                        icon: "5.circle.fill",
                        title: "Save or Upload",
                        text: "Save locally to Files, AirDrop to another device, or upload to your configured server."
                    )
                } header: {
                    Text("HOW TO USE")
                }
                .listRowBackground(Color.white.opacity(0.05))

                // MARK: - Export Formats
                Section {
                    formatRow(
                        format: "Scan4D",
                        desc: "Default format. Includes mesh, raw frames, depth maps, camera poses, and relocalization data. Optimized for Scan4D server workflows."
                    )
                    formatRow(
                        format: "Polycam",
                        desc: "Polycam-compatible bundle: RGB images, depth maps, per-frame camera JSONs (cameras/), and mesh_info.json. Compatible with Polycam's raw data import."
                    )
                    formatRow(
                        format: "RAW",
                        desc: "Nerfstudio-compatible bundle: RGB images, 16-bit depth maps, and camera poses (transforms.json). Use for NeRF/3DGS reconstruction."
                    )
                    formatRow(
                        format: "USDZ",
                        desc: "Apple's 3D format. Opens natively on iPhone/iPad with Quick Look — tap to view in AR."
                    )
                    formatRow(
                        format: "PLY",
                        desc: "Polygon file with vertex data. Common in photogrammetry and point cloud workflows."
                    )
                    formatRow(
                        format: "OBJ",
                        desc: "Wavefront 3D mesh. Universal format supported by almost all 3D software."
                    )
                } header: {
                    Text("EXPORT FORMATS")
                }
                .listRowBackground(Color.white.opacity(0.05))

                // MARK: - Recommended Viewers
                Section {
                    appRow(name: "Files", icon: "folder.fill", color: .blue,
                           desc: "Built-in. Browse exported files, preview USDZ in Quick Look.",
                           appStore: nil, website: nil)
                    appRow(name: "Reality Composer", icon: "arkit", color: .cyan,
                           desc: "Apple's AR viewer. Natively opens USDZ files in AR.",
                           appStore: "https://apps.apple.com/us/app/reality-composer/id1462358802",
                           website: nil)
                    appRow(name: "MeshLab", icon: "cube.transparent", color: .orange,
                           desc: "Free app for viewing OBJ and PLY meshes on iOS.",
                           appStore: "https://apps.apple.com/us/app/meshlab-for-ios/id465175969",
                           website: "https://www.meshlab.net")
                    appRow(name: "Polycam", icon: "viewfinder", color: .purple,
                           desc: "3D scanning app. Can import and view OBJ, PLY, and USDZ.",
                           appStore: "https://apps.apple.com/us/app/polycam-lidar-3d-scanner/id1532482376",
                           website: "https://poly.cam")
                    appRow(name: "Nerfstudio", icon: "desktopcomputer", color: .green,
                           desc: "Desktop tool for NeRF/3DGS training. Use RAW exports with ns-process-data.",
                           appStore: nil, website: "https://docs.nerf.studio")
                } header: {
                    Text("RECOMMENDED VIEWERS")
                } footer: {
                    Text("USDZ files can be previewed directly in the Files app. For OBJ/PLY, install MeshLab or Polycam. RAW exports are designed for desktop processing with Nerfstudio or COLMAP.")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("User Guide")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Helper Views

    @ViewBuilder
    private func guideRow(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.cyan)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .foregroundColor(.white)
                    .font(.subheadline).bold()
                Text(text)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func formatRow(format: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(format)
                .font(.caption).bold()
                .foregroundColor(.black)
                .frame(width: 40, height: 24)
                .background(Color.cyan)
                .cornerRadius(6)
            Text(desc)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func appRow(name: String, icon: String, color: Color, desc: String,
                        appStore: String? = nil, website: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .foregroundColor(.white)
                    .font(.subheadline).bold()
                Text(desc)
                    .font(.caption)
                    .foregroundColor(.gray)
                HStack(spacing: 12) {
                    if let appStore = appStore, let url = URL(string: appStore) {
                        Button(action: { UIApplication.shared.open(url) }) {
                            Label("App Store", systemImage: "arrow.down.app")
                                .font(.caption2)
                                .foregroundColor(.cyan)
                        }
                    }
                    if let website = website, let url = URL(string: website) {
                        Button(action: { UIApplication.shared.open(url) }) {
                            Label("Website", systemImage: "safari")
                                .font(.caption2)
                                .foregroundColor(.cyan)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        UserGuideView()
    }
}
