import SwiftUI
import SwiftData
import ARKit

/// A developer slider's scale: its range, step, and the unit its value reads in ("60%", "7 FPS").
private struct DevSliderScale {
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
}

struct SettingsView: View {
    var scrollToDevMode: Bool = false
    @Environment(\.modelContext) private var modelContext
    @Query private var locations: [ScanLocation]

    @AppStorage(AppConstants.Key.rawOverlapMax) private var overlapMax: Double = AppConstants.overlapMax
    @AppStorage(AppConstants.Key.rawRejectBlur) private var rejectBlur: Bool = AppConstants.rejectBlur
    @AppStorage(AppConstants.Key.captureMode) private var captureMode: String = AppConstants.captureMode
    @AppStorage(AppConstants.Key.developerMode) private var developerMode: Bool = AppConstants.developerMode
    @AppStorage(AppConstants.Key.mockIMU) private var mockIMU: Bool = AppConstants.mockIMU
    @AppStorage(AppConstants.Key.mockCameraImages) private var mockCameraImages: Bool = AppConstants.mockCameraImages
    @AppStorage(AppConstants.Key.mockDepthMaps) private var mockDepthMaps: Bool = AppConstants.mockDepthMaps
    @AppStorage(AppConstants.Key.mockWearable) private var mockWearable: Bool = AppConstants.mockWearable
    @AppStorage(AppConstants.Key.hideLivePoints) private var hideLivePoints: Bool = AppConstants.hideLivePoints
    @AppStorage(AppConstants.Key.perfDiagnostics) private var perfDiagnostics: Bool = AppConstants.perfDiagnostics
    @AppStorage(AppConstants.Key.perfSampleUnderDebugger) private var perfSampleUnderDebugger: Bool = AppConstants.perfSampleUnderDebugger
    @AppStorage(AppConstants.Key.sweepCoverageLiveReadout) private var sweepCoverageLiveReadout: Bool = AppConstants.sweepCoverageLiveReadout
    @AppStorage(AppConstants.Key.pauseVRCompute) private var pauseVRCompute: Bool = AppConstants.pauseVRCompute
    @AppStorage(AppConstants.Key.vrBloomEnabled) private var vrBloomEnabled: Bool = AppConstants.vrBloomEnabled
    @AppStorage(AppConstants.Key.memDiagForceReclaim) private var memDiagForceReclaim: Bool = AppConstants.memDiagForceReclaim
    @AppStorage(AppConstants.Key.forceRebuildArtifacts) private var forceRebuildArtifacts: Bool = AppConstants.forceRebuildArtifacts
    @AppStorage(AppConstants.Key.meshClassifier) private var meshClassifier: Bool = AppConstants.meshClassifier
    @AppStorage(AppConstants.Key.colorizeFrom360Faces) private var colorizeFrom360Faces: Bool = AppConstants.colorizeFrom360Faces
    @AppStorage(AppConstants.Key.keepCameraOriginals) private var keepCameraOriginals: Bool = AppConstants.keepCameraOriginals
    @AppStorage(AppConstants.Key.privacyFilterTimeLimitHours) private var privacyFilterTimeLimitHours: Int = AppConstants.privacyFilterTimeLimitHours
    @AppStorage(AppConstants.Key.gpuColorize) private var gpuColorize: Bool = AppConstants.gpuColorize
    @AppStorage(AppConstants.Key.keyframeWeightBonus) private var keyframeWeightBonus: Bool = AppConstants.keyframeWeightBonus
    @AppStorage(AppConstants.Key.robustColorMedian) private var robustColorMedian: Bool = AppConstants.robustColorMedian
    @AppStorage(AppConstants.Key.activeMeshColor) private var activeMeshColor: String = AppConstants.activeMeshColor
    // 0 = Auto (no override); N = force format index N-1 of supportedVideoFormats.
    @AppStorage(AppConstants.Key.videoFormatIndex) private var videoFormatIndex: Int = AppConstants.videoFormatIndex
    @AppStorage(AppConstants.Key.captureAudioEnabled) private var captureAudioEnabled: Bool = AppConstants.captureAudioEnabled
    @AppStorage(AppConstants.Key.ghostMeshColor) private var ghostMeshColor: String = AppConstants.ghostMeshColor
    @AppStorage(AppConstants.Key.metaWearablesFPS) private var metaWearablesFPS: Double = AppConstants.metaWearablesFPS
    @AppStorage(AppConstants.Key.semanticLabeling) private var semanticLabeling: Bool = AppConstants.semanticLabeling
    @AppStorage(AppConstants.Key.scanCoachingEnabled) private var scanCoachingEnabled: Bool = AppConstants.scanCoachingEnabled
    @AppStorage(AppConstants.Key.rigMeasuredDyMeters) private var rigMeasuredDyMeters: Double = 0
    @AppStorage(AppConstants.Key.rigHeightUnitImperial) private var rigHeightUnitImperial: Bool = false
    /// The rig-height editor (RigHeightSheet: keypad, m/in, commit on Set).
    @State private var showRigHeightSheet = false
    @State private var isExportingLog = false
    @State private var diagnosticsLogURL: URL?
    @State private var showRestoreDeveloperDefaults = false

