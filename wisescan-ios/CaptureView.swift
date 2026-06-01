import SwiftUI
import ARKit
import SwiftData

struct CaptureView: View {
    @Environment(ScanStore.self) private var scanStore
    @Environment(\.modelContext) private var modelContext
    @State private var scanStats = ScanStats()
    @State private var locationManager = LocationManager()
    @AppStorage(AppConstants.Key.privacyFilter) private var isPrivacyFilterOn = AppConstants.privacyFilter
    @AppStorage(AppConstants.Key.developerMode) private var developerMode: Bool = AppConstants.developerMode
    @AppStorage(AppConstants.Key.flipCameraEnabled) private var flipCameraEnabled: Bool = AppConstants.flipCameraEnabled
    @AppStorage(AppConstants.Key.mockIMU) private var mockIMU: Bool = AppConstants.mockIMU
    @AppStorage(AppConstants.Key.mockCameraImages) private var mockCameraImages: Bool = AppConstants.mockCameraImages
    @AppStorage(AppConstants.Key.mockDepthMaps) private var mockDepthMaps: Bool = AppConstants.mockDepthMaps
    @AppStorage(AppConstants.Key.activeMeshColor) private var activeMeshColor: String = AppConstants.activeMeshColor
    @AppStorage(AppConstants.Key.captureMode) private var captureModeStr: String = AppConstants.captureMode
    // Stream mode removed — fixed to Capture (Stream is a future feature)
    @State private var usingFrontCamera = false
    @State private var currentARSession: ARSession? = nil
    @State private var saveMessage: String? = nil
    @State private var isRecording = false
    @State private var recordingSeconds = 0
    @State private var recordingTimer: Timer? = nil
    @State private var frameCaptureSession = FrameCaptureSession()
    // colorAccumulator removed — vertex coloring now deferred to post-processing
    @AppStorage(AppConstants.Key.rawOverlapMax) private var overlapMax: Double = AppConstants.overlapMax
    @AppStorage(AppConstants.Key.rawRejectBlur) private var rejectBlur: Bool = AppConstants.rejectBlur
    @Binding var selectedTab: Int
    var initialWorldMapURL: URL? = nil // Support for Scan4D anchoring

    // Scan4D properties
    @State private var showNamePrompt = false
    @State private var newLocationName = ""
    @State private var pendingScan: PendingScanData? = nil
    @State private var isProcessingMesh = false
    @State private var isWaitingToSave = false
    @State private var cachedGhostMeshData: Data? = nil
    @State private var isARSessionReady = false

    @State private var showExtendPrompt = false

    // Ghost mesh relocalization controls
    @State private var showRelocDialog = false
    @State private var showManualAdjust = false
    @State private var ghostYRotation: Float = 0
    @State private var ghostXOffset: Float = 0
    @State private var ghostZOffset: Float = 0
    @State private var dismissGhostMesh = false

    struct PendingScanData {
        let locationId: UUID?
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
                isSessionReady: $isARSessionReady,
                scanStats: scanStats,
                privacyFilter: isPrivacyFilterOn,
                activeMeshColor: activeMeshColor,
                captureMode: AppConstants.CaptureMode(rawValue: captureModeStr) ?? .ar,
                useFrontCamera: usingFrontCamera,
                initialWorldMapURL: scanStore.activeRelocalizationMap,
                initialGhostMeshData: cachedGhostMeshData,
                ghostYRotation: ghostYRotation,
                ghostXOffset: ghostXOffset,
                ghostZOffset: ghostZOffset,
                dismissGhostMesh: dismissGhostMesh
            )
                .ignoresSafeArea()

