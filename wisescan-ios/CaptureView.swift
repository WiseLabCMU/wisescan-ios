import SwiftUI
import ARKit
import RealityKit
import RoomPlan
import SwiftData

// swiftlint:disable file_length type_body_length
struct CaptureView: View {
    @Environment(ScanStore.self) var scanStore
    @Environment(\.modelContext) var modelContext
    @State var scanStats = ScanStats()
    @State var locationManager = LocationManager()
    @AppStorage(AppConstants.Key.privacyFilter) var isPrivacyFilterOn = AppConstants.privacyFilter
    @AppStorage(AppConstants.Key.developerMode) var developerMode: Bool = AppConstants.developerMode
    @AppStorage(AppConstants.Key.mockIMU) var mockIMU: Bool = AppConstants.mockIMU
    @AppStorage(AppConstants.Key.mockCameraImages) var mockCameraImages: Bool = AppConstants.mockCameraImages
    @AppStorage(AppConstants.Key.mockDepthMaps) var mockDepthMaps: Bool = AppConstants.mockDepthMaps
    @AppStorage(AppConstants.Key.activeMeshColor) private var activeMeshColor: String = AppConstants.activeMeshColor
    @AppStorage(AppConstants.Key.ghostMeshColor) private var ghostMeshColor: String = AppConstants.ghostMeshColor
    @AppStorage(AppConstants.Key.captureMode) private var captureModeStr: String = AppConstants.captureMode
    // Stream mode removed — fixed to Capture (Stream is a future feature)
    // NOTE: capture/recording state is `internal` (not private) because the recording, alignment,
    // and extend flows live in CaptureView+Recording/+Alignment/+Extend.swift extensions.
    @State var currentARSession: ARSession?
    @State var saveMessage: String?
    /// Mesh vertex count captured at record-start. The "move to start the live mesh" cue is shown
    /// until enough NEW vertices appear; a baseline makes it fire in relocalized ghost/stitch flows
    /// where `totalVertices` already starts high (would otherwise never cross an absolute threshold).
    @State var verticesAtRecordStart = 0
    @State var isRecording = false
    // Set true by ARCoverageView's coordinator when VIO tracking is lost mid‑recording; observed
    // below to halt the scan and prompt save/rescan (data after VIO loss is corrupt).
    @State var vioCompromised = false
    // Battery: pauses ARCoverageView's session after the capture tab has been hidden for
    // AppConstants.arIdleTeardownSeconds; resumed on return. Rapid successive scans stay warm.
    @State private var pauseARSession = false
    @State private var idleTeardownTimer: Timer?
    @State var recordingSeconds = 0
    @State var recordingTimer: Timer?
    @State var frameCaptureSession = FrameCaptureSession()
    // Detects main-thread stalls during scanning when Perf Diagnostics is on (no-op otherwise).
    @State private var mainThreadWatchdog = MainThreadWatchdog()
    // colorAccumulator removed — vertex coloring now deferred to post-processing
    @AppStorage(AppConstants.Key.rawOverlapMax) var overlapMax: Double = AppConstants.overlapMax
    @AppStorage(AppConstants.Key.rawRejectBlur) var rejectBlur: Bool = AppConstants.rejectBlur
    @Binding var selectedTab: Int
    var initialWorldMapURL: URL? // Support for Scan4D anchoring

    // Scan4D properties
    @State var showNamePrompt = false
    @State var newLocationName = ""
    @State var pendingScan: PendingScanData?
    @State var isProcessingMesh = false
    @State var isWaitingToSave = false
    @State var cachedGhostMeshData: Data?
    /// Track C — connectors shared by the active location's scans with other maps, in the active
    /// scans' world frame. Computed here (CaptureView owns the ModelContext) and passed to
    /// ARCoverageView, which renders one labeled marker per connector when rescanning an existing
    /// space. Empty unless `activeScanCase == .rescanSpace` with linked scans.
    @State var connectorAnchors: [ConnectorAnchor] = []
    /// RoomPlan: final CapturedRoom snapshot captured at recording stop. Populated by the
    /// ARCoverageView Coordinator; consumed by finishStopRecording for export.
    @State var finalCapturedRoom: CapturedRoom?
    @State private var isARSessionReady = false
    @State var messageVersion = 0
    @State var hapticGenerator = UIImpactFeedbackGenerator(style: .medium)

