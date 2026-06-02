import SwiftUI
import ARKit
import RealityKit
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
    @AppStorage(AppConstants.Key.ghostMeshColor) private var ghostMeshColor: String = AppConstants.ghostMeshColor
    @AppStorage(AppConstants.Key.captureMode) private var captureModeStr: String = AppConstants.captureMode
    // Stream mode removed — fixed to Capture (Stream is a future feature)
    @State private var usingFrontCamera = false
    @State private var currentARSession: ARSession? = nil
    @State private var saveMessage: String? = nil
    @State private var isRecording = false
    // Set true by ARCoverageView's coordinator when VIO tracking is lost mid‑recording; observed
    // below to halt the scan and prompt save/rescan (data after VIO loss is corrupt).
    @State private var vioCompromised = false
    @State private var recordingSeconds = 0
    @State private var recordingTimer: Timer? = nil
    @State private var frameCaptureSession = FrameCaptureSession()
    // Detects main-thread stalls during scanning when Perf Diagnostics is on (no-op otherwise).
    @State private var mainThreadWatchdog = MainThreadWatchdog()
    // colorAccumulator removed — vertex coloring now deferred to post-processing
    @AppStorage(AppConstants.Key.rawOverlapMax) private var overlapMax: Double = AppConstants.overlapMax
    @AppStorage(AppConstants.Key.rawRejectBlur) private var rejectBlur: Bool = AppConstants.rejectBlur
    @Binding var selectedTab: Int
    var initialWorldMapURL: URL? = nil // Support for Scan4D anchoring

    // Scan4D properties
    @State private var showNamePrompt = false
    @State private var newLocationName = ""
    @State private var newLocationScanCase: ScanCase = .rescan
    @State private var cachedGhostMeshData: Data? = nil
    @State private var isARSessionReady = false
    @State private var showSettings = false
    @State private var showRelocDialog = false
    @State private var showManualAdjust = false
    @State private var ghostYRotation: Float = 0
    @State private var ghostXOffset: Float = 0
    @State private var ghostZOffset: Float = 0
    @State private var dismissGhostMesh = false
    @State private var bakedGhostTransform: simd_float4x4? = nil
    @State private var activeLocationName: String? = nil

    struct ProcessingData {
        let frame: ARFrame?
        let rawDataPath: URL?
        let thumbnailData: Data?
    }
    @State private var pendingProcessingData: ProcessingData?

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
                vioCompromised: $vioCompromised,
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
                dismissGhostMesh: dismissGhostMesh,
                bakedGhostTransform: bakedGhostTransform
            )
                .ignoresSafeArea()
                .onChange(of: vioCompromised) { _, lost in
                    if lost { handleVIOCompromised() }
                }

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
                    HStack(spacing: 8) {
                        Text("🔄 Move camera to relocalize with previous scan")
                        OctahedronIcon(color: ghostMeshColor.swiftUIColor)
                    }
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
                    } else {
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape.fill")
                                .font(.title3)
                                .foregroundColor(.white)
                                .padding(10)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                    }

                }
                .padding()

                if let locName = activeLocationName {
                    let modeText = scanStore.activeScanToExtend != nil ? "Extend Scan" : "Rescan"
                    Text("\(locName) — \(modeText)")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                
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
                                OctahedronIcon(color: ghostMeshColor.swiftUIColor)
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
            // Pick up any Settings change to the diagnostics flag, then start the main-thread
            // stall watchdog for this capture session (both no-ops unless Perf Diagnostics is on).
            PerfDiag.refresh()
            mainThreadWatchdog.start()

            if let locId = scanStore.activeLocationForScan {
                let descriptor = FetchDescriptor<ScanLocation>(predicate: #Predicate { $0.id == locId })
                if let loc = try? modelContext.fetch(descriptor).first {
                    activeLocationName = loc.name
                }
            }
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

            // Auto-revert to back camera when developer mode is disabled
            if !developerMode || !flipCameraEnabled {
                usingFrontCamera = false
            }

            // Bind wearable proxy frame session and start stream
            MetaWearableManager.shared.activeCaptureSession = frameCaptureSession
            MetaWearableManager.shared.startStreaming()
        }
        .onDisappear {
            mainThreadWatchdog.stop()

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
            activeLocationName = nil
        }
        .overlay {
            if showNamePrompt {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    
                    VStack(spacing: 20) {
                        Text("Name this Space")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("Enter a unique name for this space so you can efficiently 'Extend Scan' later.")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                            .foregroundColor(.secondary)
                        
                        TextField("Location Name (e.g., Living Room)", text: $newLocationName)
                            .textFieldStyle(.roundedBorder)
                            .padding(.horizontal)
                        
                        Picker("Use Case", selection: $newLocationScanCase) {
                            Text("Time-Series").tag(ScanCase.rescan)
                            Text("Space Extension").tag(ScanCase.extend)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        
                        HStack {
                            Button("Cancel") {
                                showNamePrompt = false
                                pendingProcessingData = nil
                                saveMessage = nil
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            
                            Button("Save") {
                                showNamePrompt = false
                                if let data = pendingProcessingData {
                                    let trimmedName = newLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let finalName = trimmedName.isEmpty ? "New Space" : trimmedName
                                    startBackgroundProcessing(name: finalName, locationId: nil, scanCase: newLocationScanCase, data: data)
                                    pendingProcessingData = nil
                                }
                            }
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 8)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(16)
                    .shadow(radius: 20)
                    .padding(40)
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
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
        // Bake the manual offsets into a permanent state right before recording starts
        if ghostXOffset != 0 || ghostYRotation != 0 || ghostZOffset != 0 {
            let rotation = simd_quatf(angle: ghostYRotation, axis: [0, 1, 0])
            let translation = SIMD3<Float>(ghostXOffset, 0, ghostZOffset)
            bakedGhostTransform = Transform(rotation: rotation, translation: translation).matrix
            
            // Zero out sliders so the UI doesn't double-apply the visual offset
            ghostYRotation = 0
            ghostXOffset = 0
            ghostZOffset = 0
        } else {
            bakedGhostTransform = nil
        }
        
        showManualAdjust = false // Dismiss manual adjustment dialog automatically

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
        startRecordingTimer()
    }
    
    private func startRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            recordingSeconds += 1
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
            alert.addAction(UIAlertAction(title: "Continue Scanning", style: .cancel) { _ in
                self.startRecordingTimer()
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
        // Capture the current frame for background mesh export + a 2D thumbnail
        let currentFrame = currentARSession?.currentFrame
        let thumbnailData = makeThumbnail(from: currentFrame)

        // ── Now switch to nominal mode (drops mesh anchors, frees AR memory) ──
        isRecording = false

        beginProcessing(ProcessingData(frame: currentFrame, rawDataPath: rawDataPath, thumbnailData: thumbnailData))
    }

    /// Renders a downsampled JPEG thumbnail from the current camera frame (sensor→portrait via .right).
    private func makeThumbnail(from currentFrame: ARFrame?) -> Data? {
        guard let currentFrame = currentFrame else { return nil }
        let ciImage = CIImage(cvPixelBuffer: currentFrame.capturedImage)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        let maxW = AppConstants.thumbnailMaxWidth
        let targetSize = CGSize(width: maxW, height: maxW * (uiImage.size.height / uiImage.size.width))
        UIGraphicsBeginImageContextWithOptions(targetSize, false, 1.0)
        UIImage(cgImage: cgImage, scale: 1.0, orientation: .right).draw(in: CGRect(origin: .zero, size: targetSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return resizedImage?.jpegData(compressionQuality: AppConstants.thumbnailJpegQuality)
    }

    /// Routes captured scan data into background processing — prompting for a name if this is a
    /// new location, or extending the active one.
    private func beginProcessing(_ processingData: ProcessingData) {
        if scanStore.activeLocationForScan == nil {
            newLocationName = ""
            newLocationScanCase = .rescan
            pendingProcessingData = processingData
            withAnimation { showNamePrompt = true }
        } else {
            // Already extending a scan; user won't be prompted. Start processing immediately.
            startBackgroundProcessing(name: "Extended Scan", locationId: scanStore.activeLocationForScan, scanCase: .extend, data: processingData)
        }
    }

    /// VIO starvation guard handler: ARKit tracking was lost mid‑recording, so frames captured
    /// after that point are unreliable. Halt capture immediately, then let the user save what was
    /// gathered so far or discard it and rescan.
    private func handleVIOCompromised() {
        vioCompromised = false // reset the latch so a later scan can trip the guard again
        guard isRecording else { return }

        recordingTimer?.invalidate()
        recordingTimer = nil

        // Halt capture now and finalize whatever was gathered before tracking was lost.
        let rawDataPath = frameCaptureSession.stop()
        let currentFrame = currentARSession?.currentFrame
        let thumbnailData = makeThumbnail(from: currentFrame)
        isRecording = false
        let processingData = ProcessingData(frame: currentFrame, rawDataPath: rawDataPath, thumbnailData: thumbnailData)

        let alert = UIAlertController(
            title: "Tracking Lost",
            message: "AR tracking was interrupted during this scan, so anything captured after that point is unreliable. Save what was captured so far, or discard it and rescan?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Discard & Rescan", style: .destructive) { _ in
            self.discardCapturedData(at: rawDataPath)
        })
        alert.addAction(UIAlertAction(title: "Save Anyway", style: .default) { _ in
            self.beginProcessing(processingData)
        })
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            rootVC.present(alert, animated: true)
        }
    }

    /// Discards a partially-captured scan: removes its on-disk capture dir and resets the capture
    /// session so the next scan starts clean.
    private func discardCapturedData(at rawDataPath: URL?) {
        if let rawDataPath = rawDataPath {
            try? FileManager.default.removeItem(at: rawDataPath)
        }
        frameCaptureSession = FrameCaptureSession()
        MetaWearableManager.shared.activeCaptureSession = frameCaptureSession
        clearMessage()
    }

    private func startBackgroundProcessing(name: String, locationId: UUID?, scanCase: ScanCase = .rescan, data: ProcessingData) {
        // Change to Scans tab immediately
        selectedTab = 2
        scanStore.isProcessingScan = true
        scanStore.processingMessage = "Exporting Mesh..."
        
        let capturedLocationId = locationId
        let frame = data.frame
        let rawDataPath = data.rawDataPath
        let thumbnailData = data.thumbnailData
        let developerMode = self.developerMode
        let mockCameraImages = self.mockCameraImages
        let mockIMU = self.mockIMU
        let mockDepthMaps = self.mockDepthMaps
        let privacyFilter = isPrivacyFilterOn

        DispatchQueue.global(qos: .utility).async {
            // 1. Export Mesh OBJ
            var finalMeshResult = ARCoverageView.exportMeshOBJ(from: frame, privacyFilter: privacyFilter)
            
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
                DispatchQueue.main.async {
                    self.saveMessage = "No Mesh Data"
                    self.frameCaptureSession = FrameCaptureSession()
                    MetaWearableManager.shared.activeCaptureSession = self.frameCaptureSession
                    self.clearMessage()
                    self.scanStore.isProcessingScan = false
                    self.scanStore.processingMessage = nil
                }
                return
            }

            DispatchQueue.main.async {
                self.scanStore.processingMessage = "Saving scan..."
            }

            let vertexColors = VertexColorAccumulator.generateNormalsColors(objData: result.data)

            DispatchQueue.main.async {
                self.scanStore.processingMessage = "Saving World Map..."

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

                        // Save directly
                        let savedScan = ScanFileManager.shared.saveScan(
                            context: self.modelContext,
                            locationId: capturedLocationId,
                            name: name,
                            meshData: result.data,
                            vertexCount: result.vertexCount,
                            faceCount: result.faceCount,
                            hardwareDeviceModel: UIDevice.current.name,
                            rawDataPath: rawDataPath,
                            vertexColors: vertexColors,
                            worldMapURL: mapURL,
                            thumbnailData: thumbnailData,
                            scanCase: scanCase
                        )

                        // Release frame capture session memory
                        self.frameCaptureSession = FrameCaptureSession()
                        MetaWearableManager.shared.activeCaptureSession = self.frameCaptureSession

                        // Reset the active state so subsequent scans don't default to this location
                        self.scanStore.activeLocationForScan = nil
                        self.scanStore.activeRelocalizationMap = nil
                        self.scanStore.activeScanToExtend = nil
                        self.cachedGhostMeshData = nil
                        self.activeLocationName = nil

                        self.scanStore.isProcessingScan = false
                        self.scanStore.processingMessage = nil

                        // Programmatically navigate to the created LocationDetailView
                        if let loc = savedScan.location {
                            self.scanStore.navigationPath.removeLast(self.scanStore.navigationPath.count)
                            self.scanStore.navigationPath.append(loc)
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
}

#Preview {
    CaptureView(selectedTab: .constant(1))
        .environment(ScanStore())
}

struct OctahedronIcon: View {
    var color: Color
    var body: some View {
        Path { path in
            let w: CGFloat = 16
            let h: CGFloat = 16
            let midX = w / 2
            let midY = h / 2
            let top = CGPoint(x: w * 0.5, y: h * 0.075)
            let bottom = CGPoint(x: w * 0.5, y: h * 0.925)
            let left = CGPoint(x: w * 0.075, y: h * 0.53)
            let right = CGPoint(x: w * 0.925, y: h * 0.47)
            let front = CGPoint(x: w * 0.61, y: h * 0.61)
            let back = CGPoint(x: w * 0.39, y: h * 0.39)
            
            // Outline
            path.move(to: top)
            path.addLine(to: right)
            path.addLine(to: bottom)
            path.addLine(to: left)
            path.closeSubpath()
            
            // Front edges
            path.move(to: top)
            path.addLine(to: front)
            path.addLine(to: bottom)
            
            path.move(to: left)
            path.addLine(to: front)
            path.addLine(to: right)
            
            // Back edges (wireframe)
            path.move(to: top)
            path.addLine(to: back)
            path.addLine(to: bottom)
            
            path.move(to: left)
            path.addLine(to: back)
            path.addLine(to: right)
        }
        .stroke(color, lineWidth: 1.5)
        .frame(width: 16, height: 16)
    }
}
