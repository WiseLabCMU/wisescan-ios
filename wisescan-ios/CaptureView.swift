import SwiftUI
import ARKit
import SwiftData

struct CaptureView: View {
    @Environment(ScanStore.self) private var scanStore
    @Environment(\.modelContext) private var modelContext
    @State private var scanStats = ScanStats()
    @State private var locationManager = LocationManager()
    @AppStorage(AppDefaults.Key.privacyFilter) private var isPrivacyFilterOn = AppDefaults.privacyFilter
    @AppStorage(AppDefaults.Key.developerMode) private var developerMode: Bool = AppDefaults.developerMode
    @AppStorage(AppDefaults.Key.flipCameraEnabled) private var flipCameraEnabled: Bool = AppDefaults.flipCameraEnabled
    @AppStorage(AppDefaults.Key.testIMU) private var testIMU: Bool = AppDefaults.testIMU
    @AppStorage(AppDefaults.Key.testCameraImages) private var testCameraImages: Bool = AppDefaults.testCameraImages
    @AppStorage(AppDefaults.Key.testDepthMaps) private var testDepthMaps: Bool = AppDefaults.testDepthMaps
    // Stream mode removed — fixed to Capture (Stream is a future feature)
    @State private var usingFrontCamera = false
    @State private var currentARSession: ARSession? = nil
    @State private var saveMessage: String? = nil
    @State private var isRecording = false
    @State private var recordingSeconds = 0
    @State private var recordingTimer: Timer? = nil
    @State private var frameCaptureSession = FrameCaptureSession()
    // colorAccumulator removed — vertex coloring now deferred to post-processing
    @AppStorage(AppDefaults.Key.rawOverlapMax) private var overlapMax: Double = AppDefaults.overlapMax
    @AppStorage(AppDefaults.Key.rawRejectBlur) private var rejectBlur: Bool = AppDefaults.rejectBlur
    @Binding var selectedTab: Int
    var initialWorldMapURL: URL? = nil // Support for Scan4D anchoring

    // Scan4D properties
    @State private var showNamePrompt = false
    @State private var newLocationName = ""
    @State private var pendingScan: PendingScanData? = nil
    @State private var isProcessingMesh = false
    @State private var isWaitingToSave = false
    @State private var cachedGhostMeshData: Data? = nil

    @State private var showExtendPrompt = false

    struct PendingScanData {
        let meshData: Data
        let vertexCount: Int
        let faceCount: Int
        let rawDataPath: URL?
        let vertexColors: Data?
        let worldMapURL: URL?
        let thumbnailData: Data?
    }

