import SwiftUI
import ARKit
import SwiftData

// swiftlint:disable file_length type_body_length
struct CaptureView: View {
    @Environment(ScanStore.self) var scanStore
    @Environment(\.modelContext) var modelContext
    @State var scanStats = ScanStats()
    @State var locationManager = LocationManager()
    @AppStorage(AppConstants.Key.privacyFilter) var isPrivacyFilterOn = AppConstants.privacyFilter
    @AppStorage(AppConstants.Key.developerMode) var developerMode: Bool = AppConstants.developerMode
    @AppStorage(AppConstants.Key.flipCameraEnabled) private var flipCameraEnabled: Bool = AppConstants.flipCameraEnabled
    @AppStorage(AppConstants.Key.mockIMU) var mockIMU: Bool = AppConstants.mockIMU
    @AppStorage(AppConstants.Key.mockCameraImages) var mockCameraImages: Bool = AppConstants.mockCameraImages
    @AppStorage(AppConstants.Key.mockDepthMaps) var mockDepthMaps: Bool = AppConstants.mockDepthMaps
    @AppStorage(AppConstants.Key.activeMeshColor) private var activeMeshColor: String = AppConstants.activeMeshColor
    // Stream mode removed — fixed to Capture (Stream is a future feature)
    @State private var usingFrontCamera = false
    @State var currentARSession: ARSession? = nil
    @State var saveMessage: String? = nil
    @State var isRecording = false
    @State var recordingSeconds = 0
    @State var recordingTimer: Timer? = nil
    @State var frameCaptureSession = FrameCaptureSession()
    // colorAccumulator removed — vertex coloring now deferred to post-processing
    @AppStorage(AppConstants.Key.rawOverlapMax) var overlapMax: Double = AppConstants.overlapMax
    @AppStorage(AppConstants.Key.rawRejectBlur) var rejectBlur: Bool = AppConstants.rejectBlur
    @Binding var selectedTab: Int
    var initialWorldMapURL: URL? = nil // Support for Scan4D anchoring

    // Scan4D properties
    @State var showNamePrompt = false
    @State var newLocationName = ""
    @State var pendingScan: PendingScanData? = nil
    @State var isProcessingMesh = false
    @State var isWaitingToSave = false
    @State var cachedGhostMeshData: Data? = nil
    @State private var isARSessionReady = false
    @State var messageVersion = 0
    @State var hapticGenerator = UIImpactFeedbackGenerator(style: .medium)

    @State var showExtendPrompt = false
    @State var showExtendOverlay = false // Semi-transparent overlay during Pin & Extend save
    @State var extendPhaseText = "" // Text shown in the extend overlay
    @State var showInsufficientTrackingAlert = false // SwiftUI alert for poor mapping status
    @State var sessionStabilizationTask: Task<Void, Never>? // Cancellable task for AR session warm-up after extend
    @State var isConfirmingAlignment = false // Re-entry guard for confirmAlignment double-tap

