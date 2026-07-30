import SwiftUI
import SwiftData
import ARKit

struct SettingsView: View {
    var scrollToDevMode: Bool = false
    @Environment(\.modelContext) private var modelContext
    @Query private var locations: [ScanLocation]

    @AppStorage(AppConstants.Key.rawOverlapMax) private var overlapMax: Double = AppConstants.overlapMax
    @AppStorage(AppConstants.Key.rawRejectBlur) private var rejectBlur: Bool = AppConstants.rejectBlur
    @AppStorage(AppConstants.Key.captureMode) private var captureMode: String = AppConstants.captureMode
    @AppStorage(AppConstants.Key.uploadURL) private var uploadURL = AppConstants.uploadURL
    @AppStorage(AppConstants.Key.developerMode) private var developerMode: Bool = AppConstants.developerMode
    @AppStorage(AppConstants.Key.mockIMU) private var mockIMU: Bool = AppConstants.mockIMU
    @AppStorage(AppConstants.Key.mockCameraImages) private var mockCameraImages: Bool = AppConstants.mockCameraImages
    @AppStorage(AppConstants.Key.mockDepthMaps) private var mockDepthMaps: Bool = AppConstants.mockDepthMaps
    @AppStorage(AppConstants.Key.mockWearable) private var mockWearable: Bool = AppConstants.mockWearable
    @AppStorage(AppConstants.Key.hideLivePoints) private var hideLivePoints: Bool = AppConstants.hideLivePoints
    @AppStorage(AppConstants.Key.perfDiagnostics) private var perfDiagnostics: Bool = AppConstants.perfDiagnostics
    @AppStorage(AppConstants.Key.pauseVRCompute) private var pauseVRCompute: Bool = AppConstants.pauseVRCompute
    @AppStorage(AppConstants.Key.vrBloomEnabled) private var vrBloomEnabled: Bool = AppConstants.vrBloomEnabled
    @AppStorage(AppConstants.Key.memDiagForceReclaim) private var memDiagForceReclaim: Bool = AppConstants.memDiagForceReclaim
    @AppStorage(AppConstants.Key.meshClassifier) private var meshClassifier: Bool = AppConstants.meshClassifier
    @AppStorage(AppConstants.Key.gpuColorize) private var gpuColorize: Bool = AppConstants.gpuColorize
    @AppStorage(AppConstants.Key.keyframeWeightBonus) private var keyframeWeightBonus: Bool = AppConstants.keyframeWeightBonus
    @AppStorage(AppConstants.Key.activeMeshColor) private var activeMeshColor: String = AppConstants.activeMeshColor
    // 0 = Auto (no override); N = force format index N-1 of supportedVideoFormats.
    @AppStorage(AppConstants.Key.videoFormatIndex) private var videoFormatIndex: Int = 0
    @AppStorage(AppConstants.Key.ghostMeshColor) private var ghostMeshColor: String = AppConstants.ghostMeshColor
    @AppStorage(AppConstants.Key.metaWearablesFPS) private var metaWearablesFPS: Double = AppConstants.metaWearablesFPS
    @AppStorage(AppConstants.Key.semanticLabeling) private var semanticLabeling: Bool = AppConstants.semanticLabeling
    @AppStorage(AppConstants.Key.scanCoachingEnabled) private var scanCoachingEnabled: Bool = AppConstants.scanCoachingEnabled
    @AppStorage(AppConstants.Key.colorizeOnPostprocess) private var colorizeOnPostprocess: Bool = AppConstants.colorizeOnPostprocess
    @AppStorage(AppConstants.Key.registerLegacyScans) private var registerLegacyScans: Bool = AppConstants.registerLegacyScans
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                LinearGradient(colors: [Color(white: 0.1), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                ScrollViewReader { proxy in
                List {
                    // MARK: - User Guide Link
                    Section {
                        NavigationLink(destination: UserGuideView()) {
                            HStack {
                                Image(systemName: "book.pages.fill")
                                    .foregroundColor(.cyan)
                                    .font(.title3)
                                Text("User Guide & Documentation")
                                    .foregroundColor(.white)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.05))

                    // MARK: - General Settings
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("https://your-server.example.com/uploads/", text: $uploadURL)
                                .foregroundColor(.white)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .keyboardType(.URL)
                            Text("HTTP(S) endpoint for scan uploads. Used by the Upload button on scan cards.")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("UPLOAD SERVER")
                    }
                    .listRowBackground(Color.white.opacity(0.05))

                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Image Overlap Maximum")
                                    .foregroundColor(.white)
                                Spacer()
                                Text("\(Int(overlapMax))%")
                                    .foregroundColor(.cyan)
                                    .font(.headline)
                            }
                            Slider(value: $overlapMax, in: 10...100, step: 5)
                                .tint(.cyan)
                            Text("Controls maximum overlap between consecutive captured frames. Lower values capture fewer, more distinct frames. Higher values capture more frames with greater overlap.")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding(.vertical, 4)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Capture View Mode")
                                .font(.headline)
                                .foregroundColor(.white)
                            Picker("Capture Mode", selection: $captureMode) {
                                Text("AR (Camera Feed)").tag(AppConstants.CaptureMode.ar.rawValue)
                                Text("VR (Live Point Cloud)").tag(AppConstants.CaptureMode.vr.rawValue)
                            }
                            .pickerStyle(.segmented)
                            .colorScheme(.dark)
                            Text("Switch between augmented reality (ARKit passthrough) and virtual reality (live depth point cloud) capture modes.")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding(.vertical, 4)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Meta Wearables Stream FPS")
                                    .foregroundColor(.white)
                                Spacer()
                                Text("\(Int(metaWearablesFPS)) FPS")
                                    .foregroundColor(.cyan)
                                    .font(.headline)
                            }
                            Slider(value: $metaWearablesFPS, in: 1...15, step: 1)
                                .tint(.cyan)
                            Text("Limits the incoming streaming frame rate to save battery and processing power.")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding(.vertical, 4)

                        Toggle(isOn: $rejectBlur) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Reject Blurred Frames")
                                    .foregroundColor(.white)
                                Text("Automatically discard frames with motion blur or camera shake during capture.")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        .tint(.cyan)
                        .padding(.vertical, 4)

                        // Mesh Visualization Colors
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Mesh Visualization")
                                .font(.headline)
                                .foregroundColor(.white)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Active Scan Wireframe")
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                                Picker("", selection: $activeMeshColor) {
                                    ForEach(meshColorOptions, id: \.self) { color in
                                        HStack {
                                            Circle()
                                                .fill(color.swiftUIColor)
                                                .frame(width: 12, height: 12)
                                            Text(color)
                                        }.tag(color)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .colorScheme(.dark)
                                Text("Color of the live depth mesh shown during scanning.")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Ghost Scan Wireframe")
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                                Picker("", selection: $ghostMeshColor) {
                                    ForEach(meshColorOptions, id: \.self) { color in
                                        HStack {
                                            Circle()
                                                .fill(color.swiftUIColor)
                                                .frame(width: 12, height: 12)
                                            Text(color)
                                        }.tag(color)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .colorScheme(.dark)
                                Text("Color of the previous scan overlay used for alignment.")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(.vertical, 4)

                        Toggle(isOn: $scanCoachingEnabled) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Scan Coaching")
                                    .foregroundColor(.white)
                                Text("Show real-time scanning tips and guidance during capture. Critical warnings (tracking, capacity) always display.")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        .tint(.cyan)
                        .padding(.vertical, 4)

                        Toggle(isOn: $semanticLabeling) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Semantic Labeling")
                                    .foregroundColor(.white)
                                Text("Enables room structure detection (walls, floors, doors) during scanning for semantic labels in exports and AR overlays.")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        .tint(.cyan)
                        .padding(.vertical, 4)

                        Toggle(isOn: $colorizeOnPostprocess) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Colorize During Post-process")
                                    .foregroundColor(.white)
                                Text("Include photo-based mesh coloring when post-processing a scan. Off = structural processing only (room model, alignment, rescan reference) — faster; you can color later by re-running Process.")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        .tint(.cyan)
                        .padding(.vertical, 4)

                    } header: {
                        Text("SCAN CAPTURE")
                    }
                    .listRowBackground(Color.white.opacity(0.05))

                    // MARK: - Data Management
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            HStack {
                                Image(systemName: "trash.fill")
                                Text("Delete All Scans")
                            }
                        }
                    } header: {
                        Text("DATA MANAGEMENT")
                    } footer: {
                        Text("This will permanently delete all scan locations, meshes, and raw data.")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    .listRowBackground(Color.white.opacity(0.05))

                    // MARK: - Developer Mode
                    Section {
                        Toggle(isOn: Binding(
                            get: { self.developerMode },
                            set: { newValue in
                                self.developerMode = newValue
                                if !newValue {
                                    // Reset all dev options to defaults when disabled
                                    self.mockIMU = AppConstants.mockIMU
                                    self.mockCameraImages = AppConstants.mockCameraImages
                                    self.mockDepthMaps = AppConstants.mockDepthMaps
                                    self.mockWearable = AppConstants.mockWearable
                                    self.semanticLabeling = AppConstants.semanticLabeling
                                    self.registerLegacyScans = AppConstants.registerLegacyScans
                                    // Default-TRUE dev toggle: a bench-OFF value must not leak into
                                    // production, where it would silently drop per-face classification
                                    // (the wall/non-wall labels plane registration depends on).
                                    self.meshClassifier = AppConstants.meshClassifier
                                    // Default-TRUE dev toggle: same leak rule as meshClassifier —
                                    // a bench-OFF value must not survive dev-mode exit.
                                    self.gpuColorize = AppConstants.gpuColorize
                                    self.keyframeWeightBonus = AppConstants.keyframeWeightBonus
                                    // Diagnostics toggles gate on their own keys (not developerMode),
                                    // so a bench-ON value would keep costing after dev-mode exit.
                                    self.hideLivePoints = AppConstants.hideLivePoints
                                    self.perfDiagnostics = AppConstants.perfDiagnostics
                                    self.pauseVRCompute = AppConstants.pauseVRCompute
                                    self.memDiagForceReclaim = AppConstants.memDiagForceReclaim
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Developer Mode")
                                    .foregroundColor(.white)
                                Text("Enable debugging tools for development and testing.")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        .tint(.orange)
                        .padding(.vertical, 4)

                        if developerMode {
                            Toggle(isOn: $mockIMU) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Simulate IMU & Poses")
                                        .foregroundColor(.white)
                                    Text("Simulates a continuous 360° circular trajectory to bypass overlap thresholds and test capture.")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.orange)
                            .padding(.vertical, 4)

                            Toggle(isOn: $mockCameraImages) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Simulate Camera Images")
                                        .foregroundColor(.white)
                                    Text("Injects a dynamically rendered synthetic frame sequence (a mid-air green box) instead of live camera.")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.orange)
                            .padding(.vertical, 4)

                            Toggle(isOn: $mockDepthMaps) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Simulate Depth Maps")
                                        .foregroundColor(.white)
                                    Text("Injects synthetic depth maps matching the virtual test images.")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.orange)
                            .padding(.vertical, 4)

                            #if canImport(MWDATMockDevice)
                            Toggle(isOn: $mockWearable) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Simulate Meta Wearable")
                                        .foregroundColor(.white)
                                    Text("Uses MockDeviceKit to simulate paired Meta Ray-Ban glasses without needing physical hardware.")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.orange)
                            .padding(.vertical, 4)
                            #endif

                            Toggle(isOn: $gpuColorize) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("GPU Colorize")
                                        .foregroundColor(.white)
                                    Text("Uses the Metal compute path for vertex-color projection (default). Turn OFF to force the CPU reference implementation — recolor the same scan once per setting to isolate suspected GPU artifacts (occlusion bleed-through, mask misses). The two paths must produce the same result; a difference is a GPU bug.")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.orange)
                            .padding(.vertical, 4)

                            Toggle(isOn: $keyframeWeightBonus) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Keyframe Weight Bonus")
                                        .foregroundColor(.white)
                                    Text("Gives sharp stillness keyframes a 3× vote in the vertex-color weighted median (default). Turn OFF to weight stills and motion frames equally — recolor the same scan once per setting to see whether the bonus amplifies edge bleed or, conversely, equal weighting lets blurry sweep colors mush crisp surfaces.")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.orange)
                            .padding(.vertical, 4)

                            Toggle(isOn: $hideLivePoints) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Hide Live Points (VR)")
                                        .foregroundColor(.white)
                                    Text("Hides the live depth point cloud in VR capture so only the accumulated voxel cloud is shown. Applied when entering VR capture. Useful for inspecting how the accumulated voxels hold up.")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.orange)
                            .padding(.vertical, 4)

                            Toggle(isOn: $perfDiagnostics) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Perf Diagnostics")
                                        .foregroundColor(.white)
                                    Text("Logs main-thread stalls, ARKit frame gaps, capture-queue backlog, and GPU/voxel pass timings to the console (subsystem org.arenaxr.scan4d, category perf) and Instruments signposts. Use to diagnose the mid-scan freeze. Applied when entering capture.")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.orange)
                            .padding(.vertical, 4)

                            Toggle(isOn: $pauseVRCompute) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Pause VR Compute")
                                        .foregroundColor(.white)
                                    Text("Skips the entire VR GPU pipeline (point-cloud projection, voxel integration, extraction, and bloom) — not just hides it. Isolation test: if the freeze disappears with this on, the GPU pipeline is implicated. Applied per frame in VR capture.")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.orange)
                            .padding(.vertical, 4)

                            Toggle(isOn: $vrBloomEnabled) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("VR Bloom Effect")
                                        .foregroundColor(.white)
                                    Text("Glow post-process on the VR point cloud (two GPU passes + a half-res texture per frame). Off by default; most useful with Hide Live Points on, where the glow softens the raw accumulated voxels. Applied live, per frame, VR mode only.")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.orange)
                            .padding(.vertical, 4)