    /// Loads ghost mesh data from the scan to extend, caching it in @State.
    private func loadGhostMeshData() {
        guard let locId = scanStore.activeLocationForScan,
              let scanId = scanStore.activeScanToExtend else {
            cachedGhostMeshData = nil
            return
        }
        let descriptor = FetchDescriptor<ScanLocation>(predicate: #Predicate { $0.id == locId })
        guard let location = try? modelContext.fetch(descriptor).first,
              let targetScan = location.scans.first(where: { $0.id == scanId }) else {
            cachedGhostMeshData = nil
            return
        }
        cachedGhostMeshData = try? Data(contentsOf: targetScan.meshFileURL)
    }

    var body: some View {
        ZStack {
            // Live ARKit Scene Reconstruction View
            ARCoverageView(
                arSession: $currentARSession,
                isRecording: $isRecording,
                scanStats: scanStats,
                privacyFilter: isPrivacyFilterOn,
                useFrontCamera: usingFrontCamera,
                initialWorldMapURL: scanStore.activeRelocalizationMap,
                initialGhostMeshData: cachedGhostMeshData
            )
                .ignoresSafeArea()

            // Face blur overlay (shown when privacy filter is on AND recording)
            if isPrivacyFilterOn && isRecording {
                FaceBlurOverlay(arSession: currentARSession)
                    .ignoresSafeArea()
            }

            // Permissions Overlay (Preempts user if not authorized)
            PermissionsOverlay(locationManager: locationManager)
                .ignoresSafeArea()

            if isRecording && frameCaptureSession.isBlurWarningActive {
                Text("⚠️ Moving too fast! Slow down.")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.orange.opacity(0.85))
                    .cornerRadius(20)
                    .shadow(radius: 5)
                    .transition(.scale.combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.2), value: frameCaptureSession.isBlurWarningActive)
            }

            // Lite mode banner for non-LiDAR devices
            if !ARCoverageView.supportsLiDAR {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                    Text("Lite Mode — Capturing images only (no depth/mesh)")
                }
                .font(.caption)
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.75))
                .cornerRadius(16)
                .padding(.top, 50)
            }

            VStack {
                // Extend Scan Prompt (transient)
                if showExtendPrompt {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Extend Scan")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("Re-scan the red area to update it over time, or move to its edge and scan new ground to stitch a larger space.")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        Spacer()
                        Button(action: { showExtendPrompt = false }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                    .padding()
                    .background(Color.indigo.opacity(0.9))
                    .cornerRadius(16)
                    .padding(.horizontal)
                    .padding(.top, developerMode ? 60 : 20) // Leave room for top controls
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.spring(), value: showExtendPrompt)
                }

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

                    // Flip Camera Button (Developer Mode only)
                    if developerMode && flipCameraEnabled && !isRecording {
                        Button(action: {
                            usingFrontCamera.toggle()
                        }) {
                            Image(systemName: "camera.rotate")
                                .font(.title3)
                                .foregroundColor(.orange)
                                .padding(10)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                                .overlay(
                                    Circle().stroke(Color.orange.opacity(0.6), lineWidth: 1)
                                )
                        }
                    }

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

                }
                .padding()
                .padding(.top, developerMode ? 16 : 0) // Leave room for dev banner

                Spacer()

                // Capacity Warning Banner (above HUD, only during recording)
                if isRecording && scanStats.isNearCapacity {
                    HStack(spacing: 8) {
                        Image(systemName: scanStats.isAtCapacity ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(.white)
                        Text(scanStats.isAtCapacity
                             ? "Session at capacity — save now to avoid quality loss"
                             : "Approaching session limits — consider saving and starting a new scan")
                            .font(.caption2).bold()
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(scanStats.isAtCapacity ? Color.red.opacity(0.9) : Color.orange.opacity(0.9))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }

                // Bottom HUD and Capture Button
                VStack {
                    ZStack(alignment: .bottom) {
                        // HUD background with live stats (only during recording)
                        if isRecording {
                            VStack(spacing: 8) {
                                // Row 1: Live metrics
                                HStack(spacing: 16) {
                                    Label(scanStats.formattedPolygons, systemImage: "triangle.fill")
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                    Label("\(scanStats.anchorCount)", systemImage: "square.grid.3x3")
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                    Label(scanStats.driftLabel, systemImage: "location.slash")
                                        .font(.caption2)
                                        .foregroundColor(scanStats.driftEstimate > 0.5 ? .orange : .white)
                                    Spacer()
                                    Label(scanStats.formattedDuration, systemImage: "clock")
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                }

                                // Row 2: Capacity bar
                                VStack(spacing: 4) {
                                    HStack {
                                        Text("Session Capacity")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                        Spacer()
                                        Text("\(scanStats.capacityPercent)%")
                                            .font(.caption2).bold()
                                            .foregroundColor(Color(
                                                red: scanStats.capacityColor.red,
                                                green: scanStats.capacityColor.green,
                                                blue: 0
                                            ))
                                    }
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Rectangle()
                                                .fill(Color.white.opacity(0.15))
                                                .frame(height: 6)
                                            Rectangle()
                                                .fill(Color(
                                                    red: scanStats.capacityColor.red,
                                                    green: scanStats.capacityColor.green,
                                                    blue: 0
                                                ))
                                                .frame(width: geo.size.width * scanStats.capacityScore, height: 6)
                                        }
                                        .cornerRadius(3)
                                    }
                                    .frame(height: 6)
                                }
                            }
                            .padding()
                            .frame(height: 90)
                            .background(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 24)
                                    .stroke(scanStats.isNearCapacity
                                            ? Color.orange.opacity(0.6)
                                            : Color.white.opacity(0.2), lineWidth: 1)
                            )
                            .cornerRadius(24)
                            .padding(.horizontal)
                        }

                        // Capture Button
                        Button(action: { toggleRecording() }) {
                            ZStack {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .frame(width: 80, height: 80)
                                    .overlay(Circle().stroke(isRecording ? Color.red : Color.cyan, lineWidth: 2))

                                if isRecording {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.red)
                                        .frame(width: 28, height: 28)
                                } else {
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 30, height: 30)
                                }

                                if let msg = saveMessage {
                                    Text(msg)
                                        .font(.caption2).bold()
                                        .foregroundColor(.white)
                                        .offset(y: 50)
                                } else {
                                    Text(isRecording ? "Tap to stop" : "Tap to scan")
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.7))
                                        .offset(y: 50)
                                }
                            }
                        }
                        .offset(y: isRecording ? -20 : 0)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Lock to portrait during capture for stable intrinsics & tracking
            AppDelegate.orientationLocked = true
            // Force UIKit to re-query supported orientations from the delegate
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            UIDevice.current.setValue(UIInterfaceOrientation.portrait.rawValue, forKey: "orientation")

            // Load ghost mesh once into @State cache (avoids recomputing on every body eval)
            loadGhostMeshData()

            showExtendPrompt = (scanStore.activeScanToExtend != nil)

            // Auto-revert to back camera when developer mode is disabled
            if !developerMode || !flipCameraEnabled {
                usingFrontCamera = false
            }
        }
        .onDisappear {
            // Unlock orientation when leaving capture
            AppDelegate.orientationLocked = false
            // Allow rotation again
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }

            // Stop GPS/heading updates to save battery (#12)
            locationManager.stopUpdating()

            if isRecording {
                stopRecording()
            }
            // Always clear ghost state when leaving Capture
            scanStore.activeLocationForScan = nil
            scanStore.activeRelocalizationMap = nil
            scanStore.activeScanToExtend = nil
            cachedGhostMeshData = nil
        }
        .alert("Name this Space", isPresented: $showNamePrompt) {
            TextField("Location Name (e.g., Living Room)", text: $newLocationName)
            Button("Save", action: { 
                if isProcessingMesh {
                    isWaitingToSave = true
                    saveMessage = "Adding location details..." 
                } else {
                    savePendingScan()
                }
            })
            Button("Cancel", role: .cancel) {
                pendingScan = nil
                saveMessage = nil
                isProcessingMesh = false
                isWaitingToSave = false
            }
        } message: {
            Text("Enter a unique name for this space so you can efficiently 'Extend Scan' later.")
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
        if let session = currentARSession {
            // Provide LocationManager to frame capture session so it can grab metadata
            frameCaptureSession.start(
                session: session,
                overlapMax: overlapMax,
                rejectBlur: rejectBlur,
                privacyFilter: isPrivacyFilterOn, // Applied during export
                locationManager: locationManager,
                activeLocationId: scanStore.activeLocationForScan,
                testIMU: developerMode && testIMU,
                testCameraImages: developerMode && testCameraImages,
                testDepthMaps: developerMode && testDepthMaps
            )
        }

        // Start a timer to track recording duration
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            recordingSeconds += 1
            if recordingSeconds > 4 {
                showExtendPrompt = false // Auto-dismiss after recording starts
            }
        }
    }

    private func stopRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil

        // ── Extract all AR data BEFORE switching to nominal mode ──
        // (Setting isRecording = false triggers ARCoverageView to drop mesh anchors)

        // Stop frame capture and get raw data path
        let rawDataPath = frameCaptureSession.stop()

        // Export mesh from the still-active AR session
        let meshResult = ARCoverageView.exportMeshOBJ(from: currentARSession, privacyFilter: isPrivacyFilterOn)

        // Capture a 2D thumbnail from the current camera frame
        var thumbnailData: Data? = nil
        if let currentFrame = currentARSession?.currentFrame {
            let ciImage = CIImage(cvPixelBuffer: currentFrame.capturedImage)
            let context = CIContext()
            if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                let uiImage = UIImage(cgImage: cgImage)
                let targetSize = CGSize(width: 800, height: Int(800.0 * (uiImage.size.height / uiImage.size.width)))
                UIGraphicsBeginImageContextWithOptions(targetSize, false, 1.0)
                UIImage(cgImage: cgImage, scale: 1.0, orientation: .right).draw(in: CGRect(origin: .zero, size: targetSize))
                let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
                UIGraphicsEndImageContext()
                thumbnailData = resizedImage?.jpegData(compressionQuality: 0.6)
            }
        }

        // ── Now switch to nominal mode (drops mesh anchors, frees AR memory) ──
        isRecording = false

        var finalMeshResult = meshResult

        // If test modes are active and no mesh was generated (e.g. Simulator), inject a dummy mesh
        if finalMeshResult == nil || finalMeshResult!.data.isEmpty {
            if developerMode && (testCameraImages || testIMU || testDepthMaps) {
                let dummyObj = "v -0.5 -0.5 -0.5\nv 0.5 -0.5 -0.5\nv 0.5 0.5 -0.5\nf 1 2 3\n"
                if let dummyObjData = dummyObj.data(using: .utf8) {
                    finalMeshResult = (dummyObjData, 3, 1)
                }
            }
        }

        guard let result = finalMeshResult, !result.data.isEmpty else {
            saveMessage = "No Mesh Data"
            frameCaptureSession = FrameCaptureSession()
            clearMessage()
            return
        }

        // Prompt the user for a name IMMEDIATELY while mesh processes
        isProcessingMesh = true
        isWaitingToSave = false
        
        if scanStore.activeLocationForScan == nil {
            newLocationName = ""
            showNamePrompt = true
            // saveMessage is left nil or minimally intrusive so user focuses on typing
        } else {
            // Already extending a scan; user won't be prompted. Wait for processing to save.
            isWaitingToSave = true
            saveMessage = "Coloring mesh..."
        }

        // Run vertex coloring in background using saved camera frames
        DispatchQueue.global(qos: .userInitiated).async {
            let vertexColors = VertexColorAccumulator.colorizeFromSavedFrames(
                objData: result.data,
                rawDataDir: rawDataPath
            )

            DispatchQueue.main.async {
                self.saveMessage = "Saving World Map..."

                // Export ARWorldMap for Scan4D relocalization
                VertexColorAccumulator.exportWorldMap(from: self.currentARSession) { mapURL in
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
                            worldMapURL: mapURL,
                            thumbnailData: thumbnailData
                        )

                        // Release frame capture session memory
                        self.frameCaptureSession = FrameCaptureSession()
                        self.isProcessingMesh = false

                        // If user already tapped save in the alert, OR if this is a background extension
                        if self.isWaitingToSave {
                            self.savePendingScan()
                        } else if self.scanStore.activeLocationForScan != nil {
                            self.savePendingScan()
                        }
                    }
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
        let locationId: UUID?
        var finalName = "New Space"

        if let activeLocationId = scanStore.activeLocationForScan {
            locationId = activeLocationId
        } else {
            let trimmedName = newLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
            finalName = trimmedName.isEmpty ? "New Space" : trimmedName
            locationId = nil // ScanFileManager will create a new location with this name
        }

        let savedScan = ScanFileManager.shared.saveScan(
            context: modelContext,
            locationId: locationId,
            name: finalName,
            meshData: pending.meshData,
            vertexCount: pending.vertexCount,
            faceCount: pending.faceCount,
            rawDataPath: pending.rawDataPath,
            vertexColors: pending.vertexColors,
            worldMapURL: pending.worldMapURL,
            thumbnailData: pending.thumbnailData
        )

        saveMessage = "Scan Saved!"
        pendingScan = nil

        // Reset the active state so subsequent scans don't default to this location
        scanStore.activeLocationForScan = nil
        scanStore.activeRelocalizationMap = nil

        // Programmatically navigate to the created LocationDetailView
        let savedLoc = savedScan.location

        // Switch to Scans tab after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            selectedTab = 2
            if let loc = savedLoc {
                // Clear any existing path and append the new/updated location
                scanStore.navigationPath.removeLast(scanStore.navigationPath.count)
                scanStore.navigationPath.append(loc)
            }
            saveMessage = nil
        }
    }
}

#Preview {
    CaptureView(selectedTab: .constant(1))
        .environment(ScanStore())
}
