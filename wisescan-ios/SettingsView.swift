import SwiftUI
import SwiftData

struct SettingsView: View {
    var scrollToDevMode: Bool = false
    @Environment(\.modelContext) private var modelContext
    @Query private var locations: [ScanLocation]

    @AppStorage(AppConstants.Key.rawOverlapMax) private var overlapMax: Double = AppConstants.overlapMax
    @AppStorage(AppConstants.Key.rawRejectBlur) private var rejectBlur: Bool = AppConstants.rejectBlur
    @AppStorage(AppConstants.Key.uploadURL) private var uploadURL = AppConstants.uploadURL
    @AppStorage(AppConstants.Key.developerMode) private var developerMode: Bool = AppConstants.developerMode
    @AppStorage(AppConstants.Key.flipCameraEnabled) private var flipCameraEnabled: Bool = AppConstants.flipCameraEnabled
    @AppStorage(AppConstants.Key.debugVertexMapping) private var debugVertexMapping: Bool = AppConstants.debugVertexMapping
    @AppStorage(AppConstants.Key.mockIMU) private var mockIMU: Bool = AppConstants.mockIMU
    @AppStorage(AppConstants.Key.mockCameraImages) private var mockCameraImages: Bool = AppConstants.mockCameraImages
    @AppStorage(AppConstants.Key.mockDepthMaps) private var mockDepthMaps: Bool = AppConstants.mockDepthMaps
    @AppStorage(AppConstants.Key.mockWearable) private var mockWearable: Bool = AppConstants.mockWearable
    @AppStorage(AppConstants.Key.activeMeshColor) private var activeMeshColor: String = AppConstants.activeMeshColor
    @AppStorage(AppConstants.Key.ghostMeshColor) private var ghostMeshColor: String = AppConstants.ghostMeshColor
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
                                    self.flipCameraEnabled = AppConstants.flipCameraEnabled
                                    self.debugVertexMapping = AppConstants.debugVertexMapping
                                    self.mockIMU = AppConstants.mockIMU
                                    self.mockCameraImages = AppConstants.mockCameraImages
                                    self.mockDepthMaps = AppConstants.mockDepthMaps
                                    self.mockWearable = AppConstants.mockWearable
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
                            Toggle(isOn: $flipCameraEnabled) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Flip Camera")
                                        .foregroundColor(.white)
                                    Text("Adds a button on the Capture screen to switch between front and back cameras. Useful for testing privacy features with the front-facing camera.")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.orange)
                            .padding(.vertical, 4)

                            Toggle(isOn: $debugVertexMapping) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Test Vertex Mapping")
                                        .foregroundColor(.white)
                                    Text("Runs and logs a diagnostic projection test during mesh coloring to verify 3D-to-2D image math accuracy.")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                            .tint(.orange)
                            .padding(.vertical, 4)

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
                        let buildType = "Debug"
                        #else
                        let buildType = "Release"
                        #endif
                        
                        HStack {
                            Spacer()
                            VStack(spacing: 4) {
                                Text("Scan4D Version \(appVersion) (\(buildNumber))")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                Text("Build Type: \(buildType)")
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