                            Toggle(isOn: $memDiagForceReclaim) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("MemDiag Force Reclaim")
                                        .foregroundColor(.white)
                                    Text("Memory attribution only. Forces freed pages back to the OS before [MemDiag] teardown snapshots so free-deltas reflect real reclaim, not cached pages. Expensive — leave OFF except when profiling. Needs Perf Diagnostics on.")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.orange)
                            .padding(.vertical, 4)

                            // ── Capture Quality ──

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Video Format")
                                    .foregroundColor(.white)
                                Text("ARKit video stream resolution. Higher = better splat quality but more storage. Requires session restart.")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                // @AppStorage (not a raw UserDefaults Binding) so the menu
                                // label refreshes when the selection changes. Tag N maps to
                                // format index N-1; 0 is the Auto sentinel.
                                Picker("Video Format", selection: $videoFormatIndex) {
                                    Text("Auto (Best Available)").tag(0)
                                    ForEach(Array(ARCoverageView.availableVideoFormats.enumerated()), id: \.offset) { index, label in
                                        Text("[\(index)] \(label)").tag(index + 1)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(.orange)
                            }
                            .padding(.vertical, 4)

                            Toggle(isOn: Binding(
                                get: {
                                    // Default to true when key hasn't been set yet
                                    UserDefaults.standard.object(forKey: AppConstants.Key.captureAudioEnabled) == nil
                                        ? AppConstants.captureAudioEnabled
                                        : UserDefaults.standard.bool(forKey: AppConstants.Key.captureAudioEnabled)
                                },
                                set: { UserDefaults.standard.set($0, forKey: AppConstants.Key.captureAudioEnabled) }
                            )) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Capture Audio")
                                        .foregroundColor(.white)
                                    Text("Play shutter click when a sharp frame is captured at a stillness point, and a chime when entering stillness.")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.orange)
                            .padding(.vertical, 4)

                            Toggle(isOn: $meshClassifier) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Mesh Classifier")
                                        .foregroundColor(.white)
                                    Text("Per-face ARKit mesh classification (.meshWithClassification). ON by default — benched at no measurable CPU delta, ~70–100 MB memory — and provides the wall/non-wall labels used for plane registration and the rescan reference mesh. Turn OFF only to re-run the A/B bench (each run stamps meshClassifier=on/off at RECORD-START).")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.orange)
                            .padding(.vertical, 4)

                            Toggle(isOn: $registerLegacyScans) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Register Legacy Scans")
                                        .foregroundColor(.white)
                                    Text("Lets pre-postprocess-era scans (no saved scan case) enter retroactive registration: old locations will show \"needs postprocess\" and Process may move their meshes into the canonical frame. OFF in production — a legacy adjacent-link is indistinguishable from a rescan and a similar room could false-lock. Scans of link-adjacent locations stay excluded either way.")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.orange)
                            .padding(.vertical, 4)
                        }
                    } header: {
                        Text("DEVELOPER MODE")
                    } footer: {
                        if developerMode {
                            Text("⚠️ Developer mode is active. Some features may behave differently than in production.")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                    .id("devModeSection")

                    // MARK: - App Info Footer
                    Section {
                        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
                        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
                        #if DEBUG
                        let distribution = "Debug"
                        #else
                        // TestFlight (and other sandbox installs) ship a "sandboxReceipt"; the App
                        // Store ships "receipt". Lets a tester tell a TestFlight build apart from a
                        // store build at a glance.
                        let distribution = (Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt") ? "TestFlight" : "App Store"
                        #endif

                        HStack {
                            Spacer()
                            VStack(spacing: 4) {
                                Text("Scan4D Version \(appVersion) (\(buildNumber))")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Text("Distribution: \(distribution)")
                                    .font(.caption2)
                                    .foregroundColor(.gray.opacity(0.7))
                            }
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                .scrollContentBackground(.hidden)
                .onAppear {
                    if scrollToDevMode {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation {
                                proxy.scrollTo("devModeSection", anchor: .top)
                            }
                        }
                    }
                }
                } // ScrollViewReader
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Delete All Data?", isPresented: $showDeleteConfirmation) {
                let totalScans = locations.reduce(0) { $0 + $1.scans.count }
                Button("Delete \(totalScans) Scan\(totalScans == 1 ? "" : "s")", role: .destructive) {
                    deleteAllData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                let totalScans = locations.reduce(0) { $0 + $1.scans.count }
                Text("This will permanently delete \(locations.count) location\(locations.count == 1 ? "" : "s") and \(totalScans) scan\(totalScans == 1 ? "" : "s"). This action cannot be undone.")
            }
            .preferredColorScheme(.dark)
        }
    }

    private func deleteAllData() {
        for location in locations {
            for scan in location.scans {
                ScanFileManager.shared.deleteScan(scan, context: modelContext)
            }
            modelContext.delete(location)
        }
        try? modelContext.save()
    }

    /// Available mesh wireframe color options
    private var meshColorOptions: [String] {
        ["Red", "Green", "Blue", "Yellow", "Cyan", "Magenta", "White", "Gray", "Black"]
    }
}

// MARK: - Color name → SwiftUI Color helper
extension String {
    var swiftUIColor: Color {
        switch self.lowercased() {
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        case "yellow": return .yellow
        case "cyan": return .cyan
        case "magenta": return Color(.magenta)
        case "white": return .white
        case "gray": return .gray
        case "black": return .black
        default: return .green
        }
    }
}

#Preview {
    SettingsView()
}
