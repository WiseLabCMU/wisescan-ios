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
                        title: "Analyze (Optional)",
                        text: "Before recording, tap Analyze and sweep the room. The app checks " +
                              "lighting, screens, open doors, and people, then reports what to fix " +
                              "for the best scan quality."
                    )
                    guideRow(
                        icon: "2.circle.fill",
                        title: "Capture",
                        text: "Point your device at a scene. The Privacy Filter (on by default) masks " +
                              "people out of the captured data. Tap the capture button to start recording — " +
                              "the mesh overlay shows scanning progress in real-time, and coaching tips " +
                              "appear when the scan needs attention (moving too fast, session near capacity). " +
                              "The overlay color tells you what each area still needs: green = not yet " +
                              "scanned, amber = depth captured but no photo yet, clear = photo-grade."
                    )
                    guideRow(
                        icon: "3.circle.fill",
                        title: "Stop, Name & Save",
                        text: "Tap stop when done and choose Save & End (or Save & Scan Adjacent to " +
                              "continue into the next room). The scan saves in the background — once " +
                              "it finishes, name your space. Your scan appears on the Workflows tab " +
                              "under its specific Location."
                    )
                    guideRow(
                        icon: "4.circle.fill",
                        title: "Process",
                        text: "Tap 'Process' on the scan card (or 'Process All' on a location) to finish " +
                              "the scan on-device: it aligns rescans into the location's shared coordinate " +
                              "frame, prepares the rescan ghost, and applies camera-based color. Upload, " +
                              "export, and rescan unlock once processing completes."
                    )
                    guideRow(
                        icon: "5.circle.fill",
                        title: "Rescan Space / Connect Adjacent Space",
                        text: "Tap 'Rescan Space' on any location to re-scan the identical area over time " +
                              "— a colored ghost overlay (default magenta, configurable in Settings) shows " +
                              "your previous scan for reference, and each new scan is auto-aligned into " +
                              "the location's shared frame using detected walls and floors. " +
                              "Tap 'Connect Adjacent Space' to scan a neighboring room: relocalize with your " +
                              "previous scan, walk to where the new connector should be, " +
                              "and confirm to place the connector and start scanning the new space. " +
                              "You can also tap 'Pin & Extend' mid-scan to drop a connector and continue " +
                              "into the next space without stopping."
                    )
                    guideRow(
                        icon: "6.circle.fill",
                        title: "Choose Format",
                        text: "Select an export format (Scan4D, Polycam, OBJ, PLY, USDZ, or RAW) " +
                              "using the format picker on each scan card."
                    )
                    guideRow(
                        icon: "7.circle.fill",
                        title: "Save or Upload",
                        text: "Save locally to Files, AirDrop to another device, or upload to your " +
                              "configured server. A cloud badge on each location shows upload state: " +
                              "solid when every scan is uploaded, dimmed when only some are."
                    )
                } header: {
                    Text("HOW TO USE")
                }
                .listRowBackground(Color.white.opacity(0.05))

                // MARK: - Scan Tips
                // User-facing distillation of the pre-scan analyzer checks and mid-scan
                // coaching rules — keep consistent with docs/SCAN_GUIDANCE.md.
                Section {
                    guideRow(
                        icon: "lightbulb.fill",
                        title: "Light the Room",
                        text: "Good, even lighting matters most — dim areas produce poor color data. " +
                              "Turn on the lights, and run Analyze if you're unsure."
                    )
                    guideRow(
                        icon: "tortoise.fill",
                        title: "Move Slowly & Smoothly",
                        text: "Fast motion blurs frames and can break tracking. Sweep steadily, and " +
                              "follow the on-screen tip if the app asks you to slow down or hold steady."
                    )
                    guideRow(
                        icon: "camera.fill",
                        title: "Hold Still, Tap for Photos",
                        text: "To capture a high-resolution photo, hold still until the center ring " +
                              "locks green, then tap the screen: a shutter click and flash confirm the " +
                              "shot, and the amber overlay clears where the photo landed. Tap on every " +
                              "amber area — these crisp stills drive the final texture quality. In the " +
                              "mesh preview, the camera toggle shows where each still (and motion frame) " +
                              "was captured."
                    )
                    guideRow(
                        icon: "arrow.left.and.right",
                        title: "Layout First, Details Second",
                        text: "Quickly cover all four walls for layout context, sweeping systematically " +
                              "from one wall to the opposite. Then move closer for fine detail and vary " +
                              "your scanning height so surfaces are seen from more than one angle."
                    )
                    guideRow(
                        icon: "tv.slash",
                        title: "Avoid Screens, Mirrors & Open Doors",
                        text: "TVs, monitors, mirrors, and glass confuse depth sensing — turn screens off. " +
                              "Close doors so the scan doesn't trail into incomplete neighboring areas " +
                              "(use Connect Adjacent Space for those instead)."
                    )
                    guideRow(
                        icon: "gauge.with.needle",
                        title: "Watch the Capacity Bar",
                        text: "Long scans approach session limits — save when the capacity warning appears. " +
                              "For large or multi-room spaces, capture several linked scans " +
                              "(Pin & Extend or Connect Adjacent Space) instead of one huge scan."
                    )
                } header: {
                    Text("SCAN TIPS")
                }
                .listRowBackground(Color.white.opacity(0.05))

                // MARK: - Semantic Colors
                Section {
                    ForEach(SemanticClass.allCases.filter { $0 != .none }, id: \.rawValue) { cls in
                        legendRow(
                            color: cls.swiftUIDisplayColor,
                            name: cls.rawValue.capitalized,
                            desc: cls.classDescription,
                            dimmed: cls == .ceiling
                        )
                    }
                } header: {
                    Text("SEMANTIC COLORS")
                } footer: {
                    Text("Room-structure classes detected while scanning (with Semantic Labeling on), " +
                         "shown in these colors in the mesh preview's semantics view and listed on the " +
                         "scan HUD. All detected classes are always included in exports.")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .listRowBackground(Color.white.opacity(0.05))

                // MARK: - Export Formats
                Section {
                    formatRow(
                        format: "Scan4D",
                        desc: "Default format. Includes scan4d_metadata, relocalization worldmap, " +
                              "room layout (roomplan) and spatial-link (stitching) metadata, " +
                              "plus the full Polycam raw import payload " +
                              "(images, depth, cameras, mesh_info). Zip archive."
                    )
                    formatRow(
                        format: "Polycam",
                        desc: "Polycam raw data import only: RGB images, depth maps, per-frame camera JSONs " +
                              "(cameras/), and mesh_info.json. Zip archive."
                    )
                    formatRow(
                        format: "RAW",
                        desc: "Nerfstudio-compatible bundle: RGB images, 16-bit depth maps, " +
                              "and camera poses (transforms.json). Use for NeRF/3DGS reconstruction."
                    )
                    formatRow(
                        format: "USDZ",
                        desc: "Apple's 3D format converted from on-device mesh via ModelIO. " +
                              "Opens natively on iPhone/iPad with Quick Look."
                    )
                    formatRow(
                        format: "PLY",
                        desc: "Polygon file with embedded vertex colors, converted from on-device OBJ mesh."
                    )
                    formatRow(
                        format: "OBJ",
                        desc: "Wavefront 3D mesh file. Universal format supported by almost all " +
                              "3D software. No vertex colors."
                    )
                } header: {
                    Text("EXPORT FORMATS")
                }
                .listRowBackground(Color.white.opacity(0.05))

                // MARK: - Supported Wearables
                Section {
                    appRow(name: "Meta Ray-Ban Smart Glasses", icon: "eyeglasses", color: .indigo,
                           desc: "Stream proxy frames directly from your Meta Ray-Bans " +
                                 "via the Device Access Toolkit (DAT).",
                           appStore: nil, website: "https://developers.meta.com/wearables")
                } header: {
                    Text("SUPPORTED WEARABLES")
                } footer: {
                    Text("Follow the Meta Wearables developer documentation to enable developer mode " +
                         "and pair your smart glasses.")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .listRowBackground(Color.white.opacity(0.05))

                // MARK: - Device Connection Guides
                Section {
                    NavigationLink(destination: MetaConnectionGuideView()) {
                        guideRow(icon: "eyeglasses", title: "Connect Meta Ray-Ban",
                                 text: "Pair in Meta AI, grant camera access, and stream proxy frames during a scan.")
                    }
                    NavigationLink(destination: ThetaConnectionGuideView()) {
                        guideRow(icon: "camera.aperture", title: "Connect Ricoh Theta",
                                 text: "Join the 360° camera's Wi‑Fi and trigger stills from the Dashboard.")
                    }
                } header: {
                    Text("DEVICE CONNECTION")
                } footer: {
                    Text("Step-by-step setup and troubleshooting for each supported capture device.")
                        .font(.caption2)
                        .foregroundColor(.gray)
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
                    Text("USDZ files can be previewed directly in the Files app. For OBJ/PLY, " +
                         "install MeshLab or Polycam. RAW exports are designed " +
                         "for desktop processing with Nerfstudio or COLMAP.")
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
}

// MARK: - Helper Views
// In a private extension so the main struct body stays under the type_body_length limit.

private extension UserGuideView {
    @ViewBuilder
    func guideRow(icon: String, title: String, text: String) -> some View {
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
    func legendRow(color: Color, name: String, desc: String, dimmed: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(dimmed ? color.opacity(0.3) : color)
                .frame(width: 12, height: 12)
                .frame(width: 28) // align with guideRow icons
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .foregroundColor(dimmed ? .gray : .white)
                    .font(.subheadline)
                Text(desc)
                    .font(.caption)
                    .foregroundColor(dimmed ? .gray.opacity(0.7) : .gray)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    func formatRow(format: String, desc: String) -> some View {
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
    func appRow(name: String, icon: String, color: Color, desc: String,
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
                        Button(action: { UIApplication.shared.open(url) }, label: {
                            Label("App Store", systemImage: "arrow.down.app")
                                .font(.caption2)
                                .foregroundColor(.cyan)
                        })
                    }
                    if let website = website, let url = URL(string: website) {
                        Button(action: { UIApplication.shared.open(url) }, label: {
                            Label("Website", systemImage: "safari")
                                .font(.caption2)
                                .foregroundColor(.cyan)
                        })
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