    struct PendingScanData {
        let locationId: UUID?
        let meshData: Data
        let vertexCount: Int
        let faceCount: Int
        let rawDataPath: URL?
        let vertexColors: Data?
        let worldMapURL: URL?
        let thumbnailData: Data?
        let scanCase: ScanCase
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
                useFrontCamera: usingFrontCamera,
                initialWorldMapURL: scanStore.activeRelocalizationMap,
                initialGhostMeshData: cachedGhostMeshData,
                scanStore: scanStore
            )
                .ignoresSafeArea()
                // Fix phase race: set .loadingWorldMap before the AR session starts
                // loading the world map. onAppear fires AFTER the first render, so
                // the AR view could detect a boundary anchor before the phase is set.
                .onAppear {
                    if scanStore.activeScanCase == .linkAdjacent && scanStore.activeScanToExtend != nil
                        && scanStore.capturePhase == .idle {
                        scanStore.capturePhase = .loadingWorldMap
                    }
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

            // Privacy blur overlay (shown when privacy filter is on AND recording)
            if isPrivacyFilterOn && isRecording {
                PrivacyBlurOverlay(arSession: currentARSession)
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
                // Scan Mode Prompt (transient)
                if showExtendPrompt {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scanStore.activeScanCase == .linkAdjacent ? "Link Adjacent Space" : "Rescan Space")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text(scanStore.activeScanCase == .linkAdjacent
                                 ? """
                                   Link Adjacent Space: Relocalize with the \
                                   previous scan, walk to the boundary, and \
                                   confirm to relationally link this adjacent \
                                   space.
                                   """
                                 : """
                                   Rescan Space: Re-scan the previous area \
                                   to capture changes over time.
                                   """)
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

                // Pin & Extend Button — available during any recording session
                if isRecording && scanStore.capturePhase == .recording && scanStats.hasEnoughFeaturesForRelocalization {
                    Button(action: { pinAndExtend() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.title3)
                            Text("Pin & Extend")
                                .font(.subheadline).bold()
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.orange.opacity(0.85))
                        .cornerRadius(20)
                        .shadow(radius: 5)
                    }
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
            // Extend transition overlay (semi-transparent over live AR)
            if showExtendOverlay {
                ZStack {
                    Color.black.opacity(0.6).ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.green)
                        Text(extendPhaseText)
                            .font(.headline)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                        Text("Do not move")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: showExtendOverlay)
            }

            // Alignment overlay for cross-session resume (Flow B)
            if scanStore.capturePhase == .loadingWorldMap
                || scanStore.capturePhase == .aligning
                || scanStore.capturePhase == .alignedReady {
                AlignmentOverlayView(
                    scanStats: scanStats,
                    onConfirm: { confirmAlignment() },
                    onCancel: { cancelAlignment() }
                )
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Load ghost mesh once into @State cache (avoids recomputing on every body eval)
            loadGhostMeshData()

            // Start GPS/heading updates for scan metadata
            locationManager.startUpdating()

            showExtendPrompt = (scanStore.activeScanToExtend != nil)

            // Prepare haptic engine for pin drop
            hapticGenerator.prepare()

            // Auto-revert to back camera when developer mode is disabled
            if !developerMode || !flipCameraEnabled {
                usingFrontCamera = false
            }

            // Bind wearable proxy frame session and start stream
            MetaWearableManager.shared.activeCaptureSession = frameCaptureSession
            MetaWearableManager.shared.startStreaming()
        }
        .onChange(of: scanStore.mapLoadFailed) { failed in
            if failed {
                showTransientMessage("Failed to load map for adjacent link.", duration: 4)

                // Abort the adjacent-link capture flow so stale source/scan state
                // cannot be reused after the error message is shown.
                let inflightStitchLink = scanStore.pendingStitchLink
                scanStore.resetCaptureState()
                scanStore.pendingStitchLink = inflightStitchLink

                scanStore.mapLoadFailed = false // reset
            }
        }
        .onDisappear {
            // Stop GPS/heading updates to save battery (#12)
            locationManager.stopUpdating()

            // Stop wearable stream and unbind proxy frame session
            MetaWearableManager.shared.stopStreaming()
            MetaWearableManager.shared.activeCaptureSession = nil

            if isRecording {
                stopRecording(force: true)
            }
            // Always clear ghost state when leaving Capture.
            // Preserve pendingStitchLink for in-flight saves — the async pipeline
            // needs it to write stitching.json. It's consumed and nilled out by
            // writeStitchingLinkIfPending when the save completes.
            let inflightStitchLink = scanStore.pendingStitchLink
            scanStore.resetCaptureState()
            scanStore.pendingStitchLink = inflightStitchLink
            cachedGhostMeshData = nil
            showExtendOverlay = false
            isARSessionReady = false
            sessionStabilizationTask?.cancel()
            sessionStabilizationTask = nil
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
            Text("Enter a unique name for this space so you can add scans later.")
        }
        .alert("Insufficient Tracking", isPresented: $showInsufficientTrackingAlert) {
            Button("Save Anyway") {
                recordingTimer?.invalidate()
                recordingTimer = nil
                performStopRecording()
            }
            Button("Discard Scan", role: .destructive) {
                recordingTimer?.invalidate()
                recordingTimer = nil
                isRecording = false
                frameCaptureSession = FrameCaptureSession()
                MetaWearableManager.shared.activeCaptureSession = frameCaptureSession
                clearMessage()
                
                // Clean up any empty location created for this flow
                if let locId = scanStore.activeLocationForScan {
                    let descriptor = FetchDescriptor<ScanLocation>(predicate: #Predicate { $0.id == locId })
                    if let location = try? modelContext.fetch(descriptor).first, location.scans.isEmpty {
                        modelContext.delete(location)
                        try? modelContext.save()
                    }
                }
                
                // Reset capture/stitching state so a stale pendingStitchLink
                // from a prior extend flow doesn't corrupt the next save.
                scanStore.resetCaptureState()
            }
        } message: {
            Text("This scan has a poor mapping status (\(scanStats.mappingStatus)). Successful relocalization later requires 'mapped' or 'extending' status. Would you like to save it anyway?")
        }
    }

    private var qualityColor: Color {
        let quality = scanStats.averageQuality
        if quality < 0.3 { return .red }
        if quality < 0.6 { return .yellow }
        return .green
    }

    var formattedTime: String {
        let minutes = recordingSeconds / 60
        let seconds = recordingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // Methods are organized into extension files:
    //   CaptureView+Recording.swift  — toggleRecording, startRecording, stopRecording, performStopRecording, savePendingScan, etc.
    //   CaptureView+Extend.swift     — pinAndExtend (Flow A: mid-session extend)
    //   CaptureView+Alignment.swift  — confirmAlignment, cancelAlignment (Flow B: cross-session alignment)
}

#Preview {
    CaptureView(selectedTab: .constant(1))
        .environment(ScanStore())
}