            // Loading overlay while AR session initializes (camera + privacy models + depth pipeline)
            if !isARSessionReady {
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.cyan)
                        Text("Initializing AR Session…")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                }
                .transition(.opacity)
            }

            // Privacy blur overlay (shown when privacy filter is on AND recording in AR mode).
            // In VR mode the point cloud already shows person-shaped holes as the privacy indicator.
            if isPrivacyFilterOn && isRecording && (AppConstants.CaptureMode(rawValue: captureModeStr) ?? .ar) != .vr {
                PrivacyBlurOverlay(arSession: currentARSession)
                    .ignoresSafeArea()
            }

            // Permissions Overlay (Preempts user if not authorized)
            PermissionsOverlay(locationManager: locationManager)
                .ignoresSafeArea()

            VStack(spacing: 12) {
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

                if cachedGhostMeshData != nil && scanStats.trackingState == "limited" && scanStats.trackingReason == "Relocalizing" {
                    Text("🔄 Move camera to relocalize with previous scan")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.blue.opacity(0.85))
                        .cornerRadius(20)
                        .shadow(radius: 5)
                        .transition(.scale.combined(with: .opacity))
                        .animation(.easeInOut(duration: 0.2), value: scanStats.trackingReason)
                }

                if isRecording && scanStats.totalVertices < 500 && scanStats.trackingReason != "Relocalizing" && !frameCaptureSession.isBlurWarningActive {
                    Text("📷 Move camera slowly to scan environment")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.indigo.opacity(0.85))
                        .cornerRadius(20)
                        .shadow(radius: 5)
                        .transition(.scale.combined(with: .opacity))
                        .animation(.easeInOut(duration: 0.2), value: scanStats.totalVertices < 500)
                }
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
                
                // Wearable PiP Overlay and Status Warnings
                let wearableManager = MetaWearableManager.shared
                if let firstDevice = wearableManager.connectedDevices.first {
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            // Device Name Title
                            Text(firstDevice.name)
                                .font(.caption2).bold()
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.ultraThinMaterial)
                                .cornerRadius(6)
                                .padding(.trailing, AppConstants.UI.pipPaddingX)

                            // Firmware compatibility warning (may be false positive in SDK 0.7.0)
                            if wearableManager.deviceUpdateRequired {
                                Button(action: {
                                    wearableManager.openFirmwareUpdate()
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                                        Text("Device update needed — tap to open Meta App")
                                    }
                                    .font(.caption2).bold()
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.orange.opacity(0.8))
                                    .cornerRadius(8)
                                }
                                .padding(.trailing, AppConstants.UI.pipPaddingX)
                            }

                            // Status warnings when connected but no proxy image is flowing
                            if wearableManager.latestProxyImage == nil {
                                if wearableManager.connectionFailed {
                                    // DeviceSession timed out — show retry action
                                    Button(action: {
                                        wearableManager.connectionFailed = false
                                        wearableManager.stopStreaming()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                            wearableManager.startStreaming()
                                        }
                                    }) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "arrow.clockwise.circle.fill").foregroundColor(.orange)
                                            Text("Connection failed — tap to retry")
                                        }
                                        .font(.caption2).bold()
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Color.orange.opacity(0.7))
                                        .cornerRadius(8)
                                    }
                                    .padding(.trailing, AppConstants.UI.pipPaddingX)
                                } else {
                                    HStack(spacing: 6) {
                                        if !wearableManager.permissionGranted {
                                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                                            Text("Meta App Permission Required")
                                        } else if !wearableManager.isStreaming {
                                            ProgressView().scaleEffect(0.7).tint(.white)
                                            Text("Starting stream...")
                                        } else {
                                            ProgressView().scaleEffect(0.7).tint(.white)
                                            Text("Waiting for frames...")
                                        }
                                    }
                                    .font(.caption2).bold()
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial)
                                    .cornerRadius(8)
                                    .padding(.trailing, AppConstants.UI.pipPaddingX)
                                }
                            }

                            // The actual PiP video feed
                            if let pipImage = wearableManager.latestProxyImage {
                                Image(uiImage: pipImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: AppConstants.UI.pipWidth, height: AppConstants.UI.pipHeight)
                                    .clipShape(RoundedRectangle(cornerRadius: AppConstants.UI.pipCornerRadius))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: AppConstants.UI.pipCornerRadius)
                                            .stroke(Color.white.opacity(0.5), lineWidth: AppConstants.UI.pipBorderWidth)
                                    )
                                    .shadow(radius: 5)
                                    .padding(.trailing, AppConstants.UI.pipPaddingX)
                            }
                        }
                    }
                }

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
                                    Label(scanStats.relocalizationLabel, systemImage: "map")
                                        .font(.caption2)
                                        .foregroundColor(scanStats.hasEnoughFeaturesForRelocalization ? .white : .red)
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

            // Relocalization status chip (bottom-left) — visible when ghost mesh is loaded
            if cachedGhostMeshData != nil && !dismissGhostMesh {
                VStack {
                    Spacer()
                    HStack {
                        Button(action: { showRelocDialog = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "location.magnifyingglass")
                                    .font(.caption)
                                Text("Ghost Mesh")
                                    .font(.caption2.bold())
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .cornerRadius(20)
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                        }
                        Spacer()
                    }
                    .padding(.leading, 16)
                    .padding(.bottom, 100)
                }
            }

            // Manual alignment slider overlay
            if showManualAdjust && cachedGhostMeshData != nil && !dismissGhostMesh {
                VStack {
                    Spacer()
                    VStack(spacing: 12) {
                        HStack {
                            Text("Manual Alignment")
                                .font(.headline)
                                .foregroundColor(.white)
                            Spacer()
                            Button("Done") {
                                showManualAdjust = false
                            }
                            .font(.subheadline.bold())
                            .foregroundColor(.cyan)
                        }

                        VStack(spacing: 8) {
                            HStack {
                                Image(systemName: "rotate.3d")
                                    .frame(width: 24)
                                Text("Y Rotation")
                                    .font(.caption)
                                    .frame(width: 70, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(ghostYRotation) },
                                    set: { ghostYRotation = Float($0) }
                                ), in: -0.524...0.524) // ±30°
                                Text("\(Int(ghostYRotation * 180 / .pi))°")
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 40, alignment: .trailing)
                            }
                            .foregroundColor(.white)

                            HStack {
                                Image(systemName: "arrow.left.and.right")
                                    .frame(width: 24)
                                Text("X Position")
                                    .font(.caption)
                                    .frame(width: 70, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(ghostXOffset) },
                                    set: { ghostXOffset = Float($0) }
                                ), in: -1.0...1.0)
                                Text(String(format: "%.2fm", ghostXOffset))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 50, alignment: .trailing)
                            }
                            .foregroundColor(.white)

                            HStack {
                                Image(systemName: "arrow.up.and.down")
                                    .frame(width: 24)
                                Text("Z Position")
                                    .font(.caption)
                                    .frame(width: 70, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(ghostZOffset) },
                                    set: { ghostZOffset = Float($0) }
                                ), in: -1.0...1.0)
                                Text(String(format: "%.2fm", ghostZOffset))
                                    .font(.caption.monospacedDigit())
                                    .frame(width: 50, alignment: .trailing)
                            }
                            .foregroundColor(.white)
                        }

                        Button(action: {
                            ghostYRotation = 0
                            ghostXOffset = 0
                            ghostZOffset = 0
                        }) {
                            Text("Reset to Default")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding()
                    .background(.ultraThinMaterial)
                    .cornerRadius(16)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 160)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(), value: showManualAdjust)
            }
        }
        .confirmationDialog("Ghost Mesh Alignment", isPresented: $showRelocDialog) {
            Button("Re-relocalize") {
                // Reset transform and reload world map by toggling ghost data
                ghostYRotation = 0
                ghostXOffset = 0
                ghostZOffset = 0
                let savedData = cachedGhostMeshData
                cachedGhostMeshData = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    cachedGhostMeshData = savedData
                }
            }
            Button("Manual Adjust") {
                showManualAdjust = true
            }
            Button("Dismiss Ghost Mesh", role: .destructive) {
                dismissGhostMesh = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The ghost mesh from your previous scan may not be accurately aligned. Choose an option:")
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Lock to portrait during capture to ensure consistent orientation
            // for privacy segmentation, depth maps, and frame export.
            //
            // Three independent rendering layers must agree on orientation:
            //   1. RealityKit scene (AR camera feed or VR point cloud — auto-rotates)
            //   2. Privacy segmentation overlay (SwiftUI — WE must rotate)
            //   3. Scene geometry (mesh wireframe in AR, point cloud in VR — auto-rotates)
            // Locking to portrait eliminates orientation mismatches between them.
            // See FaceBlurOverlay.swift for the full orientation architecture docs.
            //
            // TODO: Apple will eventually require all-orientation support on iPad
            // (iPadOS logs warn "UIRequiresFullScreen will soon be ignored" and
            // "Support for all orientations will soon be required"). When that
            // happens, replace this lock with dynamic orientation handling across
            // all layers and both capture modes (AR + VR).
            // See the TODO section in FaceBlurOverlay.swift.
            AppDelegate.orientationLocked = true
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }

            // Reset ghost mesh alignment state for this session
            dismissGhostMesh = false
            showManualAdjust = false
            showRelocDialog = false
            ghostYRotation = 0
            ghostXOffset = 0
            ghostZOffset = 0

            // Load ghost mesh once into @State cache (avoids recomputing on every body eval)
            loadGhostMeshData()

            // Start GPS/heading updates for scan metadata
            locationManager.startUpdating()

            showExtendPrompt = (scanStore.activeScanToExtend != nil)

            // Auto-revert to back camera when developer mode is disabled
            if !developerMode || !flipCameraEnabled {
                usingFrontCamera = false
            }

            // Bind wearable proxy frame session and start stream
            MetaWearableManager.shared.activeCaptureSession = frameCaptureSession
            MetaWearableManager.shared.startStreaming()
        }
        .onDisappear {
            // Unlock orientation when leaving capture
            AppDelegate.orientationLocked = false
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .all))
            }

            // Stop GPS/heading updates to save battery (#12)
            locationManager.stopUpdating()

            // Stop wearable stream and unbind proxy frame session
            MetaWearableManager.shared.stopStreaming()
            MetaWearableManager.shared.activeCaptureSession = nil

            if isRecording {
                stopRecording()
            }
            // Always clear ghost state when leaving Capture
            scanStore.activeLocationForScan = nil
            scanStore.activeRelocalizationMap = nil
            scanStore.activeScanToExtend = nil
            cachedGhostMeshData = nil
            isARSessionReady = false
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
                hardwareDeviceModel: UIDevice.current.name,
                mockIMU: developerMode && mockIMU,
                mockCameraImages: developerMode && mockCameraImages,
                mockDepthMaps: developerMode && mockDepthMaps
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
        // Validate mapping status before allowing save
        if !scanStats.hasEnoughFeaturesForRelocalization {
            // Give user a choice: discard or save anyway (knowing relocalization will fail)
            let alert = UIAlertController(
                title: "Insufficient Tracking",
                message: "This scan has an insufficient mapping status (\(scanStats.mappingStatus)). Successful relocalization later requires 'mapped' status. We suggest scanning more of the area to achieve 'mapped' status before saving. Would you like to save it anyway?",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Save Anyway", style: .default) { _ in
                self.performStopRecording()
            })
            alert.addAction(UIAlertAction(title: "Discard Scan", style: .destructive) { _ in
                self.isRecording = false
                self.frameCaptureSession = FrameCaptureSession()
                MetaWearableManager.shared.activeCaptureSession = self.frameCaptureSession
                self.clearMessage()
                // Session tracking resets naturally when starting a new scan
            })
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.present(alert, animated: true)
            }
            return
        }

        performStopRecording()
    }

    private func performStopRecording() {
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
                let maxW = AppConstants.thumbnailMaxWidth
                let targetSize = CGSize(width: maxW, height: maxW * (uiImage.size.height / uiImage.size.width))
                UIGraphicsBeginImageContextWithOptions(targetSize, false, 1.0)
                UIImage(cgImage: cgImage, scale: 1.0, orientation: .right).draw(in: CGRect(origin: .zero, size: targetSize))
                let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
                UIGraphicsEndImageContext()
                thumbnailData = resizedImage?.jpegData(compressionQuality: AppConstants.thumbnailJpegQuality)
            }
        }

        // ── Now switch to nominal mode (drops mesh anchors, frees AR memory) ──
        isRecording = false

        var finalMeshResult = meshResult

        // If test modes are active and no mesh was generated (e.g. Simulator), inject a dummy mesh
        if finalMeshResult == nil || finalMeshResult!.data.isEmpty {
            if developerMode && (mockCameraImages || mockIMU || mockDepthMaps) {
                let dummyObj = "v -0.5 -0.5 -0.5\nv 0.5 -0.5 -0.5\nv 0.5 0.5 -0.5\nf 1 2 3\n"
                if let dummyObjData = dummyObj.data(using: .utf8) {
                    finalMeshResult = (dummyObjData, 3, 1)
                }
            }
        }

        guard let result = finalMeshResult, !result.data.isEmpty else {
            saveMessage = "No Mesh Data"
            frameCaptureSession = FrameCaptureSession()
            MetaWearableManager.shared.activeCaptureSession = frameCaptureSession
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

        let capturedLocationId = scanStore.activeLocationForScan

        // Run vertex coloring in background using saved camera frames (.utility QoS
        // so the name-prompt keyboard stays responsive while coloring runs)
        DispatchQueue.global(qos: .utility).async {
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
                            locationId: capturedLocationId,
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
                        MetaWearableManager.shared.activeCaptureSession = self.frameCaptureSession
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

        let locationId: UUID?
        var finalName = "New Space"

        if let activeLocationId = pending.locationId {
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
            hardwareDeviceModel: UIDevice.current.name,
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
