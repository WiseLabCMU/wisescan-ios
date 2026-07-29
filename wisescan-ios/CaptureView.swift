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
    @State private var thetaManager = ThetaCameraManager.shared
    @State var rigCalibrationManager = RigCalibrationManager.shared
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
    /// Opacity of the white shutter-flash overlay shown when a sharp keyframe is captured.
    @State private var captureFlashOpacity: Double = 0
    // Detects main-thread stalls during scanning when Perf Diagnostics is on (no-op otherwise).
    @State private var mainThreadWatchdog = MainThreadWatchdog()
    /// [MemDiag] logs a MEM-PRESSURE marker (footprint + headroom) when the OS flags the app near its
    /// jetsam limit — the redline trip-flag. No-op unless Perf Diagnostics is on.
    @State private var memoryPressureMonitor = MemoryPressureMonitor {
        String(format: "footprint=%.0fMB avail=%.0fMB compressed=%.0fMB",
               ScanStats.currentFootprintMB(), ScanStats.currentAvailableMemoryMB(), ScanStats.currentCompressedMB())
    }
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
    @State var isStabilizingBeforeSave = false // hold-steady settle window before the save pose is captured
    @State var cachedGhostMeshData: Data?
    /// True once loadGhostMeshData() has run for this appearance — gates handing the world map to
    /// ARCoverageView (see the body comment) so the session's first start is ghost-complete, while
    /// still allowing ghost-less relocalization when no ghost mesh could be loaded. Reset in
    /// onDisappear.
    @State var ghostLoadAttempted = false
    /// Ghost auto-align reference planes (ghost room, RAW capture frame) — loaded alongside the
    /// ghost mesh, fed to ARCoverageView's live plane fit. Empty when not rescanning.
    @State var ghostReferencePlanes: [PlaneRegistration.Plane] = []
    /// True when `cachedGhostMeshData` holds the wall-subtracted proxy (DECISION 2) — the renderer
    /// then draws the RoomPlan wall/floor quads in the same wireframe style to complete the ghost.
    @State var ghostIsProxy = false
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
    @State var saveNavigationTask: Task<Void, Never>? // Delayed post-save tab switch; cancelled if the view leaves first
    @State var isConfirmingAlignment = false // Re-entry guard for confirmAlignment double-tap
    @State var showStopMenu = false
    @State var showDiscardConfirm = false // destructive Discard from the stop menu → confirm first
    @State var showPendingDiscardConfirm = false // destructive Discard from the naming dialog → confirm first
    @State var showExtendErrorAlert = false
    @State var isAwaitingAlignment = false // Phase 2.1 (perfDiag): briefly holding record for the auto-align correction

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
    @State var scanCoach = ScanCoach()
    @AppStorage(AppConstants.Key.scanCoachingEnabled) var scanCoachingEnabled: Bool = AppConstants.scanCoachingEnabled
    @AppStorage(AppConstants.Key.semanticLabeling) private var semanticLabeling: Bool = AppConstants.semanticLabeling

    // MARK: - Space Analysis (pre-scan staging check)
    @State var isAnalyzing = false
    @State var spaceAnalyzer = SpaceAnalyzer()
    @State private var analysisResult: SpaceAnalysisResult?
    @State private var showAnalysisReport = false
    // Relocalization-timeout watchdog (item 3): a rescan can hang forever on "move camera to
    // relocalize" when the space is feature-poor / self-similar (ARKit never reaches `.normal` —
    // false loop-closure, a fundamental limit). If we're still `.relocalizing` after
    // AppConstants.relocalizationTimeoutSeconds, `relocTimedOut` flips and the prompt becomes a
    // guidance panel with escape routes (Try Again / Go Back). Non-blocking: clears itself if
    // relocalization then succeeds.
    @State private var relocTimeoutTimer: Timer?
    @State private var relocTimedOut = false

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
        // Map saved with a wandering outlier cluster in its feature cloud (tracking excursion,
        // e.g. an OS interruption with motion) — persisted so rescan/link can warn (default lets
        // the VIO-recovery construction sites, which save no map, omit it).
        var worldMapSuspect = false
    }

    /// Companion 360° still for an ACCEPTED shutter tap: capture a Theta equirect into the
    /// active scan, tagged with the phone's ARKit world pose + timestamp at tap time. Called
    /// from the shutter-tap handler only when `requestStillCapture()` accepts, so the Theta
    /// inherits the phone still's one-per-stillness-pause gate — every pause yields a co-timed
    /// phone-hi-res + 360° pair, the raw material for the deferred rig hand–eye calibration.
    /// Inert unless a Theta is connected and a raw-data dir is open; the pose is snapshotted
    /// here (synchronously) before the ~seconds-long trigger/download.
    private func captureThetaStill() {
        guard isRecording, thetaManager.isConnected,
              let frame = currentARSession?.currentFrame,
              let rawDataDir = frameCaptureSession.captureDir else { return }
        // Toast only when the capture actually started — the manager refuses while the
        // previous still's ~7s pipeline is in flight, and a phantom "still #N…" for a
        // refused capture would overcount (the phone keyframe of this pause still fires;
        // that pair is simply phone-only).

        // Snapshot the phone pose for the first-still spot-check (before the ~7s pipeline)
        let phonePose = frame.camera.transform
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }

        if thetaManager.captureStillForScan(
            phoneTransform: phonePose,
            timestamp: frame.timestamp,
            into: rawDataDir
        ) {
            let stillNumber = thetaManager.scanStillCount + 1
            showTransientMessage("📸 360° still #\(stillNumber)…", duration: 2)

            // First-still calibration spot-check: after the capture pipeline downloads
            // the JPEG, run a quick drift check against the stored calibration.
            if stillNumber == 1 {
                Task {
                    // Wait for the capture pipeline to finish (isCapturing → false)
                    while thetaManager.isCapturing {
                        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                    }
                    // The JPEG was written to equirect_stills/still_0001.JPG
                    let jpegURL = rawDataDir
                        .appendingPathComponent("equirect_stills")
                        .appendingPathComponent("still_0001.JPG")
                    guard let jpegData = try? Data(contentsOf: jpegURL) else { return }

                    let passed = rigCalibrationManager.spotCheckFirstStill(
                        phoneTransform: phonePose,
                        jpegData: jpegData,
                        meshAnchors: meshAnchors
                    )
                    if !passed, let warning = rigCalibrationManager.driftWarning {
                        showTransientMessage(warning, duration: 5)
                    }
                }
            }
        }
    }

    /// Triggers a calibration capture using the current AR frame and mesh.
    private func captureCalibrationStill() {
        guard let frame = currentARSession?.currentFrame else { return }
        let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }
        rigCalibrationManager.captureCalibrationStill(
            phoneTransform: frame.camera.transform,
            timestamp: frame.timestamp,
            meshAnchors: meshAnchors
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    /// Ensure the AR session has mesh reconstruction enabled for calibration.
    /// Normally mesh is only enabled at record-start (to save battery/thermals);
    /// calibration needs it pre-record so the solver has geometry to align against.
    /// Called when the calibration overlay appears.
    private func ensureCalibrationMesh() {
        guard let session = currentARSession,
              ARCoverageView.supportsLiDAR,
              let currentConfig = session.configuration as? ARWorldTrackingConfiguration,
              currentConfig.sceneReconstruction == [] else { return }

        let config = ARCoverageView.makeConfiguration(enableMeshReconstruction: true)
        // Preserve existing frame semantics (depth, person segmentation, etc.)
        config.frameSemantics = currentConfig.frameSemantics
        session.run(config, options: []) // no reset — keep coordinate frame
        PerfDiag.log("Enabled mesh reconstruction for rig calibration")
    }

    /// Disable mesh reconstruction after calibration is done (returns to pre-record config
    /// to save battery/thermals).
    private func disableCalibrationMesh() {
        guard let session = currentARSession,
              !isRecording, // don't disable during recording — recording needs mesh
              ARCoverageView.supportsLiDAR,
              let currentConfig = session.configuration as? ARWorldTrackingConfiguration,
              currentConfig.sceneReconstruction != [] else { return }

        let config = ARCoverageView.makeConfiguration(enableMeshReconstruction: false)
        config.frameSemantics = currentConfig.frameSemantics
        session.run(config, options: [])
        PerfDiag.log("Disabled mesh reconstruction after calibration")
    }

    /// Pre-record calibration banner — appears over the AR view when the user starts
    /// calibration from the Dashboard card and switches to the Capture tab.
    /// Granular label for the calibration capture button, reflecting the pipeline stage.
    private var calibrationButtonLabel: String {
        if thetaManager.isCapturing { return "Triggering shutter…" }
        if thetaManager.isDownloading { return "Downloading still…" }
        if rigCalibrationManager.isCapturingCalibrationStill { return "Processing edges…" }
        return "Capture Calibration Still"
    }

    @ViewBuilder
    private var calibrationOverlay: some View {
        VStack(spacing: 8) {
            if case .capturing(let count) = rigCalibrationManager.state {
                HStack(spacing: 8) {
                    Image(systemName: "scope")
                        .foregroundColor(.cyan)
                    Text("Calibration: still \(count)/\(AppConstants.calibrationStillCount)")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                }
                Text("Walk to a position, pause, then tap Capture.")
                    .font(.caption)
                    .foregroundColor(.gray)

                if !rigCalibrationManager.isEnvironmentSufficient {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.yellow)
                        Text("Low mesh density — move to an area with more surfaces.")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }
                }

                Button(action: captureCalibrationStill) {
                    HStack {
                        if thetaManager.isCapturing || thetaManager.isDownloading
                            || rigCalibrationManager.isCapturingCalibrationStill {
                            ProgressView().tint(.black).padding(.trailing, 2)
                        } else {
                            Image(systemName: "camera.fill")
                        }
                        Text(calibrationButtonLabel)
                            .font(.subheadline.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.cyan.opacity(0.85))
                    .cornerRadius(10)
                    .foregroundColor(.black)
                }
                .disabled(thetaManager.isCapturing || thetaManager.isDownloading
                          || rigCalibrationManager.isCapturingCalibrationStill
                          || !thetaManager.isConnected)

                Button("Cancel Calibration") { rigCalibrationManager.cancelCalibration() }
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            if case .solving = rigCalibrationManager.state {
                HStack(spacing: 8) {
                    ProgressView().tint(.cyan)
                    Text("Solving rig calibration…")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                }
                Text("Aligning mesh edges to 360° images.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            if case .failed(let reason) = rigCalibrationManager.state {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text("Calibration failed")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                }
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)

                Button("Retry") { rigCalibrationManager.beginCalibration() }
                    .font(.subheadline.bold())
                    .padding(.vertical, 8)
                    .padding(.horizontal, 20)
                    .background(Color.cyan.opacity(0.85))
                    .cornerRadius(8)
                    .foregroundColor(.black)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 120)
    }

    /// Loads ghost mesh data from the scan to extend, caching it in @State. SwiftData reads stay
    /// on MAIN; the heavy tail — reading a multi-MB OBJ plus the O(n) de-registration text
    /// rewrite — runs on a background queue (deferred PR #28 review item: it ran on main during
    /// capture bring-up, the most contended window; a legacy full-mesh ghost with an applied
    /// registration could stall main for seconds). The completion sets ALL ghost state together
    /// on main — including `ghostLoadAttempted` — so the body's world-map gate still hands
    /// map + ghost to the session in a single start, exactly as the synchronous version did
    /// (cached data always arrived after makeUIView anyway; updateUIView's nil→data reload with
    /// the map is the designed bring-up path in both timings).
    private func loadGhostMeshData() {
        // Reset the proxy flag up front so an early-return guard below can't leave a stale
        // ghostIsProxy=true from a prior appearance (it is @State and survives across appearances);
        // the async completion re-sets it when a proxy actually loads.
        ghostIsProxy = false
        guard let locId = scanStore.activeLocationForScan,
              let scanId = scanStore.activeScanToExtend else {
            cachedGhostMeshData = nil
            ghostReferencePlanes = []
            ghostLoadAttempted = true   // nothing to load — release the world-map gate now
            return
        }
        let descriptor = FetchDescriptor<ScanLocation>(predicate: #Predicate { $0.id == locId })
        guard let location = try? modelContext.fetch(descriptor).first,
              let targetScan = location.scans.first(where: { $0.id == scanId }) else {
            cachedGhostMeshData = nil
            ghostReferencePlanes = []
            ghostLoadAttempted = true
            return
        }
        // Snapshot everything the background pass needs on MAIN — SwiftData models and their
        // relationships are not thread-safe off the main actor.
        let isRescan = scanStore.activeScanCase == .rescanSpace
        let scanDirectory = targetScan.scanDirectory
        let proxyCandidates = [
            targetScan.scanDirectory.appendingPathComponent("mesh_proxy.obj"),
            targetScan.rawDataPath.appendingPathComponent("mesh_proxy.obj")
        ]
        let meshFileURL = targetScan.meshFileURL
        // [MemDiag] Ghost mesh = the ICP-source mesh, held resident ALONGSIDE the live scan mesh
        // through a rescan — the genuine 2× mesh coexistence, and it happens during scan time. blob =
        // exact bytes read in (the parse into a displayed RealityKit entity is a separate, later cost);
        // footprintΔ is the Data buffer. Baseline read only when diagnostics are on → free otherwise.
        let foot0 = PerfDiag.enabled ? ScanStats.currentFootprintMB() : 0

        DispatchQueue.global(qos: .userInitiated).async {
            let (ghostData, isProxy, planes) = Self.readGhostArtifacts(
                isRescan: isRescan, scanDirectory: scanDirectory,
                proxyCandidates: proxyCandidates, meshFileURL: meshFileURL, scanId: scanId)

            DispatchQueue.main.async {
                // Staleness guard: the user may have left the capture tab or retargeted while the
                // file was read — applying a stale ghost would hand the WRONG mesh/planes to the
                // next session start. (A repeat load of the SAME target is idempotent.)
                guard scanStore.activeScanToExtend == scanId else { return }
                cachedGhostMeshData = ghostData
                ghostIsProxy = isProxy
                ghostReferencePlanes = planes
                ghostLoadAttempted = true   // ghost + map now hand over together (body's gate)
                if PerfDiag.enabled {
                    let blobMB = Double(ghostData?.count ?? 0) / (1024.0 * 1024.0)
                    let foot1 = ScanStats.currentFootprintMB()
                    PerfDiag.log(String(format: "[MemDiag] EVENT GHOST-LOAD blob=%.1fMB footprint=%.0fMB (Δ%+.0f)",
                                        blobMB, foot1, foot1 - foot0))
                }
            }
        }
    }

    /// Background half of `loadGhostMeshData` — file reads + de-registration + plane decode
    /// (no SwiftData, no @State; everything arrives as plain values snapshotted on main).
    private static func readGhostArtifacts(isRescan: Bool, scanDirectory: URL,
                                           proxyCandidates: [URL], meshFileURL: URL, scanId: UUID)
        -> (data: Data?, isProxy: Bool, planes: [PlaneRegistration.Plane]) {
        // DECISION 2: rescans load the light proxy (walls/floor/ceiling subtracted, RoomPlan
        // quads baked in) instead of the full 10⁵–10⁶-face mesh — killing the 2× mesh-
        // coexistence memory and most of the ghost render/parse cost. A proxy ghost also
        // retires the mesh-ICP path for the session (plane auto-align drives the green chip;
        // save-time registration is the correction authority) — the dense-ICP machinery only
        // engages for legacy scans with no proxy artifact.
        var ghostData: Data?
        var isProxy = false
        if isRescan {
            for url in proxyCandidates {
                if let data = try? Data(contentsOf: url) {
                    ghostData = data
                    isProxy = true
                    print("[GhostProxy] rescan ghost using proxy (\(data.count / 1024)KB)")
                    break
                }
            }
        }
        if !isProxy {
            ghostData = try? Data(contentsOf: meshFileURL)
        }
        // DECISION 1 co-framing: if this scan's mesh was registered into the canonical frame
        // at ITS save, undo that here — the live session relocalizes into the scan's RAW
        // capture frame (the world map can't be re-based), and the ghost must share it
        // (visual overlay, manual nudge, and the ICP probe all assume ghost ≡ live frame).
        // One O(n) text pass, only for scans that actually carry an applied registration.
        if let data = ghostData,
           let undo = SaveRegistration.inverseForGhost(scanDirectory: scanDirectory) {
            ghostData = SaveRegistration.transformOBJ(data, by: undo)
            print("[PlaneReg] ghost mesh de-registered back to its raw capture frame for relocalization overlay")
        }
        // Ghost auto-align reference: the ghost room's planes in the SAME raw frame as the
        // (de-registered) mesh + world map. Rescan only — a link-adjacent capture is a
        // different physical room; auto-fitting its walls to the ghost's would be a false lock.
        let planes = isRescan ? SaveRegistration.rawFramePlanes(scanDirectory: scanDirectory) : []
        if !planes.isEmpty {
            print("[PlaneReg] ghost auto-align reference loaded: \(planes.count) planes")
        } else if isRescan {
            // Loud, not silent: without reference planes there is NO auto-align, NO plane
            // detection, and no [PlaneReg] output at all — this line is the only breadcrumb.
            print("[PlaneReg] auto-align DISABLED: no reference planes — roomplan.json missing/undecodable for scan \(scanId) (was a room built at its save?)")
        }
        return (ghostData, isProxy, planes)
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
        // Frame-invariant guard: aggregating connectors across ALL the location's scans is only
        // correct when we relocalize against the LATEST scan (every scan then shares its world frame
        // via the rescan→latest chain). Today rescan always targets latest, so this aggregates all —
        // but if a non-latest scan ever becomes the target, restrict to ITS connectors so we never
        // render another scan's connectors in the wrong frame (the failure the comment above warns of).
        let latestId = location.scans.max(by: { $0.capturedAt < $1.capturedAt })?.id
        let target = scanStore.activeScanToExtend
        let scansForConnectors: [CapturedScan] = (target == nil || target == latestId)
            ? location.scans
            : location.scans.filter { $0.id == target }
        var seenConnectors = Set<UUID>()
        connectorAnchors = scansForConnectors
            .flatMap { StitchLinkStore.connectorAnchors(for: $0, from: linkIndex[$0.id] ?? []) }
            .filter { seenConnectors.insert($0.id).inserted }
    }

    // MARK: - Relocalization timeout (item 3)

    /// Arms/cancels the relocalization watchdog from the relevant state changes. Called from the
    /// `.onChange` handlers below. The timer fires once (no auto-restart on intermediate tracking-state
    /// flips); it stands down — and clears any timed-out flag — the moment relocalization succeeds
    /// (`.normal`), recording starts, or the ghost is cleared.
    private func evaluateRelocalizationTimeout() {
        let relocalizing = cachedGhostMeshData != nil
            && !isRecording
            && scanStats.trackingStatus == .limited(reason: .relocalizing)
        if relocalizing {
            // Arm once. Don't restart if already running or already timed out.
            guard relocTimeoutTimer == nil && !relocTimedOut else { return }
            relocTimeoutTimer = Timer.scheduledTimer(
                withTimeInterval: AppConstants.relocalizationTimeoutSeconds,
                repeats: false
            ) { _ in
                // Fires on the main run loop. Re-check we're still stuck (a success/back-out would
                // have cancelled us via onChange, but guard against the race).
                if cachedGhostMeshData != nil && !isRecording
                    && scanStats.trackingStatus == .limited(reason: .relocalizing) {
                    relocTimedOut = true
                }
                relocTimeoutTimer = nil
            }
        } else {
            relocTimeoutTimer?.invalidate()
            relocTimeoutTimer = nil
            // Only drop the timed-out banner when we genuinely left the relocalizing-with-ghost
            // state (relocalized, or ghost gone) — not on a transient flip while still recording.
            if scanStats.trackingStatus.isNormal || cachedGhostMeshData == nil {
                relocTimedOut = false
            }
        }
    }

    /// "Try Again" — restart relocalization from scratch by reloading the world map (toggling the
    /// ghost data, the proven `showRelocDialog` Re-relocalize path). Re-arms the watchdog.
    private func retryRelocalization() {
        relocTimeoutTimer?.invalidate()
        relocTimeoutTimer = nil
        relocTimedOut = false
        ghostYRotation = 0
        ghostXOffset = 0
        ghostZOffset = 0
        let savedData = cachedGhostMeshData
        cachedGhostMeshData = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            cachedGhostMeshData = savedData
        }
    }

    /// "Go Back" — bail out of a relocalization that won't lock. Returns to the Scans tab (where the
    /// rescan was launched from); onDisappear handles the capture teardown (resetCaptureState, ghost
    /// clear, session). Matches the post-save navigation (selectedTab = 2).
    private func exitCaptureFromRelocTimeout() {
        relocTimeoutTimer?.invalidate()
        relocTimeoutTimer = nil
        relocTimedOut = false
        selectedTab = 2
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
                // Withhold the world map until the ghost cache is loaded: makeUIView runs on the
                // FIRST body render, but loadGhostMeshData() runs in onAppear (after it) — handing
                // the map over immediately made makeUIView start relocalizing ghost-less, then the
                // ghost's arrival re-ran the whole map load + resetTracking (a second
                // `[LocDiag ε] map load` + a restarted relocalization every rescan). Gating the URL
                // on the ghost means the one-and-only session start happens with both together.
                // A relocalization flow with no loadable ghost (mesh missing) degrades to
                // ghost-less relocalization once loadGhostMeshData has run (ghostLoadAttempted).
                initialWorldMapURL: (scanStore.activeScanToExtend != nil
                                     && cachedGhostMeshData == nil
                                     && !ghostLoadAttempted) ? nil : scanStore.activeRelocalizationMap,
                initialGhostMeshData: cachedGhostMeshData,
                ghostReferencePlanes: ghostReferencePlanes,
                ghostIsProxy: ghostIsProxy,
                scanStore: scanStore,
                connectorAnchors: connectorAnchors,
                finalCapturedRoom: $finalCapturedRoom,
                frameCaptureSession: frameCaptureSession,
                ghostYRotation: ghostYRotation,
                ghostXOffset: ghostXOffset,
                ghostZOffset: ghostZOffset,
                dismissGhostMesh: dismissGhostMesh,
                bakedGhostTransform: bakedGhostTransform,
                pauseARSession: pauseARSession,
                isAnalyzing: $isAnalyzing
            )
                .ignoresSafeArea()
                // Shutter tap — the deterministic still trigger, gated on stillness.
                // Attached to the AR view (behind the HUD) so buttons keep their own
                // taps; fires nothing unless recording. A warning haptic answers taps
                // while moving ("hold still first"); capture feedback (shutter click +
                // flash) comes from the accepted save itself.
                //
                // MERGE FUSION (still-source-360 × capture-quality): an ACCEPTED tap also
                // fires the Theta 360° still (inert when no camera is connected), so each
                // stillness pause yields a co-timed phone-hi-res + 360° pair with a shared
                // phone pose — the calibration raw material this branch exists for. A
                // refused tap fires neither, keeping the pair invariant.
                .onTapGesture {
                    guard isRecording else { return }
                    if frameCaptureSession.requestStillCapture() {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        captureThetaStill()
                    } else {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    }
                }
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
                // Rig calibration: enable mesh reconstruction when calibration starts,
                // disable when it ends (pre-record only — recording enables mesh itself).
                .onChange(of: rigCalibrationManager.isCalibrating) { _, calibrating in
                    if calibrating {
                        ensureCalibrationMesh()
                    } else {
                        disableCalibrationMesh()
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

            // Rig calibration overlay — pre-record only, when calibration is active.
            // Shows capture progress + solver spinner. Review/accept and failure/retry
            // display on the Dashboard card (auto-navigated by ContentView).
            if !isRecording && isARSessionReady && rigCalibrationManager.isCalibrating {
                calibrationOverlay
            }

            // Stillness reticle — the hold-still-then-tap affordance. The ring fills as
            // the device settles, locks green when a shutter tap will capture, and shows
            // "Capturing…" while a tapped still is in flight. Shown in both AR and VR
            // modes: keyframes are captured in both. Wrapped in a host view so the 10Hz
            // progress updates re-evaluate only the reticle's body, not this entire view.
            if isRecording && isARSessionReady {
                StillnessReticleHost(session: frameCaptureSession)
                    .allowsHitTesting(false)
            }

            // Centered startup/tracking pills (kept separate from ScanCoach)
            centeredTrackingPills

            // Lite mode banner for non-LiDAR devices. Top-aligned: unanchored it sat at the
            // ZStack's vertical center — directly over the stillness reticle (2026-07-22 field
            // report from the iPhone Lite pass).
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
                .padding(.top, 60)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    PrivacyFilterPill(isOn: $isPrivacyFilterOn,
                                      locked: isRecording,
                                      show360Note: thetaManager.isConnected)

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

                            // Sharp frame counter — shows frames captured while device was still
                            if frameCaptureSession.sharpFrameCount > 0 {
                                Divider()
                                    .frame(height: 12)
                                    .background(Color.white.opacity(0.5))
                                HStack(spacing: 3) {
                                    Image(systemName: "camera.fill")
                                        .font(.caption2)
                                    Text("\(frameCaptureSession.sharpFrameCount)")
                                        .font(.caption).bold()
                                }
                                .foregroundColor(.green)
                            }
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

                // ScanCoach Bar (above HUD, only during recording)
                if isRecording {
                    CoachBarView(tip: scanCoach.currentTip) {
                        scanCoach.dismissCurrentTip()
                    }
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

                                // Row 1.5: Semantic classes detected (colored dot + label).
                                // DISABLED with the deferred-build migration: we no longer render live
                                // RoomPlan outlines, so the color legend maps to nothing on screen.
                                // detectedClasses is still collected (extractRoomMetadata → saved
                                // semanticClassesDetected). Restore this if a visualize-RoomPlan mode lands.
                                /*
                                if !scanStats.detectedClasses.isEmpty {
                                    HStack(spacing: 6) {
                                        Image(systemName: "tag.fill")
                                            .font(.caption2)
                                            .foregroundColor(.gray)
                                        ForEach(SemanticClass.allCases.filter { $0 != .none && scanStats.detectedClasses.contains($0.rawValue) },
                                                id: \.rawValue) { cls in
                                            HStack(spacing: 2) {
                                                Circle()
                                                    .fill(cls.swiftUIDisplayColor)
                                                    .frame(width: 8, height: 8)
                                                Text(cls.rawValue.capitalized)
                                                    .font(.system(size: 9))
                                                    .foregroundColor(.white.opacity(0.7))
                                            }
                                        }
                                        Spacer()
                                    }
                                }
                                */

                                // Row 1.5b: Capture quality (sharp vs total frames)
                                if frameCaptureSession.totalCapturedFrameCount > 0 {
                                    HStack(spacing: 16) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "camera.fill")
                                                .font(.caption2)
                                                .foregroundColor(.green)
                                            Text("\(frameCaptureSession.sharpFrameCount)")
                                                .font(.caption2).bold()
                                                .foregroundColor(.green)
                                            Text("sharp")
                                                .font(.caption2)
                                                .foregroundColor(.gray)
                                        }
                                        HStack(spacing: 4) {
                                            Image(systemName: "photo.on.rectangle")
                                                .font(.caption2)
                                                .foregroundColor(.white.opacity(0.6))
                                            Text("\(frameCaptureSession.totalCapturedFrameCount)")
                                                .font(.caption2)
                                                .foregroundColor(.white.opacity(0.6))
                                            Text("total")
                                                .font(.caption2)
                                                .foregroundColor(.gray)
                                        }
                                        Spacer()
                                        // Stillness indicator
                                        if frameCaptureSession.isCurrentlyStill {
                                            HStack(spacing: 3) {
                                                Image(systemName: "hand.raised.fill")
                                                    .font(.caption2)
                                                Text("Still")
                                                    .font(.caption2).bold()
                                            }
                                            .foregroundColor(.green)
                                        }
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

                        // Capture Button + Analyze Space Button
                        HStack(spacing: 24) {
                            // Analyze Space button — visible when not recording
                            if !isRecording {
                                Button(action: { startAnalysis() }, label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: "scope")
                                            .font(.system(size: 22))
                                            .foregroundColor(.cyan)
                                            .frame(width: 44, height: 44)
                                            .background(.ultraThinMaterial)
                                            .clipShape(Circle())
                                            .overlay(Circle().stroke(Color.cyan.opacity(0.5), lineWidth: 1))
                                        Text("Analyze")
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.7))
                                    }
                                })
                                .disabled(isAnalyzing || isProcessingMesh || isWaitingToSave)
                                .opacity(isAnalyzing ? 0.4 : 1.0)
                            }

                            // Record button
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
                                    } else if isProcessingMesh || isWaitingToSave {
                                        // Previous scan's export/coloring still running — recording is
                                        // blocked until it finishes. Show a spinner so the disabled button
                                        // isn't a silent dead tap (a spinner that never clears = a stuck
                                        // isProcessingMesh/isWaitingToSave reset, a separate bug).
                                        ProgressView().tint(.white)
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
                                        Text(recordButtonCaption)
                                            .font(.caption2)
                                            .foregroundColor(.white.opacity(0.7))
                                            .offset(y: 50)
                                    }
                                }
                            })
                            // After Stop, the mesh export/save runs while isRecording is already
                            // false; block taps during that window so a new recording can't start
                            // on top of the in-flight export. Also block during analysis.
                            // And in a link-adjacent flow recording starts programmatically after
                            // alignment, never from this button — disable it for the whole
                            // pre-recording window so a tap can't race ahead of the alignment overlay
                            // and start an un-aligned scan (the ~90°/offset ghost-jump race).
                            // activeScanCase is set synchronously at the trigger; cleared on save.
                            .disabled(isProcessingMesh || isWaitingToSave || isStabilizingBeforeSave || isAnalyzing || showAnalysisReport
                                      || (scanStore.activeScanCase == .linkAdjacent && !isRecording))
                            .offset(y: isRecording ? -20 : 0)
                        }
                    }
                }
                .padding(.bottom, 20)
            }

            // Analysis progress overlay (shown during the 360° sweep)
            if isAnalyzing {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    VStack(spacing: 20) {
                        Image(systemName: "scope")
                            .font(.system(size: 48))
                            .foregroundColor(.cyan)
                            .symbolEffect(.pulse, isActive: true)

                        Text("Analyzing Space")
                            .font(.title2.bold())
                            .foregroundColor(.white)

                        Text(spaceAnalyzer.progressLabel)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center)

                        // Progress ring
                        ZStack {
                            Circle()
                                .stroke(Color.white.opacity(0.2), lineWidth: 6)
                            Circle()
                                .trim(from: 0, to: CGFloat(spaceAnalyzer.progress))
                                .stroke(Color.cyan, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.easeInOut(duration: 0.3), value: spaceAnalyzer.progress)
                            Text("\(Int(spaceAnalyzer.progress * 100))%")
                                .font(.title3.bold())
                                .foregroundColor(.white)
                        }
                        .frame(width: 100, height: 100)

                        Button("Cancel") {
                            stopAnalysis(cancelled: true)
                        }
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                        .padding(.top, 8)
                    }
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: isAnalyzing)
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

            // Phase 2.1 (perfDiag): briefly holding record while the auto-align correction lands.
            awaitingAlignmentOverlay

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

            // Stop Recording menu — anchored at the BOTTOM, just above the record button.
            // Replaces a .confirmationDialog, which iPad rendered as a centered/top popover far
            // from the record button the user just tapped. Same three actions.
            if showStopMenu {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.45)
                        .ignoresSafeArea()
                        .onTapGesture { showStopMenu = false }

                    VStack(spacing: 12) {
                        Text("Stop Recording")
                            .font(.headline)
                            .foregroundColor(.white)

                        Button(action: {
                            showStopMenu = false
                            stopRecording()
                        }, label: {
                            Text("Save & End")
                                .font(.body.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.cyan.opacity(0.85))
                                .foregroundColor(.white)
                                .cornerRadius(14)
                        })

                        // Offered for new scans and extend legs (chaining rooms). Hidden for a
                        // rescan of an existing space (activeScanToExtend set): its purpose is
                        // refreshing that space's map, not growing the link graph from it.
                        if !(scanStore.activeScanCase == .rescanSpace && scanStore.activeScanToExtend != nil) {
                            Button(action: {
                                showStopMenu = false
                                if scanStats.hasEnoughFeaturesForRelocalization {
                                    pinAndExtend()
                                } else {
                                    showExtendErrorAlert = true
                                }
                            }, label: {
                                Text("Save & Scan Adjacent")
                                    .font(.body.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color.indigo.opacity(0.85))
                                    .foregroundColor(.white)
                                    .cornerRadius(14)
                            })
                        }

                        Button(action: {
                            showStopMenu = false
                            showDiscardConfirm = true
                        }, label: {
                            Text("Discard Scan")
                                .font(.body.bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.red.opacity(0.8))
                                .foregroundColor(.white)
                                .cornerRadius(14)
                        })

                        Button(action: { showStopMenu = false }, label: {
                            Text("Cancel")
                                .font(.body)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(.ultraThinMaterial)
                                .foregroundColor(.white)
                                .cornerRadius(14)
                        })
                    }
                    .padding(20)
                    .background(.ultraThinMaterial)
                    .cornerRadius(24)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 130) // sit just above the record button
                }
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: showStopMenu)
                .zIndex(10)
            }

            // Ghost-mesh manual nudger (restored from main): a bottom-left status chip that opens an
            // alignment dialog, plus a slider overlay to rotate/translate the ghost when
            // relocalization is imperfect. Complements the anchor-based AlignmentOverlayView above;
            // startRecording bakes any offset into the world origin so mesh + world map stay co-framed.
            if cachedGhostMeshData != nil && !dismissGhostMesh {
                ghostMeshChipStack
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

            // Keyframe capture flash — a brief white blink (camera-app shutter language)
            // each time a sharp keyframe is saved. Drawn last so it covers the full view.
            Color.white
                .opacity(captureFlashOpacity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .onChange(of: frameCaptureSession.sharpFrameCount) { oldCount, newCount in
            guard newCount > oldCount else { return } // ignore session-start reset to 0
            // Two-phase so the peak actually renders: commit the peak opacity this
            // update, then animate down on the next runloop turn — writing both in one
            // transaction can coalesce to 0→0 and skip the flash entirely.
            captureFlashOpacity = AppConstants.captureFlashOpacity
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: AppConstants.captureFlashDuration)) {
                    captureFlashOpacity = 0
                }
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
            memoryPressureMonitor.start()

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
            memoryPressureMonitor.stop()
            // Next appearance must re-load the ghost before the world map is handed over (the
            // makeUIView-vs-onAppear race gate in body).
            ghostLoadAttempted = false

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

            // A transient onDisappear can arrive when we are NOT actually leaving the capture tab
            // (selectedTab == 1): SwiftUI tab-churn during a Connect Adjacent / Rescan hand-off —
            // aggravated by the multi-second main-thread stalls these AR sessions hit on marginal
            // devices — can deliver this callback AFTER we've already switched back to capture and
            // armed the next flow. Running the leaving-capture teardown then is the ROOT of the
            // link-adjacent ghost-jump bug: resetCaptureState reverts activeScanCase /
            // activeScanToExtend / activeLocationForScan to defaults while the ghost mesh (a separate
            // @State) stays on screen — so the record button goes live + ungated (activeScanCase is no
            // longer .linkAdjacent, defeating both the button .disabled and the toggleRecording guard)
            // AND the resulting scan is context-less (stop prompts to name a brand-new location). Only
            // tear down when genuinely leaving the capture tab. Mirrors the selectedTab != 1 guard the
            // idle-teardown timer above already uses, and the routing snapshot performStopRecording
            // takes to survive this same clobber on the stop path.
            if selectedTab != 1 {
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
                saveNavigationTask?.cancel()
                saveNavigationTask = nil
                activeLocationName = nil
                // Relocalization watchdog (item 3): cancel + reset so it can't fire after we leave.
                relocTimeoutTimer?.invalidate()
                relocTimeoutTimer = nil
                relocTimedOut = false
            }
        }
        .onChange(of: scanStore.activeLocationForScan) { _, newLocId in
            if let locId = newLocId {
                let descriptor = FetchDescriptor<ScanLocation>(predicate: #Predicate { $0.id == locId })
                if let loc = try? modelContext.fetch(descriptor).first {
                    activeLocationName = loc.name
                }
            } else {
                activeLocationName = nil
            }
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
            .disabled(newLocationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            // Labeled as the discard it is (was "Cancel"): recording has already ended and
            // the only alternatives are save-with-name or delete. Routes through the
            // destructive-warning confirmation — every Discard Scan does.
            Button("Discard Scan", role: .destructive) {
                showPendingDiscardConfirm = true
            }
        } message: {
            Text("Enter a unique name for this space so you can add scans later.")
        }
        // Both destructive-discard confirmations live in a ViewModifier — inlining two more
        // .alert blocks here pushed SwiftUI's type-checker over its time budget.
        .modifier(DiscardConfirmAlerts(
            showDiscardConfirm: $showDiscardConfirm,
            showPendingDiscardConfirm: $showPendingDiscardConfirm,
            onKeepPending: { showNamePrompt = true },
            onDiscardLive: { discardInProgressScan(isExtendFlow: false, completion: nil) },
            onDiscardPending: { discardPendingScan() }
        ))
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
                + "later requires a 'mapped' world map. To finish mapping, aim the camera at detail-rich "
                + "areas — furniture, shelves, posters, floor texture (blank walls, glass, and screens "
                + "don't track) — and sweep slowly until tracking improves, then stop again. Or discard "
                + "and start over. Discarding deletes this recording's frames and photos and cannot be undone.")
        }
        .alert("Not Enough Features", isPresented: $showExtendErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Move the device around to map more of the environment before placing a connector.")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        // ScanCoach evaluation: triggered by anchor count changes (~10Hz from ARKit,
        // but ScanCoach internally throttles to ~1Hz). Also clears tips when recording stops.
        .onChange(of: scanStats.anchorCount) {
            evaluateScanCoach()
        }
        .onChange(of: isRecording) { _, recording in
            if !recording {
                scanCoach.evaluate(
                    scanStats: scanStats,
                    frameCaptureSession: frameCaptureSession,
                    capturedRoom: finalCapturedRoom,
                    semanticLabelingEnabled: semanticLabeling,
                    isRecording: false,
                    coachingEnabled: scanCoachingEnabled
                )
            }
        }
        .onChange(of: frameCaptureSession.isBlurWarningActive) {
            evaluateScanCoach()
        }
        .onChange(of: scanStats.trackingStatus) {
            evaluateScanCoach()
        }
        // Space Analysis: feed camera yaw to the analyzer for 360° progress
        .onChange(of: scanStats.analysisYaw) {
            if isAnalyzing {
                spaceAnalyzer.updateYaw(scanStats.analysisYaw, currentLux: scanStats.ambientIntensity)
            }
        }
        // Space Analysis: auto-complete when 360° is covered
        .onChange(of: spaceAnalyzer.isComplete) { _, complete in
            if complete && isAnalyzing {
                stopAnalysis(cancelled: false)
            }
        }
        .sheet(isPresented: $showAnalysisReport, onDismiss: {
            // Safety net: ensure analysis state is fully cleaned up when the report is dismissed.
            // The normal flow stops analysis before showing the report, but this guards edge cases.
            if isAnalyzing { isAnalyzing = false }
        }) {
            if let result = analysisResult {
                ScanAnalysisReportView(result: result)
            }
        }
    }

    /// Centered startup/tracking pills (kept separate from ScanCoach). Extracted from `body` to
    /// keep its expression type-checkable (the body ZStack is at the compiler's budget).
    private var centeredTrackingPills: some View {
        VStack(spacing: 12) {
            if cachedGhostMeshData != nil && scanStats.trackingStatus == .limited(reason: .relocalizing) {
                if relocTimedOut {
                    relocTimeoutPanel
                } else {
                    relocalizingPrompt
                }
            }

            stormWarningBanner

            let capturedSinceStart = scanStats.totalVertices - verticesAtRecordStart
            let needsLiveMeshCue = capturedSinceStart < AppConstants.liveMeshCueVertexThreshold
            // LiDAR-gated: Lite devices never produce mesh vertices, so this cue would show
            // (and never clear) for a mesh that cannot exist (2026-07-22 Lite field report).
            if isRecording && ARCoverageView.supportsLiDAR && needsLiveMeshCue &&
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
        // Relocalization-timeout watchdog (item 3): arm/cancel whenever the inputs to the
        // relocalizing-with-ghost state change. Attached here (an always-present subtree) rather
        // than to the body chain, which is at the type-checker's expression budget.
        .onChange(of: scanStats.trackingStatus) { _, _ in evaluateRelocalizationTimeout() }
        // Key on `.count` (Int?), not the multi-MB `Data` — a value compare of the whole mesh on
        // every frequent stats-driven update cycle would be needlessly expensive; the count captures
        // the meaningful transitions (loaded / cleared / reloaded).
        .onChange(of: cachedGhostMeshData?.count) { _, _ in evaluateRelocalizationTimeout() }
        .onChange(of: isRecording) { _, _ in evaluateRelocalizationTimeout() }
    }

    // Item 2 (perfDiag-gated during dev validation; reframed 2026-06-25 to a STORM signal):
    // a burst of non-physical mid-scan jumps means relocalization is oscillating / the session
    // has destabilized (a self-similar space ARKit can't lock onto) — distinct from a single
    // benign snap (the mesh re-pins). The flag is only set on a storm, and latches for the scan.
    @ViewBuilder private var stormWarningBanner: some View {
        if isRecording, PerfDiag.enabled, let unreliable = scanStore.trackingUnreliable {
            Text(String(format: "⚠️ Tracking unstable — %d sudden jumps mid-scan; relocalization may be failing", unreliable.snapCount))
                .font(.headline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Color.red.opacity(0.85))
                .cornerRadius(20)
                .shadow(radius: 5)
                .transition(.scale.combined(with: .opacity))
                .animation(.easeInOut(duration: 0.2), value: unreliable)
        }
    }

    /// Phase 2.1 (perfDiag): full-screen hold shown while toggleRecording briefly waits for the
    /// auto-align correction to land before starting the recording.
    @ViewBuilder private var awaitingAlignmentOverlay: some View {
        if isAwaitingAlignment {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView().scaleEffect(1.5).tint(.green)
                    Text("📐 Finalizing alignment…")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Holding for the auto-align correction")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: isAwaitingAlignment)
        }
    }

    /// Bottom-left ghost-mesh chip column: the Phase-2.1 align-status chips (green "correction
    /// locked" / orange "still computing", perfDiag-gated) above the Ghost Mesh dialog chip.
    private var ghostMeshChipStack: some View {
        VStack {
            Spacer()
            // Phase 2.1 (perfDiagnostics-only): "alignment sweep done — correction locked"
            // cue. icpAlignReady is set only when a trusted ICP refine has converged during
            // the pre-record phase; its appearance tells the user it's safe to record (the
            // gravity-locked correction will bake into the world origin at record-start).
            if !isRecording, let align = scanStore.icpAlignReady {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(String(format: "Auto-aligned · %.1f cm / %.1f° — ready to record", align.transCm, align.yawDeg))
                            .font(.caption2.bold())
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.green.opacity(0.85))
                    .cornerRadius(20)
                    Spacer()
                }
                .padding(.leading, 16)
                .padding(.bottom, 8)
            } else if !isRecording, PerfDiag.enabled, scanStats.trackingStatus.isNormal {
                // Not-yet-ready cue: relocalized, correction still computing. The ABSENCE of the
                // green chip is otherwise ambiguous ("nothing to do" vs "still working") — this
                // tells the user to wait for green before recording (the ghost mesh appearing is
                // NOT the same as the correction being locked).
                HStack {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.7).tint(.white)
                        Text("📐 Aligning — wait for green before recording")
                            .font(.caption2.bold())
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.85))
                    .cornerRadius(20)
                    Spacer()
                }
                .padding(.leading, 16)
                .padding(.bottom, 8)
            }
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

    /// The indefinite "move camera" pill shown while ARKit relocalizes against the loaded map.
    /// Extracted from `body` (with `relocTimeoutPanel`) to keep the body expression type-checkable.
    private var relocalizingPrompt: some View {
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

    /// Watchdog fired — relocalization is taking unusually long / may never lock (feature-poor or
    /// self-similar space). Replaces the indefinite "move camera" prompt with actionable guidance +
    /// escape routes so the user is never stuck.
    private var relocTimeoutPanel: some View {
        VStack(spacing: 12) {
            Text("🔄 Having trouble recognizing this spot")
                .font(.headline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Text("This area may look too similar to other places or lack distinct features. Move to a more recognizable spot — aim at corners, furniture, or textured surfaces — and make sure it's well lit.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.9))
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button(action: { retryRelocalization() }, label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.9))
                        .cornerRadius(12)
                })
                Button(action: { exitCaptureFromRelocTimeout() }, label: {
                    Label("Go Back", systemImage: "chevron.left")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                })
            }
        }
        .padding(20)
        .background(Color.orange.opacity(0.9))
        .cornerRadius(20)
        .shadow(radius: 5)
        .padding(.horizontal, 16)
        .transition(.scale.combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: relocTimedOut)
    }

    /// Caption under the record button. A computed String (not a chained ternary in `body`) so the
    /// body expression stays type-checkable.
    private var recordButtonCaption: String {
        if isRecording { return "Tap to stop" }
        if isProcessingMesh || isWaitingToSave { return "Processing previous scan…" }
        return "Tap to scan"
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

    /// Evaluates ScanCoach rules engine with current scan state.
    /// Respects the Settings toggle: CRITICAL/WARNING always evaluate,
    /// GUIDANCE/INFO are suppressed when coaching is disabled.
    private func evaluateScanCoach() {
        guard isRecording else { return }
        scanCoach.evaluate(
            scanStats: scanStats,
            frameCaptureSession: frameCaptureSession,
            capturedRoom: finalCapturedRoom,
            semanticLabelingEnabled: semanticLabeling,
            isRecording: isRecording,
            coachingEnabled: scanCoachingEnabled
        )
    }

    // MARK: - Space Analysis

    /// Begins the pre-scan space analysis: resets stats, starts the SpaceAnalyzer yaw tracker,
    /// and sets `isAnalyzing` (which triggers ARCoverageView to start the analysis RoomPlan session).
    func startAnalysis() {
        spaceAnalyzer.resetStats(scanStats)
        spaceAnalyzer.start()
        withAnimation { isAnalyzing = true }
    }

    /// Ends the analysis phase. If not cancelled, builds the report and presents the modal.
    /// - Parameter cancelled: If true, skip the report and just clean up.
    func stopAnalysis(cancelled: Bool) {
        withAnimation { isAnalyzing = false }

        if cancelled {
            spaceAnalyzer.resetStats(scanStats)
            return
        }

        // Build the report from accumulated stats
        let result = spaceAnalyzer.buildReport(from: scanStats, privacyFilterOn: isPrivacyFilterOn)
        analysisResult = result
        showAnalysisReport = true
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
        // The session's internal map is corrupt (this halt only fires on hard collapse —
        // snap storm / RoomPlan DriftDetection). Schedule a full .resetTracking for the next
        // config run (the post-stop nominal downgrade), or the warm session relocalizes
        // against the dead map forever and no new scan can start (2026-07-23 field report).
        scanStore.needsTrackingReset = true

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

/// Privacy Filter toggle pill. Expands with an informed-consent warning while OFF — capturing
/// people is a supported, deliberate choice (e.g. a group-photo 3D model), and with a 360°
/// camera connected that choice includes everyone around the operator, not just who the phone
/// sees. LOCKED while recording: the setting must describe the whole scan as one binary state —
/// a mid-scan flip half-masks the capture (segmentation masks exist only for the ON portion)
/// while the exported `privacy_filter` flag records just the stop-time value, so the export
/// blur gate would mis-reason about the unmasked half.
private struct PrivacyFilterPill: View {
    @Binding var isOn: Bool
    let locked: Bool
    let show360Note: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Privacy Filter")
                    .font(.subheadline)
                    .foregroundColor(.white)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .tint(.green)
                    .disabled(locked)
            }
            if !isOn {
                Text(warningText)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .frame(maxWidth: 260, alignment: .leading)
        .opacity(locked ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.2), value: isOn)
    }

    private var warningText: String {
        var text = "People in view will be captured unblurred — moving people will corrupt texture maps."
        if show360Note {
            text += " The connected 360° camera captures ALL directions, including people behind you."
        }
        return text
    }
}

