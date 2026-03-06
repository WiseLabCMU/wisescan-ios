import SwiftUI
import ARKit

struct CaptureView: View {
    @Environment(ScanStore.self) private var scanStore
    @State private var scanStats = ScanStats()
    @State private var locationManager = LocationManager()
    @AppStorage("privacyFilter") private var isPrivacyFilterOn = true
    @State private var mode = 1 // 0 = Streaming, 1 = Capture
    @State private var currentARSession: ARSession? = nil
    @State private var saveMessage: String? = nil
    @State private var isRecording = false
    @State private var recordingSeconds = 0
    @State private var recordingTimer: Timer? = nil
    @State private var frameCaptureSession = FrameCaptureSession()
    @State private var colorAccumulator = ARCoverageView.VertexColorAccumulator()
    @AppStorage("rawOverlapMax") private var rawOverlapMax: Double = 60.0
    @AppStorage("rawRejectBlur") private var rawRejectBlur: Bool = true
    @Binding var selectedTab: Int
    var initialWorldMapURL: URL? = nil // Support for Scan4D anchoring

    // Scan4D properties
    @State private var showNamePrompt = false
    @State private var newLocationName = ""
    @State private var pendingScan: PendingScanData? = nil

    struct PendingScanData {
        let meshData: Data
        let vertexCount: Int
        let faceCount: Int
        let rawDataPath: URL?
        let vertexColors: Data?
        let worldMapURL: URL?
    }

    var activeGhostMeshData: Data? {
        guard let locId = scanStore.activeLocationForScan,
              let location = scanStore.locations.first(where: { $0.id == locId }),
              let latestScan = location.scans.first else {
            return nil
        }
        return latestScan.meshData
    }