    @ViewBuilder
    private var settingsSection1: some View {
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
    }

    @ViewBuilder
    private var settingsSection3: some View {
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
    }

    /// Developer Mode, in groups like the everyday Settings: the master switch with the field's
    /// diagnostics right under it (Export Diagnostics Log, Perf Diagnostics and its sub-options),
    /// then Capture, Privacy & 360° camera, Color, Display & VR, Simulation and Processing, and
    /// Restore last.
    /// A new developer option goes into the group it belongs to AND into
    /// AppConstants.developerOptionDefaults; the Restore section stays last.
    @ViewBuilder
    private var settingsSection4: some View {
        developerModeSection
        if developerMode {
            developerCaptureSection
            developerPrivacySection
            developerColorSection
            developerDisplaySection
            developerSimulationSection
            developerProcessingSection
            developerRestoreSection
        }
    }

    private var developerModeSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { self.developerMode },
                set: { newValue in
                    self.developerMode = newValue
                    if !newValue {
                        // Leaving Developer Mode restores every developer option, the same
                        // list as the Restore button: no bench value may outlive dev mode
                        // (why each one matters: AppConstants.developerOptionDefaults).
                        AppConstants.restoreDeveloperDefaults()
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
                diagnosticsExportRow
                devToggle($perfDiagnostics, "Perf Diagnostics",
                          "Logs main-thread stalls, ARKit frame gaps, capture-queue backlog, and GPU/voxel pass timings to the console (subsystem org.arenaxr.scan4d, category perf) and Instruments signposts. Use to diagnose the mid-scan freeze. Applied when entering capture.")
                if perfDiagnostics {
                    devToggle($perfSampleUnderDebugger, "Sample Stalls Under Debugger",
                              "Off: when Xcode is attached the sampler stays quiet, because lldb pauses the app on its SIGUSR1 (the pause itself shows the stack). On: it fires anyway and logs frames — first run `process handle SIGUSR1 -n false -p true -s false` in the lldb console (or add it to ~/.lldbinit), or every stall over 2 s will pause the debugger.")
                    devToggle($sweepCoverageLiveReadout, "Live Coverage Readout",
                              "While recording, shows the sweep-coverage counters in a small block at the left edge, refreshed once a second: observed surface and free cells, updates, dropped frames (busy/rate), skipped frames (tracking/no depth), and per-update CPU. The same numbers the [Coverage] log lines carry, live. Reads a cached copy and never pauses the sweep. Requires Perf Diagnostics on.")
                    devToggle($memDiagForceReclaim, "MemDiag Force Reclaim",
                              "Memory attribution only. Forces freed pages back to the OS before [MemDiag] teardown snapshots so free-deltas reflect real reclaim, not cached pages. Expensive — leave OFF except when profiling. Needs Perf Diagnostics on.")
                }
            }
        } header: {
            Text("DEVELOPER MODE")
        } footer: {
            if developerMode {
                Label("Developer mode is active. Some features may behave differently than in production.",
                      systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.tintedIcon(.orange))
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .listRowBackground(Color.white.opacity(0.05))
        .id("devModeSection")
    }

    private var developerCaptureSection: some View {
        devSection("CAPTURE", icon: "camera.fill") {
            devSlider($overlapMax, "Image Overlap Maximum", DevSliderScale(range: 10...100, step: 5, unit: "%"),
                      "Controls maximum overlap between consecutive captured frames. Lower values capture fewer, more distinct frames. Higher values capture more frames with greater overlap.")
            devToggle($rejectBlur, "Reject Blurred Frames",
                      "Automatically discard frames with motion blur or camera shake during capture.")
            devToggle($semanticLabeling, "Semantic Labeling",
                      "Room structure detection (RoomPlan: walls, floors, doors) during scanning, for semantic labels, registration and the rescan reference. ON by default. Off saves memory, but scans then get no room data and Rescan / Connect Adjacent treat them as bad scans.")
            devToggle($meshClassifier, "Mesh Classifier",
                      "Per-face ARKit mesh classification (.meshWithClassification). ON by default — benched at no measurable CPU delta, ~70–100 MB memory — and provides the wall/non-wall labels used for plane registration and the rescan reference mesh. Turn OFF only to re-run the A/B bench (each run stamps meshClassifier=on/off at RECORD-START).")
            videoFormatPicker
            // @AppStorage (not a raw UserDefaults Binding) so the switch redraws when a
            // restore removes the stored value.
            devToggle($captureAudioEnabled, "Capture Audio",
                      "Play a shutter click for a tapped 360° rig still, and a chime when entering stillness. Automatic stills make the system camera sound, which the silent switch mutes. The screen flashes for every saved still either way.")
            devSlider($metaWearablesFPS, "Meta Wearables Stream FPS", DevSliderScale(range: 1...15, step: 1, unit: " FPS"),
                      "Limits the incoming streaming frame rate to save battery and processing power.")
        }
    }

    private var developerPrivacySection: some View {
        devSection("PRIVACY & 360° CAMERA", icon: "hand.raised.fill") {
            privacyTimeLimitPicker
            devToggle($keepCameraOriginals, "Keep 360° Originals on Camera",
                      "Debugging only: skips the security sweep that deletes each 360° still from the camera once its bytes are verified on the device. Raw equirects capture bystanders in every direction, and the camera's open access point with factory password is the weakest place to leave them — keep this OFF except when comparing against camera-side originals.")
        }
    }

    /// The colorize A/B switches (projection path, keyframe weighting, reduce) and the 360° face probe.
    private var developerColorSection: some View {
        devSection("COLOR", icon: "paintpalette.fill") {
            devToggle($gpuColorize, "GPU Colorize",
                      "Uses the Metal compute path for vertex-color projection (default). Turn OFF to force the CPU reference implementation — recolor the same scan once per setting to isolate suspected GPU artifacts (occlusion bleed-through, mask misses). The two paths must produce the same result; a difference is a GPU bug.")
            devToggle($keyframeWeightBonus, "Keyframe Weight Bonus",
                      "Gives sharp stillness keyframes a 3× vote in the vertex-color weighted median (default). Turn OFF to weight stills and motion frames equally — recolor the same scan once per setting to see whether the bonus amplifies edge bleed or, conversely, equal weighting lets blurry sweep colors mush crisp surfaces.")
            devToggle($robustColorMedian, "Robust Color Median",
                      "Resolves each vertex color by consensus: picks the observation that most agrees with the others and averages only its cluster, so minority bleed colors are excluded outright and the result is always a color that was actually seen (default). Turn OFF for the legacy per-channel weighted median — recolor the same scan once per setting to compare.")
            devToggle($colorizeFrom360Faces, "Color from 360° Faces",
                      "Colors the preview mesh EXCLUSIVELY from cube faces cut from the scan's 360° stills at their baked poses (normal keyframe/motion frames excluded). A measurement tool: misplaced color reads back cube-face pose error directly. Faces carry depth rasterized from the scan's own mesh, so occlusion is ON and misplaced color measures POSE, not bleed. Privacy fail-closed still applies: on privacy-ON deferred-blur scans, maskless face frames are skipped entirely — probe with a people-free or consent (filter OFF) scan. Re-run Color after toggling.")
        }
    }

    private var developerDisplaySection: some View {
        devSection("DISPLAY & VR", icon: "eye.fill") {
            wireframeColorPicker("Active Scan Wireframe", selection: $activeMeshColor,
                                 "Color of the live depth mesh shown during scanning.")
            wireframeColorPicker("Ghost Scan Wireframe", selection: $ghostMeshColor,
                                 "Color of the previous scan overlay used for alignment.")
            devToggle($hideLivePoints, "Hide Live Points (VR)",
                      "Hides the live depth point cloud in VR capture so only the accumulated voxel cloud is shown. Applied when entering VR capture. Useful for inspecting how the accumulated voxels hold up.")
            devToggle($vrBloomEnabled, "VR Bloom Effect",
                      "Glow post-process on the VR point cloud (two GPU passes + a half-res texture per frame). Off by default; most useful with Hide Live Points on, where the glow softens the raw accumulated voxels. Applied live, per frame, VR mode only.")
            devToggle($pauseVRCompute, "Pause VR Compute",
                      "Skips the entire VR GPU pipeline (point-cloud projection, voxel integration, extraction, and bloom) — not just hides it. Isolation test: if the freeze disappears with this on, the GPU pipeline is implicated. Applied per frame in VR capture.")
        }
    }

    private var developerSimulationSection: some View {
        devSection("SIMULATION", icon: "testtube.2") {
            devToggle($mockIMU, "Simulate IMU & Poses",
                      "Simulates a continuous 360° circular trajectory to bypass overlap thresholds and test capture.")
            devToggle($mockCameraImages, "Simulate Camera Images",
                      "Injects a dynamically rendered synthetic frame sequence (a mid-air green box) instead of live camera.")
            devToggle($mockDepthMaps, "Simulate Depth Maps",
                      "Injects synthetic depth maps matching the virtual test images.")
            #if canImport(MWDATMockDevice)
            devToggle($mockWearable, "Simulate Meta Wearable",
                      "Uses MockDeviceKit to simulate paired Meta Ray-Ban glasses without needing physical hardware.")
            #endif
        }
    }

    private var developerProcessingSection: some View {
        devSection("PROCESSING", icon: "gearshape.2.fill") {
            devToggle($forceRebuildArtifacts, "Force Rebuild Artifacts",
                      "Makes long-press Re-run Processing rebuild the derived artifacts (ghost proxy, dynamic mesh, derived surfaces) even when they are already at the current builder version, instead of reporting \"Nothing to process\". Their diagnostics are computed during the build, so this is the only way to re-examine a finished scan without bumping a version header. Registration is never forced — it bakes into mesh.obj in place.")
            devToggle($registerLegacyScans, "Register Legacy Scans",
                      "Lets pre-postprocess-era scans (no saved scan case) enter retroactive registration: old locations will show \"needs postprocess\" and Process may move their meshes into the canonical frame. OFF in production — a legacy adjacent-link is indistinguishable from a rescan and a similar room could false-lock. Scans of link-adjacent locations stay excluded either way.")
        }
    }

    /// Keep this LAST: it resets every option in the sections above.
    private var developerRestoreSection: some View {
        Section {
            restoreDeveloperDefaultsRow
        }
        .listRowBackground(Color.white.opacity(0.05))
    }

    // MARK: Developer rows

    /// A developer section: an orange icon in the header marks it as Developer Mode only.
    private func devSection<Content: View>(_ title: LocalizedStringKey, icon: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        Section {
            content()
        } header: {
            Label(title, systemImage: icon)
                .labelStyle(.tintedIcon(.orange))
        }
        .listRowBackground(Color.white.opacity(0.05))
    }

    private func devToggle(_ isOn: Binding<Bool>, _ title: LocalizedStringKey, _ caption: LocalizedStringKey) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .foregroundColor(.white)
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .tint(.orange)
        .padding(.vertical, 4)
    }