#Preview("Privacy pill (off, 360)") {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 12) {
            PrivacyFilterPill(isOn: .constant(true), locked: false, show360Note: false)
            PrivacyFilterPill(isOn: .constant(false), locked: false, show360Note: false)
            PrivacyFilterPill(isOn: .constant(false), locked: true, show360Note: true)
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

/// The two destructive-discard confirmation alerts (stop menu + naming dialog), sharing
/// one warning message so every "Discard Scan" carries the same destructive notice.
/// Extracted from CaptureView.body — inlining them pushed SwiftUI's type-checker over
/// its time budget ("unable to type-check this expression in reasonable time").
private struct DiscardConfirmAlerts: ViewModifier {
    @Binding var showDiscardConfirm: Bool
    @Binding var showPendingDiscardConfirm: Bool
    /// Reopens the naming prompt — a pending scan must never be stranded with no UI
    /// to save or discard it.
    let onKeepPending: () -> Void
    let onDiscardLive: () -> Void
    let onDiscardPending: () -> Void

    static let warningText = "All frames and photos captured in this recording will be deleted. "
        + "This cannot be undone."

    func body(content: Content) -> some View {
        content
            // Stop-menu discard: recording is still live (the menu only dismissed) —
            // Keep Scanning resumes untouched; Discard tears down the capture session
            // and deletes the raw capture directory.
            .alert("Discard this scan?", isPresented: $showDiscardConfirm) {
                Button("Keep Scanning", role: .cancel) { }
                Button("Discard Scan", role: .destructive) { onDiscardLive() }
            } message: {
                Text(Self.warningText)
            }
            // Naming-dialog discard: recording already ended and the mesh is baked;
            // Back returns to the naming prompt, Discard deletes the pending artifacts.
            .alert("Discard this scan?", isPresented: $showPendingDiscardConfirm) {
                Button("Back", role: .cancel) { onKeepPending() }
                Button("Discard Scan", role: .destructive) { onDiscardPending() }
            } message: {
                Text(Self.warningText)
            }
    }
}