    @State var showExtendPrompt = false
    @State var showExtendOverlay = false // Semi-transparent overlay during Pin & Extend save
    @State var extendPhaseText = "" // Text shown in the extend overlay
    @State var showInsufficientTrackingAlert = false // SwiftUI alert for poor mapping status
    @State var sessionStabilizationTask: Task<Void, Never>? // Cancellable task for AR session warm-up after extend
    @State var isConfirmingAlignment = false // Re-entry guard for confirmAlignment double-tap

    @State private var showSettings = false
    @State private var activeLocationName: String?
    // Ghost-mesh manual "nudger" (from main) — coexists with our anchor-based AlignmentOverlayView.
    // The sliders adjust the ghost overlay; startRecording bakes the offset into the ARKit world
    // origin (bakedGhostTransform → ARCoverageView.setWorldOrigin) so the captured mesh and the
    // world map exported at save time stay co-framed. `internal` (not private) where the recording
    // extension (startRecording) needs access.
    @State var ghostYRotation: Float = 0
    @State var ghostXOffset: Float = 0
    @State var ghostZOffset: Float = 0
    @State private var dismissGhostMesh = false
    @State var bakedGhostTransform: simd_float4x4?
    @State private var showRelocDialog = false
    @State var showManualAdjust = false

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

    /// Computes the connector anchors for the active location (Track C). Only populated when
    /// rescanning an existing space: gathers every connector each scan in the location shares with
    /// other maps via `StitchLinkStore.connectorAnchors(for:)`. ARCoverageView renders these as
    /// labeled markers once the rescan relocalizes (record-start). Cleared otherwise.
    private func loadConnectorAnchors() {
        guard scanStore.activeScanCase == .rescanSpace,
              let locId = scanStore.activeLocationForScan else {
            connectorAnchors = []
            return
        }
        let descriptor = FetchDescriptor<ScanLocation>(predicate: #Predicate { $0.id == locId })
        guard let location = try? modelContext.fetch(descriptor).first else {
            connectorAnchors = []
            return
        }
        // Safe to aggregate connectors across ALL scans in the location: a location's scans share
        // one world frame (each rescan relocalizes to the latest scan's map, which itself was
        // captured by relocalizing to the prior one — a continuous frame chain), so every scan's
        // `localAnchor` pose is expressed in the same frame we relocalize into here. If rescanning
        // a NON-latest scan is ever allowed, this invariant breaks and this must filter to the
        // connectors of the scan actually being relocalized against (`activeScanToExtend`).
        //
        // This surfaces EVERY connector incident to the location — the ≤1 link TO this map (it is a
        // target) plus the 0..N links FROM this map (it is a source) — because the underlying query
        // is direction-agnostic (see StitchLinkStore.incidentLinks). De-dup by link id: a connector
        // could otherwise repeat if both its endpoints are scans of THIS location. The links are
        // fetched ONCE via the scan-id index, not per scan.
        let linkIndex = StitchLinkStore.incidentLinksByScanId(in: modelContext)
        var seenConnectors = Set<UUID>()
        connectorAnchors = location.scans
            .flatMap { StitchLinkStore.connectorAnchors(for: $0, from: linkIndex[$0.id] ?? []) }
            .filter { seenConnectors.insert($0.id).inserted }
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
                initialWorldMapURL: scanStore.activeRelocalizationMap,
                initialGhostMeshData: cachedGhostMeshData,
                scanStore: scanStore,
                connectorAnchors: connectorAnchors,
                finalCapturedRoom: $finalCapturedRoom,
                ghostYRotation: ghostYRotation,
                ghostXOffset: ghostXOffset,
                ghostZOffset: ghostZOffset,
                dismissGhostMesh: dismissGhostMesh,
                bakedGhostTransform: bakedGhostTransform,
                pauseARSession: pauseARSession
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
                // Main's VIO-loss guard: halt + prompt save/rescan when tracking is lost mid-scan.
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

            // Live privacy indicator (shown when privacy filter is on AND recording in AR mode).
            // A cheap red-eye marker over each person region, driven by ARKit's existing
            // segmentation stencil — NOT the old per-tick Vision pass + pixelate render (which
            // competed with VIO). Saved RGB frames are still blurred; this is just the live signal.
            // In VR mode the point cloud already shows person-shaped holes as the indicator.
            if isPrivacyFilterOn && isRecording && (AppConstants.CaptureMode(rawValue: captureModeStr) ?? .ar) != .vr {
                PrivacyEyeOverlay(arSession: currentARSession)
                    .ignoresSafeArea()
            }

            // Permissions Overlay (Preempts user if not authorized)
            PermissionsOverlay(locationManager: locationManager)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                if isRecording, let warning = frameCaptureSession.blurWarningReason {
                    Text(warning == .fastMotion ?
                         "⚠️ Slow down — moving too fast" :
                         "⚠️ Hold steady — regaining tracking")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background((warning == .fastMotion ? Color.orange : Color.blue).opacity(0.85))
                        .cornerRadius(20)
                        .shadow(radius: 5)
                        .transition(.scale.combined(with: .opacity))
                        .animation(.easeInOut(duration: 0.2), value: frameCaptureSession.blurWarningReason)
                }

                if cachedGhostMeshData != nil && scanStats.trackingStatus == .limited(reason: .relocalizing) {
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
                        .animation(.easeInOut(duration: 0.2), value: scanStats.trackingStatus)
                }

                let capturedSinceStart = scanStats.totalVertices - verticesAtRecordStart
                let needsLiveMeshCue = capturedSinceStart < AppConstants.liveMeshCueVertexThreshold
                if isRecording && needsLiveMeshCue &&
                   scanStats.trackingStatus != .limited(reason: .relocalizing) &&
                   !frameCaptureSession.isBlurWarningActive {
                    Text("📷 Move the camera to start the live mesh")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.indigo.opacity(0.85))
                        .cornerRadius(20)
                        .shadow(radius: 5)
                        .transition(.scale.combined(with: .opacity))
                        .animation(.easeInOut(duration: 0.2), value: needsLiveMeshCue)
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
                // Scan Mode Prompt (transient)
                if showExtendPrompt {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(scanStore.activeScanCase == .linkAdjacent ? "Connect Adjacent Space" : "Rescan Space")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text(scanStore.activeScanCase == .linkAdjacent
                                 ? """
                                   Connect Adjacent Space: Relocalize with the \
                                   previous scan, walk to where the new connector should be, and \
                                   confirm to connect this adjacent \
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
                        Button(action: { showExtendPrompt = false }, label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white.opacity(0.6))
                        })
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
                        Button(action: { showSettings = true }, label: {
                            Image(systemName: "gearshape.fill")
                                .font(.title3)
                                .foregroundColor(.white)
                                .padding(10)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        })
                    }

                }
                .padding()

                if let locName = activeLocationName {
                    let modeText = scanStore.activeScanCase == .linkAdjacent ? "Connect Adjacent Space" : "Rescan Space"
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
                                }, label: {
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
                                })
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
                                    }, label: {
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
                                    })
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
                        Image(systemName: scanStats.isAtCapacity ?
                              "exclamationmark.octagon.fill" :
                              "exclamationmark.triangle.fill")
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
                    Button(action: { pinAndExtend() }, label: {
                        HStack(spacing: 8) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.title3)
                                Text("Save Scan & Place Connector")
                                    .font(.subheadline).bold()
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.orange.opacity(0.85))
                        .cornerRadius(20)
                        .shadow(radius: 5)
                    })
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

                                // Row 1.5: Semantic classes detected (colored dots)
                                if !scanStats.detectedClasses.isEmpty {
                                    HStack(spacing: 6) {
                                        Image(systemName: "tag.fill")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                        ForEach(SemanticClass.allCases.filter { $0 != .none && scanStats.detectedClasses.contains($0.rawValue) },
                                                id: \.rawValue) { cls in
                                            Circle()
                                                .fill(cls.swiftUIDisplayColor)
                                                .frame(width: 8, height: 8)
                                        }
                                        Spacer()
                                    }
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
                        Button(action: { toggleRecording() }, label: {
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
                        })
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

            // Ghost-mesh manual nudger (restored from main): a bottom-left status chip that opens an
            // alignment dialog, plus a slider overlay to rotate/translate the ghost when
            // relocalization is imperfect. Complements the anchor-based AlignmentOverlayView above;
            // startRecording bakes any offset into the world origin so mesh + world map stay co-framed.
            if cachedGhostMeshData != nil && !dismissGhostMesh {
                VStack {
                    Spacer()
                    HStack {
                        Button(action: { showRelocDialog = true }, label: {
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
                        })
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
                        }, label: {
                            Text("Reset to Default")
                                .font(.caption)
                                .foregroundColor(.orange)
                        })
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
                // Reset transform and reload the world map by toggling the ghost data.
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
            Text("The ghost mesh from your previous scan may not be perfectly aligned. Choose an option:")
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Pick up any Settings change to the diagnostics flag, then start the main-thread
            // stall watchdog for this capture session (both no-ops unless Perf Diagnostics is on).
            PerfDiag.refresh()
            mainThreadWatchdog.start()

            // Battery: returning to the capture tab — cancel any pending idle teardown and resume
            // the AR session if it was paused while we were away.
            idleTeardownTimer?.invalidate()
            idleTeardownTimer = nil
            pauseARSession = false

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

            // Track C — gather connectors for a rescan so ARCoverageView can mark coverage
            // boundaries once the session relocalizes.
            loadConnectorAnchors()

            // Start GPS/heading updates for scan metadata
            locationManager.startUpdating()

            showExtendPrompt = (scanStore.activeScanToExtend != nil)

            // Prepare haptic engine for pin drop
            hapticGenerator.prepare()

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

                // Tear down the reference ghost loaded for the (now-failed) link: clearing
                // cachedGhostMeshData drives ARCoverageView's teardown path (removes the ghost
                // anchor, resets the coordinator's hasAddedGhostMesh/hasWorldMap), so the stale
                // "Ghost Mesh" chip + overlay don't linger into the next scan in this view.
                cachedGhostMeshData = nil
                dismissGhostMesh = false

                scanStore.mapLoadFailed = false // reset
            }
        }
        .onDisappear {
            mainThreadWatchdog.stop()

            // Battery: left the capture tab — after an idle period, pause the AR session (camera +
            // sensors off). Guarded at fire time so we never pause mid-recording or during post-scan
            // processing (the worldmap export still needs the live session). Returning to capture
            // cancels this (see onAppear). One-shot; rapid successive scans return before it fires.
            idleTeardownTimer?.invalidate()
            idleTeardownTimer = Timer.scheduledTimer(
                withTimeInterval: AppConstants.arIdleTeardownSeconds,
                repeats: false
            ) { _ in
                // Don't pause mid-recording or during the post-scan processing/save window — the
                // world-map export + save still need the live session. isProcessingScan is currently
                // unused by the capture path, so gate on the flags this pipeline actually maintains:
                // isProcessingMesh (export/color in flight) and a pendingScan awaiting its name/save.
                let processing = isProcessingMesh || pendingScan != nil
                if selectedTab != 1 && !isRecording && !processing && !scanStore.isProcessingScan {
                    pauseARSession = true
                }
            }

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
            activeLocationName = nil
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
                // Nothing consumes the pending scan after cancel, so remove its temp artifacts —
                // both live in FileManager.temporaryDirectory and saveScan would normally move them.
                // Dropping pendingScan alone would leak the (potentially large) raw-frames dir.
                if let pending = pendingScan {
                    if let rawDir = pending.rawDataPath {
                        try? FileManager.default.removeItem(at: rawDir)
                    }
                    if let mapURL = pending.worldMapURL {
                        try? FileManager.default.removeItem(at: mapURL)
                    }
                }
                pendingScan = nil
                saveMessage = nil
                isProcessingMesh = false
                isWaitingToSave = false
            }
        } message: {
            Text("Enter a unique name for this space so you can add scans later.")
        }
        .alert("Insufficient Tracking", isPresented: $showInsufficientTrackingAlert) {
            // A scan without a usable world map can't be relocalized or extended, so we don't offer
            // "Save Anyway". Recording is still live here (stopRecording returned early without
            // tearing down), so "Keep Scanning" just dismisses and lets the user map more area.
            Button("Keep Scanning", role: .cancel) { }
            Button("Discard Scan", role: .destructive) {
                discardInProgressScan(isExtendFlow: false, completion: nil)
            }
        } message: {
            Text("This scan's mapping status is '\(scanStats.mappingStatus)'. Relocalizing or extending it "
                + "later requires a 'mapped' world map. Keep scanning the area to improve it, or discard "
                + "and start over.")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
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

    // Recording / save / stitching methods are organized into extension files:
    // CaptureView+Recording.swift  — toggleRecording, startRecording, stopRecording, 
    // performStopRecording, savePendingScan, etc.
    //   CaptureView+Extend.swift     — pinAndExtend (Flow A: mid-session extend)
    //   CaptureView+Alignment.swift  — confirmAlignment, cancelAlignment (Flow B: cross-session alignment)

    /// VIO starvation guard handler (ported from main, adapted to our save pipeline): ARKit tracking
    /// was lost mid-recording, so frames captured after that point are unreliable. Halt new-frame
    /// capture, then let the user save what was gathered before the loss (our `performStopRecording`
    /// flow, which co-frames the world map with the OBJ) or discard and rescan.
    func handleVIOCompromised() {
        vioCompromised = false // reset the latch so a later scan can trip the guard again
        guard isRecording else { return }

        recordingTimer?.invalidate()
        recordingTimer = nil

        // Stop new frames immediately so no more post-loss (corrupt) frames are captured while the
        // prompt is up. The good frames captured before the loss are still on disk; performStopRecording
        // calls frameCaptureSession.stop() to flush them on "Save Anyway".
        let capturedCount = frameCaptureSession.frameCount
        frameCaptureSession.pauseCapture()

        let alert: UIAlertController
        if scanStore.pendingStitchLink != nil {
            // Stitch flow (mapB of a Pin & Extend / Link Adjacent link): the link pins pinB's pose
            // to mapB's world-map frame. If tracking is lost the saved map can drift away from that
            // pinned point, silently corrupting the A→B transform — a salvaged-but-misposed link is
            // worse than none. So we don't offer "Save Anyway" here; the user is still physically in
            // the space, so discarding and redoing the link is the safe, cheap path.
            alert = UIAlertController(
                title: "Tracking Lost",
                message: "AR tracking was interrupted while linking this space. Saving now could "
                    + "misalign the spatial link, so this scan will be discarded. Reposition and "
                    + "start the link again.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Discard & Rescan", style: .destructive) { _ in
                self.discardInProgressScan(isExtendFlow: false, completion: nil)
            })
        } else if capturedCount > 0 {
            alert = UIAlertController(
                title: "Tracking Lost",
                message: "AR tracking was interrupted during this scan, so anything captured after that "
                    + "point is unreliable. Save the \(capturedCount) frame\(capturedCount == 1 ? "" : "s") "
                    + "captured so far, or discard and rescan?",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Discard & Rescan", style: .destructive) { _ in
                self.discardInProgressScan(isExtendFlow: false, completion: nil)
            })
            alert.addAction(UIAlertAction(title: "Save Anyway", style: .default) { _ in
                // Our save pipeline tears down reconstruction itself and captures the world map
                // co-framed with the OBJ; it flips isRecording = false once the map is grabbed.
                self.performStopRecording()
            })
        } else {
            // Nothing usable was captured (tracking lost almost immediately) — don't offer a save.
            alert = UIAlertController(
                title: "Tracking Lost",
                message: "AR tracking was lost before any usable data was captured, " +
                         "so nothing was saved. Reposition and rescan when ready.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                self.discardInProgressScan(isExtendFlow: false, completion: nil)
            })
        }

        // VIO loss takes precedence: if the manual-stop "Insufficient Tracking" alert (which offers
        // "Keep Scanning") is already up, dismiss it first so a scan that lost tracking can only
        // be saved as-is or discarded, never extended with post-loss frames.
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = (windowScene.windows.first(where: { $0.isKeyWindow }) ??
                         windowScene.windows.first)?.rootViewController {
            if let presented = rootVC.presentedViewController {
                presented.dismiss(animated: false) { rootVC.present(alert, animated: true) }
            } else {
                rootVC.present(alert, animated: true)
            }
        }
    }

    /// Presents a UIAlertController above whatever is currently on screen (any tab / modal).
    /// Returns false if there's no window to present in, so callers that must not hang (e.g. the
    /// world-map-export prompt) can fall back to a safe default instead of stalling.
    @discardableResult
    func presentTopAlert(_ alert: UIAlertController) -> Bool {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = (scene.windows.first(where: { $0.isKeyWindow }) ??
                          scene.windows.first)?.rootViewController else {
            return false
        }
        var top: UIViewController = root
        while let presented = top.presentedViewController { top = presented }
        top.present(alert, animated: true)
        return true
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