    private func devSlider(_ value: Binding<Double>, _ title: LocalizedStringKey, _ scale: DevSliderScale,
                           _ caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .foregroundColor(.white)
                Spacer()
                Text("\(Int(value.wrappedValue))\(scale.unit)")
                    .foregroundColor(.orange)
                    .font(.headline)
            }
            Slider(value: value, in: scale.range, step: scale.step)
                .tint(.orange)
            Text(caption)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(.vertical, 4)
    }

    private func wireframeColorPicker(_ title: LocalizedStringKey, selection: Binding<String>,
                                      _ caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .foregroundColor(.white)
            Picker("", selection: selection) {
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
            Text(caption)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var settingsSection5: some View {
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

    /// One section per property: `body` had grown into a single expression large enough
    /// that ANY addition anywhere in it failed to type-check, which made the file
    /// effectively closed to change. Extracting sections keeps inference local.
    @ViewBuilder
    private var appearanceSection: some View {
        Section {
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

            VStack(alignment: .leading, spacing: 8) {
                // Opens the shared keypad editor rather than hosting a text
                // field: the system decimal pad crashed this flow repeatedly
                // (see RigHeightSheet for the mechanism). One editor, no
                // keyboard anywhere in the rig-height path.
                Button(action: { showRigHeightSheet = true }, label: {
                    HStack {
                        Text("360° Rig Height")
                            .foregroundColor(.white)
                        Spacer()
                        Text(rigHeightSummary)
                            .foregroundColor(rigMeasuredDyMeters > 0 ? .cyan : .orange)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                })
                .buttonStyle(.plain)
                Text("Tape-measured distance from the iPad's camera cluster to the 360° camera's lens center. Used as the BOOTSTRAP anchor for each scan's calibration solve (the solve refines within a small window — the image-based solve has a known upward pull without an anchor). Stored in meters regardless of entry unit. 0 = unmeasured.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.vertical, 4)

        } header: {
            Text("SCAN CAPTURE")
        }
        .listRowBackground(Color.white.opacity(0.05))
    }

    /// Developer Mode's last row (its own section): puts every option in
    /// AppConstants.developerOptionDefaults back to its default after a confirm, and leaves
    /// Developer Mode on. Greyed out while everything is already default. Its alert rides on the
    /// row so the section's modifier chain stays inside the type checker's budget.
    private var restoreDeveloperDefaultsRow: some View {
        Button(role: .destructive, action: { showRestoreDeveloperDefaults = true }, label: {
            VStack(alignment: .leading, spacing: 4) {
                Label("Restore Default Developer Options", systemImage: "arrow.counterclockwise")
                Text("Puts every developer option above back to its default. Developer Mode stays on.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        })
        .disabled(AppConstants.developerOptionsAreDefault())
        .padding(.vertical, 4)
        .alert("Restore Developer Defaults?", isPresented: $showRestoreDeveloperDefaults) {
            Button("Restore Defaults", role: .destructive) { AppConstants.restoreDeveloperDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every developer option goes back to its default, including the simulation, " +
                 "diagnostics, colorize and VR switches, Video Format and Capture Audio. " +
                 "Developer Mode stays on.")
        }
    }

    /// How long the Privacy Filter may stay off before it turns itself back on (PrivacyFilterTimer).
    /// A developer option, so it is in AppConstants.developerOptionDefaults and a restore puts it
    /// back to 24 h. Lives in the Privacy & 360° camera group.
    private var privacyTimeLimitPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Privacy Filter Time Limit")
                    .foregroundColor(.white)
                Spacer()
                Picker("Privacy Filter Time Limit", selection: $privacyFilterTimeLimitHours) {
                    ForEach(AppConstants.privacyFilterTimeLimitChoices, id: \.self) { hours in
                        Text(hours == 0 ? "None" : PrivacyFilterTimer.describe(hours: hours)).tag(hours)
                    }
                }
                .pickerStyle(.menu)
                // The row's own title names it; a menu picker would print its label again beside the value.
                .labelsHidden()
                .tint(.orange)
            }
            Text("Switched off on the capture screen, the Privacy Filter turns itself back on after this long, so a switch left off by mistake doesn't keep capturing people unblurred. None keeps it off until switched back on.")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(.vertical, 4)
    }

    /// Extracted alongside the diagnostics row: this section is long enough that the
    /// two together exceed the type checker's budget when inlined.
    private var videoFormatPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Video Format")
                .foregroundColor(.white)
            Text("ARKit video stream resolution. Higher = better splat quality but more storage. Requires session restart.")
                .font(.caption)
                .foregroundColor(.gray)
            // @AppStorage (not a raw UserDefaults Binding) so the menu label refreshes
            // when the selection changes. Tag N maps to format index N-1; 0 is Auto.
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
    }

    /// Field diagnostics with no host attached: reads this launch's own unified-log
    /// entries and hands back a text file. See DiagnosticsLogExport for the two limits.
    /// Extracted from `body` — that view is long enough that inlining it exceeds the
    /// type checker's budget.
    private var diagnosticsExportRow: some View {
        Button(action: exportDiagnostics, label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(isExportingLog ? "Collecting…" : "Export Diagnostics Log")
                        .foregroundColor(.cyan)
                    Spacer()
                    Image(systemName: "square.and.arrow.up")
                        .foregroundColor(.cyan)
                }
                Text("Pulls this launch's log entries into a shareable text file — no Mac, cable, or debug session needed. Current launch only; for an earlier run use sysdiagnose (both volume buttons + power, then Analytics Data). Needs Performance Diagnostics ON for the capture/solver tuning lines.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        })
        .buttonStyle(.plain)
        .disabled(isExportingLog)
        .padding(.vertical, 4)
    }

    /// Collects off-main — getEntries walks the whole store — then offers the file.
    private func exportDiagnostics() {
        isExportingLog = true
        Task.detached(priority: .userInitiated) {
            let url = DiagnosticsLogExport.writeToFile()
            await MainActor.run {
                isExportingLog = false
                diagnosticsLogURL = url
            }
        }
    }

    /// Row value: the stored height in the user's display unit, or an unset marker.
    private var rigHeightSummary: String {
        guard rigMeasuredDyMeters > 0 else { return "Not set" }
        let display = rigHeightUnitImperial ? rigMeasuredDyMeters / 0.0254 : rigMeasuredDyMeters
        return String(format: rigHeightUnitImperial ? "%.1f in" : "%.2f m", display)
    }

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
                    settingsSection1

                    // The Scan4D server's settings live in its own tab now.
                    Section {
                        Label("The Scan4D server's connection, status and bundles are in the Server tab.",
                              systemImage: "server.rack")
                            .font(.caption)
                            .foregroundColor(.gray)
                    } header: {
                        Text("SCAN4D SERVER")
                    }
                    .listRowBackground(Color.white.opacity(0.05))

                    appearanceSection

                    // MARK: - Data Management
                    settingsSection3

                    // MARK: - Developer Mode
                    settingsSection4

                    // MARK: - App Info Footer
                    settingsSection5
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
            .scrollDismissesKeyboard(.interactively)
            .sheet(isPresented: $showRigHeightSheet) { RigHeightSheet() }
            .sheet(item: $diagnosticsLogURL) { ShareSheet(activityItems: [$0]) }
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
    // Settings reads its scans through a SwiftData query.
    SettingsView()
        .modelContainer(for: [ScanLocation.self, CapturedScan.self], inMemory: true)
}