    var body: some View {
        ZStack {
            // Live ARKit Scene Reconstruction View
            ARCoverageView(
                arSession: $currentARSession,
                scanStats: scanStats,
                privacyFilter: isPrivacyFilterOn,
                initialWorldMapURL: scanStore.activeRelocalizationMap,
                initialGhostMeshData: activeGhostMeshData
            )
                .ignoresSafeArea()

            // Face blur overlay (shown when privacy filter is on)
            if isPrivacyFilterOn {
                FaceBlurOverlay(arSession: currentARSession)
                    .ignoresSafeArea()
            }

            // Permissions Overlay (Preempts user if not authorized)
            PermissionsOverlay(locationManager: locationManager)
                .ignoresSafeArea()

            VStack {
                // Top Controls
                HStack {
                    // Privacy Filter Toggle
                    HStack {
                        Text("Privacy Filter")
                            .font(.subheadline)
                            .foregroundColor(.white)
                        Toggle("", isOn: $isPrivacyFilterOn)
                            .labelsHidden()
                            .tint(.green)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)

                    Spacer()

                    // Recording indicator
                    if isRecording {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 10, height: 10)
                            Text("REC \(formattedTime)")
                                .font(.caption).bold()
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.3))
                        .cornerRadius(20)
                    }

                    Spacer()

                    // Mode Switcher
                    Picker("Mode", selection: $mode) {
                        Text("Streaming").tag(0)
                        Text("Capture").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .disabled(isRecording)
                }
                .padding()

                Spacer()

                // Bottom HUD and Capture Button
                VStack {
                    ZStack(alignment: .bottom) {
                        // HUD background with live stats
                        HStack {
                            Text("\(scanStats.formattedSize) | \(scanStats.formattedPolygons) Polygons")
                                .font(.caption)
                                .foregroundColor(.white)

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Scan Quality: \(scanStats.qualityPercent)%")
                                    .font(.caption)
                                    .foregroundColor(.white)
                                // Quality bar
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Rectangle()
                                            .fill(Color.white.opacity(0.2))
                                            .frame(height: 4)
                                        Rectangle()
                                            .fill(qualityColor)
                                            .frame(width: geo.size.width * scanStats.averageQuality, height: 4)
                                    }
                                    .cornerRadius(2)
                                }
                                .frame(width: 60, height: 4)
                            }
                        }
                        .padding()
                        .frame(height: 80)
                        .background(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                        .cornerRadius(24)
                        .padding(.horizontal)

                        // Capture Button overlaying HUD
                        Button(action: {
                            if mode == 1 {
                                toggleRecording()
                            }
                        }) {
                            ZStack {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .frame(width: 80, height: 80)
                                    .overlay(Circle().stroke(isRecording ? Color.red : Color.cyan, lineWidth: 2))

                                if isRecording {
                                    // Stop icon (rounded square)
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.red)
                                        .frame(width: 28, height: 28)
                                } else {
                                    Circle()
                                        .fill(mode == 1 ? Color.white : Color.red)
                                        .frame(width: 30, height: 30)
                                }

                                if let msg = saveMessage {
                                    Text(msg)
                                        .font(.caption2).bold()
                                        .foregroundColor(.white)
                                        .offset(y: 50)
                                } else {
                                    Text(isRecording ? "Tap to stop" : (mode == 1 ? "Tap to scan" : ""))
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.7))
                                        .offset(y: 50)
                                }
                            }
                        }
                        .offset(y: -20)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear {
            if isRecording {
                stopRecording()
            }
        }
        .alert("Name this Space", isPresented: $showNamePrompt) {
            TextField("Location Name (e.g., Living Room)", text: $newLocationName)
            Button("Save", action: { savePendingScan() })
            Button("Cancel", role: .cancel) {
                pendingScan = nil
                saveMessage = nil
            }
        } message: {
            Text("Enter a unique name for this space so you can efficiently 'Scan Again' later.")
        }
    }

    private var qualityColor: Color {
        let q = scanStats.averageQuality
        if q < 0.3 { return .red }
        if q < 0.6 { return .yellow }
        return .green
    }

    private var formattedTime: String {
        let minutes = recordingSeconds / 60
        let seconds = recordingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        recordingSeconds = 0
        saveMessage = nil

        // Start frame capture for raw data export
        // Start vertex color accumulation for preview
        if let session = currentARSession {
            // Provide LocationManager to frame capture session so it can grab metadata
            frameCaptureSession.start(
                session: session,
                overlapMax: rawOverlapMax,
                rejectBlur: rawRejectBlur,
                privacyFilter: isPrivacyFilterOn,
                locationManager: locationManager,
                activeLocationId: scanStore.activeLocationForScan
            )
            colorAccumulator.start(session: session)
        }

        // Start a timer to track recording duration
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            recordingSeconds += 1
        }
    }

    private func stopRecording() {
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil

        // Stop frame capture and get raw data path
        let rawDataPath = frameCaptureSession.stop()
        colorAccumulator.stop()

        // Export and save the scan (with privacy filtering)
        guard let result = ARCoverageView.exportMeshOBJ(from: currentARSession, privacyFilter: isPrivacyFilterOn),
              !result.data.isEmpty else {
            saveMessage = "No Mesh Data"
            clearMessage()
            return
        }

        // Build accumulated vertex colors for preview
        let vertexColors = colorAccumulator.buildColorData(from: currentARSession)

        saveMessage = "Saving World Map..."

        // Export ARWorldMap for Scan4D relocalization
        ARCoverageView.VertexColorAccumulator.exportWorldMap(from: currentARSession) { mapURL in
            DispatchQueue.main.async {

                // Package the Mesh OBJ and ARWorldMap into the raw data directory for zipping
                if let rawDir = rawDataPath {
                    let meshFileURL = rawDir.appendingPathComponent("mesh.obj")
                    try? result.data.write(to: meshFileURL)

                    if let mapURL = mapURL {
                        let destMapURL = rawDir.appendingPathComponent("relocalization.worldmap")
                        try? FileManager.default.copyItem(at: mapURL, to: destMapURL)
                    }
                }

                self.pendingScan = PendingScanData(
                    meshData: result.data,
                    vertexCount: result.vertexCount,
                    faceCount: result.faceCount,
                    rawDataPath: rawDataPath,
                    vertexColors: vertexColors,
                    worldMapURL: mapURL
                )

                if self.scanStore.activeLocationForScan != nil {
                    // It's a "Scan Again", skip prompt and save immediately
                    self.savePendingScan()
                } else {
                    // It's a brand new scan, prompt for a name
                    self.newLocationName = ""
                    self.showNamePrompt = true
                }
            }
        }
    }

    private func clearMessage() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            saveMessage = nil
        }
    }

    private func savePendingScan() {
        guard let pending = pendingScan else { return }

        // Determine the location ID
        let locationId: UUID
        var finalName = "New Space"

        if let activeLocationId = scanStore.activeLocationForScan {
            locationId = activeLocationId
        } else {
            let trimmedName = newLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
            finalName = trimmedName.isEmpty ? "New Space" : trimmedName
            // Create a new location to hold this scan and future Scan4D rescans
            let newLocation = scanStore.addLocation(name: finalName)
            locationId = newLocation.id
        }

        let _ = scanStore.addScan(
            meshData: pending.meshData,
            vertexCount: pending.vertexCount,
            faceCount: pending.faceCount,
            rawDataPath: pending.rawDataPath,
            vertexColors: pending.vertexColors,
            worldMapURL: pending.worldMapURL,
            locationId: locationId
        )

        saveMessage = "Scan Saved!"
        pendingScan = nil

        // Reset the active state so subsequent scans don't default to this location
        scanStore.activeLocationForScan = nil
        scanStore.activeRelocalizationMap = nil

        // Switch to Workflows tab after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            selectedTab = 2
            saveMessage = nil
        }
    }
}

#Preview {
    CaptureView(selectedTab: .constant(1))
        .environment(ScanStore())
}
