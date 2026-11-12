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
                              "people out of the captured data. Switched off, it turns itself back on " +
                              "24 hours later, so a switch left off by mistake doesn't keep capturing " +
                              "people. Tap the capture button to start recording — " +
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
                        title: "Process & Color",
                        text: "Processing runs by itself after you save: it aligns rescans into the " +
                              "location's shared coordinate frame and prepares the rescan ghost. Tap " +
                              "'Color' on a scan card to color its mesh from your photos (it finishes any " +
                              "processing still left first); long-press it to re-run processing. If a scan " +
                              "isn't processed yet, Share and Rescan ask to process it first, and its " +
                              "bundle for the lab server waits until it is."
                    )
                    guideRow(
                        icon: "5.circle.fill",
                        title: "Rescan Space / Connect Adjacent Space",
                        text: "Tap 'Rescan Space' on any location to re-scan the identical area over time " +
                              "— a magenta ghost overlay shows " +
                              "your previous scan for reference, and each new scan is auto-aligned into " +
                              "the location's shared frame using detected walls and floors. " +
                              "Rescan asks what to capture: the whole room, or one region (a focus scan, " +
                              "below). " +
                              "Tap 'Connect Adjacent Space' to scan a neighboring room: relocalize with your " +
                              "previous scan, walk to where the new connector should be, " +
                              "and confirm to place the connector and start scanning the new space. " +
                              "Or, when you stop a scan, choose 'Save & Scan Adjacent' to drop a connector " +
                              "and carry straight on into the next space."
                    )
                    guideRow(
                        icon: "scope",
                        title: "Focus Scan a Region",
                        text: "Rescan Space > Focus on a region photographs one area in detail, like a " +
                              "work table. Tap a table or object in the scan to draw a box around it (or " +
                              "tap the surface for a default box), adjust it with the sliders, and pick " +
                              "how much to capture: Check takes about 5 photos and finishes by itself, " +
                              "Detail about 30, Splat 150 or more for 3D reconstruction. Look around until " +
                              "the ghost mesh appears (the scan can't start before that), and a yellow box " +
                              "shows the region: tap record and walk around it. If tracking is lost, the " +
                              "scan stops and keeps the photos taken so far. " +
                              "Photos are taken only while the box is in view; the dial fills with " +
                              "the directions you have covered. The result is a partial scan in the same " +
                              "location (no mesh of its own) that you can share or sync like any other. " +
                              "Once a space has focus scans, its list switches between Room, Focus and All " +
                              "(Room is the default; the list opens on a scan you just saved). " +
                              "A region file from another tool can be imported from the same menu. " +
                              "With a control plane set, the lab can also ask for a focus scan: the " +
                              "request waits in the To do list on the Dashboard, even offline (an urgent one also " +
                              "alerts once), and Open takes you to the region in the editor."
                    )
                    guideRow(
                        icon: "6.circle.fill",
                        title: "Choose Format",
                        text: "Pick the export format with Global Export Format on a space's screen: Scan4D " +
                              "(the default), OBJ, PLY, or USDZ. It applies to every space. Scan4D carries " +
                              "everything the scan captured; the lab server turns it into a Nerfstudio " +
                              "dataset or a flame3d bundle."
                    )
                    guideRow(
                        icon: "7.circle.fill",
                        title: "Share or Sync",
                        text: "Share sends the selected format to another app or device: Files, AirDrop, " +
                              "Mail. The screen stays on while a scan is being converted. Sync keeps your " +
                              "lab's server up to date with everything in the spaces you sync. Set the " +
                              "server in Settings > Control plane, then tap Sync to Lab Server in a space, " +
                              "or Sync on a stitched map in the graph view; Settings > Auto sync adds every " +
                              "space (All), the ones you start after joining (New, the default) or none " +
                              "(Off). The server gets each space's map first: names, times, poses, links " +
                              "and room layouts. Then each processed scan goes up as one bundle, photos " +
                              "included, with people blurred when the Privacy Filter is on. A bundle keeps " +
                              "going if you lock the screen or switch apps. Bundles wait for Wi-Fi unless " +
                              "you turn that off, and you choose which go in Settings > Control plane > " +
                              "Pending bundles. All are selected, except a scan captured with the Privacy " +
                              "Filter off: its photos show people unblurred, so it waits until you select " +
                              "it. No bundle is prepared during a scan or while you Share. A cloud on each space shows " +
                              "what the server has: an outline for its map, a green check for everything, " +
                              "an arrow while a bundle goes up (Troubleshooting, below, explains every " +
                              "badge). If the server wants its password, Sync opens Settings at the " +
                              "password field first, then carries on when you tap Done."
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
                        title: "Photos Are Automatic",
                        text: "High-resolution photos are taken for you whenever the device is steady " +
                              "enough and the view has changed since the last one; the amber overlay " +
                              "clears where photos land. Slow down over amber areas and step sideways " +
                              "now and then so surfaces are seen from more than one spot. With a 360° " +
                              "camera connected, tapping the screen while holding still takes a 360° " +
                              "still and a matching phone photo. The screen flashes briefly for every " +
                              "photo kept, so you can follow along with the sound off; the screen stays " +
                              "on while you record. In the mesh preview, the camera toggle " +
                              "shows where each photo was captured."
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
                              "(Save & Scan Adjacent or Connect Adjacent Space) instead of one huge scan."
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
                    Text("Room-structure classes detected while scanning, " +
                         "shown in these colors in the mesh preview's semantics view and listed on the " +
                         "scan HUD. All detected classes are always included in exports. " +
                         "The mesh preview names each box with RoomPlan's full label set " +
                         "(sofa, stove, bathtub and the rest), drawn as shades of these same " +
                         "colors — tap a legend row to hide or show that label, or tap a box " +
                         "to identify it.")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .listRowBackground(Color.white.opacity(0.05))

                // MARK: - Troubleshooting: status icons (UserGuideStatusIcons.swift)
                StatusIconsGuideSections()

                // MARK: - Export Formats
                Section {
                    formatRow(
                        format: "Scan4D",
                        desc: "Default format: everything the scan captured, in one zip. RGB frames and " +
                              "stills, 16-bit LiDAR depth and confidence, a camera pose for every image, " +
                              "the mesh with its colors, room layout (RoomPlan), ARKit feature points, " +
                              "spatial links (stitching), 360° stills with their cube faces, and " +
                              "scan4d_metadata. The lab server turns it into what other tools read: a " +
                              "Nerfstudio dataset for training, or the input flame3d searches objects in."
                    )
                    formatRow(
                        format: "USDZ",
                        desc: "Apple's 3D format converted from on-device mesh via ModelIO, with its colors. " +
                              "Opens natively on iPhone/iPad with Quick Look."
                    )
                    formatRow(
                        format: "PLY",
                        desc: "Polygon file converted from the on-device mesh, with per-vertex colors."
                    )
                    formatRow(
                        format: "OBJ",
                        desc: "Wavefront 3D mesh file. Universal format supported by almost all " +
                              "3D software, with per-vertex colors."
                    )
                    formatRow(
                        format: "Focus scan",
                        desc: "Focus scans always export as one zip, whatever format is selected: the " +
                              "photos with their poses, LiDAR depth and confidence, the region box " +
                              "(focus_region.json) and capture logs. With the Privacy Filter on, people " +
                              "are blurred, and a photo that can't be checked is left out."
                    )
                } header: {
                    Text("EXPORT FORMATS")
                } footer: {
                    Text("Every export carries the mesh, colored from your captured frames: a scan that " +
                         "hasn't been colored yet is colored first, so its first export takes a little longer.")
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
                           desc: "Desktop tool for NeRF/3DGS training. Train on the Nerfstudio dataset " +
                                 "the lab server makes from a Scan4D export.",
                           appStore: nil, website: "https://docs.nerf.studio")
                } header: {
                    Text("RECOMMENDED VIEWERS")
                } footer: {
                    Text("USDZ files can be previewed directly in the Files app. For OBJ/PLY, " +
                         "install MeshLab or Polycam. Scan4D exports are for the lab server, which " +
                         "turns them into a Nerfstudio dataset or a flame3d bundle.")
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
