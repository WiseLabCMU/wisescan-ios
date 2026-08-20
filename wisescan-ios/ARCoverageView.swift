import SwiftUI
import RealityKit
import ARKit
import RoomPlan
import Synchronization
import os               // always-on Logger for deferred-build timeout warnings

/// Dedups the repeated `UnlitMaterial(color: UIColor(red: CGFloat(c.x), …))` construction from a
/// SIMD4 color (x,y,z as RGB; `alpha` defaults opaque). Fileprivate to ARCoverageView.
private extension UnlitMaterial {
    init(rgb c: SIMD4<Float>, alpha: CGFloat = 1.0) {
        self.init(color: UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: alpha))
    }
}

// swiftlint:disable type_body_length
struct ARCoverageView: UIViewRepresentable {
    @Binding var arSession: ARSession?
    @Binding var isRecording: Bool
    @Binding var isSessionReady: Bool
    /// Set true by the coordinator when ARKit tracking is lost mid‑recording (VIO starvation).
    /// CaptureView observes this to halt the scan and prompt the user to save or rescan, since
    /// any data captured after VIO loss is corrupt.
    @Binding var vioCompromised: Bool
    var scanStats: ScanStats
    var privacyFilter: Bool
    var activeMeshColor: String = AppConstants.activeMeshColor
    var captureMode: AppConstants.CaptureMode
    var initialWorldMapURL: URL? // Support for Scan4D anchoring
    var initialGhostMeshData: Data? // Raw OBJ data from the previous scan
    /// Ghost auto-align reference: the ghost scan's room planes in its RAW capture frame (from
    /// `SaveRegistration.rawFramePlanes`) — registered live against detected ARPlaneAnchors to keep
    /// the ghost ENTITY visually seated on reality (user-confidence; never touches the world origin
    /// or the recording frame — save-time registration stays the authority). Empty = feature off.
    var ghostReferencePlanes: [PlaneRegistration.Plane] = []
    /// True when `initialGhostMeshData` is the wall-subtracted proxy (DECISION 2): the ghost
    /// renderer then draws `ghostReferencePlanes` as wall/floor quads in the SAME wireframe style
    /// (one material → reads as one ghost). False for the full mesh (quads would double-draw).
    var ghostIsProxy: Bool = false
    var scanStore: ScanStore? // Runtime state for boundary anchor tracking
    /// Track C — all connectors the active location's scans share with other maps, in the
    /// relocalized session's world frame. Computed by CaptureView (which has the ModelContext) and
    /// rendered as labeled markers on record-start when rescanning an existing space. Empty otherwise.
    var connectorAnchors: [ConnectorAnchor] = []
    /// RoomPlan: binding to receive the final CapturedRoom when recording stops.
    /// Written by the Coordinator in stopRoomPlanSession(); consumed by finishStopRecording for export.
    @Binding var finalCapturedRoom: CapturedRoom?
    /// Frame capture session, wired at record-start so sharp keyframe captures can mark
    /// mesh anchors as photo-covered in the coverage overlay (amber → clear).
    var frameCaptureSession: FrameCaptureSession?

    /// Well-known name for boundary anchors so they can be identified across sessions.
    static let boundaryAnchorName = "Scan4D_Boundary_Anchor"

    // Ghost mesh manual alignment
    var ghostYRotation: Float = 0       // Radians, applied as Y-axis rotation offset
    var ghostXOffset: Float = 0         // Meters, X-axis position offset
    var ghostZOffset: Float = 0         // Meters, Z-axis position offset
    var dismissGhostMesh: Bool = false  // When true, remove ghost mesh from scene
    var bakedGhostTransform: simd_float4x4? // Manual transform to bake into the session origin

    /// Battery: when true, pause the AR session (camera + sensors power down). Raised by CaptureView
    /// after an idle period on a non-capture tab; lowered on return to capture. Resume re-runs a
    /// nominal config (the "Initializing" overlay covers it — non-blocking now the delegate is off-main).
    var pauseARSession: Bool = false

    /// Space Analysis: when true, start a temporary RoomPlan session for staging checks (door/screen
    /// detection) regardless of the Semantic Labeling toggle. The Coordinator's `didUpdate room:`
    /// delegate pushes updates to `scanStats.analysisRoom`. Set false to stop and snapshot results.
    @Binding var isAnalyzing: Bool

    /// Whether this device has LiDAR for scene reconstruction and depth capture.
    static let supportsLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    /// Human-readable labels for each supported video format, for the dev settings picker.
    static var availableVideoFormats: [String] {
        ARWorldTrackingConfiguration.supportedVideoFormats.map { f in
            let w = Int(f.imageResolution.width)
            let h = Int(f.imageResolution.height)
            let fps = f.framesPerSecond
            let hiRes = f.isRecommendedForHighResolutionFrameCapturing ? " [hiRes]" : ""
            return "\(w)×\(h) @ \(fps)fps\(hiRes)"
        }
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // Disable RealityKit's automatic person occlusion rendering.
        // We enable personSegmentationWithDepth for the raw buffer data only —
        // privacy masking is handled in our compute shaders and FaceBlurOverlay.
        // Without this, RealityKit composites black silhouettes over people,
        // which creates stuck artifacts in VR mode (black background).
        arView.renderOptions.insert(.disablePersonOcclusion)

        // Start in nominal mode: camera passthrough only, no scene reconstruction
        // EXCEPT if we are extending a scan, in which case we load the map right away.
        // Phase-2.1 precursor: when diagnostics are on AND we're relocalizing into a map, enable mesh
        // *during the alignment phase* (normally off until record-start) so a live LiDAR cloud
        // accumulates before recording — that's the only window in which to measure/ICP-refine the
        // relocalization offset before the origin is baked. No-op in production (perfDiag off).
        // Alignment-phase mesh reconstruction exists ONLY to feed the dense mesh-ICP probe; a
        // proxy ghost has no ICP target, so skip it — the "drop mesh-during-alignment" prize
        // (plane detection below is far cheaper and serves the plane auto-align instead).
        let alignmentMesh = PerfDiag.enabled && initialWorldMapURL != nil && !ghostIsProxy
        // Rig calibration needs mesh anchors to extract edges for the solver's cost function.
        // Enable mesh reconstruction pre-record when calibration is active.
        let calibrationMesh = RigCalibrationManager.shared.isCalibrating
        // Plane detection ONLY when the ghost auto-align can actually engage (reference planes
        // loaded) — never as free-floating load on the already-sensitive alignment phase.
        let config = Self.makeConfiguration(enableMeshReconstruction: alignmentMesh || calibrationMesh, worldMapURL: initialWorldMapURL,
                                            enablePlaneDetection: initialWorldMapURL != nil && !ghostReferencePlanes.isEmpty)
        let runOptions: ARSession.RunOptions = config.initialWorldMap != nil ? [.resetTracking, .removeExistingAnchors] : []
        if PerfDiag.enabled, let m = config.initialWorldMap {
            context.coordinator.locDiagSummary.recordMap(m, name: initialWorldMapURL?.lastPathComponent) // 0.x: start a fresh per-run summary
            context.coordinator.locDiagBeginRun() // reset per-run settle state (delegate queue)
        }

        context.coordinator.scanStats = scanStats
        context.coordinator.arView = arView
        context.coordinator.privacyFilter = privacyFilter
        context.coordinator.activeMeshColor = activeMeshColor
        context.coordinator.captureMode = captureMode
        context.coordinator.isRecording.store(false, ordering: .relaxed)
        context.coordinator.isSessionReadyBinding = $isSessionReady
        context.coordinator.vioCompromisedBinding = $vioCompromised
        context.coordinator.finalCapturedRoomBinding = $finalCapturedRoom
        context.coordinator.hasWorldMap.store(config.initialWorldMap != nil, ordering: .relaxed)
        context.coordinator.scanStore = scanStore
        context.coordinator.resetGhostAutoAlign(referencePlanes: ghostReferencePlanes)
        context.coordinator.ghostIsProxy = ghostIsProxy
        // Let the stop flow end the recording-mode RoomPlan session promptly (see ScanStore). Weak
        // coordinator capture → no retain cycle; stopRoomPlanSession is idempotent + main-thread-only,
        // and the stop flow invokes this on the main thread.
        scanStore?.requestStopRoomPlan = { [weak coordinator = context.coordinator] in
            coordinator?.stopRoomPlanSession()
        }
        // [DEFERRED-ROOMPLAN] DECISION 3: no save-time reconstruction — the stop flow just tells the
        // box where to persist the (possibly late-arriving) CapturedRoomData; ScanPostprocessor runs
        // RoomBuilder from that sidecar later, on a cool device.
        scanStore?.setRoomDataPersistDir = { [weak coordinator = context.coordinator] dir in
            coordinator?.currentDeferredRoomBox()?.setPersistDirectory(dir)
        }
        // Record-tap escape hatch: lets CaptureView revive a wedged capture graph (no frames
        // flowing) when the "establishing tracking" gate keeps bouncing the record button.
        scanStore?.reviveARSession = { [weak coordinator = context.coordinator] in
            coordinator?.reviveSessionIfStalled()
        }
        // Genuine map-load failure on the fresh-view path (requested but archive missing/corrupt) —
        // knowable synchronously here. Mirror of the updateUIView relocalization branch; replaces the
        // racy per-frame inference removed from driveAlignmentPhase (see that comment + git log).
        if initialWorldMapURL != nil && config.initialWorldMap == nil {
            let coord = context.coordinator
            DispatchQueue.main.async { coord.scanStore?.mapLoadFailed = true }
        }

        // Always start with the live camera feed — even in VR mode.
        // The VR point cloud + skybox are activated only when recording starts (in updateUIView).
        arView.environment.background = .cameraFeed()

        arView.session.delegate = context.coordinator
        // Deliver delegate callbacks on a background serial queue (not main) so a busy main thread
        // can never starve ARKit's frame pool. See Coordinator.sessionDelegateQueue for invariants.
        arView.session.delegateQueue = context.coordinator.sessionDelegateQueue
        // No debug options in nominal mode (no wireframe overlay)

        arView.session.run(config, options: runOptions)

        // Background parse the ghost mesh if provided (Scan4D extend scan)
        if let ghostData = initialGhostMeshData {
            Self.loadGhostMesh(data: ghostData, coordinator: context.coordinator, arView: arView)
        }
        // Record the ghost-data count we just consumed. makeUIView has already loaded the map (in
        // `config`) and the ghost above, so without this the FIRST updateUIView sees `nil → count` as a
        // change and re-runs the entire load — a second `makeConfiguration` (re-deserializing the same
        // world map, the expensive bring-up step) plus a second `session.run(.resetTracking)` that
        // restarts the relocalization makeUIView just began. That double bring-up both wastes the
        // deserialize and destabilizes the lock (observed: two identical `[LocDiag ε] map load` lines +
        // a slow/snappy settle). Seeding the counter here makes updateUIView a no-op for the unchanged
        // ghost; it still fires correctly if the user later switches to a *different* ghost/map.
        context.coordinator.lastGhostMeshDataCount = initialGhostMeshData?.count

        DispatchQueue.main.async {
            self.arSession = arView.session
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.privacyFilter = privacyFilter

        // Battery: pause/resume the session when the capture tab goes idle / returns. ARKit keeps
        // the camera + sensors powered until paused. While paused, skip the rest of updateUIView
        // (nothing to render). Resume re-runs the same nominal config makeUIView uses; the
        // "Initializing" overlay covers it, and it no longer freezes main now the delegate is off-main.
        if pauseARSession {
            if !context.coordinator.isSessionPausedForBattery {
                PerfDiag.log("battery: pausing AR session (idle)")
                uiView.session.pause()
                context.coordinator.isSessionPausedForBattery = true
            }
            return
        } else if context.coordinator.isSessionPausedForBattery {
            context.coordinator.isSessionPausedForBattery = false
            PerfDiag.log("battery: resuming AR session (returned to capture)")
            // Resume in the nominal (new-scan) configuration. The idle pause only fires after the
            // user has LEFT the capture tab, and leaving abandons any in-progress extend (CaptureView
            // .onDisappear clears the extend/ghost state, and the ghost overlay is removed on return)
            // — so there is intentionally NO world map to preserve here. Re-running the stale extend
            // config would relocalize to the abandoned map for nothing. If the user wants to extend
            // again they re-tap Extend, which reloads the map + ghost fresh; a brand-new scan's
            // record-start reconfigures and clears anchors. (Supersedes b579197.)
            // Full factory config + full reset, not a bare re-run. Two failure modes lived here
            // (2026-07-24 run-8 timing sweep, M2): (1) the bare ARWorldTrackingConfiguration ran
            // ARKit's DEFAULT video format (1920×1440@60), not our selected 30fps; (2) resuming a
            // paused session without reset options left the capture graph wedged (Fig err=-17281
            // storm) with Recon3D dead on EVERY post-resume recording — while the mesh-halt's
            // .resetTracking retry recovered 100% of the time. Nominal mode has nothing to
            // preserve (see above), so resume exactly the way the proven recovery path does.
            uiView.session.run(ARCoverageView.makeConfiguration(),
                               options: [.resetTracking, .removeExistingAnchors])
        }

        // Live active mesh color update — recolor all existing wireframe entities
        if activeMeshColor != context.coordinator.activeMeshColor {
            context.coordinator.activeMeshColor = activeMeshColor
            context.coordinator.recolorActiveMeshEntities()
        }

        // Space Analysis: start/stop the analysis-mode RoomPlan session
        if isAnalyzing && !context.coordinator.isAnalysisRoomPlan {
            context.coordinator.startAnalysisRoomPlanSession(arSession: uiView.session)
        } else if !isAnalyzing && context.coordinator.isAnalysisRoomPlan {
            context.coordinator.stopAnalysisRoomPlanSession()
        }

        let modeChanged = (captureMode != context.coordinator.captureMode)
        let recordingChanged = (isRecording != context.coordinator.isRecording.load(ordering: .relaxed))

        if modeChanged {
            context.coordinator.captureMode = captureMode
        }

        let shouldShowVR = (captureMode == .vr && isRecording)
        let wasShowingVR = (context.coordinator.pointCloudManager != nil)

        if shouldShowVR && !wasShowingVR {
            // [MemDiag] VR-ENTER→VR-READY brackets the voxel + point-cloud allocation. VoxelGrid /
            // PointCloudManager allocate their Metal buffers at capacity (350k voxels, 256×192×4
            // verts) up front, so this delta is the fixed VR footprint — independent of scene size.
            PerfDiag.log("[MemDiag] EVENT VR-ENTER \(context.coordinator.memMarker())")
            // Keep cameraFeed() background during setup — switch to black
            // only after the first point cloud frame renders (see session(_:didUpdate:)).
            context.coordinator.vrBackgroundSet = false
            context.coordinator.pointCloudManager = PointCloudManager(arView: uiView)
            context.coordinator.pointCloudManager?.setup(
                in: context.coordinator.rootEntity,
                activeMeshColor: activeMeshColor
            )
            let vrAnchor = AnchorEntity(world: .zero)
            vrAnchor.addChild(context.coordinator.rootEntity)
            uiView.scene.addAnchor(vrAnchor)
            context.coordinator.vrAnchorEntity = vrAnchor

            // NO session.run here. shouldShowVR requires isRecording, so the record-start
            // branch below ALWAYS runs the full reconstruction config (which inserts
            // .sceneDepth) within this same updateUIView pass. An extra re-run of the
            // stale nominal config here made record-start a back-to-back double
            // reconfiguration — exactly the churn that wedges Recon3D's SLAM on some
            // devices (see makeConfiguration note re: M2 iPad Pro), device-observed as
            // "everything runs but no mesh integrates" on VR restarts.
            context.coordinator.removeAllMeshEntities()
            PerfDiag.log("[MemDiag] EVENT VR-READY \(context.coordinator.memMarker())")
        } else if !shouldShowVR && wasShowingVR {
            // [MemDiag] VR-EXIT free-delta: same pattern as the recording teardown — Metal buffers
            // free on RealityKit's schedule, so defer one runloop turn + (dev-flag) force-reclaim
            // before measuring so the delta reflects reclaimed pages, not cached ones.
            PerfDiag.log("[MemDiag] EVENT VR-EXIT \(context.coordinator.memMarker())")
            uiView.environment.background = .cameraFeed()
            context.coordinator.pointCloudManager?.destroy()
            context.coordinator.pointCloudManager = nil
            context.coordinator.vrAnchorEntity?.removeFromParent()
            context.coordinator.vrAnchorEntity = nil

            if captureMode == .vr {
                context.coordinator.removeAllMeshEntities()
            }
            DispatchQueue.main.async {
                ScanStats.forceReclaimIfEnabled()
                PerfDiag.log("[MemDiag] EVENT VR-EXIT-DONE \(context.coordinator.memMarker())")
            }
        }

        if modeChanged && captureMode == .vr {
            context.coordinator.removeAllMeshEntities()
        }

        // If the session is already running (e.g. tab switch back) but isSessionReady
        // was reset in onDisappear, re-signal readiness immediately.
        if !isSessionReady && uiView.session.currentFrame != nil {
            DispatchQueue.main.async {
                self.isSessionReady = true
            }
            context.coordinator.hasSetSessionReady = true
        }

        // Track C — mirror the rescan's named connector set to the coordinator and paint the markers
        // as soon as relocalization confirms. Three gated paths drive the (idempotent, one-shot)
        // render: here on every updateUIView, the record-start branch below, and per-frame from
        // session(_:didUpdate:) — updateUIView isn't guaranteed to fire each frame during
        // relocalization, so the delegate path is the continuous retry. The legacy single nameless
        // boundary marker is suppressed for rescans (see session(_:didAdd:)).
        context.coordinator.syncRescanConnectors(connectorAnchors, isRescan: scanStore?.activeScanCase == .rescanSpace)
        context.coordinator.renderRescanConnectorsIfReady(arView: uiView)

        // Detect ghost mesh data changes (e.g., user tapped "Rescan Space" or "Link Adjacent Space" after initial view creation)
        let newGhostCount = initialGhostMeshData?.count
        if newGhostCount != context.coordinator.lastGhostMeshDataCount {
            context.coordinator.lastGhostMeshDataCount = newGhostCount

            // Tear down old ghost mesh if any
            if let oldAnchor = context.coordinator.ghostAnchorEntity {
                uiView.scene.removeAnchor(oldAnchor)
            }
            context.coordinator.ghostAnchorEntity = nil
            context.coordinator.hasAddedGhostMesh.store(false, ordering: .relaxed)
            context.coordinator.resetGhostAutoAlign(
                referencePlanes: initialGhostMeshData != nil ? ghostReferencePlanes : [])
            context.coordinator.ghostIsProxy = ghostIsProxy

            if let ghostData = initialGhostMeshData {
                // Load the world map for relocalization. Phase-2.1 precursor: also enable mesh during
                // the pre-record alignment phase when diagnostics are on (see makeUIView) so the live
                // cloud exists to ICP-measure the relocalization offset before record-start.
                let config = Self.makeConfiguration(
                    enableMeshReconstruction: isRecording || (PerfDiag.enabled && initialWorldMapURL != nil && !ghostIsProxy),
                    worldMapURL: initialWorldMapURL,
                    enablePlaneDetection: initialWorldMapURL != nil && !ghostReferencePlanes.isEmpty
                )
                if PerfDiag.enabled, let m = config.initialWorldMap {
                    context.coordinator.locDiagSummary.recordMap(m, name: initialWorldMapURL?.lastPathComponent) // 0.x: fresh per-run summary
                    context.coordinator.locDiagBeginRun() // reset per-run settle state (delegate queue)
                    context.coordinator.pendingICPBake = nil // Phase 2.1: drop any stale correction from a prior/cancelled alignment
                    context.coordinator.icpRefineCandidates.removeAll() // and the stale candidate buffer
                    scanStore?.icpAlignReady = nil
                }

                let runOptions: ARSession.RunOptions = config.initialWorldMap != nil ? [.resetTracking, .removeExistingAnchors] : []
                context.coordinator.hasWorldMap.store(config.initialWorldMap != nil, ordering: .relaxed)
                context.coordinator.hasSeenRelocalizing.store(false, ordering: .relaxed)
                // A GENUINE map-load failure (a relocalization map was requested but the archive was
                // missing/corrupt) is knowable HERE, synchronously, the instant the config is built.
                // Surface it now — do NOT infer it per-frame from `phase==.loadingWorldMap &&
                // !hasWorldMap`: that check ran on the AR delegate's background queue and raced THIS
                // main-thread config apply. On a stalled main thread (multi-second AR stalls on
                // marginal devices) the per-frame check won, saw hasWorldMap still false, and
                // FALSE-flagged a failure → mapLoadFailed → resetCaptureState wiped the just-armed
                // link-adjacent routing → ungated record button + 90°/offset ghost. (See git log.)
                if initialWorldMapURL != nil && config.initialWorldMap == nil {
                    let coord = context.coordinator
                    DispatchQueue.main.async { coord.scanStore?.mapLoadFailed = true }
                }
                uiView.session.run(config, options: runOptions)

                // Background parse the new ghost mesh
                Self.loadGhostMesh(data: ghostData, coordinator: context.coordinator, arView: uiView)
            }
        }

        // Dismiss ghost mesh if requested
        if dismissGhostMesh, let ghostAnchor = context.coordinator.ghostAnchorEntity {
            uiView.scene.removeAnchor(ghostAnchor)
            context.coordinator.ghostAnchorEntity = nil
            context.coordinator.hasAddedGhostMesh.store(false, ordering: .relaxed)
        }

        // Clear a stale boundary visual when the app cleared the boundary anchor state without an
        // isRecording transition (the alignment reset paths — confirmAlignment / cancelAlignment /
        // stabilization timeout — nil scanStore.boundaryAnchorTransform but never start recording,
        // so resetForRecording/Nominal don't run). Without this, mapA's boundary sphere lingers in
        // the freshly-reset mapB/idle session. Guarded on !isRecording so an active scan's marker
        // (and the brief place-then-publish window) is untouched.
        if !isRecording, scanStore?.boundaryAnchorTransform == nil,
           let staleBoundary = context.coordinator.boundaryAnchorEntity {
            staleBoundary.removeFromParent()
            context.coordinator.boundaryAnchorEntity = nil
            context.coordinator.boundaryAnchorId = nil
            context.coordinator.scanStats?.hasBoundaryAnchor = false
            context.coordinator.refreshHasBillboardMarkers()
        }

        // Ghost transform: the user's manual nudge wins when active; otherwise the plane-based
        // auto-align seats the ghost (visual-only — never baked into the world origin).
        if let ghostAnchor = context.coordinator.ghostAnchorEntity {
            let manualActive = ghostXOffset != 0 || ghostZOffset != 0 || ghostYRotation != 0
            context.coordinator.manualNudgeActive.store(manualActive, ordering: .relaxed)
            if manualActive {
                if isRecording {
                    // When recording, the manual offset is baked into the world origin, so the mesh stays at identity
                    ghostAnchor.transform = Transform.identity
                } else {
                    let rotation = simd_quatf(angle: ghostYRotation, axis: [0, 1, 0])
                    let translation = SIMD3<Float>(ghostXOffset, 0, ghostZOffset)
                    ghostAnchor.transform = Transform(rotation: rotation, translation: translation)
                }
            } else {
                // Auto-align: held at its last pre-record value through recording (keeps the ghost
                // seated — it was never baked, so identity would snap it back to misaligned);
                // reset to identity when the dev ICP bake moves the world origin instead.
                ghostAnchor.transform = Transform(matrix: context.coordinator.ghostAutoAlign)
            }
        }

        // Detect recording state change → switch AR session config
        if recordingChanged {
            context.coordinator.isRecording.store(isRecording, ordering: .relaxed)
            if isRecording {
                // Upgrade to full scene reconstruction via makeConfiguration — ensures a
                // consistent video format (avoiding a 30fps→60fps switch that confuses
                // Recon3D's internal SLAM on some devices, e.g. M2 iPad Pro). makeConfiguration
                // preserves the relocalized frame by loading initialWorldMapURL and honours our
                // meshClassifier bench toggle internally (meshReconstructionMode).
                let config = Self.makeConfiguration(
                    enableMeshReconstruction: true,
                    worldMapURL: initialWorldMapURL
                )
                if privacyFilter, ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                    config.frameSemantics.insert(.personSegmentationWithDepth)
                }
                if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                    config.frameSemantics.insert(.sceneDepth)
                }
                // Don't reset tracking — preserve the current relocalized coordinate frame.
                // But for a NEW scan, drop any ARMeshAnchors the warm session is still holding from
                // a previous scan of the same space — otherwise scene-reconstruction geometry from
                // the earlier scan bleeds into this scan's mesh export (exportMeshOBJ enumerates the
                // live currentFrame.anchors). An extend preserves its anchors: the world-map load
                // path (makeUIView / ghost-mesh-data) already cleared stale ones with
                // .removeExistingAnchors, and we want to keep re-meshing in the relocalized frame.
                var runOptions: ARSession.RunOptions = config.initialWorldMap != nil ? [] : .removeExistingAnchors
                if scanStore?.needsTrackingReset == true, config.initialWorldMap == nil {
                    // Belt to the nominal-downgrade reset: if a VIO-compromised halt's flag is
                    // somehow still pending at the next NEW-scan record-start, re-bootstrap here
                    // (never for an extend — resetTracking would discard the loaded map's frame).
                    scanStore?.needsTrackingReset = false
                    runOptions.insert(.resetTracking)
                    PerfDiag.log("record-start: pending post-halt .resetTracking applied")
                }
                if config.initialWorldMap == nil, !runOptions.contains(.resetTracking),
                   case .limited(.relocalizing) = uiView.session.currentFrame?.camera.trackingState ?? .notAvailable {
                    // A NEW scan starting while the session is chasing a relocalization (idle
                    // OS-interruption resume relocalizes to the session's own map) has no use for
                    // that old frame — and on a weak device the chase can never converge: the
                    // recording then sits degraded indefinitely with Recon3D dead and BOTH
                    // watchdogs unarmed (each waits for a first .normal frame). Observed
                    // 2026-07-28 A12Z: minutes of "[VR] Tracking degraded", faces=0, no stillness
                    // settle. Reset instead of chasing — a fresh scan starts from a fresh frame.
                    runOptions.insert(.resetTracking)
                    PerfDiag.log("record-start: session was relocalizing with no map to honor — .resetTracking for a fresh frame")
                }
                PerfDiag.log(config.initialWorldMap != nil
                    ? "record-start: extend → preserving anchors + world map"
                    : "record-start: new scan → .removeExistingAnchors (clear prior scan's mesh)")
                uiView.session.run(config, options: runOptions)

                // Phase 2.1 (perfDiag, dev-only): bake the gravity-locked ICP correction from the
                // alignment-phase refine into the world origin so recorded geometry lands in the
                // canonical/ghost frame regardless of how the user approached. Only trusted fits reach
                // here (pendingICPBake is nil for untrusted/none-ready/off → raw relocalized frame, as
                // today). Applied BEFORE the manual nudge so any nudge composes on the aligned frame.
                if let icpBake = context.coordinator.pendingICPBake {
                    uiView.session.setWorldOrigin(relativeTransform: icpBake)
                    let t = icpBake.columns.3
                    let trans = simd_length(SIMD3<Float>(t.x, t.y, t.z))
                    let yaw = atan2(icpBake.columns.2.x, icpBake.columns.2.z) * 180 / .pi
                    PerfDiag.log(String(format: "[LocDiag BAKE] applied gravity-locked ICP correction: trans=%.1fcm yaw=%.2f° — re-measuring post-bake", trans * 100, yaw))
                    context.coordinator.locDiagSummary.bakedTransM = trans
                    context.coordinator.locDiagSummary.bakedYawDeg = yaw
                    context.coordinator.pendingICPBake = nil
                    context.coordinator.icpRefineCandidates.removeAll() // alignment phase is over; drop candidates
                    scanStore?.icpAlignReady = nil
                    // The bake moved the WORLD into the ghost frame; the visual auto-align
                    // (measured pre-bake) is stale by exactly that correction — the ghost
                    // belongs at identity again.
                    context.coordinator.ghostAutoAlign = matrix_identity_float4x4
                    context.coordinator.ghostAnchorEntity?.transform = Transform.identity
                    // Re-measure post-bake during recording: if the bake's sign/magnitude are right, the
                    // residual trans collapses toward ~0 (overwrites summary.icp with the post-bake report).
                    context.coordinator.locDiagRearmICPForPostBake()
                }

                // If the user manually aligned the ghost mesh, bake that transform into the ARKit world origin
                if let baked = bakedGhostTransform {
                    uiView.session.setWorldOrigin(relativeTransform: baked)
                    print("[ARCoverageView] Applied baked ghost transform to ARSession world origin.")
                }

                // Active wireframe is now rendered via procedural geometry (not .showSceneUnderstanding)
                // Entities are built incrementally in session(_:didAdd:) and session(_:didUpdate:)
                context.coordinator.resetForRecording()
                // [MemDiag] baseline the instant recording begins — BEFORE RoomPlan starts, so the
                // RP-START marker's delta isolates RoomPlan's bring-up cost from the mesh baseline.
                // Stamp RoomPlan on/off so each run's log self-documents the mode (live consume is now
                // always deferred, so there's no separate knob to stamp).
                let sl = UserDefaults.standard.bool(forKey: AppConstants.Key.semanticLabeling)
                let meshClass = (config.sceneReconstruction == .meshWithClassification)
                let mode = "mode(semanticLabeling=\(sl ? "on" : "off") meshClassifier=\(meshClass ? "on" : "off") liveConsume=deferred)"
                PerfDiag.log("[MemDiag] EVENT RECORD-START \(context.coordinator.memMarker()) \(mode)")
                // Phase-0 diag: mark this run as recorded so stop emits a summary. A no-map run
                // has nothing to relocalize → start the summary fresh (drops any stale map/settle).
                if PerfDiag.enabled {
                    if config.initialWorldMap == nil { context.coordinator.locDiagSummary = .init() }
                    context.coordinator.locDiagSummary.didRecord = true
                }
                // Start RoomPlan session alongside ARKit (shares the same ARSession)
                context.coordinator.startRoomPlanSession(arSession: uiView.session)
                // Add coverage overlay green quad in AR mode
                if captureMode == .ar {
                    context.coordinator.addCoverageGreenQuad(to: uiView)
                }
                // Photo coverage: each sharp keyframe stamps the coverage grid from its
                // depth map, then flips AR anchors that crossed the coverage threshold from
                // amber ("depth only") to clear ("photo-grade") — or, in VR mode, clears the
                // amber tint on covered voxels. Wired here so the callback lives exactly as
                // long as the recording.
                let coordinator = context.coordinator
                frameCaptureSession?.onKeyframeCaptured = { [weak coordinator] keyframe in
                    coordinator?.markPhotoCoverage(keyframe)
                }

                // Background parse the ghost mesh if we didn't already load it in nominal mode
                if let ghostData = initialGhostMeshData, context.coordinator.ghostAnchorEntity == nil {
                    Self.loadGhostMesh(data: ghostData, coordinator: context.coordinator, arView: uiView)
                }

                // Draw the boundary marker for a metadata-only Pin B (mapB link flow). With no
                // world map there's no ARWorldMap anchor to trigger the didAdd visual path, and
                // resetForRecording above cleared any stale marker — so render it directly from
                // the pose pinB published to scanStore. (World-map flows keep using didAdd.)
                if config.initialWorldMap == nil,
                   let pinTransform = scanStore?.boundaryAnchorTransform {
                    context.coordinator.addBoundaryAnchorVisual(at: pinTransform, in: uiView)
                }

                // Track C — rescan coverage: render a labeled marker for EVERY connector the active
                // location shares with other maps. resetForRecording above cleared markers and the
                // render gate, so re-paint now (we're past relocalization at record-start). The same
                // path also runs continuously from updateUIView / cameraDidChangeTrackingState so the
                // markers are visible during relocalization too, not just once recording begins.
                context.coordinator.renderRescanConnectorsIfReady(arView: uiView)
            } else {
                // Phase-0 diag: emit the one-line per-run summary at stop for every recorded run.
                // No-map (baseline) runs print "map=none" so the absence of relocalization is
                // explicit rather than a silently-missing line. ICP may still be in flight → it
                // logs "pending" and the separate [LocDiag ICP] line carries the values.
                if PerfDiag.enabled, context.coordinator.locDiagSummary.didRecord {
                    LocalizationDiag.logSummary(context.coordinator.locDiagSummary)
                }
                // Downgrade to nominal: pure camera passthrough — no overlays
                // [MemDiag] snapshot the peak BEFORE any teardown free — pairs with the deferred
                // TEARDOWN marker below to give the AGGREGATE free-delta of the whole scan's resident
                // set (RoomPlan + mesh anchors + wireframe mirror + ghost). Per-step deltas aren't
                // honestly measurable here (the frees hop across the delegate/main queues and Metal
                // releases lazily), so we bracket the sum, which is the reliable number.
                PerfDiag.log("[MemDiag] EVENT PRE-TEARDOWN \(context.coordinator.memMarker())")
                // Stop RoomPlan and capture final CapturedRoom BEFORE reset clears state
                context.coordinator.stopRoomPlanSession()
                context.coordinator.resetForNominal()
                context.coordinator.removeCoverageGreenQuad()
                frameCaptureSession?.onKeyframeCaptured = nil

                // Remove ghost mesh from scene (will be re-added on next recording if needed)
                if let ghostAnchor = context.coordinator.ghostAnchorEntity {
                    ghostAnchor.removeFromParent()
                }

                let config = Self.makeConfiguration()
                if scanStore?.needsTrackingReset == true {
                    // VIO-compromised halt: re-bootstrap tracking with the nominal downgrade —
                    // the collapsed session otherwise stays relocalizing against its corrupt
                    // internal map indefinitely and the next scan can never establish tracking.
                    // resetTracking here is a ~1-2s VIO re-init on the live camera, NOT the
                    // 13s cold start (the session itself stays warm).
                    scanStore?.needsTrackingReset = false
                    PerfDiag.log("post-halt nominal downgrade → .resetTracking (re-bootstrap after VIO collapse)")
                    uiView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
                } else {
                    uiView.session.run(config)
                }
                // Clear ALL debug options for pure passthrough (or VR background)
                uiView.debugOptions = []
                // [MemDiag] post-teardown floor: RoomPlan stopped + mesh config dropped. Deferred one
                // runloop turn so the synchronous removeFromParent + queued frees above have landed
                // before we measure; forceReclaimIfEnabled() then (dev-flag-gated) decommits malloc's
                // free-list so the PRE→post delta reflects reclaimed pages, not cached ones.
                DispatchQueue.main.async {
                    ScanStats.forceReclaimIfEnabled()
                    PerfDiag.log("[MemDiag] EVENT TEARDOWN \(context.coordinator.memMarker())")
                }
            }
        }

    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Ghost Mesh Helper

    /// Loads ghost mesh OBJ data on a background queue, builds procedural wireframe geometry,
    /// and adds it to the AR scene when ready.
    /// Uses procedural edge geometry + opaque UnlitMaterial — no CustomMaterial, no transparency.
    /// CustomMaterial is fundamentally incompatible with RealityKit's AR video compositing
    /// pipeline (fsSurfaceMeshShadowCasterProgrammableBlending crashes due to missing
    /// videoRuntimeFunctionConstants buffer bindings).
    private static func loadGhostMesh(data: Data, coordinator: Coordinator, arView: ARView) {
        // 0.2: keep the ghost (prior/canonical) OBJ as the ICP target for the residual probe, and
        // build its surfel cloud ONCE here (off the delegate queue) so the per-refine path doesn't
        // re-parse the whole mesh every ~2 s (a thermal/compute load that can destabilize tracking).
        if PerfDiag.enabled, coordinator.ghostIsProxy {
            // Proxy ghost: no dense surfel target — the mesh-ICP probe/bake stay quiet for this
            // session (plane auto-align + save-time registration own alignment now). Legacy scans
            // without a proxy artifact still exercise the full ICP path below.
            PerfDiag.log("[LocDiag ICP] n/a this session — proxy ghost (plane registration owns alignment)")
            coordinator.sessionDelegateQueue.async { coordinator.locDiagGhostSurfels = nil }
        } else if PerfDiag.enabled {
            DispatchQueue.main.async { coordinator.locDiagSummary.ghostLoaded = true }
            coordinator.sessionDelegateQueue.async { coordinator.locDiagGhostSurfels = nil } // drop stale
            coordinator.locDiagICPQueue.async {
                // [MemDiag] Bracket the one-time surfel build (OBJ parse → capped surfel cloud). The
                // parse is the transient spike — the ghost OBJ can be 100k–700k faces (the old
                // per-2 s re-parse was the earlier thermal confound; it's built once here now).
                // footprintΔ = parse working set + retained cloud; wall = how long the load blocks a
                // fresh correction from being available. Same load/unload footprint pattern as the
                // mesh brackets. On the named `icp` queue so its CPU is attributable too.
                let wall0 = Date()
                let foot0 = ScanStats.currentFootprintMB()
                let surfels = LocalizationDiag.buildGhostSurfels(from: data)
                let foot1 = ScanStats.currentFootprintMB()
                PerfDiag.log(String(format: "[MemDiag] EVENT ICP-SURFELS wall=%.2fs footprint=%.0fMB (Δ%+.0f) surfels=%d bytes=%d",
                                    Date().timeIntervalSince(wall0), foot1, foot1 - foot0,
                                    surfels?.pts.count ?? 0, data.count))
                coordinator.sessionDelegateQueue.async { coordinator.locDiagGhostSurfels = surfels }
            }
        }
        // Room-outline source: the ghost's plane rectangles (already de-registered into the
        // ghost's raw frame — same frame as the proxy OBJ; set by resetGhostAutoAlign before
        // every loadGhostMesh call site). Captured on main here, used on the build queue below.
        let outlinePlanes = coordinator.ghostIsProxy ? coordinator.ghostReferencePlanes : []
        DispatchQueue.global(qos: .userInitiated).async {
            // Build procedural wireframe: thin 3D quads for each unique edge. A proxy ghost's
            // RoomPlan quads are already baked INTO the OBJ at save (coordinate-locked with the
            // mesh remainder), so there is deliberately no dynamic assembly here — but the
            // TRAILING lattice faces (count in the v4 header) render with thick lines: the sparse
            // 1 m grid is sub-pixel at the mesh's 1 mm default beyond ~1.5 m and visually vanishes.
            var descriptors: [MeshDescriptor]
            if coordinator.ghostIsProxy,
               let quadFaces = Self.ghostProxyQuadFaceCount(from: data), quadFaces > 0,
               let parsed = MeshParser.parseOBJ(from: data), parsed.faces.count > quadFaces {
                let split = parsed.faces.count - quadFaces
                descriptors = MeshParser.buildWireframeDescriptors(
                    vertices: parsed.vertices, faces: Array(parsed.faces[..<split]), thickness: 0.001)
                // Cross-section (not flat-ribbon) lines for the lattice: a flat ribbon with a
                // fixed perpendicular is edge-on/backface-invisible for axis-aligned grid lines
                // on walls of particular orientations (the "clips on some walls" finding).
                descriptors += MeshParser.buildCrossWireframeDescriptors(
                    vertices: parsed.vertices, faces: Array(parsed.faces[split...]),
                    thickness: Self.ghostProxyQuadLineThickness)
            } else {
                descriptors = MeshParser.generateWireframeDescriptors(from: data)
            }
            guard !descriptors.isEmpty else { return }

            // Room OUTLINE: each plane rectangle's 4 border edges — the wall-wall vertical
            // corners, the wall-floor seams, and the ceiling line — drawn bolder and lighter than
            // the interior lattice so the room's structural box reads at a glance (architectural-
            // drawing emphasis). Adjacent rects contribute coincident borders (a wall's bottom ≈
            // the floor's edge) — harmless, same color. Rendered as children of the same container
            // so it rides auto-align / manual nudge / de-registration with everything else.
            var outlineDescriptors: [MeshDescriptor] = []
            if !outlinePlanes.isEmpty {
                var edges: [(SIMD3<Float>, SIMD3<Float>)] = []
                for p in outlinePlanes {
                    let hx = p.xAxis * (p.width / 2)
                    let hy = p.yAxis * (p.height / 2)
                    let c00 = p.center - hx - hy, c10 = p.center + hx - hy
                    let c11 = p.center + hx + hy, c01 = p.center - hx + hy
                    edges.append(contentsOf: [(c00, c10), (c10, c11), (c11, c01), (c01, c00)])
                }
                outlineDescriptors = MeshParser.buildCrossWireframeDescriptors(
                    edges: edges, thickness: Self.ghostProxyOutlineThickness)
            }

            DispatchQueue.main.async {
                let ghostColorStr = UserDefaults.standard.string(forKey: AppConstants.Key.ghostMeshColor) ?? AppConstants.ghostMeshColor
                let color = ghostColorStr.toSIMD4Color
                // Fully opaque UnlitMaterial — the only stable material in ARView
                let material = UnlitMaterial(rgb: color)
                // Outline: same hue, strongly lightened — reads as the same ghost's frame while
                // separating architecture from content, and can't collide with the live-scan
                // color whatever the user picked for either.
                let outlineColor = simd_mix(color, SIMD4<Float>(1, 1, 1, color.w),
                                            SIMD4<Float>(repeating: 0.55))
                let outlineMaterial = UnlitMaterial(rgb: outlineColor)

                let containerEntity = Entity()

                // Generating resources on the main thread, 1 chunk per MeshResource.
                // This bypasses RealityKit's multi-part internal buffers and concurrent background generation crashes.
                for desc in descriptors {
                    if let resource = try? MeshResource.generate(from: [desc]) {
                        let chunkModel = ModelEntity(mesh: resource, materials: [material])
                        containerEntity.addChild(chunkModel)
                    }
                }
                for desc in outlineDescriptors {
                    if let resource = try? MeshResource.generate(from: [desc]) {
                        let chunkModel = ModelEntity(mesh: resource, materials: [outlineMaterial])
                        containerEntity.addChild(chunkModel)
                    }
                }
                // The ghost OBJ is already baked in the world frame of the source
                // scan's ARWorldMap (mesh + map are captured together at save time;
                // see performStopRecording). After relocalization the live session
                // adopts that same map coordinate frame, so the mesh overlays the
                // real space correctly at identity by default (the manual offset above
                // layers on top when the user nudges alignment).
                let anchorEntity = AnchorEntity(world: .zero)
                anchorEntity.addChild(containerEntity)
                coordinator.ghostAnchorEntity = anchorEntity

                // Only add immediately if no world map is loaded (no relocalization needed)
                // or if the session has already relocalized.
                let canAdd = !coordinator.hasWorldMap.load(ordering: .relaxed) || coordinator.hasSeenRelocalizing.load(ordering: .relaxed)
                if canAdd && arView.session.currentFrame?.camera.trackingState == .normal,
                   let ghostAnchor = coordinator.ghostAnchorEntity,
                   // Atomic test-and-set: only the path that flips false→true adds the anchor, so the
                   // delegate-queue add-path can never double-add the same AnchorEntity.
                   coordinator.hasAddedGhostMesh.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged {
                    print("Ghost mesh ready, adding immediately (hasWorldMap=\(coordinator.hasWorldMap.load(ordering: .relaxed)), relocalized=\(coordinator.hasSeenRelocalizing.load(ordering: .relaxed)))")
                    arView.scene.addAnchor(ghostAnchor)
                }
            }
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, ARSessionDelegate {
        weak var arView: ARView?
        var scanStats: ScanStats?
        let rootEntity = Entity()
        /// Serial queue for ALL ARSession delegate callbacks. Keeping them off the main thread is
        /// the fix for "delegate is retaining N ARFrames": when main is busy (name-prompt keyboard,
        /// post-scan processing, ARView render), ARKit can still hand frames to this queue, so the
        /// camera/SLAM pipeline never stalls. Invariants: (1) every RealityKit / entity / SwiftUI
        /// binding mutation is dispatched to `main`; (2) the delegate-owned dictionaries + VIO/stat
        /// counters below are touched ONLY on this queue (so `resetForRecording/Nominal`, called
        /// from updateUIView on main, hop here to clear them — never mutate them on main).
        let sessionDelegateQueue = DispatchQueue(label: "org.arenaxr.scan4d.arsession.delegate")
        /// [MemDiag] Dedicated NAMED serial queue for the Phase-2.1 ICP refine (was an anonymous
        /// `DispatchQueue.global(qos:.utility)`, which lumped its CPU into "unnamed" on the
        /// `cpu-by-thread` line). The label's last dotted component ("icp") is what
        /// `ScanStats.currentCPUByThread` reports — so the refine's cost is now attributable as
        /// `icp=N%` alongside `arkit=`/`voxel=`, isolating the perfDiag probe's contribution to the
        /// thread contention that starves VIO. Serial so back-to-back refines can't overlap-contend.
        let locDiagICPQueue = DispatchQueue(label: "org.arenaxr.scan4d.icp", qos: .utility)
        /// Tracks whether we paused the session for battery (idle on a non-capture tab), so we resume
        /// it exactly once on return rather than re-running the config on every update.
        var isSessionPausedForBattery = false
        var privacyFilter: Bool = true
        var activeMeshColor: String = AppConstants.activeMeshColor
        var captureMode: AppConstants.CaptureMode = .ar
        var pointCloudManager: PointCloudManager?
        var vrAnchorEntity: AnchorEntity?
        // Written on main (updateUIView), read on both main and the AR delegate queue
        // (session(_:didUpdate:) and the anchor callbacks). Atomic with relaxed ordering so the
        // cross-queue read/write is formally race-free (a plain Bool here is a data race, even
        // though it's word-aligned); relaxed matches the prior semantics — a one-frame-stale read
        // is harmless and self-corrects.
        let isRecording = Atomic<Bool>(false)
        /// Whether the VR black background has been applied (deferred until first frame)
        var vrBackgroundSet: Bool = false
        var isSessionReadyBinding: Binding<Bool>?
        var hasSetSessionReady = false
        /// VIO starvation guard: becomes armed once tracking reaches `.normal` while recording.
        /// Once armed, a drop to `.notAvailable`/`.relocalizing` means the world frame is lost and
        /// everything captured afterward is corrupt — so we trip the guard (halt + prompt) once.
        var vioCompromisedBinding: Binding<Bool>?
        /// RoomPlan: binding to push the final CapturedRoom snapshot back to CaptureView for export.
        var finalCapturedRoomBinding: Binding<CapturedRoom?>?
        private var vioGuardArmed = false
        /// ARFrame timestamp when tracking first went degraded (0 = currently fine). Used to
        /// measure *continuous* degradation for the VIO guard. Touched on the delegate queue.
        private var vioDegradedSince: TimeInterval = 0
        private var anchorUpdateCounts: [UUID: Int] = [:]
        /// Coalescing flag: prevents queuing multiple main-actor dispatches
        /// that each hold CVPixelBuffer references → ARFrame retention.
        private var pendingVRUpdate = false
        /// Per-anchor vertex/face counts — avoids reading geometry from session.currentFrame
        /// which pins ARFrame memory alive and triggers "retaining N ARFrames" warnings.
        private var anchorVertexCounts: [UUID: Int] = [:]
        private var anchorFaceCounts: [UUID: Int] = [:]

        /// Perf diagnostics: timestamp of the previous ARFrame, to detect gaps in frame
        /// delivery (the signature of ARKit VIO being starved). Touched only on the delegate queue.
        private var lastFrameTimestamp: TimeInterval = 0

        /// Wall-clock (ms) of the most recent ARFrame delivery, readable from any thread.
        /// 0 = no frame yet. Drives `reviveSessionIfStalled` — the record button's escape from a
        /// dead capture graph (2026-07-24 run 3: after a battery-idle resume the Fig capture
        /// source stayed wedged, no frames ever flowed, tracking sat in .initializing forever,
        /// and every record tap bounced off the "establishing tracking" gate with no way out).
        let lastFrameWallMs = Atomic<Int64>(0)
        /// Wall-clock (ms) of the most recent frame whose tracking state the record gate would
        /// accept (not .initializing/.notAvailable). 0 = never this session. The revive's second
        /// signal: frames flowing but tracking stuck cold since long ago.
        let lastTrackingReadyWallMs = Atomic<Int64>(0)

        // ── LiDAR mesh-start watchdog (delegate-queue state) ──
        // A recording on a LiDAR device that never produces an ARMeshAnchor means Recon3D is dead
        // for this scan — the capture graph came up wrong (2026-07-24 runs: 60fps default-format
        // fallback + Fig err storm after RoomPlan's internal reconfigure; faces=0 for the whole
        // scan). Mesh anchors are the product-level signal: they subsume a dead depth stream
        // (mesh needs depth) AND a dead reconstruction on a live stream. Action is a HALT via the
        // VIO guard — NOT a live config rebuild: re-running the session under an active RoomPlan
        // crashed ObjectUnderstanding (EXC_BREAKPOINT in OUSession updateWithKeyframes at save,
        // run 4). The halt's needsTrackingReset gives the NEXT record-start the full fresh
        // rebuild, which is the manual fix that always worked.
        private var recordStartTimestamp: TimeInterval = 0
        /// First .normal-tracking frame timestamp of this recording (0 until seen) — the mesh
        /// budget starts here so VIO initialization time doesn't count against it.
        private var meshWatchdogBaseline: TimeInterval = 0
        private var sawMeshAnchorThisRecording = false
        private var meshWatchdogFired = false

        // ── Phase-0 localization diagnostics (log-only; see docs/fix-localization-plan.md).
        //    All delegate-queue state. ──
        /// 0.1: one-shot guard + start stamp for the relocalization-settle ε log.
        private var locDiagLoggedSettle = false
        private var locDiagRelocStart: TimeInterval = 0
        private var locDiagSawReloc = false
        /// 0.2: the ghost (prior/canonical) surfel cloud (face centroids + normals) used as the ICP
        /// target — parsed/built from the ghost OBJ **once** at ghost-load and reused every refine.
        /// (The parse over a 100k–700k-face mesh was being redone every ~2 s, a real thermal/compute
        /// load that could throttle VIO into a tracking breakdown.) Built on a background queue,
        /// stored + read on the delegate queue; plus a per-anchor sample of live world-space verts
        /// accumulated during recording, run through ICP once enough has accumulated.
        var locDiagGhostSurfels: (pts: [SIMD3<Float>], nrm: [SIMD3<Float>])?
        private var locDiagLiveSamples: [UUID: [SIMD3<Float>]] = [:]
        private var locDiagRanICP = false
        /// 0.3: detects the frame-correction "snap" that baked world:.zero overlays don't follow.
        private var locDiagSnap = LocalizationDiag.SnapTracker()
        /// Phase 2.1 item 2 (production signal, NOT perfDiag-gated): detects a snap STORM — a cluster of
        /// non-physical frame discontinuities (loop-closure / relocalization jumps) under continuous
        /// `.normal` tracking, the session collapse the VIO guard misses. A SINGLE snap is benign (the
        /// saved mesh re-pins from live anchor transforms at export), so only the storm fires the flag.
        /// Delegate-queue state; reset at record-start, fires the ScanStore flag.
        private var trackingStability = TrackingStabilityMonitor()
        /// Per-run consolidated summary. **Main-thread only** — delegate/ICP-queue probes hop to
        /// main to populate it (see LocalizationDiag.Summary). Emitted at stop-recording.
        var locDiagSummary = LocalizationDiag.Summary()
        /// Phase 2.1 (perfDiag, dev-only): the gravity-locked correction from the alignment-phase
        /// refine, gated to trusted fits, waiting to be baked into the world origin at record-start.
        /// **Main-thread only** (set on the ICP-completion main hop, read in updateUIView's record-start).
        var pendingICPBake: simd_float4x4?
        /// Phase 2.1 polish: a short rolling buffer of recent **trusted** refines (passed `BakeGate`
        /// and above the min-offset floor). The pre-record refine re-runs every ~2 s and its quality
        /// swings wildly in feature-desert rooms, so `pendingICPBake` tracks the *best* of these by
        /// `LocalizationDiag.refineQuality`, not the latest. **Main-thread only** (same as
        /// `pendingICPBake`); cleared at map load and once a bake is consumed at record-start.
        var icpRefineCandidates: [(report: LocalizationDiag.ICPReport, bake: simd_float4x4)] = []
        private let icpRefineBufferMax = 6

        // Session capacity tracking
        private var sessionStartTime: Date = Date()
        private var baselineMemoryMB: Double = ScanStats.currentMemoryUsageMB()
        private var trackingDegradationCount: Int = 0
        private var totalTrackingUpdates: Int = 0
        /// Throttle for HUD stat recomputation/publishing. `updateStats` is invoked on
        /// every anchor add/update/remove (very frequent during scanning); the HUD does
        /// not need 60 Hz, so we recompute and publish at most ~10 Hz. This bounds both
        /// the reduce passes + memory query here and the SwiftUI re-renders of CaptureView
        /// that every @Observable ScanStats write triggers.
        private var lastStatsUpdateTime: Date = .distantPast
        private let statsUpdateInterval: TimeInterval = 0.1

        // [MemDiag] RoomPlan memory profiling (perfDiagnostics-gated, log-only). Separate 1 Hz
        // throttle so the memory timeline is readable — updateStats fires at 10 Hz. Reset on
        // record-start alongside lastStatsUpdateTime so the first sample lands immediately.
        private var lastMemDiagLogTime: Date = .distantPast
        private let memDiagLogInterval: TimeInterval = 1.0
        // Frames delivered since the last [MemDiag] sample → measured ARKit FPS. The end-of-scan
        // "visible slowdown" is CPU/thermal throttle + memory-compressor churn stealing frames; this
        // quantifies it next to footprint/thermal so the A/B shows the compute cost, not just memory.
        private var memDiagFrameCount: Int = 0
        // PRODUCTION fps (ungated, drives the capacity bar's fpsPressure — distinct from the perfDiag
        // memDiag fps above): frames since the last updateStats publish, and the EMA-smoothed rate.
        // Delegate-queue owned (incremented in didUpdate frame, consumed in updateStats — same queue).
        private var prodFrameCount: Int = 0
        private var smoothedFPSValue: Double = 60
        // PRODUCTION cpu (ungated, drives the capacity bar's cpuPressure): total CPU% across all cores,
        // sampled ~1 Hz (throttled — walking the thread list isn't free and the bar doesn't need 10 Hz
        // CPU resolution) and EMA-smoothed (raw CPU% is noisy tick-to-tick). Sampled unconditionally so
        // the bar works with PerfDiag OFF; the MemDiag log keeps its own raw read for per-thread parity.
        private var smoothedCPUValue: Double = 0
        private var lastCPUSampleTime: Date = .distantPast
        private let cpuSampleInterval: TimeInterval = 0.9

        // Active Mesh Wireframe properties
        /// One wireframe entity per ARMeshAnchor, keyed by anchor UUID.
        private var activeMeshEntities: [UUID: (anchor: AnchorEntity, model: Entity)] = [:]
        /// Throttle: last time wireframe was rebuilt for each anchor.
        private var lastAnchorWireframeTime: [UUID: Date] = [:]
        /// Minimum interval between wireframe rebuilds for the same anchor (seconds).
        private let wireframeThrottleInterval: TimeInterval = 0.5

        // Photo coverage (three-state overlay: green = unscanned, amber = depth only,
        // clear = photo-grade). Main-thread-owned — written when mesh entities are
        // (re)built and when a sharp keyframe stamps the coverage grid.
        /// Coverage-grid voxels occupied by each anchor's mesh (the denominator of the
        /// anchor's photo-covered fraction). Rebuilt whenever the anchor's mesh rebuilds.
        private var anchorVoxels: [UUID: Set<SIMD3<Int32>>] = [:]
        /// Last time each anchor's amber tint MeshResource was regenerated — rebuilds
        /// inside `photoTintRebuildInterval` reuse the previous tint entity instead.
        private var lastTintBuildTime: [UUID: Date] = [:]
        /// Anchors whose photo-covered voxel fraction crossed the threshold. Their amber
        /// "depth only" tint is disabled, leaving clean camera passthrough (photo-grade).
        private var photoCoveredAnchors: Set<UUID> = []
        /// World-space voxel grid of surfaces covered by sharp keyframe photos, stamped
        /// from each keyframe's depth map (occlusion-correct — no through-wall marking).
        let photoCoverageGrid = PhotoCoverageGrid()

        // RoomPlan: structured room detection alongside ARKit mesh
        /// Active RoomPlan session sharing our ARSession. Provides oriented surfaces/objects.
        private var roomCaptureSession: RoomCaptureSession?
        /// Set when RoomPlan has reconfigured the shared session (dropping our frame semantics) but
        /// tracking isn't `.normal` yet. cameraDidChangeTrackingState re-asserts the semantics once
        /// tracking stabilizes — re-running session.run() mid-initialization destabilizes VIO and
        /// causes RoomPlan "world tracking failure" / zero frames on cold first scans. Cross-queue
        /// (RoomPlan queue → main, ARSession delegate queue), so Atomic.
        let needsSemanticReassert = Atomic<Bool>(false)
        /// [MemDiag] one-shot latches for CoreML model-LOAD attribution. Both models load
        /// asynchronously AFTER their session-config activation, so the activation marker (RP-START /
        /// RECORD-START) captures the floor and these capture the moment the model's first output
        /// proves it's resident — the delta between is the load cost. Reset per recording; ~0 on a
        /// second scan means the framework cached the model process-wide. Cross-queue → Atomic.
        let loggedRoomPlanReady = Atomic<Bool>(false)   // trips on first recording-mode didUpdate room
        let loggedSegModelReady = Atomic<Bool>(false)   // trips on first frame carrying a segmentationBuffer
        /// Latest room snapshot from RoomPlan (updated in real-time via delegate).
        private var latestCapturedRoom: CapturedRoom?
        /// Final CapturedRoom snapshot captured at recording stop (for export).
        var finalCapturedRoom: CapturedRoom?

        /// [DEFERRED-ROOMPLAN] build box for the current recording's RoomPlan capture. Created
        /// fresh in startRoomPlanSession, fed the CapturedRoomData at didEndWith, and armed with
        /// the saved scan's directory AFTER saveScan. DECISION 3 (revised): the box runs
        /// RoomBuilder as a fire-and-forget post-save continuation and writes roomplan.json/_raw
        /// itself (CapturedRoomData can't be persisted for a later build). Guarded by a lock
        /// because it's written on main (start/analysis) and read on the RoomPlan + save queues.
        private let deferredRoomLock = NSLock()
        private var deferredRoomBuild: DeferredRoomBuild?
        /// The current recording box (nil for analysis-mode / RoomPlan-off). Thread-safe.
        func currentDeferredRoomBox() -> DeferredRoomBuild? { deferredRoomLock.withLock { deferredRoomBuild } }
        /// Strong hold on a just-stopped RoomCaptureSession until its async didEndWith delivers the
        /// CapturedRoomData (see stopRoomPlanSession — dropping the last reference at stop() lost
        /// the callback on long scans). Released at didEndWith or when a new session starts.
        var stoppingRoomCaptureSession: RoomCaptureSession?
        /// Throttle: last time RoomPlan semantic metadata was extracted (see extractRoomMetadata).
        private var lastRoomPlanOutlineTime: Date = .distantPast
        /// Accumulated set of detected semantic classes (published to ScanStats for HUD).
        private var detectedSemanticClasses: Set<String> = []

        // Coverage Overlay: 3D occlusion-based negative rendering
        /// The green background quad entity (far plane). Mesh occlusion punches holes.
        private var coverageGreenQuadAnchor: AnchorEntity?

        // Ghost Mesh properties
        var ghostAnchorEntity: AnchorEntity?
        // Written on main (updateUIView / loadGhostMesh) and on the AR delegate queue
        // (cameraDidChangeTrackingState); read on both. Atomic (relaxed) for formally race-free
        // cross-queue access — same rationale as `isRecording`. hasAddedGhostMesh additionally uses
        // compareExchange as an atomic test-and-set so the main and delegate add-paths can't both fire.
        let hasAddedGhostMesh = Atomic<Bool>(false)
        let hasWorldMap = Atomic<Bool>(false)
        let hasSeenRelocalizing = Atomic<Bool>(false)
        var lastGhostMeshDataCount: Int? // Track changes to ghost mesh data

        // Ghost auto-align (plane-based live nudge — user-confidence: the ghost visually seats on
        // reality instead of floating at the relocalization ε for the whole session). Ownership:
        // `ghostReferencePlanes` is written on main at ghost (re)load — before plane anchors
        // accumulate — and read on the delegate queue; `livePlaneAnchors` + the throttle/applied
        // state are delegate-queue-owned; `ghostAutoAlign` is main-owned (applied to the entity and
        // read by updateUIView). Manual-slider state crosses main→delegate, so it's atomic.
        var ghostReferencePlanes: [PlaneRegistration.Plane] = []
        var ghostIsProxy = false // mirrors the view flag; read at ghost build (main)
        var livePlaneAnchors: [UUID: ARPlaneAnchor] = [:]
        var ghostAutoAlign: simd_float4x4 = matrix_identity_float4x4
        private var ghostAutoAlignApplied = matrix_identity_float4x4
        private var lastGhostAutoAlignAt: TimeInterval = 0
        // Convergence stop: after this many consecutive trusted fits land within the re-seat
        // hysteresis, the seat is stable — stop fitting for the rest of the session (the
        // relocalization ε is stationary once settled; a handful of seats total is the contract).
        private var ghostAutoAlignStableCount = 0
        private var ghostAutoAlignConverged = false
        // Lowest finalRMS among trusted seats this session. The ANCHOR fit (`ghostAutoAlignFit`,
        // composed into Pin A at Confirm) is BEST-not-latest: unlike a rescan — which re-bakes the
        // alignment at save, so its live seat is only visual — the adjacent stitch bakes this fit
        // into the link at Confirm with NO post-save correction. So a later looser / wandering seat
        // (boundary correspondence noise, a relocalization snap) must not overwrite a tighter one.
        // Delegate-queue-owned (set in maybeRunGhostAutoAlign, reset in resetGhostAutoAlign).
        private var ghostAutoAlignBestRMS: Float = .greatestFiniteMagnitude
        let manualNudgeActive = Atomic<Bool>(false)

        /// Ghost (re)load reset — main thread; the session was just re-run with
        /// `.removeExistingAnchors`, so stale plane anchors are gone (didRemove also clears late ones).
        func resetGhostAutoAlign(referencePlanes: [PlaneRegistration.Plane]) {
            ghostAutoAlign = matrix_identity_float4x4
            ghostReferencePlanes = referencePlanes
            scanStore?.icpAlignReady = nil // stale chip from a prior ghost/alignment
            scanStore?.ghostAutoAlignFit = nil // stale pinA correction from a prior connect/ghost
            sessionDelegateQueue.async { [weak self] in
                self?.livePlaneAnchors.removeAll()
                self?.ghostAutoAlignApplied = matrix_identity_float4x4
                self?.lastGhostAutoAlignAt = 0
                self?.ghostAutoAlignStableCount = 0
                self?.ghostAutoAlignConverged = false
                self?.ghostAutoAlignBestRMS = .greatestFiniteMagnitude
            }
        }

        /// Register the ghost's raw-frame room planes onto the live classified ARPlaneAnchors and
        /// seat the ghost ENTITY on the result. Visual only — the world origin / recording frame
        /// are never touched (save-time registration remains the authority), which is exactly why
        /// this may re-run continuously as the fit improves, unlike a `setWorldOrigin` bake.
        /// Delegate-queue; throttled to 2 s with a 1.5 cm / 0.25° re-seat hysteresis.
        func maybeRunGhostAutoAlign() {
            guard !ghostAutoAlignConverged,
                  !isRecording.load(ordering: .relaxed),
                  !manualNudgeActive.load(ordering: .relaxed),
                  hasWorldMap.load(ordering: .relaxed),
                  hasAddedGhostMesh.load(ordering: .relaxed),
                  !ghostReferencePlanes.isEmpty else { return }
            let now = Date().timeIntervalSinceReferenceDate
            guard now - lastGhostAutoAlignAt >= 2.0 else { return }
            lastGhostAutoAlignAt = now

            let anchors = Array(livePlaneAnchors.values)
            let live = PlaneRegistration.planes(fromPlaneAnchors: anchors)
            let liveWalls = live.filter { $0.category == .wall }.count

            // Caveat monitor (perfDiag): one line per attempt on the NON-seated outcomes, so a
            // rescan where the ghost won't seat says WHY — starved for classified walls, no
            // correspondence, or a gate refusal (with the failing stat). Distinguishes ARKit not
            // surfacing/classifying enough walls (→ prescan RoomPlan-continuous fallback) from a
            // genuine fit problem (→ tune the gate). Success already logs below.
            func diag(_ outcome: String) {
                guard PerfDiag.enabled else { return }
                // ARPlaneAnchor.classification: the status lives on the `.none` case's associated
                // value (.undetermined = still deciding; .notAvailable/.unknown = won't classify).
                var wall = 0, floor = 0, otherClass = 0, undet = 0, unavail = 0
                for a in anchors {
                    switch a.classification {
                    case .wall: wall += 1
                    case .floor: floor += 1
                    case let .none(status): status == .undetermined ? (undet += 1) : (unavail += 1)
                    default: otherClass += 1 // ceiling/table/seat/window/door — classified, non-scaffold
                    }
                }
                PerfDiag.log(String(format: "[PlaneReg diag] planeAnchors=%d class(wall=%d floor=%d other=%d | undet=%d n/a=%d) usable=%d liveWalls=%d ghostRef=%d → %@",
                                    anchors.count, wall, floor, otherClass, undet, unavail,
                                    live.count, liveWalls, ghostReferencePlanes.count, outcome))
            }

            guard liveWalls >= 2 else {
                diag("starved: <2 classified walls (ARKit hasn't surfaced/classified enough)")
                return
            }
            guard let report = PlaneRegistration.register(source: ghostReferencePlanes, target: live) else {
                diag("no correspondence (ghost planes ↔ live planes didn't match)")
                return
            }
            guard let fit = PlaneRegistration.exportTransform(from: report) else {
                diag(String(format: "gate refused: RMS=%.1fmm walls=%d weakFrac=%.2f trans=%.1fcm yaw=%.2f° conv=%@",
                            report.finalRMS * 1000, report.matchedWalls, report.weakAxisFrac,
                            report.transM * 100, report.yawDeg, report.converged ? "y" : "n"))
                return
            }

            let d = fit * ghostAutoAlignApplied.inverse
            let dTrans = simd_length(SIMD3<Float>(d.columns.3.x, d.columns.3.y, d.columns.3.z))
            let dYawDeg = abs(atan2(d.columns.2.x, d.columns.2.z)) * 180 / .pi
            guard dTrans > 0.015 || dYawDeg > 0.25 else {
                // Trusted fit, same seat: count toward convergence — 3 in a row (~6 s stable,
                // planes no longer changing the answer) ends fitting for this session.
                ghostAutoAlignStableCount += 1
                if ghostAutoAlignStableCount >= 3 {
                    ghostAutoAlignConverged = true
                    print("[PlaneReg] ghost auto-align settled — no further fits this session")
                    // The seat is final — stop paying for ARKit's plane detection too. Mutate the
                    // LIVE config (the save path's proven pattern: preserves initialWorldMap + the
                    // relocalized frame, no reset). ARKit drops the plane anchors; didRemove clears.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.isRecording.load(ordering: .relaxed),
                              let session = self.arView?.session,
                              let liveConfig = session.configuration as? ARWorldTrackingConfiguration,
                              !liveConfig.planeDetection.isEmpty else { return }
                        liveConfig.planeDetection = []
                        session.run(liveConfig)
                        print("[PlaneReg] plane detection off (auto-align settled)")
                    }
                }
                return
            }
            ghostAutoAlignStableCount = 0
            ghostAutoAlignApplied = fit

            let transCm = report.transM * 100
            let yawDeg = report.yawDeg
            // Anchor fit is BEST-not-latest (see ghostAutoAlignBestRMS): rank by finalRMS — how well
            // the walls actually line up. The adjacent Pin-A composition bakes the winner with no
            // post-save correction, so a later looser seat must not replace a tighter one. The visual
            // seat + green chip below still track the LATEST fit (a rescan re-bakes at save anyway).
            let isBestAnchorFit = report.finalRMS < ghostAutoAlignBestRMS
            if isBestAnchorFit { ghostAutoAlignBestRMS = report.finalRMS }
            // "★anchor←best" marks the seat composed into Pin A on the adjacent connect (tightest so
            // far) — device validation reads which fit the stitch used, not just the latest.
            print(String(format: "[PlaneReg] ghost auto-align: trans=%.1fcm yaw=%.2f° (RMS=%.1fmm walls=%d weakFrac=%.2f livePlanes=%d)%@",
                         report.transM * 100, report.yawDeg, report.finalRMS * 1000,
                         report.matchedWalls, report.weakAxisFrac, live.count,
                         isBestAnchorFit ? " ★anchor←best" : ""))
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isRecording.load(ordering: .relaxed),
                      !self.manualNudgeActive.load(ordering: .relaxed) else { return }
                self.ghostAutoAlign = fit
                self.ghostAnchorEntity?.transform = Transform(matrix: fit)
                // Publish the fit so the adjacent-connect can compose it into pinA at Confirm — the
                // stitch anchor then lands in the ghost's raw frame, not the raw relocalization pose.
                // Best-not-latest: only a tighter-RMS seat replaces the published fit (pinA has no
                // post-save bake, so the tightest trusted seat wins, not whatever's latest at Confirm).
                if isBestAnchorFit { self.scanStore?.ghostAutoAlignFit = fit }
                // A trusted plane fit IS the alignment-ready signal — drive the green chip from it
                // (successor to the mesh-ICP refine's chip; that path is quiet for proxy ghosts).
                self.scanStore?.icpAlignReady = ScanStore.ICPAlignReady(transCm: transCm, yawDeg: yawDeg)
            }
        }

        // Boundary Anchor tracking
        weak var scanStore: ScanStore?
        var boundaryAnchorEntity: AnchorEntity?
        var boundaryAnchorId: UUID?

        // Connector markers (Track C). Each labeled marker is an AnchorEntity whose top-level
        // child is billboarded toward the camera each frame. `connectorMarkerEntities` holds the
        // markers rendered for a rescan (one per ConnectorAnchor); `boundaryAnchorEntity` is the
        // lone single-link marker. We billboard whatever is present in either set.
        var connectorMarkerEntities: [AnchorEntity] = []

        // Track C — the rescan's named connector set, mirrored here from updateUIView (which owns
        // the ModelContext). They must render only AFTER relocalization confirms, so the stored
        // world-frame poses line up with the live frame — otherwise they'd land in the pre-reloc
        // frame and never correct (unlike ARKit-owned anchors). `rescanConnectorsRendered` gates
        // the one-shot render; reset on every record/nominal transition so they re-render.
        var rescanConnectorAnchors: [ConnectorAnchor] = []
        // Written on main (syncRescanConnectors / reset paths) and read on the AR delegate queue
        // (session(_:didUpdate:)). Atomic (relaxed) — same cross-queue rationale as `isRecording`.
        let isRescanForConnectors = Atomic<Bool>(false)
        let rescanConnectorsRendered = Atomic<Bool>(false)

        /// Mirror the rescan connector set from updateUIView. Resets the render gate when the set
        /// changes so the new markers paint on the next relocalization check.
        func syncRescanConnectors(_ anchors: [ConnectorAnchor], isRescan: Bool) {
            let wanted = isRescan ? anchors : []
            if wanted.map(\.id) != rescanConnectorAnchors.map(\.id) {
                rescanConnectorAnchors = wanted
                rescanConnectorsRendered.store(false, ordering: .relaxed)
            }
            isRescanForConnectors.store(isRescan, ordering: .relaxed)
        }

        /// Renders the named connector markers once the session has relocalized to the saved world
        /// map (tracking `.normal`, and — if a map was loaded — relocalization confirmed). Idempotent
        /// and main-thread only (RealityKit scene mutation).
        func renderRescanConnectorsIfReady(arView: ARView) {
            guard isRescanForConnectors.load(ordering: .relaxed), !rescanConnectorsRendered.load(ordering: .relaxed), !rescanConnectorAnchors.isEmpty else { return }
            let relocalized = (!hasWorldMap.load(ordering: .relaxed) || hasSeenRelocalizing.load(ordering: .relaxed))
                && arView.session.currentFrame?.camera.trackingState == .normal
            guard relocalized else { return }
            rescanConnectorsRendered.store(true, ordering: .relaxed)
            renderConnectorMarkers(rescanConnectorAnchors, in: arView)
        }

        // Delegate-queue-visible mirror of "are there any billboard markers right now?". Lets
        // session(_:didUpdate:) skip the per-frame main hop entirely when there's nothing to
        // billboard (the common case — normal scans with no connectors/boundary). Written on main
        // whenever the marker sets change; read on the AR delegate queue. Atomic (relaxed) for the
        // same reason as `isRecording` — formally race-free cross-queue access, with a harmless,
        // self-correcting one-frame-stale read. `connectorMarkerEntities`/`boundaryAnchorEntity`
        // are main-only so they can't be read off the delegate queue directly.
        let hasBillboardMarkers = Atomic<Bool>(false)

        /// Recompute `hasBillboardMarkers` from the (main-only) marker sets. Call on main after any
        /// mutation of `connectorMarkerEntities` or `boundaryAnchorEntity`.
        func refreshHasBillboardMarkers() {
            hasBillboardMarkers.store(!connectorMarkerEntities.isEmpty || boundaryAnchorEntity != nil, ordering: .relaxed)
        }

        /// Reset coordinator state when entering recording mode.
        func resetForRecording() {
            baselineMemoryMB = ScanStats.currentMemoryUsageMB() // read on main in updateStats's publish block
            // [MemDiag] re-arm the model-load one-shots so each recording measures load fresh.
            loggedRoomPlanReady.store(false, ordering: .relaxed)
            loggedSegModelReady.store(false, ordering: .relaxed)
            // Clear delegate-owned counters/flags ON the delegate queue (never on main): the
            // ARSession callbacks mutate these dictionaries, and a concurrent mutation would crash.
            sessionDelegateQueue.async { [weak self] in
                guard let self = self else { return }
                self.anchorUpdateCounts.removeAll()
                self.anchorVertexCounts.removeAll()
                self.anchorFaceCounts.removeAll()
                self.lastAnchorWireframeTime.removeAll()
                self.detectedSemanticClasses.removeAll()
                self.trackingDegradationCount = 0
                self.totalTrackingUpdates = 0
                // Fresh fps state so the capacity bar doesn't inherit the last scan's low rate.
                // Delegate-queue-owned (mutated in didUpdate/updateStats) → reset HERE, not on main.
                self.prodFrameCount = 0
                self.smoothedFPSValue = 60
                self.smoothedCPUValue = 0                // fresh cpu EMA → bar won't inherit last scan's load
                self.lastCPUSampleTime = .distantPast    // first cpu sample lands immediately
                self.sessionStartTime = Date()
                self.lastStatsUpdateTime = .distantPast // let the first stats update publish immediately
                self.lastMemDiagLogTime = .distantPast  // [MemDiag] first memory sample lands immediately too
                // VIO guard: arm immediately if tracking is already normal at record start; otherwise
                // it arms on the first `.normal` frame (see session(_:didUpdate:)).
                self.vioGuardArmed = (self.arView?.session.currentFrame?.camera.trackingState == .normal)
                self.vioDegradedSince = 0
                // Item 2: fresh tracking-stability accumulators for this scan.
                self.trackingStability.reset()
                // Phase-2.1: the ICP probe is now armed at map load (locDiagBeginRun), NOT here, so a
                // measurement taken during the pre-record alignment phase (the moment 2.1 bakes the
                // correction) survives into recording rather than being clobbered by a record-time
                // re-run. If alignment never fired it (e.g. too little mesh pre-record), it's still
                // armed and fires during recording as before. (Settle flags likewise reset at load.)
            }
            // Clear any stale wireframe entities from a previous recording (RealityKit → main)
            removeAllActiveMeshEntities()
            latestCapturedRoom = nil
            finalCapturedRoom = nil
            lastRoomPlanOutlineTime = .distantPast

            scanStats?.hasBoundaryAnchor = false
            scanStats?.detectedClasses.removeAll()

            // Remove boundary anchor visual from the scene — prevents stale marker
            // from appearing at wrong position after session/coordinate-frame reset.
            if let existing = boundaryAnchorEntity {
                existing.removeFromParent()
            }
            boundaryAnchorEntity = nil
            boundaryAnchorId = nil
            // Clear any rescan connector markers and reset the render gate so they re-paint in the
            // recording frame (preserved relocalized frame → still valid; render gated on .normal).
            removeConnectorMarkers()
            rescanConnectorsRendered.store(false, ordering: .relaxed)
        }

        /// Reset coordinator state when returning to nominal (idle) mode.
        func resetForNominal() {
            // Clear delegate-owned counters/flags ON the delegate queue (see resetForRecording).
            sessionDelegateQueue.async { [weak self] in
                guard let self = self else { return }
                self.anchorUpdateCounts.removeAll()
                self.anchorVertexCounts.removeAll()
                self.anchorFaceCounts.removeAll()
                self.lastAnchorWireframeTime.removeAll()
                self.detectedSemanticClasses.removeAll()
                self.trackingDegradationCount = 0
                self.totalTrackingUpdates = 0
                self.vioGuardArmed = false
                self.vioDegradedSince = 0
                // Phase-0 diag: clear a prior alignment attempt's settle state.
                self.locDiagLoggedSettle = false
                self.locDiagRelocStart = 0
                self.locDiagSawReloc = false
            }

            // Remove all active mesh wireframe entities from the scene (RealityKit → main)
            removeAllActiveMeshEntities()
            // Stop RoomPlan session if still running
            roomCaptureSession?.stop(pauseARSession: false)
            roomCaptureSession = nil

            // Remove boundary anchor visual from the scene
            if let existing = boundaryAnchorEntity {
                existing.removeFromParent()
            }
            boundaryAnchorEntity = nil
            boundaryAnchorId = nil
            // Clear any rescan connector markers and reset the render gate.
            removeConnectorMarkers()
            rescanConnectorsRendered.store(false, ordering: .relaxed)

            DispatchQueue.main.async { [weak self] in
                // Zero out scan stats
                self?.scanStats?.totalVertices = 0
                self?.scanStats?.totalFaces = 0
                self?.scanStats?.anchorCount = 0
                self?.scanStats?.sessionDuration = 0
                self?.scanStats?.hasBoundaryAnchor = false
                self?.scanStats?.memoryUsageMB = 0
                self?.scanStats?.baselineMemoryMB = 0
                self?.scanStats?.driftEstimate = 0
                self?.scanStats?.averageQuality = 0
                // Do NOT reset trackingStatus here. The UI copy only refreshes on ARKit
                // TRANSITIONS (cameraDidChangeTrackingState) — when a teardown leaves the live
                // session in .normal the whole time, a hardcoded .notAvailable is never
                // corrected, and the record gate bounces "Hold steady…" forever against a
                // healthy session (2026-07-24 run 10; the revive rightly saw a healthy session
                // and stayed silent — the staleness was here, not in ARKit). The last pushed
                // value stays truthful: if the teardown really does restart tracking, the
                // transition fires and updates it.
                self?.scanStats?.detectedClasses.removeAll()
            }
        }

        // MARK: - Active Mesh Wireframe

        /// Removes all active mesh wireframe entities from the AR scene.
        private func removeAllActiveMeshEntities() {
            // Main-only: activeMeshEntities + RealityKit removeFromParent. (lastAnchorWireframeTime
            // is delegate-owned; it's cleared on the delegate queue by resetForRecording/Nominal.)
            for (_, entry) in activeMeshEntities {
                entry.anchor.removeFromParent()
            }
            activeMeshEntities.removeAll()
            anchorVoxels.removeAll()
            photoCoveredAnchors.removeAll()
            lastTintBuildTime.removeAll()
            photoCoverageGrid.reset()
            scanStats?.photoCoverageCovered = 0
            scanStats?.photoCoverageOccupied = 0
            scanStats?.meanStillOverlap = 0
            scanStats?.standpointDiversity = 0
        }

        /// Recolors all existing active mesh wireframe entities with the current activeMeshColor.
        /// Uses entity replacement (not in-place mutation) to avoid render thread races.
        func recolorActiveMeshEntities() {
            let c = activeMeshColor.toSIMD4Color
            let material = UnlitMaterial(rgb: c)
            for (_, entry) in activeMeshEntities {
                // The stored `model` is a container Entity. Iterate its children (the chunks).
                let children = entry.model.children.map { $0 }
                for child in children {
                    guard let modelEntity = child as? ModelEntity, let mesh = modelEntity.model?.mesh else { continue }
                    // Skip the coverage-overlay fills — the occlusion punch and the amber
                    // photo tint keep their own materials (recoloring them to the wireframe
                    // color would break the green-quad hole punch).
                    guard modelEntity.name != "occlusionFill" && modelEntity.name != "photoTint" else { continue }
                    modelEntity.removeFromParent()
                    let newModel = ModelEntity(mesh: mesh, materials: [material])
                    entry.model.addChild(newModel)
                }
            }
        }

        /// Builds or updates the wireframe entity for a single ARMeshAnchor.
        /// Extracts geometry data synchronously to avoid retaining ARFrame references,
        /// then runs wireframe generation on a background queue.
        /// Vertices are transformed to world space (matching exportMeshOBJ) so the
        /// entity can be anchored at the origin — avoids AnchorEntity transform issues.
        private func buildWireframeForAnchor(_ meshAnchor: ARMeshAnchor) {
            if captureMode == .vr { return } // No wireframes in VR mode

            let anchorId = meshAnchor.identifier
            let colorStr = activeMeshColor

            // Throttle: skip if we rebuilt this anchor's wireframe too recently
            if let lastTime = lastAnchorWireframeTime[anchorId],
               Date().timeIntervalSince(lastTime) < wireframeThrottleInterval {
                return
            }
            lastAnchorWireframeTime[anchorId] = Date()

            // ── Extract geometry data synchronously to release ARFrame references ──
            // ARMeshAnchor.geometry buffers hold references to internal ARFrame memory.
            // Dispatching the anchor itself to a background queue retains those frames,
            // triggering "retaining N ARFrames" warnings and starving the SLAM pipeline.
            let geometry = meshAnchor.geometry
            let vertices = geometry.vertices
            let faces = geometry.faces
            let anchorTransform = meshAnchor.transform

            guard faces.bytesPerIndex == 4, faces.indexCountPerPrimitive == 3 else { return }

            // Transform vertices to world space (same math as exportMeshOBJ).
            //
            // BOUNDED READS (2026-07-23 M2 crash — EXC_BAD_ACCESS at a page-aligned address in
            // this loop): a SIMD3<Float> pointee loads 16 bytes against ARKit's packed 12-byte
            // vertex stride, over-reading the FINAL vertex by 4 bytes — harmless while Metal
            // pads the allocation, fatal when the buffer ends exactly on a page boundary. Read
            // x/y/z as three 4-byte floats instead (the same fix buildMeshOBJ's parse already
            // carries), honor the source's byte offset, and clamp the declared counts to what
            // the mapped buffer can actually hold (ARKit can recycle/resize the underlying
            // MTLBuffer while a queued didUpdate drains — truncated geometry renders one
            // throttle-cycle stale; a fault kills the scan).
            let vStride = max(vertices.stride, MemoryLayout<Float>.size * 3)
            let vBase = vertices.buffer.contents().advanced(by: vertices.offset)
            let vAvail = max(0, vertices.buffer.length - vertices.offset)
            let safeVertexCount = min(vertices.count, vAvail / vStride)
            var worldPositions = [SIMD3<Float>]()
            worldPositions.reserveCapacity(safeVertexCount)
            for i in 0..<safeVertexCount {
                let xyz = vBase.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                let worldPos = anchorTransform * SIMD4<Float>(xyz[0], xyz[1], xyz[2], 1.0)
                worldPositions.append(SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z))
            }

            let faceStride = faces.bytesPerIndex * faces.indexCountPerPrimitive
            let safeFaceCount = min(faces.count, faces.buffer.length / max(faceStride, 1))
            var faceIndices = [(UInt32, UInt32, UInt32)]()
            faceIndices.reserveCapacity(safeFaceCount)
            let vertexCount = worldPositions.count
            for i in 0..<safeFaceCount {
                let ptr = faces.buffer.contents().advanced(by: i * faceStride)
                let face = ptr.assumingMemoryBound(to: (UInt32, UInt32, UInt32).self).pointee
                // Validate indices are within vertex bounds — corrupted geometry
                // from recycled ARFrame buffers can produce wild index values.
                guard Int(face.0) < vertexCount && Int(face.1) < vertexCount && Int(face.2) < vertexCount else {
                    continue
                }
                faceIndices.append(face)
            }
            // ── ARMeshAnchor reference is now released — geometry buffers won't retain ARFrame ──
            // (0.2 ICP live-sample feed moved to the anchor handlers via locDiagSampleAnchorForICP
            //  so it runs in VR mode too — this wireframe path early-returns in VR.)

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let descriptors = MeshParser.buildWireframeDescriptors(
                    vertices: worldPositions, faces: faceIndices, thickness: 0.001
                )
                guard !descriptors.isEmpty else { return }

                // Build filled triangle mesh for occlusion (coverage overlay hole punch)
                var filledDescriptor = MeshDescriptor(name: "occlusion_fill")
                filledDescriptor.positions = MeshBuffers.Positions(worldPositions)
                var flatIndices = [UInt32]()
                flatIndices.reserveCapacity(faceIndices.count * 3)
                for face in faceIndices {
                    flatIndices.append(face.0)
                    flatIndices.append(face.1)
                    flatIndices.append(face.2)
                }
                filledDescriptor.primitives = .triangles(flatIndices)

                // Photo-coverage support: world AABB for keyframe frustum tests, and a
                // slightly inflated copy of the fill mesh for the amber "depth only" tint.
                let coverageData = Self.buildPhotoCoverageData(
                    worldPositions: worldPositions,
                    flatIndices: flatIndices
                )

                DispatchQueue.main.async {
                    guard let self = self, let arView = self.arView, self.isRecording.load(ordering: .relaxed) else { return }

                    let c = colorStr.toSIMD4Color
                    let material = UnlitMaterial(rgb: c)

                    let containerEntity = Entity()

                    // Add wireframe edges
                    for desc in descriptors {
                        if let res = try? MeshResource.generate(from: [desc]) {
                            let model = ModelEntity(mesh: res, materials: [material])
                            containerEntity.addChild(model)
                        }
                    }

                    if self.captureMode == .ar {
                        // Add filled occlusion mesh (invisible, writes depth to punch holes in green quad)
                        if let occlusionRes = try? MeshResource.generate(from: [filledDescriptor]) {
                            let occlusionEntity = ModelEntity(
                                mesh: occlusionRes,
                                materials: [OcclusionMaterial()]
                            )
                            occlusionEntity.name = "occlusionFill"
                            containerEntity.addChild(occlusionEntity)
                        }
                        // Record this rebuild's occupied voxels, then re-evaluate coverage:
                        // an anchor can rebuild larger (new geometry) after it was already
                        // photo-covered, so recompute against the grid rather than trusting
                        // the prior flag.
                        self.anchorVoxels[anchorId] = coverageData.occupiedVoxels
                        let covered = self.isAnchorPhotoCovered(coverageData.occupiedVoxels)
                        if covered {
                            self.photoCoveredAnchors.insert(anchorId)
                        } else {
                            self.photoCoveredAnchors.remove(anchorId)
                        }
                        // Amber "depth only" tint over the camera feed — skipped entirely
                        // when the anchor is already photo-covered: generating a disabled
                        // tint mesh on the main thread would be pure wasted capture-time work.
                        if !covered {
                            // The tint's MeshResource.generate is the costliest main-thread
                            // part of the rebuild hop, and the hint tolerates brief staleness —
                            // so within the throttle window, carry the previous tint entity
                            // over instead of regenerating a third full mesh copy.
                            if let previousTint = self.activeMeshEntities[anchorId]?.model.findEntity(named: "photoTint"),
                               let builtAt = self.lastTintBuildTime[anchorId],
                               Date().timeIntervalSince(builtAt) < AppConstants.photoTintRebuildInterval {
                                previousTint.removeFromParent()
                                previousTint.isEnabled = true
                                containerEntity.addChild(previousTint)
                            } else if let tintRes = try? MeshResource.generate(from: [coverageData.tintDescriptor]) {
                                var tintMaterial = UnlitMaterial(rgb: AppConstants.photoTintColor, alpha: AppConstants.photoTintAlpha)
                                tintMaterial.blending = .transparent(opacity: 1.0)
                                let tintEntity = ModelEntity(mesh: tintRes, materials: [tintMaterial])
                                tintEntity.name = "photoTint"
                                containerEntity.addChild(tintEntity)
                                self.lastTintBuildTime[anchorId] = Date()
                            }
                        }
                    }

                    if let existing = self.activeMeshEntities[anchorId] {
                        // Replace the model entity entirely to avoid RealityKit render
                        // thread race conditions. In-place mesh mutation (model.model?.mesh = ...)
                        // can crash because the render thread may read the old index buffer
                        // against the new vertex buffer mid-swap.
                        existing.model.removeFromParent()
                        existing.anchor.addChild(containerEntity)
                        self.activeMeshEntities[anchorId] = (anchor: existing.anchor, model: containerEntity)
                    } else {
                        // Create new entity at world origin (vertices are world-space)
                        let anchorEntity = AnchorEntity(world: .zero)
                        anchorEntity.addChild(containerEntity)
                        arView.scene.addAnchor(anchorEntity)
                        self.activeMeshEntities[anchorId] = (anchor: anchorEntity, model: containerEntity)
                    }
                }
            }
        }

        /// Phase-0 diag (delegate queue): reset per-run settle state at the start of a new run
        /// (map load). Settle flags are delegate-owned, so hop onto the delegate queue. Called from
        /// main at the recordMap sites — NOT from resetForRecording, so a settle observed during
        /// pre-record alignment survives into recording.
        func locDiagBeginRun() {
            sessionDelegateQueue.async { [weak self] in
                self?.locDiagLoggedSettle = false
                self?.locDiagRelocStart = 0
                self?.locDiagSawReloc = false
                // Arm the one-shot ICP probe per run at map load (not at record-start) so it can fire
                // during the pre-record alignment phase — see resetForRecording.
                self?.locDiagRanICP = false
                self?.locDiagLiveSamples.removeAll()
            }
        }

        /// 0.2 helper (delegate queue): extract a bounded sample of an ARMeshAnchor's world-space
        /// verts for the ICP probe. Sourced from the anchor directly (NOT the wireframe path, which
        /// is AR-only) so the probe also works in **VR** capture mode. Reads geometry synchronously
        /// so no ARFrame reference is retained, matching buildWireframeForAnchor's discipline.
        private func locDiagSampleAnchorForICP(_ mesh: ARMeshAnchor) {
            guard PerfDiag.enabled, hasWorldMap.load(ordering: .relaxed), !locDiagRanICP, locDiagGhostSurfels != nil else { return }
            let vertices = mesh.geometry.vertices
            guard vertices.count > 0 else { return }
            let anchorTransform = mesh.transform
            // Bounded reads — same hazard and fix as buildWireframeForAnchor: three-float loads
            // (a SIMD3 pointee over-reads packed 12-byte strides by 4 bytes), source offset
            // honored, count clamped to the mapped buffer.
            let vStride = max(vertices.stride, MemoryLayout<Float>.size * 3)
            let vBase = vertices.buffer.contents().advanced(by: vertices.offset)
            let vAvail = max(0, vertices.buffer.length - vertices.offset)
            let safeCount = min(vertices.count, vAvail / vStride)
            guard safeCount > 0 else { return }
            let cap = 400
            let step = max(1, safeCount / cap)
            var samples = [SIMD3<Float>]()
            samples.reserveCapacity(min(cap, safeCount))
            var i = 0
            while i < safeCount {
                let xyz = vBase.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                let w = anchorTransform * SIMD4<Float>(xyz[0], xyz[1], xyz[2], 1.0)
                samples.append(SIMD3<Float>(w.x, w.y, w.z))
                i += step
            }
            locDiagAccumulateAndMaybeRunICP(anchorId: mesh.identifier, worldPositions: samples)
        }

        /// 0.2 helper (delegate queue): keep a bounded per-anchor sample of live world-space
        /// verts; once enough has accumulated during a relocalized recording, run the point-to-
        /// plane ICP residual probe once against the ghost (prior/canonical) mesh. The initial
        /// residual it logs is how far this relocalization landed off — the gross-failure signal.
        private func locDiagAccumulateAndMaybeRunICP(anchorId: UUID, worldPositions: [SIMD3<Float>]) {
            guard hasWorldMap.load(ordering: .relaxed), !locDiagRanICP, let ghostSurfels = locDiagGhostSurfels else { return }
            // Cap each anchor's contribution so one large surface can't dominate the cloud.
            let cap = 400
            if worldPositions.count <= cap {
                locDiagLiveSamples[anchorId] = worldPositions
            } else {
                let step = worldPositions.count / cap
                var s = [SIMD3<Float>](); s.reserveCapacity(cap)
                var i = 0; while i < worldPositions.count { s.append(worldPositions[i]); i += step }
                locDiagLiveSamples[anchorId] = s
            }
            let total = locDiagLiveSamples.values.reduce(0) { $0 + $1.count }
            // Phase 2.1: fire SOONER pre-record (the alignment window rarely accumulates 4000 verts
            // before the user taps record, so the bake had no correction ready), full budget while
            // recording (post-bake re-measure / the 0.2 probe).
            let preRecord = !isRecording.load(ordering: .relaxed)
            let threshold = preRecord ? 2000 : 4000
            guard total >= threshold else { return }
            locDiagRanICP = true
            let live = locDiagLiveSamples.values.flatMap { $0 }
            locDiagLiveSamples.removeAll() // free the buffer; the probe is one-shot per fire
            DispatchQueue.main.async { [weak self] in self?.locDiagSummary.icpPending = true }
            let targetCount = ghostSurfels.pts.count
            locDiagICPQueue.async { [weak self] in
                // [MemDiag] Bracket the refine to quantify the probe's compute cost — this runs
                // adjacent to live VIO during the alignment phase (re-armed ~2 s pre-record), so its
                // wall/CPU is exactly the sustained load that can throttle tracking. cpu-seconds ÷ wall
                // = average cores busy; footprintΔ = the refine's transient working set. Same shape as
                // the RP-BUILD-START/END save-time bracket. All reads are perfDiag-gated (syscalls).
                let diag = PerfDiag.enabled
                let wall0 = Date()
                let cpu0 = diag ? ScanStats.currentCPUTimeSeconds() : 0
                let foot0 = diag ? ScanStats.currentFootprintMB() : 0
                let report = LocalizationDiag.runICPResidualLog(liveWorldVertices: live,
                                                                targetPts: ghostSurfels.pts, targetNrm: ghostSurfels.nrm)
                if diag {
                    let wall = Date().timeIntervalSince(wall0)
                    let cpuSecs = ScanStats.currentCPUTimeSeconds() - cpu0
                    let foot1 = ScanStats.currentFootprintMB()
                    PerfDiag.log(String(format: "[MemDiag] EVENT ICP-REFINE wall=%.2fs cpu=%.2fs (%.0f%% of 1 core)"
                                        + " footprint=%.0fMB (Δ%+.0f) live=%d target=%d %@",
                                        wall, cpuSecs, wall > 0.001 ? cpuSecs / wall * 100 : 0,
                                        foot1, foot1 - foot0, live.count, targetCount,
                                        preRecord ? "pre-record" : "recording"))
                }
                // Pre-record: re-arm after a throttle so the correction stays fresh and is ready
                // whenever the user records (uses the latest/most alignment mesh). Recording fires are
                // one-shot. Guarded so a re-arm can't reopen the probe once recording has started.
                if preRecord {
                    self?.sessionDelegateQueue.asyncAfter(deadline: .now() + 2.0) {
                        guard let self = self, !self.isRecording.load(ordering: .relaxed) else { return }
                        self.locDiagRanICP = false
                        self.locDiagLiveSamples.removeAll()
                    }
                }
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // Classify by DISPATCH-time state (preRecord), not completion-time: a pre-record
                    // refine still in flight at record-start sampled the cloud BEFORE the bake, so it's
                    // a stale straggler — ignore it entirely (don't overwrite summary.icp, don't judge it
                    // as a post-bake re-measure). Only a refine dispatched DURING recording is post-bake.
                    if preRecord {
                        // Pre-bake measurement → candidate correction, only valid while record hasn't
                        // started. If recording began, this is a stale straggler → drop it.
                        guard !self.isRecording.load(ordering: .relaxed) else { return }
                        self.locDiagSummary.icp = report
                        if let r = report, let bake = LocalizationDiag.bakeTransform(from: r) {
                            let t = bake.columns.3
                            let trans = simd_length(SIMD3<Float>(t.x, t.y, t.z))
                            if trans < LocalizationDiag.BakeGate.minTransM {
                                // Trusted fit, but the offset is within the measurement-noise floor —
                                // relocalization is already aligned, so a correction would be within
                                // error of nothing. Skip (common small/cramped-space case); chip stays
                                // hidden, so "no chip" reads as "already aligned, nothing to correct".
                                // Leave the candidate buffer untouched — a sub-floor reading is "no
                                // correction needed", not a competing correction.
                                PerfDiag.log(String(format: "[LocDiag BAKE SKIP] offset %.1fcm within ~%.0fcm noise floor — relocalization already aligned, no bake", trans * 100, LocalizationDiag.BakeGate.minTransM * 100))
                            } else {
                                // Phase 2.1 polish: buffer this trusted refine and bake the BEST recent
                                // one by quality, not the latest. Refine quality swings wildly in
                                // feature-desert rooms; the latest fit is often worse than one seconds old.
                                self.icpRefineCandidates.append((r, bake))
                                if self.icpRefineCandidates.count > self.icpRefineBufferMax {
                                    self.icpRefineCandidates.removeFirst()
                                }
                                guard let best = self.icpRefineCandidates.max(by: {
                                    LocalizationDiag.refineQuality($0.report) < LocalizationDiag.refineQuality($1.report)
                                }) else { return }
                                self.pendingICPBake = best.bake
                                let bt = best.bake.columns.3
                                let bestTrans = simd_length(SIMD3<Float>(bt.x, bt.y, bt.z))
                                let yaw = atan2(best.bake.columns.2.x, best.bake.columns.2.z) * 180 / .pi
                                self.scanStore?.icpAlignReady = ScanStore.ICPAlignReady(transCm: bestTrans * 100, yawDeg: yaw)
                                if self.icpRefineCandidates.count > 1 {
                                    let inlierPct = best.report.sourcePoints > 0
                                        ? Float(best.report.correspondences) / Float(best.report.sourcePoints) * 100 : 0
                                    PerfDiag.log(String(format: "[LocDiag BAKE PICK] best of %d recent refines: quality=%.3f trans=%.1fcm horizMin=%.2f inliers=%.0f%% finalRMS=%.1fmm",
                                                        self.icpRefineCandidates.count, LocalizationDiag.refineQuality(best.report),
                                                        bestTrans * 100, best.report.horizMinObservability, inlierPct, best.report.finalRMS * 1000))
                                }
                            }
                        }
                    } else {
                        // Dispatched DURING recording: a genuine post-bake re-measure (or, if nothing was
                        // baked, a plain recording-phase probe). Either way it's the trustworthy current
                        // measurement, so it owns summary.icp.
                        self.locDiagSummary.icp = report
                        if let r = report, let baked = self.locDiagSummary.bakedTransM {
                            // Post-bake verdict, three outcomes:
                            // - baked below the ~residual-noise floor → INCONCLUSIVE (can't see a collapse
                            //   under the noise; a near-noise bake is also low-value). Need a larger offset.
                            // - residual clearly smaller than baked → OK (genuine collapse).
                            // - residual not smaller → WARN (inverted sign, bad lock, or rough tracking).
                            let residual = r.correctionTransM
                            let noiseFloor: Float = 0.06 // post-bake residual noise (~2–5cm clean, more if rough)
                            if baked < noiseFloor {
                                PerfDiag.log(String(format: "[LocDiag BAKE INCONCLUSIVE] baked %.1fcm is below the ~%.0fcm residual-noise floor — post-bake %.1fcm can't confirm a collapse; need a larger offset (farther approach) to validate", baked * 100, noiseFloor * 100, residual * 100))
                            } else if residual < baked * 0.6 {
                                PerfDiag.log(String(format: "[LocDiag BAKE OK] post-bake residual trans=%.1fcm collapsed below baked %.1fcm — bake nulled the offset", residual * 100, baked * 100))
                            } else {
                                PerfDiag.log(String(format: "[LocDiag BAKE WARN] post-bake residual trans=%.1fcm did NOT collapse below baked %.1fcm — inverted sign, bad lock, or rough tracking", residual * 100, baked * 100))
                            }
                        }
                    }
                }
            }
        }

        /// Phase 2.1: re-arm the one-shot ICP on the delegate queue so it re-measures during recording
        /// (used after a bake to capture the POST-bake residual — the on-device sign/efficacy check).
        func locDiagRearmICPForPostBake() {
            sessionDelegateQueue.async { [weak self] in
                self?.locDiagRanICP = false
                self?.locDiagLiveSamples.removeAll()
            }
        }

        // MARK: - RoomPlan Outlines

        /// Starts RoomPlan alongside the existing ARSession.
        /// Call on main thread after recording starts.
        func startRoomPlanSession(arSession: ARSession) {
            let semanticEnabled = UserDefaults.standard.bool(forKey: AppConstants.Key.semanticLabeling)
            guard semanticEnabled else { return }
            // Guard against leaking a still-live session (e.g. an analysis session that wasn't torn
            // down first): stop it before replacing the reference. Normally stopAnalysis runs first.
            if roomCaptureSession != nil {
                PerfDiag.log("startRoomPlanSession: a RoomCaptureSession was still live — stopping it first")
                roomCaptureSession?.stop(pauseARSession: false)
                roomCaptureSession = nil
            }
            // [DEFERRED-ROOMPLAN] Fresh build box for this recording; didEndWith feeds it, the
            // persisted sidecar carries it to ScanPostprocessor.
            deferredRoomLock.withLock { deferredRoomBuild = DeferredRoomBuild() }
            // A new session supersedes any still-finalizing stopped one — release the hold (its
            // late didEndWith would hit a fresh box anyway; the old recording's chance has passed).
            stoppingRoomCaptureSession = nil
            roomCaptureSession = RoomCaptureSession(arSession: arSession)
            roomCaptureSession?.delegate = self
            let config = RoomCaptureSession.Configuration()
            roomCaptureSession?.run(configuration: config)
            PerfDiag.log("RoomPlan session started (sharing ARSession)")
            PerfDiag.log("[MemDiag] EVENT RP-START \(memMarker())")
        }

        /// RoomPlan's `run(configuration:)` reconfigures the shared ARSession with its own config,
        /// dropping the `.sceneDepth` / `.personSegmentationWithDepth` frame semantics we set at
        /// record-start. Without them `frame.sceneDepth` goes nil (no depth/confidence captured) and
        /// the privacy filter falls back to the slow Vision path every frame. Re-assert the semantics
        /// onto whatever config RoomPlan applied, running with NO reset options so tracking, the world
        /// map, and RoomPlan itself all keep running — we only add the two semantics.
        /// Called from the RoomPlan `didStartWith` delegate, which fires after RoomPlan's config lands.
        ///
        /// During analysis mode, personSegmentation is also re-asserted even when privacy filter is
        /// OFF, since we temporarily enable it for person detection (see `startAnalysisRoomPlanSession`).
        func reassertFrameSemantics() {
            guard let session = arView?.session,
                  let config = session.configuration as? ARWorldTrackingConfiguration else { return }
            var changed = false
            // Re-assert personSegmentation if: (a) privacy filter is on, OR (b) analysis mode
            // (where we temporarily enable segmentation for person detection regardless of filter).
            if (privacyFilter || isAnalysisRoomPlan),
               ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth),
               !config.frameSemantics.contains(.personSegmentationWithDepth) {
                config.frameSemantics.insert(.personSegmentationWithDepth)
                changed = true
            }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
               !config.frameSemantics.contains(.sceneDepth) {
                config.frameSemantics.insert(.sceneDepth)
                changed = true
            }
            // RoomPlan's internal session run can also silently reset the video format to ARKit's
            // default (1920×1440 @ 60fps — format[0]). Observed 2026-07-24 run 4: the 60fps
            // fallback kept Recon3D from ever initializing (faces=0, fps=60 for the whole scan)
            // and ObjectUnderstanding asserted at save. Re-force our selection in the SAME run()
            // as the semantics fix — one restart, at the point already proven safe for post-
            // RoomPlan reconfiguration. The factory re-runs format selection, so a Developer-Mode
            // format override is respected, not fought.
            let preferred = ARCoverageView.makeConfiguration().videoFormat
            if config.videoFormat.framesPerSecond != preferred.framesPerSecond
                || config.videoFormat.imageResolution != preferred.imageResolution {
                config.videoFormat = preferred
                changed = true
            }
            guard changed else { return }
            session.run(config, options: []) // no reset → preserve tracking/world map and RoomPlan
            PerfDiag.log("Re-asserted frame semantics after RoomPlan (sceneDepth + personSegmentation, "
                + "\(Int(config.videoFormat.imageResolution.width))×\(Int(config.videoFormat.imageResolution.height)) "
                + "@ \(config.videoFormat.framesPerSecond)fps)")
        }

        /// Record-tap escape from a dead session (main thread): if the session hasn't delivered a
        /// frame for several seconds, the capture graph is wedged (Fig err=-17281 storm after a
        /// battery-idle resume — tracking then sits in .initializing forever and the record
        /// button's "establishing tracking" gate bounces every tap with nothing to heal it).
        /// Re-running the configuration rebuilds the graph; a no-op if frames are flowing and the
        /// session is merely still initializing (fresh VIO warms up in ~1–2 s on its own).
        func reviveSessionIfStalled() {
            guard let session = arView?.session else { return }
            let now = CFAbsoluteTimeGetCurrent()
            let lastMs = lastFrameWallMs.load(ordering: .relaxed)
            let stalledSecs = lastMs == 0 ? Double.greatestFiniteMagnitude : now - Double(lastMs) / 1000
            if stalledSecs > 3 {
                // Dead graph: no frames at all — rebuild it (same config, no reset).
                let config = session.configuration ?? ARCoverageView.makeConfiguration()
                session.run(config, options: [])
                PerfDiag.log("[Session] revive: no ARFrame for "
                    + (lastMs == 0 ? "this session" : "\(Int(stalledSecs))s")
                    + " — re-ran configuration to rebuild the capture graph")
                return
            }
            // Frames flowing but tracking stuck cold: a warm session can sit in .initializing
            // indefinitely after a save (2026-07-24 run 9 tail — record taps bounced with frames
            // alive, so the dead-graph branch above never applied). A plain new scan doesn't
            // need the session's old map, so reset it. Never under a loaded world map — the
            // rescan/link relocalization owns that state (its timeout UX recovers it), and
            // .relocalizing counts as record-ready anyway. Requires having BEEN ready once
            // (lastReadyMs > 0) so a normal cold-start warm-up is never reset mid-init.
            let lastReadyMs = lastTrackingReadyWallMs.load(ordering: .relaxed)
            guard lastReadyMs > 0, !hasWorldMap.load(ordering: .relaxed) else { return }
            let stuckSecs = now - Double(lastReadyMs) / 1000
            guard stuckSecs > 5 else { return }
            session.run(ARCoverageView.makeConfiguration(),
                        options: [.resetTracking, .removeExistingAnchors])
            PerfDiag.log("[Session] revive: frames flowing but tracking cold for \(Int(stuckSecs))s "
                + "— reset tracking for a fresh start")
        }

        // NOTE: there is deliberately no mid-recording config rebuild. Re-running the session
        // under an active RoomPlan crashed ObjectUnderstanding (EXC_BREAKPOINT in
        // OUSession updateWithKeyframes at save, 2026-07-24 run 4) — the mesh-start watchdog
        // HALTS instead, and the halt's needsTrackingReset rebuilds everything at the next
        // record-start. Live rebuilds are only safe in nominal mode (reviveSessionIfStalled,
        // above) where RoomPlan is never running.

        /// Stops RoomPlan and stores the final CapturedRoom for export.
        /// Call on main thread before recording cleanup.
        func stopRoomPlanSession() {
            guard let session = roomCaptureSession else { return }
            finalCapturedRoom = latestCapturedRoom
            // Push through binding so CaptureView.finishStopRecording can access it for export
            finalCapturedRoomBinding?.wrappedValue = finalCapturedRoom
            session.stop(pauseARSession: false) // keep ARKit alive
            // KEEP THE STOPPING SESSION ALIVE until didEndWith delivers the CapturedRoomData.
            // didEndWith fires ASYNCHRONOUSLY after stop() — RoomPlan finalizes the captured data
            // first, which on a long/heavy scan takes seconds. `roomCaptureSession = nil` here was
            // the LAST strong reference: the session deallocated mid-finalize and the callback
            // (and the room data with it) was silently lost — quick scans won the race, big scans
            // (2026-07-13; the 2026-07-16 497k-face scan) lost their room. Released at didEndWith
            // / next session start.
            stoppingRoomCaptureSession = session
            roomCaptureSession = nil
            needsSemanticReassert.store(false, ordering: .relaxed) // cancel any pending deferred re-assert
            PerfDiag.log("RoomPlan session stopped (ARSession preserved)")
            PerfDiag.log("[MemDiag] EVENT RP-STOP \(memMarker())")
        }

        // MARK: - Analysis-Mode RoomPlan

        /// Whether the current RoomPlan session was started for analysis (not recording).
        /// When true, `stopAnalysisRoomPlanSession` cleans up without touching finalCapturedRoom.
        private(set) var isAnalysisRoomPlan = false

        /// True if we temporarily added personSegmentation for the analysis phase (privacy filter was OFF).
        /// On analysis stop we'll remove it to restore the pre-analysis AR config.
        private var addedSegForAnalysis = false

        /// Starts RoomPlan for the space analysis phase, regardless of the Semantic Labeling toggle.
        /// Also ensures `personSegmentationWithDepth` is active so we can detect people even when
        /// the Privacy Filter is off. This enables door/screen/person detection unconditionally.
        func startAnalysisRoomPlanSession(arSession: ARSession) {
            guard roomCaptureSession == nil else { return } // don't double-start
            // [MemDiag] Analysis runs a RoomCaptureSession BEFORE recording, so it pre-loads RoomPlan's
            // (and personSeg's) CoreML models. This marker makes the log self-honest: if it appears
            // before RECORD-START, a later RP-READY≈0 means "already loaded here", not "RoomPlan free".
            PerfDiag.log("[MemDiag] EVENT ANALYSIS-START \(memMarker())")
            isAnalysisRoomPlan = true
            addedSegForAnalysis = false
            // [DEFERRED-ROOMPLAN] Analysis mode has no deferred build — clear any recording box so an
            // analysis-session didEndWith can't feed a stale box (analysis consumes the room live).
            deferredRoomLock.withLock { deferredRoomBuild = nil }
            stoppingRoomCaptureSession = nil // supersedes any still-finalizing stopped session

            // Ensure person segmentation is available for analysis even when Privacy Filter is OFF
            if !privacyFilter,
               ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth),
               let config = arSession.configuration as? ARWorldTrackingConfiguration,
               !config.frameSemantics.contains(.personSegmentationWithDepth) {
                config.frameSemantics.insert(.personSegmentationWithDepth)
                arSession.run(config, options: []) // no reset — preserve tracking
                addedSegForAnalysis = true
                PerfDiag.log("Analysis: temporarily enabled personSegmentation (privacy filter OFF)")
            }

            roomCaptureSession = RoomCaptureSession(arSession: arSession)
            roomCaptureSession?.delegate = self
            let config = RoomCaptureSession.Configuration()
            roomCaptureSession?.run(configuration: config)
            PerfDiag.log("RoomPlan analysis session started (sharing ARSession)")
        }

        /// Stops the analysis-mode RoomPlan session. Does NOT touch finalCapturedRoom/binding
        /// (that's for the recording flow). Pushes the latest room to scanStats.analysisRoom
        /// so SpaceAnalyzer can read it. If we temporarily added personSegmentation for the
        /// analysis phase, remove it to restore the pre-analysis state.
        func stopAnalysisRoomPlanSession() {
            guard let session = roomCaptureSession, isAnalysisRoomPlan else { return }
            scanStats?.analysisRoom = latestCapturedRoom
            session.stop(pauseARSession: false)
            roomCaptureSession = nil
            isAnalysisRoomPlan = false
            needsSemanticReassert.store(false, ordering: .relaxed)

            // Clear latestCapturedRoom so stale analysis data doesn't bleed into a future recording.
            latestCapturedRoom = nil

            // Remove temporarily-added personSegmentation if privacy filter is still OFF
            if addedSegForAnalysis,
               let arSession = arView?.session,
               let config = arSession.configuration as? ARWorldTrackingConfiguration,
               config.frameSemantics.contains(.personSegmentationWithDepth) {
                config.frameSemantics.remove(.personSegmentationWithDepth)
                arSession.run(config, options: [])
                PerfDiag.log("Analysis: removed temporary personSegmentation (privacy filter OFF)")
            }
            addedSegForAnalysis = false

            PerfDiag.log("RoomPlan analysis session stopped")
            // [MemDiag] ANALYSIS-START→STOP brackets the pre-scan analysis footprint. Note the models
            // stay resident (CoreML process-cached) past this point — this delta is analysis's own
            // working set releasing, NOT the model unloading. See ANALYSIS-START.
            PerfDiag.log("[MemDiag] EVENT ANALYSIS-STOP \(memMarker())")
        }

        // MARK: - Person Detection Helper

        /// Quick strided scan of a segmentation stencil for person pixels. Returns true if the
        /// buffer contains enough person-labeled pixels to indicate a real person (not noise).
        /// Runs on the delegate queue so it must not retain the ARFrame.
        static func hasPersonPixels(in mask: CVPixelBuffer) -> Bool {
            CVPixelBufferLockBaseAddress(mask, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(mask) else { return false }
            let w = CVPixelBufferGetWidth(mask)
            let h = CVPixelBufferGetHeight(mask)
            guard w > 0, h > 0 else { return false }
            let stride = CVPixelBufferGetBytesPerRow(mask)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            let step = 8 // coarse sample for speed
            var count = 0
            let threshold = 20 // ~20 sampled pixels = real person, not noise
            var y = 0
            while y < h {
                let row = ptr + y * stride
                var x = 0
                while x < w {
                    if row[x] > 128 { count += 1 }
                    if count >= threshold { return true }
                    x += step
                }
                y += step
            }
            return false
        }

        /// Renders oriented bounding-box wireframes from the latest CapturedRoom.
        /// Each Surface/Object becomes a set of 12 colored edges (thin boxes) with the
        /// correct transform. Throttled to avoid per-frame rebuilds.
        /// [DEFERRED-ROOMPLAN] Tier-2 metadata consume — the CHEAP half of the former
        /// `renderRoomPlanOutlines`: collect the detected semantic classes (for the live HUD and the
        /// saved `semanticClassesDetected`) WITHOUT building the per-surface RealityKit outline
        /// geometry. The geometry was the expensive part the deferred-build migration removed (the
        /// during-scan footprint); reading class names off the value-type room is nearly free. Called
        /// on main from the recording-mode `didUpdate room`; throttled like the old outline rebuild.
        private func extractRoomMetadata(from room: CapturedRoom) {
            guard Date().timeIntervalSince(lastRoomPlanOutlineTime) >= AppConstants.semanticThrottleInterval else { return }
            lastRoomPlanOutlineTime = Date()

            var classes = Set<String>()
            for surface in room.walls + room.floors + room.doors + room.windows + room.openings {
                let semantic = SemanticClass.from(surface.category)
                guard semantic != .none else { continue }
                classes.insert(semantic.rawValue)
            }
            for object in room.objects {
                let semantic = SemanticClass.from(object.category)
                guard semantic != .none else { continue }
                classes.insert(semantic.rawValue)
            }

            detectedSemanticClasses.formUnion(classes)
            let detectedForHUD = detectedSemanticClasses
            DispatchQueue.main.async { [weak self] in
                self?.scanStats?.detectedClasses = detectedForHUD
            }
        }

        // MARK: - Coverage Overlay (3D Occlusion)

        /// Creates the full-screen green background quad at a far distance.
        /// Mesh occlusion entities will punch holes through it.
        func addCoverageGreenQuad(to arView: ARView) {
            guard coverageGreenQuadAnchor == nil else { return }
            // Create a large quad far behind real-world geometry.
            // generatePlane(width:height:) creates an XY plane with normal +Z (facing camera).
            // 200m × 200m at 50m distance covers the full camera frustum generously.
            let mesh = MeshResource.generatePlane(width: 200, height: 200)
            let c = activeMeshColor.toSIMD4Color
            var material = UnlitMaterial(rgb: c, alpha: 0.3)
            material.blending = .transparent(opacity: 1.0)
            let model = ModelEntity(mesh: mesh, materials: [material])
            // Place 50m ahead of camera (in camera-local space, -Z is forward)
            model.position = [0, 0, -50]
            let anchor = AnchorEntity(.camera)
            anchor.addChild(model)
            arView.scene.addAnchor(anchor)
            coverageGreenQuadAnchor = anchor
        }

        /// Removes the green coverage quad.
        func removeCoverageGreenQuad() {
            coverageGreenQuadAnchor?.removeFromParent()
            coverageGreenQuadAnchor = nil
        }

        // MARK: - Photo Coverage (sharp keyframe frustum marking)

        /// Photo-coverage support data for a rebuilt anchor mesh: its world-space AABB (for
        /// keyframe frustum tests) and the amber tint mesh descriptor.
        struct PhotoCoverageData {
            /// Coverage-grid voxels occupied by the anchor's vertices — the denominator
            /// of the anchor's photo-covered fraction.
            let occupiedVoxels: Set<SIMD3<Int32>>
            let tintDescriptor: MeshDescriptor
        }

        /// Builds the photo-coverage support data for a rebuilt anchor mesh. The tint mesh is
        /// a copy of the fill mesh inflated along vertex normals so the translucent tint
        /// doesn't z-fight the coincident occlusion fill (which writes depth).
        /// Pure function; runs on the background mesh-build queue.
        private static func buildPhotoCoverageData(
            worldPositions: [SIMD3<Float>],
            flatIndices: [UInt32]
        ) -> PhotoCoverageData {
            var occupiedVoxels = Set<SIMD3<Int32>>()
            for position in worldPositions {
                occupiedVoxels.insert(PhotoCoverageGrid.key(for: position))
            }
            let vertexNormals = MeshParser.accumulateVertexNormals(
                vertices: worldPositions, flatIndices: flatIndices
            )
            var tintDescriptor = MeshDescriptor(name: "photo_tint")
            tintDescriptor.positions = MeshBuffers.Positions(
                worldPositions.enumerated().map { index, position in
                    let normal = vertexNormals[index]
                    let length = simd_length(normal)
                    return length > 1e-8 ? position + (normal / length) * AppConstants.photoTintInflation : position
                }
            )
            tintDescriptor.primitives = .triangles(flatIndices)
            return PhotoCoverageData(occupiedVoxels: occupiedVoxels, tintDescriptor: tintDescriptor)
        }

        /// Whether an anchor's mesh is sufficiently photo-covered to drop its amber tint:
        /// at least `photoCoverageAnchorFraction` of its occupied voxels appear in the
        /// coverage grid.
        private func isAnchorPhotoCovered(_ voxels: Set<SIMD3<Int32>>) -> Bool {
            guard !voxels.isEmpty else { return false }
            let hits = voxels.reduce(0) { $0 + (photoCoverageGrid.isCovered($1) ? 1 : 0) }
            return Double(hits) / Double(voxels.count) >= AppConstants.photoCoverageAnchorFraction
        }

        /// Stamps the photo-coverage grid from a sharp keyframe's depth map, then flips any
        /// anchor that crossed the coverage threshold from amber ("depth only") to clean
        /// camera passthrough ("photo-grade"). Runs on main, only at keyframe-capture events
        /// (a few times a minute).
        ///
        /// Coverage is occlusion-correct: only surfaces the depth map actually measured are
        /// stamped, so geometry behind a wall is never marked covered through the wall (the
        /// failure mode of the earlier frustum/AABB test this replaces).
        func markPhotoCoverage(_ keyframe: FrameCaptureSession.KeyframeStill) {
            guard let depthMap = keyframe.depthMap else { return }

            let stamp = photoCoverageGrid.stamp(
                depthMap: depthMap,
                cameraTransform: keyframe.transform,
                intrinsics: keyframe.intrinsics,
                imageWidth: keyframe.width,
                imageHeight: keyframe.height
            )
            // Multi-standpoint fraction walks the whole grid — compute once per keyframe
            // and share it between the log line and the published stats.
            let standpointDiversity = photoCoverageGrid.multiStandpointFraction
            if PerfDiag.enabled {
                // Per-still overlap with prior stills — the field-tuning signal for the
                // multi-view coaching thresholds (photogrammetry target ≈ 0.6).
                print("[Coverage] Still overlap: \(Int(stamp.overlap * 100))% (\(stamp.newlyCovered) new of \(stamp.stamped) voxels, mean \(Int(photoCoverageGrid.meanStillOverlap * 100))%, multi-standpoint \(Int(standpointDiversity * 100))%)")
            }
            publishCoverageStats(standpointDiversity: standpointDiversity)
            guard stamp.newlyCovered > 0 else { return } // no grid change → nothing can flip

            if captureMode == .ar {
                for (anchorId, voxels) in anchorVoxels where !photoCoveredAnchors.contains(anchorId) {
                    guard isAnchorPhotoCovered(voxels) else { continue }
                    photoCoveredAnchors.insert(anchorId)
                    // Disable the amber tint — this anchor is now photo-grade (clean camera feed).
                    activeMeshEntities[anchorId]?.model.findEntity(named: "photoTint")?.isEnabled = false
                }
            } else {
                // VR: push the enlarged covered-cell set to the voxel grid — covered voxels
                // drop their amber tint at the next pack (~0.5s).
                pointCloudManager?.applyPhotoCoverage(coveredCells: photoCoverageGrid.coveredPackedKeys())
            }
        }

        /// Publishes photo-coverage progress (covered vs occupied voxels across all anchors)
        /// plus the multi-view stats (mean still overlap, standpoint diversity) to ScanStats
        /// for the coach tips and the final scan metadata.
        /// Called on the main thread (keyframe-capture path), where ScanStats is written.
        /// Pass `standpointDiversity` when the caller already computed it (it walks the
        /// whole coverage grid).
        private func publishCoverageStats(standpointDiversity: Double? = nil) {
            var occupied = Set<SIMD3<Int32>>()
            for voxels in anchorVoxels.values { occupied.formUnion(voxels) }
            let coveredCount = occupied.reduce(0) { $0 + (photoCoverageGrid.isCovered($1) ? 1 : 0) }
            scanStats?.photoCoverageCovered = coveredCount
            scanStats?.photoCoverageOccupied = occupied.count
            scanStats?.meanStillOverlap = photoCoverageGrid.meanStillOverlap
            scanStats?.standpointDiversity = standpointDiversity ?? photoCoverageGrid.multiStandpointFraction
        }

        // Watch for relocalization success and track drift
        func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
            // Signal to CaptureView that the AR session is ready (dismiss loading overlay)
            if !hasSetSessionReady {
                switch camera.trackingState {
                case .normal, .limited:
                    hasSetSessionReady = true
                    DispatchQueue.main.async { [weak self] in
                        self?.isSessionReadyBinding?.wrappedValue = true
                    }
                default:
                    break
                }
            }

            // Deferred frame-semantics re-assert: RoomPlan dropped our semantics but tracking wasn't
            // .normal yet (see didStartWith). Now that it is, re-assert once — safe to re-run the
            // session config here because VIO is established. One-shot via compareExchange.
            if camera.trackingState == .normal,
               needsSemanticReassert.compareExchange(expected: true, desired: false, ordering: .relaxed).exchanged {
                DispatchQueue.main.async { [weak self] in self?.reassertFrameSemantics() }
            }

            // Track relocalization state for ghost mesh placement
            if case .limited(.relocalizing) = camera.trackingState {
                if !hasSeenRelocalizing.load(ordering: .relaxed) {
                    hasSeenRelocalizing.store(true, ordering: .relaxed)
                    print("[GhostMesh] Session entered relocalizing state — will wait for .normal before placing ghost mesh")
                }
            }

            // Only add ghost mesh after confirmed relocalization (if world map was loaded)
            if camera.trackingState == .normal && !hasAddedGhostMesh.load(ordering: .relaxed) {
                let canAdd = !hasWorldMap.load(ordering: .relaxed) || hasSeenRelocalizing.load(ordering: .relaxed)
                // Atomic test-and-set so this delegate path and the main loadGhostMesh path can't
                // both add the same anchor (compareExchange returns exchanged == true for the winner).
                if canAdd, let ghostAnchor = ghostAnchorEntity, let arView = arView,
                   hasAddedGhostMesh.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged {
                    let sawReloc = hasSeenRelocalizing.load(ordering: .relaxed), hadMap = hasWorldMap.load(ordering: .relaxed)
                    DispatchQueue.main.async { // RealityKit scene mutation must be on main
                        print("[GhostMesh] Session relocalized (hasWorldMap=\(hadMap), sawRelocalizing=\(sawReloc)). Adding Ghost Mesh overlay.")
                        arView.scene.addAnchor(ghostAnchor)
                    }
                } else if hasWorldMap.load(ordering: .relaxed) && !hasSeenRelocalizing.load(ordering: .relaxed) {
                    print("[GhostMesh] Tracking is .normal but relocalization not yet confirmed — deferring ghost mesh placement")
                }

                // Track C — same moment the ghost mesh is placed: the session has relocalized to the
                // saved world map, so the stored connector poses now line up with the live frame.
                // Hop to main and run the GATED render there — the connector array is written on main
                // by syncRescanConnectors, so it must never be read from this delegate queue (a
                // concurrent read during reassignment can race on the array's storage). The Bool gates
                // below are a cheap delegate-queue early-out only; `renderRescanConnectorsIfReady`
                // re-checks the gate and reads the array on main (one-shot; idempotent).
                if (!hasWorldMap.load(ordering: .relaxed) || hasSeenRelocalizing.load(ordering: .relaxed)),
                   isRescanForConnectors.load(ordering: .relaxed), !rescanConnectorsRendered.load(ordering: .relaxed),
                   let arView = arView {
                    DispatchQueue.main.async { [weak self] in
                        self?.renderRescanConnectorsIfReady(arView: arView)
                    }
                }
            }

            // Track drift via tracking state transitions
            totalTrackingUpdates += 1
            var status: TrackingStatus = .normal
            switch camera.trackingState {
            case .normal:
                status = .normal
            case .notAvailable:
                status = .notAvailable
                trackingDegradationCount += 1
            case .limited(let reason):
                switch reason {
                case .excessiveMotion:
                    status = .limited(reason: .excessiveMotion)
                    trackingDegradationCount += 1 // Real drift indicator
                case .insufficientFeatures:
                    status = .limited(reason: .insufficientFeatures)
                    trackingDegradationCount += 1 // Real drift indicator
                case .initializing:
                    status = .limited(reason: .initializing)
                    // Don't count as drift — normal startup
                case .relocalizing:
                    status = .limited(reason: .relocalizing)
                    // Don't count as drift — normal recovery
                @unknown default:
                    status = .limited(reason: .unknown)
                }
            }

            let trackingDesc: String
            switch status {
            case .normal: trackingDesc = "normal"
            case .notAvailable: trackingDesc = "notAvailable"
            case .limited(let r): trackingDesc = "limited (\(r.rawValue))"
            }
            PerfDiag.log("ARKit tracking → \(trackingDesc)")
            // (VIO starvation guard lives in session(_:didUpdate:) — it needs per-frame
            // timing to catch frame-delivery stalls + sustained degradation, not just transitions.)

            DispatchQueue.main.async { [weak self] in
                self?.scanStats?.trackingStatus = status
            }
        }

        // MARK: - Per-Frame Alignment Phase Transitions

        /// Drives alignment phase transitions based on tracking state.
        /// Relocalization succeeds when ARKit reaches `.normal` tracking
        /// after loading a world map — no boundary anchor required.
        /// Distance-to-boundary-anchor is still published when available
        /// as optional visual feedback in the overlay.
        /// Drives the pre-recording relocalization/alignment phase transitions for Link Adjacent /
        /// Rescan. Called from session(_:didUpdate frame:); a no-op outside the alignment phases.
        private func driveAlignmentPhase(_ frame: ARFrame) {
            guard let phase = scanStore?.capturePhase,
                  phase == .loadingWorldMap || phase == .aligning || phase == .alignedReady else {
                return
            }

            let isTrackingNormal = frame.camera.trackingState == .normal
            // In Link Adjacent, `.loadingWorldMap` means this flow expects relocalization
            // against a source scan. If loading failed and `hasWorldMap` is false, do not
            // treat that the same as a no-world-map flow.
            let worldMapWasRequested = phase == .loadingWorldMap || hasWorldMap.load(ordering: .relaxed)

            // NOTE: map-load failure is NOT inferred here anymore. This delegate runs on a background
            // queue, so on a stalled main thread it could observe `phase==.loadingWorldMap` (set
            // synchronously by Connect Adjacent) BEFORE updateUIView/makeUIView had applied the
            // world-map config (which sets hasWorldMap) — and false-flag a failure that wiped the
            // link-adjacent routing. Genuine failure is now detected synchronously at the config-build
            // sites (makeUIView + the updateUIView relocalization branch), where the load result is
            // known for certain. Here we simply wait for relocalization to complete.

            let isRelocalized = isTrackingNormal && (!worldMapWasRequested || hasSeenRelocalizing.load(ordering: .relaxed))
            // (0.1 settle detection lives in session(_:didUpdate:) now — it must run for ALL
            //  flows/modes, but this alignment FSM only engages for linkAdjacent.)

            // Optionally update distance to boundary anchor if one exists (visual only)
            if let anchorTransform = scanStore?.boundaryAnchorTransform {
                let anchorPos = SIMD3<Float>(anchorTransform.columns.3.x, anchorTransform.columns.3.y, anchorTransform.columns.3.z)
                let camPos = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
                let dist = simd_distance(anchorPos, camPos)
                DispatchQueue.main.async { [weak self] in
                    self?.scanStore?.distanceToBoundaryAnchor = dist
                }
            }

            DispatchQueue.main.async { [weak self] in
                // Re-read capturePhase inside the main-queue block to avoid stale
                // values overwriting a user-initiated cancel/reset that occurred
                // between the ARKit delegate call and this dispatch.
                guard let currentPhase = self?.scanStore?.capturePhase else { return }
                // Drive capturePhase transitions based on tracking state:
                // .loadingWorldMap → .aligning: ARKit has relocalized
                // .aligning → .alignedReady: tracking is stable, user can confirm
                // .alignedReady → .aligning: tracking degraded, revert
                if currentPhase == .loadingWorldMap && isRelocalized {
                    self?.scanStore?.capturePhase = .aligning
                } else if currentPhase == .aligning && isRelocalized {
                    self?.scanStore?.capturePhase = .alignedReady
                } else if currentPhase == .alignedReady && !isRelocalized {
                    self?.scanStore?.capturePhase = .aligning
                }
            }
        }

        // ── OS interruption guard ──
        // A system interruption (Control Center, app switch, phone call) stops frame delivery
        // entirely; on resume ARKit reports .initializing/.relocalizing — the exact states the
        // gap-based VIO guard treats as "recovering", so it never trips. But if the device MOVED
        // during the interruption, ARKit fully reinitializes SLAM (map_size→0) and merges
        // dead-reckoned features into the session map (observed 2026-07-24 M2 interruption test:
        // a room-sized scan saved a 223m feature cloud, poses written before the gap disagree
        // with the re-pinned mesh → misplaced vertex colors, offset ghost for the next scan).
        // ARKit tells us about interruptions directly — treat one mid-recording as a VIO trip:
        // halt capture and let the user save what was gathered before the gap, or discard.
        func sessionWasInterrupted(_ session: ARSession) {
            let recording = isRecording.load(ordering: .relaxed)
            PerfDiag.log("[Session] OS interruption began (recording=\(recording))")
            guard recording else { return }
            // Disarm the gap-based guard: the resume frame after this interruption will carry a
            // multi-second gap that would hard-trip it a second time — one halt/alert is enough.
            vioGuardArmed = false
            DispatchQueue.main.async { [weak self] in
                self?.vioCompromisedBinding?.wrappedValue = true
            }
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            PerfDiag.log("[Session] OS interruption ended")
        }

        /// Ask ARKit to relocalize to the session's own map after an interruption instead of
        /// resetting the world origin. Mid-recording we halt anyway (above), but for the benign
        /// cases — interruption while idle, during a ghost preview, or before the halt's stop/save
        /// flow grabs the world map — relocalizing preserves the existing frame (ghost alignment,
        /// anchor poses) rather than silently re-origining. A relocalization that can't succeed
        /// isn't a stuck-state risk: the halt path sets `needsTrackingReset`, which the next config
        /// run consumes as a full `.resetTracking`.
        func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            memDiagFrameCount &+= 1 // [MemDiag] frames/sample → measured FPS (the "visible slowdown")
            prodFrameCount &+= 1    // production fps → capacity bar (ungated)

            // [MemDiag] First frame carrying a segmentation buffer = the person-segmentation CoreML
            // model (enabled by the privacy filter / analysis mode) is loaded and resident. The delta
            // vs the preceding RECORD-START marker ≈ the model-load cost. See loggedSegModelReady.
            if PerfDiag.enabled, frame.segmentationBuffer != nil,
               loggedSegModelReady.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged {
                PerfDiag.log("[MemDiag] EVENT SEG-READY \(memMarker())")
            }

            // Pre-recording relocalization/alignment phase driver (no-op outside those phases).
            driveAlignmentPhase(frame)

            // 0.3: log the camera-pose discontinuities (the frame-correction "snap" baked
            // world:.zero overlays don't follow). No-op unless perfDiagnostics is on.
            if PerfDiag.enabled,
               let jump = locDiagSnap.observe(frame.camera.transform, tracking: frame.camera.trackingState) {
                DispatchQueue.main.async { [weak self] in
                    self?.locDiagSummary.recordSnap(dPos: jump.dPos, dRotDeg: jump.dRotDeg)
                }
            }

            // Item 2 (reframed 2026-06-25): mid-scan tracking-stability. A SINGLE non-physical jump is
            // benign — the saved mesh re-pins on export (see TrackingStabilityMonitor / [[saved-mesh-
            // repins-immune-to-snaps]]). But a STORM of them (self-similar-room relocalization oscillating
            // under nominal `.normal` tracking) is a real "session destabilized" collapse the VIO guard
            // misses. Only flag on the storm. Recording-only (when geometry is committed).
            if isRecording.load(ordering: .relaxed),
               let snap = trackingStability.observe(frame.camera.transform,
                                                    tracking: frame.camera.trackingState,
                                                    timestamp: frame.timestamp) {
                let count = trackingStability.snapCount
                PerfDiag.log(String(format: "[TrackStab] jump #%d: Δpos=%.1fcm Δrot=%.2f° (%.1f m/s)%@",
                                    count, snap.dPosM * 100, snap.dRotDeg, snap.velocityMS,
                                    snap.stormActive ? " — STORM (session destabilizing)" : " — isolated (benign; mesh re-pins)"))
                if snap.stormJustTriggered {
                    PerfDiag.log(String(format: "[TrackStab] SNAP STORM: ≥%d non-physical jumps within %.0fs under .normal tracking — relocalization oscillating / session destabilized (VIO guard misses this — tracking still reports normal)",
                                        TrackingStabilityMonitor.stormThreshold, TrackingStabilityMonitor.stormWindow))
                }
                if snap.stormActive {
                    let maxPosCm = trackingStability.maxSnapPosM * 100
                    let maxRotDeg = trackingStability.maxSnapRotDeg
                    DispatchQueue.main.async { [weak self] in
                        self?.scanStore?.trackingUnreliable = ScanStore.TrackingUnreliable(
                            snapCount: count, maxPosCm: maxPosCm, maxRotDeg: maxRotDeg)
                    }
                }
            }

            // 0.1: relocalization-settle detection — FSM-independent (runs for every flow/mode,
            // unlike driveAlignmentPhase which only engages for linkAdjacent). Against a loaded
            // map, the first `.normal` frame IS the relocalization lock; log the camera pose there
            // (re-stand at a marked spot across generations → the pose drifts by the compounding ε).
            // Reset per run via locDiagBeginRun() at map load — NOT at record-start — so the
            // alignment-time settle survives into recording.
            if PerfDiag.enabled, hasWorldMap.load(ordering: .relaxed) {
                let now = frame.timestamp
                if locDiagRelocStart == 0 { locDiagRelocStart = now }
                if case .limited(.relocalizing) = frame.camera.trackingState, !locDiagSawReloc {
                    locDiagSawReloc = true
                    DispatchQueue.main.async { [weak self] in self?.locDiagSummary.sawRelocalizing = true }
                }
                if frame.camera.trackingState == .normal, !locDiagLoggedSettle {
                    locDiagLoggedSettle = true
                    let secs = now - locDiagRelocStart
                    let sawReloc = locDiagSawReloc
                    LocalizationDiag.logSettle(camera: frame.camera, secondsToSettle: secs)
                    let t = frame.camera.transform
                    let pos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
                    let yaw = atan2(t.columns.2.x, t.columns.2.z) * 180 / .pi
                    DispatchQueue.main.async { [weak self] in
                        self?.locDiagSummary.recordSettle(pos: pos, yaw: yaw, secs: secs)
                        self?.locDiagSummary.sawRelocalizing = sawReloc
                    }
                }
            }

            // Billboard connector/boundary markers toward the camera (Track C). RealityKit mutations
            // must run on main; extract the camera transform here so the ARFrame isn't forwarded.
            // Gate the per-frame main hop on `hasBillboardMarkers` — true ONLY while markers are
            // actually in the scene — so normal scans (no connectors, no boundary) pay nothing.
            if hasBillboardMarkers.load(ordering: .relaxed) {
                let camTransform = frame.camera.transform
                DispatchQueue.main.async { [weak self] in
                    self?.updateConnectorBillboards(cameraTransform: camTransform)
                }
            }

            // ── Space Analysis: ambient light + person detection ──
            // Forward ambient light intensity to ScanStats every frame (cheap read). During analysis
            // mode, also detect person presence via segmentation stencil and forward the camera yaw
            // for 360° progress tracking. These are read by SpaceAnalyzer on main.
            if let lightEstimate = frame.lightEstimate {
                let intensity = lightEstimate.ambientIntensity
                // Person detection: segmentation buffer is only present when privacy filter is ON
                // (personSegmentationWithDepth is in frame semantics). When available, check if
                // any person pixels exist. SpaceAnalyzer handles the "privacy off" case separately.
                var hasPerson = false
                if let seg = frame.segmentationBuffer {
                    hasPerson = Self.hasPersonPixels(in: seg)
                }
                let yaw = frame.camera.eulerAngles.y // radians, ±π
                DispatchQueue.main.async { [weak self] in
                    guard let stats = self?.scanStats else { return }
                    stats.ambientIntensity = intensity
                    // Running average for the analysis report
                    stats.ambientLightSampleCount += 1
                    let n = CGFloat(stats.ambientLightSampleCount)
                    stats.averageAmbientIntensity = stats.averageAmbientIntensity * ((n - 1) / n) + intensity / n
                    // Person detection: latch true if ANY frame has person pixels
                    if hasPerson { stats.personDetectedDuringAnalysis = true }
                    // Yaw for 360° progress (stored as raw radians, SpaceAnalyzer tracks coverage)
                    stats.analysisYaw = yaw
                }
            }

            // Per-frame ARKit timing (runs in AR + VR, above the VR-only guard). The frame-delivery
            // gap is the direct signal that VIO was starved.
            let ts = frame.timestamp
            let frameGap = lastFrameTimestamp > 0 ? ts - lastFrameTimestamp : 0
            lastFrameTimestamp = ts
            lastFrameWallMs.store(Int64(CFAbsoluteTimeGetCurrent() * 1000), ordering: .relaxed)
            // Record-tap revive's second signal: when tracking was last in a record-ready state
            // (everything except the cold .initializing/.notAvailable the record gate blocks).
            switch frame.camera.trackingState {
            case .notAvailable, .limited(.initializing): break
            default: lastTrackingReadyWallMs.store(Int64(CFAbsoluteTimeGetCurrent() * 1000), ordering: .relaxed)
            }
            if PerfDiag.enabled, frameGap > 0.1 {
                let normal = frame.camera.trackingState == .normal
                PerfDiag.log("[PerfDiag] ARKit frame gap \(Int(frameGap * 1000))ms (tracking \(normal ? "normal" : "degraded"))")
            }

            // ── LiDAR mesh-start watchdog ──
            // Cost when healthy: one Bool check per frame (the first ARMeshAnchor in didAdd
            // latches sawMeshAnchorThisRecording within a second or two of any movement).
            // Fires at most once per recording; the main hop re-verifies that this recording
            // actually wants mesh (skips proxy-streaming and Lite-style configs).
            //
            // The budget starts at the recording's FIRST .normal tracking frame, not at
            // record-start: on a hot post-idle start VIO takes ~4s to initialize and the user is
            // primed by "hold steady" to stay still, so charging init time against the mesh
            // budget false-halted a recoverable scan at exactly 10s (2026-07-24 run 7 — the
            // anchors landed as the alert presented). A truly dead reconstruction still trips:
            // those scans reach .normal within ~2s and then stay meshless forever (run 6).
            if isRecording.load(ordering: .relaxed) {
                if recordStartTimestamp == 0 {
                    recordStartTimestamp = ts
                    meshWatchdogBaseline = 0
                    sawMeshAnchorThisRecording = false
                    meshWatchdogFired = false
                }
                if meshWatchdogBaseline == 0, frame.camera.trackingState == .normal {
                    meshWatchdogBaseline = ts
                }
                // Never-settled backstop: a recording whose tracking NEVER reaches .normal has
                // both graduated guards structurally unarmed (each waits for a first .normal
                // frame), so a session stuck chasing a relocalization sits degraded forever —
                // faces=0, no stillness, no trip (2026-07-28 A12Z). If .normal hasn't arrived
                // within the generous settle budget, the recording is unusable: halt.
                if meshWatchdogBaseline == 0, !meshWatchdogFired, ARCoverageView.supportsLiDAR,
                   ts - recordStartTimestamp > AppConstants.trackingSettleWatchdogSeconds {
                    meshWatchdogFired = true
                    vioGuardArmed = false
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let session = self.arView?.session,
                              let cfg = session.configuration as? ARWorldTrackingConfiguration,
                              cfg.sceneReconstruction != [],
                              !MetaWearableManager.shared.isStreaming else { return }
                        PerfDiag.log("⛔️ [Session] Tracking never settled \(Int(AppConstants.trackingSettleWatchdogSeconds))s into recording — halting scan")
                        self.vioCompromisedBinding?.wrappedValue = true
                    }
                }
                if !sawMeshAnchorThisRecording, !meshWatchdogFired, ARCoverageView.supportsLiDAR,
                   meshWatchdogBaseline > 0,
                   ts - meshWatchdogBaseline > AppConstants.meshStartWatchdogSeconds {
                    meshWatchdogFired = true
                    vioGuardArmed = false // one halt/alert is enough (re-arms on the next .normal frame)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let session = self.arView?.session,
                              let cfg = session.configuration as? ARWorldTrackingConfiguration,
                              cfg.sceneReconstruction != [],
                              !MetaWearableManager.shared.isStreaming else { return }
                        PerfDiag.log("⛔️ [Session] No mesh anchor \(Int(AppConstants.meshStartWatchdogSeconds))s after tracking settled — reconstruction is dead, halting scan")
                        self.vioCompromisedBinding?.wrappedValue = true
                    }
                }
            } else {
                recordStartTimestamp = 0
            }

            // ── VIO starvation guard ──
            // Once tracking has been .normal during recording (armed), trip if EITHER a large
            // frame-delivery gap was FOLLOWED by hard-degraded tracking (gap + the recovering frame
            // still notAvailable/excessiveMotion/insufficientFeatures → VIO diverged through the
            // stall) OR tracking stayed degraded continuously past a threshold for such a NON-recovery
            // reason. Data captured after VIO loss is corrupt, so we halt + prompt. **Relocalization
            // is the recovery we must wait for** — ARKit enters `.relocalizing` after a loss and it
            // routinely takes longer than vioDegradedTripSeconds, so (like `.initializing`) it is
            // benign and resets the timer rather than tripping. A bare frame gap does NOT trip: a
            // compute hiccup (not real VIO failure) drops frames yet resumes .normal, and cutting
            // those sessions was the false-positive we're fixing. See CaptureView.handleVIOCompromised().
            if isRecording.load(ordering: .relaxed) {
                switch frame.camera.trackingState {
                case .normal:
                    vioGuardArmed = true
                    vioDegradedSince = 0
                case .limited(.initializing), .limited(.relocalizing):
                    // Benign: startup or active relocalization recovery. Don't accumulate toward the
                    // sustained-degradation trip; give relocalization a fresh window to succeed.
                    vioDegradedSince = 0
                default:
                    if vioGuardArmed && vioDegradedSince == 0 { vioDegradedSince = ts }
                }
                if vioGuardArmed {
                    let sustainedDegraded = vioDegradedSince > 0 && (ts - vioDegradedSince) > AppConstants.vioDegradedTripSeconds
                    // A large frame gap alone is NOT proof VIO diverged. A compute stall (GPU/main-thread
                    // spike, heavy voxel/mesh burst) drops frames for >1.5s, yet ARKit resumes tracking
                    // cleanly — the old instant-trip-on-gap cut those sessions for nothing. The gap branch
                    // only ever evaluates on the FIRST frame after the gap (frames have already resumed),
                    // so inspect that frame: only treat the gap as a stall if tracking came back
                    // hard-degraded (notAvailable / excessiveMotion / insufficientFeatures). If it returned
                    // .normal — or .relocalizing/.initializing (actively recovering) — let it ride.
                    let recovered: Bool
                    switch frame.camera.trackingState {
                    case .normal, .limited(.relocalizing), .limited(.initializing): recovered = true
                    default: recovered = false
                    }
                    let stalled = frameGap > AppConstants.vioFrameGapTripSeconds && !recovered
                    // Belt for OS actions that stall delivery WITHOUT an interruption callback:
                    // Control Center on iPadOS fired no sessionWasInterrupted on either 2026-07-24
                    // run, and the 7.9s run-1 gap resumed via benign-looking .initializing (so
                    // `recovered` above excused it) while SLAM fully reinitialized underneath. A
                    // gap this large mid-recording means VIO dead-reckoned or reinitialized through
                    // it no matter how the recovery frame presents — halt unconditionally.
                    let hardStalled = frameGap > AppConstants.vioHardFrameGapTripSeconds
                    if sustainedDegraded || stalled || hardStalled {
                        vioGuardArmed = false // fire once per recording
                        vioDegradedSince = 0
                        let why = hardStalled ? "hard frame gap \(Int(frameGap * 1000))ms"
                            : stalled ? "frame gap \(Int(frameGap * 1000))ms"
                            : "tracking degraded >\(AppConstants.vioDegradedTripSeconds)s"
                        PerfDiag.log("⛔️ VIO guard tripped (\(why)) — halting scan")
                        DispatchQueue.main.async { [weak self] in
                            self?.vioCompromisedBinding?.wrappedValue = true
                        }
                    }
                }
            } else {
                vioGuardArmed = false
                vioDegradedSince = 0
            }

            // ── VR Mode: update point cloud ──
            // IMPORTANT: Extract pixel buffers and camera data HERE (on the delegate queue)
            // so the ARFrame reference is released immediately. Do NOT forward the ARFrame
            // to the main actor — that queues work and holds references to 10+ frames.
            //
            // Gate on `isRecording`: once the scan ends, stop the live point-cloud / voxel
            // pipeline immediately. Otherwise it keeps projecting + integrating every frame while
            // the AR view is still mounted (name prompt, post-scan processing), starving the main
            // thread/GPU — that's what made the keyboard take seconds to open after stopping.
            guard isRecording.load(ordering: .relaxed), captureMode == .vr, let pcm = pointCloudManager else { return }

            // Skip VR updates when tracking is degraded — prevents accumulating
            // voxels with wrong coordinates during SLAM re-initialization.
            guard frame.camera.trackingState == .normal else {
                // Clear accumulated voxels only for the states where the coordinate frame can
                // *shift* under us — relocalizing / initializing / notAvailable — since a
                // post-recovery correction would otherwise leave the old cloud baked in the
                // wrong frame (visibly flying off). excessiveMotion / insufficientFeatures keep
                // tracking in the same frame (just noisier), so don't wipe the viz for those.
                // Capture the tracking *state value* (not the ARFrame) before hopping to main —
                // forwarding `frame` into the closure would retain ARFrame memory.
                let state = frame.camera.trackingState
                let frameMayShift: Bool
                switch state {
                case .notAvailable: frameMayShift = true
                case .limited(.initializing), .limited(.relocalizing): frameMayShift = true
                default: frameMayShift = false
                }
                if frameMayShift {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, let pcm = self.pointCloudManager else { return }
                        pcm.resetVoxels()
                        // The wipe also cleared the grid's covered-cell set — re-push it so
                        // voxels re-accumulated over already-photographed surfaces don't
                        // demand redundant stills. (photoCoverageGrid is main-owned.)
                        pcm.applyPhotoCoverage(coveredCells: self.photoCoverageGrid.coveredPackedKeys())
                        print("[VR] Tracking degraded (frame may shift) — cleared accumulated voxels")
                    }
                }
                return
            }

            // Coalesce: if a main-actor dispatch is already pending, skip this frame.
            // This limits retained CVPixelBuffers to at most 2 (one in-flight GPU + one pending).
            guard !pendingVRUpdate else { return }

            let depthMap = frame.sceneDepth?.depthMap
            let confidenceMap = frame.sceneDepth?.confidenceMap
            let capturedImage = frame.capturedImage
            let segBuffer = privacyFilter ? frame.segmentationBuffer : nil
            let cameraTransform = frame.camera.transform
            let intrinsics = frame.camera.intrinsics
            let privFilter = privacyFilter
            // ARFrame reference is now released — only CVPixelBuffers are retained

            pendingVRUpdate = true
            DispatchQueue.main.async { [weak self] in
                pcm.update(
                    depthMap: depthMap,
                    capturedImage: capturedImage,
                    segBuffer: segBuffer,
                    confidenceMap: confidenceMap,
                    cameraTransform: cameraTransform,
                    intrinsics: intrinsics,
                    privacyFilter: privFilter
                )
                // Seamless transition: flip camera feed → black background on first rendered frame,
                // unless semantic labeling is on (keep camera feed to overlay RoomPlan outlines).
                let semanticOn = UserDefaults.standard.bool(forKey: AppConstants.Key.semanticLabeling)
                if !semanticOn,
                   !(self?.vrBackgroundSet ?? true),
                   pcm.hasRenderedFirstFrame,
                   let arView = self?.arView {
                    arView.environment.background = .color(.black)
                    self?.vrBackgroundSet = true
                }
                // Reset the coalescing flag on the delegate queue — its only owner (the guard above
                // reads it there), so it never races between main and the delegate queue.
                self?.sessionDelegateQueue.async { self?.pendingVRUpdate = false }
            }
        }

        // Track anchor update counts via delegate + build active mesh wireframe
        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            // Mesh-start watchdog: the first ARMeshAnchor proves Recon3D is alive this recording.
            if !sawMeshAnchorThisRecording, anchors.contains(where: { $0 is ARMeshAnchor }) {
                sawMeshAnchorThisRecording = true
            }
            // Detect boundary anchors from loaded ARWorldMap (visual marker only —
            // phase transitions are driven by tracking state in didUpdate frame).
            for anchor in anchors {
                if anchor.name == ARCoverageView.boundaryAnchorName {
                    // During a RESCAN, the named connector markers own in-scene rendering — they
                    // cover this same physical point WITH the connected map's name, plus every other
                    // connector. Drawing the legacy nameless boundary marker here would put a lone
                    // "Connector" over the relocalized map instead of the named set, so skip it.
                    if scanStore?.activeScanCase == .rescanSpace {
                        continue
                    }
                    print("[BoundaryAnchor] Detected boundary anchor from ARWorldMap: \(anchor.identifier)")
                    boundaryAnchorId = anchor.identifier
                    DispatchQueue.main.async { [weak self] in
                        self?.scanStore?.boundaryAnchorTransform = anchor.transform
                        self?.scanStore?.boundaryAnchorId = anchor.identifier
                        self?.scanStats?.hasBoundaryAnchor = true

                        // Render the existing boundary anchor (must be on main thread
                        // because RealityKit scene mutations are not thread-safe)
                        if let arView = self?.arView {
                            self?.addBoundaryAnchorVisual(at: anchor.transform, in: arView)
                        }
                    }
                }
            }

            // Phase-2.1 precursor: feed the ICP during the pre-record alignment phase, so the
            // relocalization offset is measured at the moment 2.1 will bake the correction. Mesh is
            // only enabled pre-record when perfDiag is on (see makeConfiguration); gate on a
            // relocalized world map so the verts are already in the map frame. The probe is one-shot
            // (locDiagRanICP) — whichever of this or the recording path hits the vertex budget first
            // wins, and during alignment it's this one. No-op in production.
            if PerfDiag.enabled, hasWorldMap.load(ordering: .relaxed), hasSeenRelocalizing.load(ordering: .relaxed), !isRecording.load(ordering: .relaxed) {
                for case let mesh as ARMeshAnchor in anchors { locDiagSampleAnchorForICP(mesh) }
            }

            // Ghost auto-align: collect classified plane anchors (alignment phase — planeDetection
            // is only on pre-record) and opportunistically re-fit the ghost seat.
            for case let plane as ARPlaneAnchor in anchors { livePlaneAnchors[plane.identifier] = plane }
            maybeRunGhostAutoAlign()

            guard isRecording.load(ordering: .relaxed) else { return }
            for anchor in anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    anchorUpdateCounts[mesh.identifier] = 1
                    anchorVertexCounts[mesh.identifier] = mesh.geometry.vertices.count
                    anchorFaceCounts[mesh.identifier] = mesh.geometry.faces.count
                    buildWireframeForAnchor(mesh)
                    locDiagSampleAnchorForICP(mesh) // 0.2 ICP feed (AR + VR; no-op unless perfDiag)
                }
            }
            updateStats(in: session)
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            for anchor in anchors {
                // Always refresh boundary anchor transform — ARKit refines anchor
                // positions during relocalization, and the alignment UI needs the
                // latest position even before recording starts.
                if anchor.name == ARCoverageView.boundaryAnchorName {
                    let transform = anchor.transform
                    DispatchQueue.main.async { [weak self] in
                        self?.scanStore?.boundaryAnchorTransform = transform
                        // Move the visual marker to match the refined anchor position
                        let pos = SIMD3<Float>(transform.columns.3.x,
                                               transform.columns.3.y,
                                               transform.columns.3.z)
                        self?.boundaryAnchorEntity?.transform.translation = pos
                    }
                }
            }

            // Phase-2.1 precursor: feed the ICP during the pre-record alignment phase (see didAdd).
            if PerfDiag.enabled, hasWorldMap.load(ordering: .relaxed), hasSeenRelocalizing.load(ordering: .relaxed), !isRecording.load(ordering: .relaxed) {
                for case let mesh as ARMeshAnchor in anchors { locDiagSampleAnchorForICP(mesh) }
            }

            // Ghost auto-align: ARKit refines plane anchors continuously — refresh + re-fit (see didAdd).
            for case let plane as ARPlaneAnchor in anchors { livePlaneAnchors[plane.identifier] = plane }
            maybeRunGhostAutoAlign()

            guard isRecording.load(ordering: .relaxed) else { return }
            for anchor in anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    anchorUpdateCounts[mesh.identifier, default: 0] += 1
                    anchorVertexCounts[mesh.identifier] = mesh.geometry.vertices.count
                    anchorFaceCounts[mesh.identifier] = mesh.geometry.faces.count
                    buildWireframeForAnchor(mesh)
                    locDiagSampleAnchorForICP(mesh) // 0.2 ICP feed (AR + VR; no-op unless perfDiag)
                }
            }
            updateStats(in: session)
        }

        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            // Ghost auto-align: drop removed planes (ARKit merges planes; also .removeExistingAnchors).
            for case let plane as ARPlaneAnchor in anchors { livePlaneAnchors.removeValue(forKey: plane.identifier) }

            guard isRecording.load(ordering: .relaxed) else { return }
            for anchor in anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    let id = mesh.identifier
                    anchorUpdateCounts.removeValue(forKey: id)
                    anchorVertexCounts.removeValue(forKey: id)
                    anchorFaceCounts.removeValue(forKey: id)
                    lastAnchorWireframeTime.removeValue(forKey: id)

                    // Remove the wireframe entity on main — RealityKit is main-only.
                    // (anchorVoxels/photoCoveredAnchors are main-owned too.)
                    DispatchQueue.main.async { [weak self] in
                        if let entry = self?.activeMeshEntities.removeValue(forKey: id) {
                            entry.anchor.removeFromParent()
                        }
                        self?.anchorVoxels.removeValue(forKey: id)
                        self?.photoCoveredAnchors.remove(id)
                        self?.lastTintBuildTime.removeValue(forKey: id)
                    }
                }
            }
            updateStats(in: session)
        }

        func removeAllMeshEntities() {
            // activeMeshEntities + RealityKit on main (this is called from updateUIView).
            for (_, entry) in activeMeshEntities {
                entry.anchor.removeFromParent()
            }
            activeMeshEntities.removeAll()
            lastTintBuildTime.removeAll()
            // Delegate-owned dicts → clear on the delegate queue (the ARSession callbacks mutate
            // them; concurrent mutation from main would crash). Clear ALL per-anchor dicts together,
            // including the vertex/face counts — otherwise updateStats keeps summing stale geometry
            // totals and anchor counts after the entities are gone (e.g. switching into VR capture).
            sessionDelegateQueue.async { [weak self] in
                self?.lastAnchorWireframeTime.removeAll()
                self?.anchorUpdateCounts.removeAll()
                self?.anchorVertexCounts.removeAll()
                self?.anchorFaceCounts.removeAll()
            }
        }

        private func updateStats(in session: ARSession) {
            guard let scanStats = scanStats else { return }

            // Throttle to ~10 Hz. Delegate callbacks are serialized on the ARSession
            // queue, so this timestamp needs no synchronization. Resets (on stop) write
            // scanStats directly and bypass this path, so they remain immediate.
            let now = Date()
            let wasFirstSample = lastStatsUpdateTime == .distantPast // reset() seeds .distantPast
            let fpsElapsed = now.timeIntervalSince(lastStatsUpdateTime) // window since last publish
            guard fpsElapsed >= statsUpdateInterval else { return }
            lastStatsUpdateTime = now

            // PRODUCTION fps → capacity bar (ungated). Frames this window / elapsed, EMA-smoothed
            // (~sub-second) so a single stall doesn't slam the bar but a sustained drop does. updateStats
            // is driven by frame callbacks, so when fps craters this fires less often and the window
            // widens — the ratio stays correct, and a genuine multi-second stall MUST decay the EMA
            // (that stall is the signal). So we skip only the first post-reset sample (huge .distantPast
            // gap) and app-suspend-scale gaps (>10s, frames paused, not slow); everything in between
            // — including a 2–8s hang — folds in and correctly drops fpsPressure.
            let frames = prodFrameCount
            prodFrameCount = 0
            if !wasFirstSample, fpsElapsed > 0, fpsElapsed < 10 {
                let instantFPS = Double(frames) / fpsElapsed
                smoothedFPSValue = smoothedFPSValue <= 0 ? instantFPS : smoothedFPSValue * 0.8 + instantFPS * 0.2
            }
            let smoothedFPS = smoothedFPSValue
            // Configured capture rate — fpsPressure is measured RELATIVE to this (30/30 is healthy, not
            // "half speed"). Read off the live session so a format switch is reflected without plumbing.
            let targetFPS = Double(session.configuration?.videoFormat.framesPerSecond ?? 60)

            // ── Extract worldMappingStatus in a tight scope ──
            // Only read the enum value; do NOT iterate frame.anchors or access
            // ARMeshAnchor.geometry — those buffers pin ARFrame memory alive and
            // cause "retaining N ARFrames" warnings that starve the SLAM pipeline.
            var statusStr = "notAvailable"
            if let status = session.currentFrame?.worldMappingStatus {
                switch status {
                case .mapped: statusStr = "mapped"
                case .extending: statusStr = "extending"
                case .limited: statusStr = "limited"
                case .notAvailable: statusStr = "notAvailable"
                @unknown default: statusStr = "notAvailable"
                }
            }
            // session.currentFrame released — no geometry buffers accessed

            // Use pre-tracked per-anchor counts from delegate callbacks.
            // These are maintained in didAdd/didUpdate/didRemove where anchor
            // data is valid for the callback duration — no extra retention.
            let totalVerts = anchorVertexCounts.values.reduce(0, +)
            let totalFaces = anchorFaceCounts.values.reduce(0, +)
            let anchorCount = anchorVertexCounts.count
            let totalUpdates = anchorUpdateCounts.values.reduce(0, +)

            // Compute capacity metrics. ONE TASK_VM_INFO fetch → footprint + resident + compressed
            // (the perfDiag block below reuses vm.* instead of re-issuing the same syscall per field).
            let duration = Date().timeIntervalSince(sessionStartTime)
            let vm = ScanStats.currentVMInfoMB()
            let memoryMB = vm.resident
            let footprintMB = vm.footprint                            // capacity bar: true ceiling
            let availableMB = ScanStats.currentAvailableMemoryMB()
            let drift: Double = totalTrackingUpdates > 0
                ? min(Double(trackingDegradationCount) / Double(totalTrackingUpdates), 1.0)
                : 0

            // ── Production CPU sample for the capacity bar (ungated, ~1 Hz, EMA) ──
            // The LEADING compute-saturation signal (see ScanStats.cpuPressure). Must run with PerfDiag
            // OFF, so it lives here, not in the diag block below. Throttled because currentCPUUsagePercent
            // walks the thread list; smoothed because raw CPU% swings hard tick-to-tick.
            if now.timeIntervalSince(lastCPUSampleTime) >= cpuSampleInterval {
                let instantCPU = ScanStats.currentCPUUsagePercent()
                smoothedCPUValue = smoothedCPUValue <= 0 ? instantCPU : smoothedCPUValue * 0.7 + instantCPU * 0.3
                lastCPUSampleTime = now
            }
            let smoothedCPU = smoothedCPUValue

            // ── [MemDiag] RoomPlan memory timeline (perfDiag-gated, ~1 Hz) ──
            // Runs on the ARSession delegate queue, so anchor{Vertex,Face}Counts are read safely
            // here (same queue that mutates them). Logs phys_footprint (the OOM metric) + resident
            // + mesh size + RoomPlan on/off so the ON-vs-OFF A/B can attribute the peak to RoomPlan
            // vs. the co-resident mesh. rp is read from the toggle (thread-safe), not the session ptr.
            if PerfDiag.enabled, now.timeIntervalSince(lastMemDiagLogTime) >= memDiagLogInterval {
                // FPS over the elapsed window (capture BEFORE bumping lastMemDiagLogTime). Thermal
                // state is the SoC throttle level — the CPU/compute limit, distinct from the OOM limit.
                let elapsed = now.timeIntervalSince(lastMemDiagLogTime)
                let fps = elapsed > 0 && elapsed < 1000 ? Double(memDiagFrameCount) / elapsed : 0
                memDiagFrameCount = 0
                lastMemDiagLogTime = now
                let footprint = footprintMB                        // reuse the single VM-info fetch above
                let compressed = vm.compressed                     // rising = compressor churn (slowdown suspect)
                let avail = availableMB                            // headroom to THIS device's jetsam limit
                let cpu = ScanStats.currentCPUUsagePercent()
                let rpOn = UserDefaults.standard.bool(forKey: AppConstants.Key.semanticLabeling)
                let thermal: String
                switch ProcessInfo.processInfo.thermalState {
                case .nominal: thermal = "nominal"
                case .fair: thermal = "fair"
                case .serious: thermal = "serious"
                case .critical: thermal = "critical"
                @unknown default: thermal = "?"
                }
                PerfDiag.log(String(format: "[MemDiag] t=%.0fs footprint=%.0fMB compressed=%.0fMB avail=%.0fMB resident=%.0fMB faces=%d verts=%d anchors=%d fps=%.0f cpu=%.0f%% thermal=%@ rp=%@",
                                    duration, footprint, compressed, avail, memoryMB, totalFaces, totalVerts, anchorCount, fps, cpu, thermal, rpOn ? "on" : "off"))
                // Second line: per-thread CPU attribution — which subsystem/queue is burning the cores.
                // The end-of-scan FPS collapse is compute-bound (not memory/thermal), so this is the
                // signal that says WHICH pass to optimize. Separate line to keep the main line parseable.
                PerfDiag.log("[MemDiag]   cpu-by-thread: \(ScanStats.currentCPUByThreadString())")
            }

            DispatchQueue.main.async { [weak self] in
                scanStats.totalVertices = totalVerts
                scanStats.totalFaces = totalFaces
                scanStats.anchorCount = anchorCount
                scanStats.sessionDuration = duration
                scanStats.memoryUsageMB = memoryMB
                scanStats.baselineMemoryMB = self?.baselineMemoryMB ?? memoryMB
                scanStats.footprintMB = footprintMB      // capacity bar: avail-based memoryPressure
                scanStats.availableMB = availableMB
                scanStats.smoothedFPS = smoothedFPS      // capacity bar: fpsPressure
                scanStats.targetFPS = targetFPS          // capacity bar: fpsPressure ceiling (relative)
                scanStats.cpuPercent = smoothedCPU       // capacity bar: cpuPressure (leading compute axis)
                scanStats.driftEstimate = drift
                scanStats.mappingStatus = statusStr
                if anchorCount > 0 {
                    let avgUpdates = Double(totalUpdates) / Double(anchorCount)
                    scanStats.averageQuality = min(avgUpdates / 10.0, 1.0)
                } else {
                    scanStats.averageQuality = 0.0
                }
            }
        }

        /// [MemDiag] one footprint+compressed+avail+resident snapshot for lifecycle event markers.
        /// Only mach `task_info` / `os_proc_available_memory` calls → thread-safe from any queue (main /
        /// delegate / RoomPlan). Wrapped in the `PerfDiag.log` autoclosure at every call site, so it
        /// costs nothing when diagnostics are off. Because it carries footprint, the paired enter/exit
        /// markers around a teardown step give the free-delta (see the teardown brackets in
        /// CaptureView+Recording) — the cleanest per-subsystem memory attribution we have.
        /// `fileprivate` (not `private`) so `updateUIView` (ARCoverageView struct) can bracket record-start.
        fileprivate func memMarker() -> String {
            String(format: "footprint=%.0fMB compressed=%.0fMB avail=%.0fMB resident=%.0fMB cpu=%.0f%%",
                   ScanStats.currentFootprintMB(), ScanStats.currentCompressedMB(), ScanStats.currentAvailableMemoryMB(),
                   ScanStats.currentMemoryUsageMB(), ScanStats.currentCPUUsagePercent())
        }

        // MARK: - Connector Markers (Track C)

        /// Adds the single-link boundary marker at `transform`, labeled with the linked map's name
        /// (falls back to a generic label). Kept as the call site used by the new-link / Pin B flow
        /// and the ARWorldMap boundary-anchor didAdd path. Backed by `addConnectorMarker`, tracked
        /// in `boundaryAnchorEntity` (so the existing remove/refresh logic continues to work).
        func addBoundaryAnchorVisual(at transform: simd_float4x4, in arView: ARView, name: String = "Connector") {
            // Remove existing boundary visual if any
            if let existing = boundaryAnchorEntity {
                existing.removeFromParent()
            }
            let marker = makeConnectorMarker(name: name, transform: transform)
            arView.scene.addAnchor(marker)
            boundaryAnchorEntity = marker
            refreshHasBillboardMarkers()
        }

        /// Renders all connectors for a rescan: one labeled marker per `ConnectorAnchor`.
        /// Clears any previously-rendered connector markers first so repeated calls don't stack.
        /// Each ConnectorAnchor's `transform` is already in the relocalized session's world frame.
        func renderConnectorMarkers(_ anchors: [ConnectorAnchor], in arView: ARView) {
            removeConnectorMarkers()
            for anchor in anchors {
                let marker = makeConnectorMarker(name: anchor.otherLocationName, transform: anchor.transform)
                arView.scene.addAnchor(marker)
                connectorMarkerEntities.append(marker)
            }
            refreshHasBillboardMarkers()
        }

        /// Removes all rescan connector markers from the scene.
        func removeConnectorMarkers() {
            for marker in connectorMarkerEntities {
                marker.removeFromParent()
            }
            connectorMarkerEntities.removeAll()
            refreshHasBillboardMarkers()
        }

        /// Builds a labeled connector marker at the anchor's world position. The marker reads as a
        /// CONNECTOR: a "link.circle.fill" SF Symbol rendered to a textured UnlitMaterial quad, with
        /// the other map's name as floating 3D text just above it. Only UnlitMaterial composites
        /// reliably in the AR video pipeline, so both the icon and the text use it (no
        /// CustomMaterial/PBR). The returned AnchorEntity's single child (`billboardRoot`) is named
        /// so the per-frame billboard pass (session(_:didUpdate:)) can rotate it toward the camera.
        private func makeConnectorMarker(name: String, transform: simd_float4x4) -> AnchorEntity {
            let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let anchorEntity = AnchorEntity(world: position)

            // A single root the billboard pass spins to face the camera; icon + label hang off it.
            let billboardRoot = Entity()
            billboardRoot.name = "connector_billboard"

            // Bright connector accent — high luminance + saturation so the glyph reads against
            // typical indoor walls/floors (the old 0.0,0.95,0.4 looked muddy/"dark" on light scenes).
            let accent = UIColor(red: 0.15, green: 1.0, blue: 0.55, alpha: 1.0)

            // ── Icon: a dark disc scrim with a BRIGHT link glyph on top — the same positive
            // treatment as the label (bright foreground over a translucent dark backing) so the two
            // read consistently. (The old approach layered the glyph as a punched-out hole over a
            // dark quad, which read as "black disc, transparent link.") UnlitMaterial throughout —
            // the only material that composites reliably over the AR camera feed. ──
            let iconSize: Float = 0.133
            let discMesh = MeshResource.generatePlane(width: iconSize, height: iconSize, cornerRadius: iconSize / 2)
            var discMaterial = UnlitMaterial(color: .black)
            discMaterial.blending = .transparent(opacity: 0.72) // matches the label scrim
            let discEntity = ModelEntity(mesh: discMesh, materials: [discMaterial])
            billboardRoot.addChild(discEntity)

            if let texture = Self.connectorGlyphTexture {
                // Baked white silhouette (centered in a square, transparent elsewhere) → tint sets
                // the color. Sits just in front of the disc so it's a bright glyph ON the scrim.
                let glyphMesh = MeshResource.generatePlane(width: iconSize, height: iconSize)
                var glyphMaterial = UnlitMaterial(color: accent)
                glyphMaterial.color = .init(tint: accent, texture: .init(texture))
                glyphMaterial.blending = .transparent(opacity: 1.0)
                glyphMaterial.opacityThreshold = 0.05
                let glyphEntity = ModelEntity(mesh: glyphMesh, materials: [glyphMaterial])
                glyphEntity.position = SIMD3<Float>(0, 0, 0.001)
                billboardRoot.addChild(glyphEntity)
            }

            // ── Floating 3D name label above the icon, on a dark rounded backing panel so the white
            // text stays readable over any background (the standard AR "label pill"). generateText is
            // extruded; size it to a ~5cm cap height. UnlitMaterial again for AR compositing. ──
            // `containerFrame: .zero` means generateText won't truncate, so bound the string
            // ourselves — a long map name would otherwise render as one very wide 3D label.
            let label = name.count > 24 ? name.prefix(23) + "…" : Substring(name)
            let textMesh = MeshResource.generateText(
                String(label),
                extrusionDepth: 0.001,
                font: .systemFont(ofSize: 0.066, weight: .semibold),
                containerFrame: .zero,
                alignment: .center,
                lineBreakMode: .byTruncatingTail
            )
            let textEntity = ModelEntity(mesh: textMesh, materials: [UnlitMaterial(color: .white)])
            // generateText origins at the baseline (NOT the box bottom), so the mesh's bounds are
            // offset from the entity origin — using only `extents` to place a backing panel leaves
            // the glyphs riding high with a gap below. Use the mesh's `bounds.center` to land the
            // text's true visual center at a known point, then center the panel on that same point.
            let textBounds = textEntity.model?.mesh.bounds ?? .init(min: .zero, max: .zero)
            let textExtents = textBounds.extents
            let textCenter = textBounds.center
            let labelCenterY = iconSize / 2 + 0.025 + textExtents.y / 2
            textEntity.position = SIMD3<Float>(-textCenter.x, labelCenterY - textCenter.y, 0)

            // Dark rounded panel behind the label (sized to the text + padding) for contrast,
            // centered exactly on the text's visual center for even margins all around.
            let padX: Float = 0.016
            let padY: Float = 0.012
            let panelW = max(textExtents.x, 0.02) + padX * 2
            let panelH = max(textExtents.y, 0.02) + padY * 2
            let panelMesh = MeshResource.generatePlane(width: panelW, height: panelH, cornerRadius: panelH * 0.35)
            var panelMaterial = UnlitMaterial(color: .black)
            panelMaterial.blending = .transparent(opacity: 0.72)
            let panelEntity = ModelEntity(mesh: panelMesh, materials: [panelMaterial])
            panelEntity.position = SIMD3<Float>(0, labelCenterY, -0.001)
            billboardRoot.addChild(panelEntity)
            billboardRoot.addChild(textEntity)

            anchorEntity.addChild(billboardRoot)
            return anchorEntity
        }

        /// The plain "link" glyph baked once as a WHITE silhouette centered in a SQUARE, transparent
        /// canvas, uploaded to the GPU a single time. The `link` symbol is wider than tall, so it's
        /// drawn centered into a square (≈70% fill) to avoid distortion when mapped onto a square
        /// plane and to leave margin inside the disc. Baking it white lets each marker's UnlitMaterial
        /// tint pick the color without re-rendering the SF Symbol per connector at record-start.
        private static let connectorGlyphTexture: TextureResource? = {
            let side: CGFloat = 128
            let config = UIImage.SymbolConfiguration(pointSize: side * 0.62, weight: .bold)
            guard let symbol = UIImage(systemName: "link", withConfiguration: config)?
                .withTintColor(.white, renderingMode: .alwaysOriginal) else { return nil }
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            format.scale = 1
            let squared = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
                let origin = CGPoint(x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2)
                symbol.draw(in: CGRect(origin: origin, size: symbol.size))
            }
            guard let cgImage = squared.cgImage else { return nil }
            return try? TextureResource(image: cgImage, options: .init(semantic: .color))
        }()

        /// Rotates every connector/boundary marker's billboard root to face the camera. Called once
        /// per ARFrame from session(_:didUpdate:). Cheap (a handful of markers); a no-op when none.
        func updateConnectorBillboards(cameraTransform: simd_float4x4) {
            let camPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
            var roots: [Entity] = connectorMarkerEntities.compactMap { $0.children.first }
            if let boundaryRoot = boundaryAnchorEntity?.children.first { roots.append(boundaryRoot) }
            guard !roots.isEmpty else { return }
            for root in roots {
                let markerPos = root.position(relativeTo: nil)
                var toCam = camPos - markerPos
                toCam.y = 0 // keep the marker upright; yaw-only billboard so text stays level
                guard simd_length(toCam) > 0.0001 else { continue }
                // Yaw the +Z face toward the camera directly. `simd_quatf(from:to:)` is degenerate
                // when the two vectors are antiparallel (camera behind the marker along -Z → NaN /
                // arbitrary-axis flip), so derive the yaw angle instead — well-defined everywhere.
                let yaw = atan2(toCam.x, toCam.z)
                root.orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))

                // Distance-compensated scaling: hold a roughly constant apparent size so the marker
                // stays legible far away (the main "underwhelming visibility" fix) without ballooning
                // up close. Scale ∝ full 3D distance, normalized so it's 1× at the design distance,
                // then clamped. Uses the full distance (incl. Y) since apparent size depends on it.
                let dist = simd_length(camPos - markerPos)
                let referenceDistance: Float = 2.0
                let scale = min(max(dist / referenceDistance, 0.8), 2.75)
                root.scale = SIMD3<Float>(repeating: scale)
            }
        }
    }

    // MARK: - Export

    /// Result of a mesh export.
    struct MeshExportResult {
        let data: Data
        let vertexCount: Int
        let faceCount: Int
        /// DECISION 3: per-face ARMeshClassification labels, ONE BYTE PER EMITTED FACE in mesh.obj
        /// face order (privacy-skipped and invalid faces are skipped here too, so the mapping can't
        /// desync). nil when no anchor carried classification (classifier off/unsupported) — the
        /// postprocess proxy build then has nothing to subtract with and is skipped. Persisted as
        /// `face_classes.bin` beside the mesh.
        let faceClasses: Data?

        init(data: Data, vertexCount: Int, faceCount: Int, faceClasses: Data? = nil) {
            self.data = data
            self.vertexCount = vertexCount
            self.faceCount = faceCount
            self.faceClasses = faceClasses
        }
    }

    /// Combined result of the ghost-proxy builder — both the full proxy (content mesh + RoomPlan
    /// quads standing in for walls/floors) AND the dynamic mesh (content faces only, no
    /// infrastructure). The dynamic mesh is the "4D" artifact: everything that isn't fixed room
    /// structure, so scrubbing across rescans shows only what changed between visits.
    struct GhostProxyBuildResult {
        /// `mesh_proxy.obj` — content mesh + RoomPlan wall/floor grid quads.
        let proxy: MeshExportResult
        /// `mesh_dynamic.obj` — content mesh only (no walls, floors, ceilings, or RoomPlan quads).
        let dynamic: MeshExportResult
        /// Walkable levels recovered from the classified mesh, for `derived_surfaces.json`. NOT
        /// deduped against RoomPlan's floor: dropping the one that duplicates it is a baking concern
        /// (two quads at one height), whereas the sidecar wants the complete set of levels in the scan.
        let levels: [PlaneRegistration.Plane]
        /// Sloped walkable planes recovered from the same mesh, same purpose.
        let ramps: [PlaneRegistration.Plane]
    }

    /// Raw, co-framed buffer snapshot taken on the main/AR thread the instant recording stops.
    /// Holds *copies* (by value) of the live ARFrame's mesh vertex/face buffers, the segmentation
    /// pixels, and the camera matrices — so nothing here references recycled ARKit memory and the
    /// whole thing is safe to hand to a background thread. Taking the snapshot is just a handful of
    /// memcpys (cheap, safe on main at Stop). ALL the expensive work — the per-vertex world
    /// transform, the privacy person-projection, and the float→string OBJ formatting — is deferred
    /// to `buildMeshOBJ(from:)` off-main. This snapshot-at-Stop is what keeps mesh + segmentation
    /// co-framed (same instant, same world frame) while moving the cost off the main thread.
    struct RawMeshSnapshot: Sendable {
        struct Anchor: Sendable {
            let transform: simd_float4x4
            let vertexData: Data            // raw vertex buffer bytes (vertexCount * vertexStride)
            let vertexCount: Int
            let vertexStride: Int
            let faceData: Data              // raw face buffer bytes (faceCount * faceBytesPerPrimitive)
            let faceCount: Int
            let faceBytesPerPrimitive: Int  // bytesPerIndex * indexCountPerPrimitive
            let faceFormatValid: Bool       // bytesPerIndex == 4 && indexCountPerPrimitive == 3
            // Per-face ARMeshClassification bytes (faceCount * classificationStride, one uchar per
            // face at each stride step). nil when `.meshWithClassification` wasn't active — the
            // ghost-proxy build then bails and the rescan overlay falls back to the full mesh.
            let classificationData: Data?
            let classificationStride: Int
        }
        struct Segmentation: Sendable {
            let pixels: Data
            let width: Int
            let height: Int
            let stride: Int
        }
        let anchors: [Anchor]
        let viewMatrix: simd_float4x4
        let projMatrix: simd_float4x4
        let segmentation: Segmentation?     // non-nil only when privacy filtering is on
    }

    /// Snapshot the live mesh / segmentation / camera state on the main thread — fast memcpys only,
    /// no transforms or projection. See `RawMeshSnapshot` for why the split exists. Returns nil when
    /// there's no mesh to export (no ARMeshAnchors with vertices), matching the old empty-OBJ guard.
    static func snapshotMeshBuffers(from currentFrame: ARFrame?, privacyFilter: Bool = false) -> RawMeshSnapshot? {
        guard let currentFrame = currentFrame else { return nil }

        // Copy the person-segmentation pixels (privacy filtering) while the buffer is locked, then
        // unlock immediately. The per-vertex projection that consumes them runs later, off-main,
        // against this copy — so the live buffer is held for only the duration of one memcpy.
        var segmentation: RawMeshSnapshot.Segmentation?
        if privacyFilter, let segBuffer = currentFrame.segmentationBuffer {
            CVPixelBufferLockBaseAddress(segBuffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(segBuffer) {
                let height = CVPixelBufferGetHeight(segBuffer)
                let stride = CVPixelBufferGetBytesPerRow(segBuffer)
                segmentation = RawMeshSnapshot.Segmentation(
                    pixels: Data(bytes: base, count: height * stride),
                    width: CVPixelBufferGetWidth(segBuffer),
                    height: height,
                    stride: stride
                )
            }
            CVPixelBufferUnlockBaseAddress(segBuffer, .readOnly)
        }

        let camera = currentFrame.camera
        // .landscapeRight: the mesh vertices are projected into the segmentation buffer's coordinate
        // space, which is always native sensor orientation (landscape-right), independent of display
        // orientation. (AR-mode export; VR mode uses PointCloudManager.) See FaceBlurOverlay.swift
        // for the full orientation architecture. These matrices are snapshotted here so the off-main
        // projection uses the Stop-instant camera, co-framed with the mesh.
        let viewMatrix = camera.viewMatrix(for: .landscapeRight)
        let imageRes = camera.imageResolution
        let projMatrix = camera.projectionMatrix(for: .landscapeRight, viewportSize: imageRes, zNear: 0.001, zFar: 100)

        var anchors: [RawMeshSnapshot.Anchor] = []
        var totalVertices = 0
        for anchor in currentFrame.anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            let geometry = meshAnchor.geometry
            let vertices = geometry.vertices
            let faces = geometry.faces
            guard vertices.count > 0 else { continue }

            let faceBytesPerPrimitive = faces.bytesPerIndex * faces.indexCountPerPrimitive
            // memcpy the raw buffers. Data(bytes:count:) copies, so these survive ARFrame recycling.
            // Copy exactly count*stride / count*faceBytes bytes; the off-main reader stays in bounds.
            let vertexData = Data(bytes: vertices.buffer.contents(), count: vertices.count * vertices.stride)
            let faceData = Data(bytes: faces.buffer.contents(), count: faces.count * faceBytesPerPrimitive)

            // Per-face classification (present iff .meshWithClassification) — one more memcpy,
            // consumed by the ghost-proxy build (wall/floor/ceiling subtraction) at save.
            var classificationData: Data?
            var classificationStride = 0
            if let cls = geometry.classification, cls.count == faces.count {
                classificationData = Data(bytes: cls.buffer.contents().advanced(by: cls.offset),
                                          count: cls.count * cls.stride)
                classificationStride = cls.stride
            }

            anchors.append(RawMeshSnapshot.Anchor(
                transform: meshAnchor.transform,
                vertexData: vertexData,
                vertexCount: vertices.count,
                vertexStride: vertices.stride,
                faceData: faceData,
                faceCount: faces.count,
                faceBytesPerPrimitive: faceBytesPerPrimitive,
                faceFormatValid: faces.bytesPerIndex == 4 && faces.indexCountPerPrimitive == 3,
                classificationData: classificationData,
                classificationStride: classificationStride
            ))
            totalVertices += vertices.count
        }

        guard totalVertices > 0 else { return nil }

        return RawMeshSnapshot(
            anchors: anchors, viewMatrix: viewMatrix, projMatrix: projMatrix, segmentation: segmentation
        )
    }

    /// Turn a `RawMeshSnapshot` into OBJ text. Pure CPU work over copied buffers — no live ARKit
    /// dependency — so this is intended to run OFF the main thread. This is where the old main-thread
    /// freeze now lives: the per-vertex world transform, the privacy person-projection, and the
    /// float→string formatting for ~300K+ vertices. Output is byte-identical to the historical
    /// on-main exporter (per-anchor `v` lines then `f` lines, 1-based indices with a running offset).
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func buildMeshOBJ(from snapshot: RawMeshSnapshot) -> MeshExportResult? {
        let viewMatrix = snapshot.viewMatrix
        let projMatrix = snapshot.projMatrix
        let seg = snapshot.segmentation

        // Write OBJ directly to a Data buffer to avoid an intermediate [String] array and the large
        // joined String copy. For large meshes (~300K+ vertices) this roughly halves peak memory.
        var objData = Data()
        objData.reserveCapacity(1024 * 1024)
        var vertexOffset = 1
        var totalVertices = 0
        var totalFaces = 0
        // DECISION 3: face-aligned classification sidecar — one label byte appended per face WRITTEN
        // to the OBJ (same skip logic), so index i in this buffer is face i in mesh.obj forever.
        // Emitted iff any anchor carries classification; anchors without it contribute 0 (= none).
        let anyClassification = snapshot.anchors.contains { $0.classificationData != nil }
        var faceClasses = Data()
        if anyClassification { faceClasses.reserveCapacity(256 * 1024) }

        for anchor in snapshot.anchors {
            let transform = anchor.transform
            let vCount = anchor.vertexCount
            let vStride = anchor.vertexStride
            var isPersonVertex = [Bool](repeating: false, count: vCount)

            anchor.vertexData.withUnsafeBytes { (vBuf: UnsafeRawBufferPointer) in
                for idx in 0..<vCount {
                    let base = idx * vStride
                    // Read x/y/z as three 4-byte floats (12 bytes) — the lanes the original SIMD3
                    // read actually used — so we never over-read past the copied count*stride bytes.
                    let x = vBuf.loadUnaligned(fromByteOffset: base, as: Float.self)
                    let y = vBuf.loadUnaligned(fromByteOffset: base + 4, as: Float.self)
                    let z = vBuf.loadUnaligned(fromByteOffset: base + 8, as: Float.self)
                    let worldPos = transform * SIMD4<Float>(x, y, z, 1.0)

                    objData.append(contentsOf: "v \(worldPos.x) \(worldPos.y) \(worldPos.z)\n".utf8)

                    // Person segmentation projection (privacy). seg is non-nil only when filtering.
                    if let seg = seg {
                        let camPos = viewMatrix * worldPos
                        let clipPos = projMatrix * camPos
                        if clipPos.w > 0 {
                            let px = Int((clipPos.x / clipPos.w * 0.5 + 0.5) * Float(seg.width))
                            let py = Int((1.0 - (clipPos.y / clipPos.w * 0.5 + 0.5)) * Float(seg.height))
                            if px >= 0 && px < seg.width && py >= 0 && py < seg.height {
                                isPersonVertex[idx] = seg.pixels[py * seg.stride + px] > 128
                            }
                        }
                    }
                }
            }
            totalVertices += vCount

            // Validate face format before iterating (mirrors the original guard).
            guard anchor.faceFormatValid else {
                vertexOffset += vCount
                continue
            }

            let faceBytes = anchor.faceBytesPerPrimitive
            // Anchor-local classification view (nil-safe): label for face i, or 0 (= none).
            let clsData = anchor.classificationData
            let clsStride = anchor.classificationStride
            anchor.faceData.withUnsafeBytes { (fBuf: UnsafeRawBufferPointer) in
                for faceIdx in 0..<anchor.faceCount {
                    let base = faceIdx * faceBytes
                    let i0 = fBuf.loadUnaligned(fromByteOffset: base, as: UInt32.self)
                    let i1 = fBuf.loadUnaligned(fromByteOffset: base + 4, as: UInt32.self)
                    let i2 = fBuf.loadUnaligned(fromByteOffset: base + 8, as: UInt32.self)

                    // Validate indices are within vertex bounds — corrupted geometry can produce
                    // wild index values.
                    guard Int(i0) < vCount, Int(i1) < vCount, Int(i2) < vCount else { continue }

                    // Skip person faces if privacy filter is on
                    if seg != nil, isPersonVertex[Int(i0)] || isPersonVertex[Int(i1)] || isPersonVertex[Int(i2)] {
                        continue
                    }

                    let v1 = Int(i0) + vertexOffset
                    let v2 = Int(i1) + vertexOffset
                    let v3 = Int(i2) + vertexOffset
                    objData.append(contentsOf: "f \(v1) \(v2) \(v3)\n".utf8)
                    if anyClassification {
                        // Same skip path as the `f` line above — the sidecar stays face-aligned.
                        if let clsData, clsStride > 0, faceIdx * clsStride < clsData.count {
                            faceClasses.append(clsData[clsData.startIndex + faceIdx * clsStride])
                        } else {
                            faceClasses.append(0)
                        }
                    }
                    totalFaces += 1
                }
            }

            vertexOffset += vCount
        }

        guard !objData.isEmpty else { return nil }

        return MeshExportResult(data: objData, vertexCount: totalVertices, faceCount: totalFaces,
                                faceClasses: anyClassification ? faceClasses : nil)
    }

    /// DECISION 2 / DECISION 3 — build the rescan ghost's light proxy mesh from the PERSISTED save
    /// artifacts (mesh.obj + the face-aligned face_classes.bin sidecar), so it can run at
    /// POST-PROCESS, chained on the RoomBuilder room (mesh.obj itself stays the untouched
    /// save/export artifact):
    /// - **ceiling faces dropped unconditionally** — no quad exists for them, and dropping them
    ///   un-lids the overlay (a readability win, not a gap);
    /// - **floor faces dropped iff a floor quad covers them** — same reconciliation rule as walls, and
    ///   load-bearing for a sharper reason: RoomPlan emits exactly ONE floor plane per room, seated at
    ///   the lowest adequately-covered horizontal surface and spanning the room's whole plan-view
    ///   footprint (device-observed on a stairwell: a mid-flight landing's quad stretched across the
    ///   entire staircase). "Floor class ⇒ a quad stands in" therefore holds only for a flat
    ///   single-level room; an upper landing, a stair tread, a raised platform or the climbing part of
    ///   a ramp is KEPT as mesh rather than deleted in favour of a flat lie. The quad set floor faces
    ///   are tested against is RoomPlan's floor plus what the same classified mesh yields — the levels
    ///   `deriveLevelPlanes` recovers and the slope `deriveRampPlanes` fits — so a landing or a ramp
    ///   comes back as a clean quad rather than staying a lump, while a staircase flight, which is
    ///   neither, stays mesh because that is the only honest thing to draw for it;
    /// - **wall/door/window faces dropped iff a RoomPlan wall covers them** — the reconciliation
    ///   rule: classifier-wall ≠ RoomPlan-wall (RoomPlan drops partial/low-texture walls), so a
    ///   wall face with no covering quad is KEPT in the lumpy proxy rather than leaving a hole;
    /// - **content faces (none/table/seat) kept** — they're the honest coverage/change signal.
    /// Vertices are compacted (only referenced ones emitted, indices remapped) so the size win is
    /// real. The wall/floor/level QUADS are baked INTO the artifact (4 corners + 2 triangles
    /// each, appended last): one coherent, coordinate-locked OBJ — quads and mesh remainder ride
    /// the registration and the ghost de-registration together, so they can never drift apart
    /// across sessions, and the renderer needs no dynamic assembly.
    ///
    /// The privacy person-filter needs no re-application here: mesh.obj was already emitted with
    /// person faces skipped, and face_classes.bin is aligned to the EMITTED face order (both come
    /// from the same buildMeshOBJ loop). Inputs must be frame-consistent: pass the RAW mesh with
    /// RAW-frame planes (the caller then applies the canonical transform to the result), or the
    /// canonical mesh with canonical planes.
    ///
    /// Returns nil on face-count/sidecar mismatch (misaligned inputs — refuse rather than
    /// mis-subtract) or when no RoomPlan walls exist to stand in — callers then skip the artifact
    /// and the rescan ghost falls back to the full mesh.
    static func buildGhostProxyOBJ(objData meshOBJ: Data, faceClasses: Data,
                                   roomPlanPlanes: [PlaneRegistration.Plane]) -> GhostProxyBuildResult? {
        let roomPlanWalls = roomPlanPlanes.filter { $0.category == .wall }
        let roomPlanFloors = roomPlanPlanes.filter { $0.category == .floor }
        guard !roomPlanWalls.isEmpty else { return nil }

        // Phase timing, printed with the other build diagnostics. The derivation/support machinery is
        // O(faces × planes) in several separate passes, so its cost scales with exactly the scenes it
        // helps most — measure rather than assume.
        let tStart = DispatchTime.now()
        var tPrev = tStart
        var laps: [(String, Double)] = []
        func lap(_ name: String) {
            let now = DispatchTime.now()
            laps.append((name, Double(now.uptimeNanoseconds - tPrev.uptimeNanoseconds) / 1e6))
            tPrev = now
        }

        // Parse the OBJ's v/f lines (buildMeshOBJ emits only those; transformOBJ may add comment
        // lines — skipped). Faces are 1-based vertex indices.
        var verts: [SIMD3<Float>] = []
        var faces: [(Int, Int, Int)] = []
        let nl = UInt8(ascii: "\n")
        meshOBJ.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var i = 0
            let count = raw.count
            while i < count {
                var j = i
                while j < count && base[j] != nl { j += 1 }
                if j > i + 2, base[i + 1] == UInt8(ascii: " ") {
                    let kind = base[i]
                    if kind == UInt8(ascii: "v") || kind == UInt8(ascii: "f") {
                        // Parse three whitespace-separated numbers after the tag.
                        var vals: [Double] = []
                        var k = i + 2
                        while k < j && vals.count < 3 {
                            while k < j && base[k] == UInt8(ascii: " ") { k += 1 }
                            var m = k
                            while m < j && base[m] != UInt8(ascii: " ") { m += 1 }
                            if m > k, let s = String(bytes: raw[k..<m], encoding: .utf8), let d = Double(s) {
                                vals.append(d)
                            }
                            k = m
                        }
                        if vals.count == 3 {
                            if kind == UInt8(ascii: "v") {
                                verts.append(SIMD3(Float(vals[0]), Float(vals[1]), Float(vals[2])))
                            } else {
                                faces.append((Int(vals[0]) - 1, Int(vals[1]) - 1, Int(vals[2]) - 1))
                            }
                        }
                    }
                }
                i = j + 1
            }
        }
        lap("parse")
        // Alignment contract: one class byte per emitted face. A mismatch means the inputs are
        // from different builds — refuse rather than subtract the wrong faces.
        guard faces.count == faceClasses.count, !verts.isEmpty else {
            print("[GhostProxy] face/class count mismatch (faces=\(faces.count) classes=\(faceClasses.count)) — skipping proxy")
            return nil
        }

        // The class partition, ONCE. Every derivation and mask consumer below reads these instead of
        // re-sweeping all faces — the build used to make up to nine full-mesh passes, each re-deriving
        // class, cross product, area and centroid, and that was most of its runtime.
        let (wallPatches, floorPatches) = classifyPatches(verts: verts, faces: faces,
                                                          faceClasses: faceClasses)
        lap("classify")

        // Levels RoomPlan never modelled — upper landings, raised platforms, sunken areas — derived
        // from this same classified mesh (see `deriveLevelPlanes`). They are baked as quads AND fed to
        // the coverage test below, so each one subtracts its own mesh faces exactly as the RoomPlan
        // floor does for a flat room: a landing arrives as a clean quad instead of a lump.
        //
        // Where a RoomPlan floor and a derived level sit at one height, the DERIVED level wins and the
        // RoomPlan floor is dropped. Both directions of this dedupe have now been tried, and preferring
        // RoomPlan lost twice over: its floor is seated on coverage, not geometry (measured 22 cm off —
        // one riser — on a partially-covered landing), and under per-cell support a mis-seated plane can
        // back zero cells, at which point deduping the level away leaves genuine flat floor with NO quad
        // at all (device-observed: floor 0/216 with the matching level discarded). The level is measured
        // from the mesh itself, so preferring it cannot lose the surface. RoomPlan floors with no
        // matching level (its seat on a stairwell flight, say) still bake, cell-gated like everything
        // else.
        let levelSearch = deriveLevelPlanes(floorPatches: floorPatches,
                                            reference: roomPlanFloors.first)
        lap("levels")
        let allLevels = levelSearch.levels
        let derivedLevels = allLevels
        let dedupedFloors = roomPlanFloors.filter { fl in
            !allLevels.contains { abs($0.center.y - fl.center.y) <= ghostProxyQuadCoverageMeters }
        }

        // Per-quad graceful degradation. RoomPlan is designed to emit neat boxes; in a non-boxy room a
        // wall quad can be a straight chord across a curve, and even cell-gated it subtracts the true
        // curved mesh at its tangency and bakes a flat lattice through it. A quad that explains too
        // little of the mesh in its own footprint is DEMOTED — it neither subtracts nor bakes, and its
        // geometry stays honest mesh (the same decision the helix gets). Box rooms are untouched: every
        // real straight wall explains nearly all of its mesh. Derived levels and ramps are exempt by
        // construction — they are measured from this mesh, so they cannot mis-model it.
        let roomPlanQuads = roomPlanWalls + dedupedFloors
        let fitness = quadModelFitness(planes: roomPlanQuads, wallPatches: wallPatches,
                                       floorPatches: floorPatches)
        let trusted = zip(roomPlanQuads, fitness).filter { $0.1 >= quadModelMinExplainedRatio }.map(\.0)
        let demoted = zip(roomPlanQuads, fitness).filter { $0.1 < quadModelMinExplainedRatio }
        let walls = trusted.filter { $0.category == .wall }
        let keptRoomPlanFloors = trusted.filter { $0.category == .floor }
        if !demoted.isEmpty {
            let desc = demoted.map { p, r in
                String(format: "%@ %.1f×%.1fm explains %.0f%%",
                       p.category == .wall ? "wall" : "floor", p.width, p.height, r * 100)
            }.joined(separator: ", ")
            print("[GhostProxy] demoted (kept as mesh): \(desc)")
        }
        // A ramp is fitted to whatever the levels leave unexplained — see `deriveRampPlanes`. It joins
        // the same two lists, so a ramp that fits coherently gets a clean tilted lattice and stops
        // being a lump, and one that does not just stays mesh.
        //
        // The "unexplained" set is computed against per-cell support, which is load-bearing rather than a
        // refinement: an over-claiming floor rectangle removes a 30 cm-tall band from every ramp passing
        // through its height, which for an 8° slope is ~2 m of run per quad. Three such rectangles sliced
        // a real ramp into fragments below the area gate and suppressed ramp detection entirely.
        // UNDILATED mask for ramp-candidate selection only. Dilation is an anti-patchiness allowance
        // for subtraction and baking; on a 1 m grid it also claims up to a metre of the ramp on the
        // adjacent level's behalf, which truncated a fitted ramp's bottom short of the floor it meets
        // and starved the fit of its end geometry. Candidate selection wants the levels' true
        // footprint; the dilated masks below still govern what gets subtracted and drawn.
        let floorSupport = buildQuadSupport(planes: keptRoomPlanFloors + derivedLevels,
                                            wallPatches: [], floorPatches: floorPatches, dilateBy: 0)
        let rampSearch = deriveRampPlanes(floorPatches: floorPatches,
                                          explainedBy: keptRoomPlanFloors + derivedLevels,
                                          support: floorSupport)
        lap("ramps")
        let derivedRamps = rampSearch.ramps
        let floorQuads = keptRoomPlanFloors + derivedLevels + derivedRamps
        let bakedPlanes = walls + keptRoomPlanFloors + derivedLevels + derivedRamps
        // ONE mask build. Competition is within-family and bakedPlanes is walls + floorQuads in that
        // order, so the wall and floor mask sets are exactly slices of the baked set — building them
        // separately produced identical masks at three times the cost.
        let bakedSupport = buildQuadSupport(planes: bakedPlanes, wallPatches: wallPatches,
                                            floorPatches: floorPatches)
        let wallSupport = Array(bakedSupport[0..<walls.count])
        let floorSupportAll = Array(bakedSupport[walls.count...])
        lap("supports")

        var objData = Data()
        objData.reserveCapacity(256 * 1024)
        // Version header (every consumer skips comment lines; transformOBJ passes them verbatim).
        // ScanPostprocessor checks the version so proxies from older builders rebuild on the next
        // Process; `quadFaces` tells the ghost renderer how many TRAILING faces are the RoomPlan
        // lattice (they get thick wireframe lines — sparse 1 m grid lines at the default 1 mm
        // thickness are sub-pixel beyond ~1.5 m and visually vanish; 2026-07-16 device finding).
        // The support masks are FINE-grid (0.25 m); baking happens on the 1 m lattice. A bake cell is
        // kept when any of its fine cells is backed — the drawn lattice stays coarse and readable while
        // the decision underneath is precise. Computed once here and reused by the bake loop and the
        // header count, which must agree with what is actually emitted.
        func bakeKept(_ p: PlaneRegistration.Plane, _ mask: QuadSupport) -> [Bool] {
            let (bCols, bRows) = quadGrid(p)
            let (fCols, fRows) = quadSupportGrid(p)
            var kept = [Bool](repeating: false, count: bCols * bRows)
            for fr in 0..<fRows {
                for fc in 0..<fCols where mask.isKept(fc, fr) {
                    // Map by coordinate, not by ratio — the two grids round up independently.
                    let u = (Float(fc) + 0.5) * p.width / Float(fCols)
                    let v = (Float(fr) + 0.5) * p.height / Float(fRows)
                    let bc = min(bCols - 1, max(0, Int(u / (p.width / Float(bCols)))))
                    let br = min(bRows - 1, max(0, Int(v / (p.height / Float(bRows)))))
                    kept[br * bCols + bc] = true
                }
            }
            return kept
        }
        let bakedKept = zip(bakedPlanes, bakedSupport).map { bakeKept($0, $1) }
        let quadFaceCount = bakedKept.reduce(0) { $0 + $1.lazy.filter { $0 }.count * 2 }
        objData.append(contentsOf: "\(ghostProxyVersionHeader) quadFaces=\(quadFaceCount)\n".utf8)

        // Pass 1: faces surviving the class filter. Two sets come out of the one pass — the proxy's,
        // and the dynamic mesh's, which is the proxy's minus the off-level floor faces (see below).
        var keptFaces: [(Int, Int, Int)] = []
        keptFaces.reserveCapacity(faces.count / 2)
        var dynamicFaces: [(Int, Int, Int)] = []
        dynamicFaces.reserveCapacity(faces.count / 4)
        var droppedCeiling = 0
        var droppedCoveredFloor = 0
        var keptFloorBeyondExtent = 0
        var keptFloorOffPlane = 0
        var droppedCoveredWall = 0
        var keptWall = 0
        var keptContent = 0
        for (faceIdx, f) in faces.enumerated() {
            guard f.0 >= 0, f.1 >= 0, f.2 >= 0, f.0 < verts.count, f.1 < verts.count, f.2 < verts.count else { continue }
            // Geometry the proxy keeps but the dynamic mesh must not: architecture — off-level floor
            // (a landing, a tread, a ramp) and uncovered wall-family faces alike. The dynamic artifact
            // is the change-detection signal, and until now kept WALL faces fell through into it, so it
            // carried the building as if it were furniture (dynamic == kept − floorKept, exactly);
            // demotion made that much worse by un-covering whole curved walls into the kept set.
            var isInfrastructure = false
            // ARMeshClassification raw: 0 none, 1 wall, 2 floor, 3 ceiling, 4 table,
            // 5 seat, 6 window, 7 door.
            switch faceClasses[faceClasses.startIndex + faceIdx] {
            case 3:
                droppedCeiling += 1
                continue // ceiling — no quad exists; dropping deliberately un-lids the overlay
            case 2:
                // floor family — subtract only where a RoomPlan floor quad actually sits on it, so
                // off-level geometry (landings, treads, ledges, the climbing part of a ramp)
                // survives instead of being replaced by the single flat full-extent quad
                switch quadCoverage(floorQuads, support: floorSupportAll,
                                    (verts[f.0] + verts[f.1] + verts[f.2]) / 3) {
                case .covered:
                    droppedCoveredFloor += 1
                    continue
                case .beyondExtent:
                    keptFloorBeyondExtent += 1
                case .offPlane:
                    keptFloorOffPlane += 1
                }
                isInfrastructure = true
            case 1, 6, 7:
                // wall-plane family — subtract only where a RoomPlan quad replaces it
                if quadCovers(walls, support: wallSupport, (verts[f.0] + verts[f.1] + verts[f.2]) / 3) {
                    droppedCoveredWall += 1
                    continue
                }
                keptWall += 1
                isInfrastructure = true
            default:
                keptContent += 1    // content — keep
            }
            keptFaces.append(f)
            if !isInfrastructure { dynamicFaces.append(f) }
        }

        lap("filter")
        // Pass 2: compact vertices (only referenced ones emitted, indices remapped 1-based) for a
        // face subset. Runs once per artifact — the two sets differ, so they cannot share a body.
        func compactedBody(_ faceList: [(Int, Int, Int)]) -> (data: Data, vertices: Int) {
            var body = Data()
            body.reserveCapacity(faceList.count * 48)
            var used = [Bool](repeating: false, count: verts.count)
            for f in faceList { used[f.0] = true; used[f.1] = true; used[f.2] = true }
            var remap = [Int](repeating: 0, count: verts.count)
            var next = 1
            for idx in 0..<verts.count where used[idx] {
                remap[idx] = next
                next += 1
                let p = verts[idx]
                body.append(contentsOf: "v \(p.x) \(p.y) \(p.z)\n".utf8)
            }
            for f in faceList {
                body.append(contentsOf: "f \(remap[f.0]) \(remap[f.1]) \(remap[f.2])\n".utf8)
            }
            return (body, next - 1)
        }

        let proxyBody = compactedBody(keptFaces)
        objData.append(proxyBody.data)
        var vertexOffset = proxyBody.vertices + 1
        var totalVertices = proxyBody.vertices
        var totalFaces = keptFaces.count

        // ── The dynamic mesh (content only, no infrastructure) ──
        // The "4D" artifact that strips walls/floors/ceilings so temporal comparisons across rescans
        // show only changes. Compacted independently rather than sliced out of the proxy body: the
        // proxy now KEEPS the floor faces no quad stands in, and those are architecture — a
        // change-detection artifact that inherited a staircase would report the building as furniture.
        let dynamicBody = compactedBody(dynamicFaces)
        var dynamicOBJData = Data("\(dynamicMeshVersionHeader)\n".utf8)
        dynamicOBJData.append(dynamicBody.data)
        let dynamicVertexCount = dynamicBody.vertices
        let dynamicFaceCount = dynamicFaces.count
        lap("compact")

        // Bake the wall + floor + derived-level quads into the same OBJ (the clean stand-ins for the
        // subtracted architectural faces). Tessellated into ~1 m grid cells rather than one big
        // 2-triangle quad: the ghost renders as WIREFRAME, and a bare quad is just its outline +
        // one diagonal — it reads as emptiness, not a wall (2026-07-16 device feedback: "I can't
        // visually tell what the walls are"). A 1 m grid draws as a visible lattice — reads as a
        // solid face — while still being massive decimation (a 5×3 m wall = 30 tris vs. the
        // thousands of mesh faces it replaced).
        for (planeIdx, p) in bakedPlanes.enumerated() {
            let (cols, rows) = quadGrid(p)
            let keptCells = bakedKept[planeIdx]
            let origin = p.center - p.xAxis * (p.width / 2) - p.yAxis * (p.height / 2)
            let dx = p.xAxis * (p.width / Float(cols))
            let dy = p.yAxis * (p.height / Float(rows))
            // Grid vertices, row-major: (cols+1) × (rows+1).
            for r in 0...rows {
                for c in 0...cols {
                    let v = origin + dx * Float(c) + dy * Float(r)
                    objData.append(contentsOf: "v \(v.x) \(v.y) \(v.z)\n".utf8)
                }
            }
            func vid(_ c: Int, _ r: Int) -> Int { vertexOffset + r * (cols + 1) + c }
            for r in 0..<rows {
                for c in 0..<cols where keptCells[r * cols + c] {
                    objData.append(contentsOf: "f \(vid(c, r)) \(vid(c + 1, r)) \(vid(c + 1, r + 1))\n".utf8)
                    objData.append(contentsOf: "f \(vid(c, r)) \(vid(c + 1, r + 1)) \(vid(c, r + 1))\n".utf8)
                    totalFaces += 2
                }
            }
            vertexOffset += (cols + 1) * (rows + 1)
            totalVertices += (cols + 1) * (rows + 1)
        }

        lap("bake")
        guard totalFaces > 0 else { return nil }
        // Diagnostic: the baked quad dimensions, verbatim from the roomplan surfaces. A wall whose
        // lattice looks "short" on device either really is short here (RoomPlan partial-wall
        // extent — the classifier-wall mesh above it is kept, no hole) or its upper mesh faces
        // were dropped by class (see the drop tally) — this line separates the two from console.
        // Derived levels are listed with their HEIGHT rather than just their size: on a stairwell the
        // whole point is which levels came out and how far apart they sit.
        // Mirrors bakedPlanes' order exactly, so this line and "quad cells backed" read in parallel.
        // Floors carry their HEIGHT: on a multi-level scan the whole question is where RoomPlan seated
        // its floor plane relative to the levels actually present, and a size alone cannot answer it.
        let quadDesc = (walls
            .map { String(format: "wall %.1f×%.1fm", $0.width, $0.height) }
            + keptRoomPlanFloors
            .map { String(format: "floor y=%+.2f %.1f×%.1fm", $0.center.y, $0.width, $0.height) }
            + derivedLevels
            .map { String(format: "level y=%.2f %.1f×%.1fm", $0.center.y, $0.width, $0.height) }
            + derivedRamps
            .map { String(format: "ramp %.1f° %.1f×%.1fm",
                          acos(min(abs($0.normal.y), 1)) * 180 / .pi, $0.width, $0.height) })
            .joined(separator: ", ")
        // The floor-remainder split is the diagnostic that matters, because the two halves mean
        // opposite things. `beyondExtent` is floor at the RIGHT height but outside the modelled
        // footprint — mesh captured through a doorway or past the room boundary — and is expected in
        // any room you did not scan strictly within its walls. `offPlane` is floor at a height NO quad
        // sits at: the landing / ledge / ramp signal the old unconditional drop was deleting, and in a
        // room believed to be flat and single-level it is a warning rather than a curiosity.
        if !levelSearch.candidates.isEmpty {
            print("[GhostProxy] level candidates: \(levelSearch.traceDescription)")
        }
        // Backed cells vs total, per plane: how much of each rectangle survived the support mask. A low
        // fraction is the rectangle over-claiming, which is what the mask exists to contain — and seeing
        // it per plane is what tells RoomPlan's footprint quad apart from two disconnected landings.
        let supportDesc = zip(bakedPlanes, bakedSupport)
            .map { p, m in
                let (cols, rows) = quadSupportGrid(p)
                return String(format: "%@ %d/%d", p.category == .wall ? "wall" : "floor",
                              m.keptCount, cols * rows)
            }
            .joined(separator: " ")
        if !rampSearch.groups.isEmpty {
            print("[GhostProxy] ramp groups: \(rampSearch.traceDescription)")
            for (i, g) in rampSearch.groups.enumerated() {
                if let map = g.shapeMap {
                    print("[GhostProxy] ramp shape[\(i)] (\(g.verdict.rawValue), across × up-slope):\n\(map)")
                }
            }
        }
        let totalMs = Double(DispatchTime.now().uptimeNanoseconds - tStart.uptimeNanoseconds) / 1e6
        let lapDesc = laps.map { String(format: "%@ %.0fms", $0.0, $0.1) }.joined(separator: " ")
        print(String(format: "[GhostProxy] build time %.0fms | %@", totalMs, lapDesc))
        print("[GhostProxy] quads baked: \(quadDesc)")
        print("[GhostProxy] quad cells backed: \(supportDesc)")
        // The face budget, split by WHY each face survived — the decimation picture in one line. The
        // quads themselves are a rounding error here (a few hundred faces against six figures), so the
        // only levers on artifact size are how much architecture gets subtracted and how much content
        // there is. `keptWall` is therefore the addressable pool for deriving more wall planes from the
        // mesh: it is architecture RoomPlan did not model, and every plane recovered from it converts
        // thousands of faces into a handful of lattice cells. `keptContent` is the honest signal and is
        // not addressable that way — it can only be decimated, which costs fidelity.
        let total = keptFaces.count + droppedCeiling + droppedCoveredFloor + droppedCoveredWall
        let keptPct = total > 0 ? 100 * keptFaces.count / total : 0
        print("[GhostProxy] faces: \(total) → \(keptFaces.count) kept (\(keptPct)%), dynamic \(dynamicFaces.count) | dropped: wall=\(droppedCoveredWall) floor=\(droppedCoveredFloor) ceiling=\(droppedCeiling) | kept: wall=\(keptWall) content=\(keptContent) floor=\(keptFloorBeyondExtent + keptFloorOffPlane) (beyondExtent=\(keptFloorBeyondExtent) offPlane=\(keptFloorOffPlane))")
        let proxyResult = MeshExportResult(data: objData, vertexCount: totalVertices, faceCount: totalFaces)
        let dynamicResult = MeshExportResult(data: dynamicOBJData, vertexCount: dynamicVertexCount, faceCount: dynamicFaceCount)
        return GhostProxyBuildResult(proxy: proxyResult, dynamic: dynamicResult,
                                     levels: allLevels, ramps: derivedRamps)
    }

    /// Which cells of a quad's tessellation grid are actually backed by mesh, so a quad stands in only
    /// where it demonstrably describes something.
    ///
    /// Rectangles are a bad fit for real surfaces, and the failures compound. RoomPlan's floor spans the
    /// room's whole plan-view footprint (observed: 8.9×23.9 m). A derived level's bounding rectangle
    /// spans every patch at that height, including the space between two areas that are not connected
    /// (observed: 6.3 m² of floor inside a 12.0×14.9 m box — 3.5% fill). A single plane fitted to a
    /// curved wall runs straight through open space. In every case the quad both DRAWS where there is
    /// nothing and SUBTRACTS mesh it does not represent — and the subtraction is the worse half, because
    /// it sliced a ramp into fragments too small to fit and so suppressed ramp detection entirely.
    ///
    /// Working per cell instead of per rectangle fixes all of them with one mechanism: the rectangle
    /// stays rectangular but only its backed cells exist, so a quad becomes a rasterisation of the shape
    /// actually observed. Baking and subtraction read the SAME mask, so a dropped cell can never leave a
    /// hole — there was nothing there to stand in for.
    ///
    /// `dilate` is the tolerance, and it is deliberately a size allowance rather than a per-cell test:
    /// marked cells grow by `quadSupportDilateCells`, so thin or patchy coverage on a genuine wall still
    /// reads as solid, while a large contiguous unbacked region — the open space beyond a curve, the gap
    /// between two disconnected landings — stays dropped.
    struct QuadSupport {
        let cols: Int
        let rows: Int
        private(set) var kept: [Bool]

        init(cols: Int, rows: Int) {
            self.cols = max(1, cols)
            self.rows = max(1, rows)
            kept = [Bool](repeating: false, count: self.cols * self.rows)
        }

        func isKept(_ c: Int, _ r: Int) -> Bool {
            guard c >= 0, c < cols, r >= 0, r < rows else { return false }
            return kept[r * cols + c]
        }

        mutating func mark(_ c: Int, _ r: Int) {
            guard c >= 0, c < cols, r >= 0, r < rows else { return }
            kept[r * cols + c] = true
        }

        var keptCount: Int { kept.lazy.filter { $0 }.count }

        /// Grow the backed region by `radius` cells (Chebyshev), closing thin gaps in real coverage.
        mutating func dilate(by radius: Int) {
            guard radius > 0 else { return }
            for _ in 0..<radius {
                var next = kept
                for r in 0..<rows {
                    for c in 0..<cols where kept[r * cols + c] {
                        for dr in -1...1 {
                            for dc in -1...1 {
                                let rr = r + dr, cc = c + dc
                                guard rr >= 0, rr < rows, cc >= 0, cc < cols else { continue }
                                next[rr * cols + cc] = true
                            }
                        }
                    }
                }
                kept = next
            }
        }
    }

    /// Cell grid dimensions a plane tessellates into for BAKING (the drawn lattice).
    static func quadGrid(_ p: PlaneRegistration.Plane) -> (cols: Int, rows: Int) {
        (max(1, Int((p.width / ghostProxyQuadCellMeters).rounded(.up))),
         max(1, Int((p.height / ghostProxyQuadCellMeters).rounded(.up))))
    }

    /// Cell grid the SUPPORT analysis runs on — deliberately finer than the bake lattice. At bake
    /// resolution (1 m) a cell straddling a landing's edge blends the landing's faces with the ramp,
    /// flight or next-room floor beside it, the blend passes the tilt gate, and the whole metre gets
    /// claimed — device-observed as the landing lattice squared out over a ramp, into a staircase, and
    /// through walls. At 0.25 m the same cells read the foreign surface's own orientation (a ramp's
    /// 3.9°, a smoothed flight's ~30°) and are rejected on their merits.
    static func quadSupportGrid(_ p: PlaneRegistration.Plane) -> (cols: Int, rows: Int) {
        (max(1, Int((p.width / quadSupportCellMeters).rounded(.up))),
         max(1, Int((p.height / quadSupportCellMeters).rounded(.up))))
    }

    /// In-plane connected components over an occupancy grid. 4-connected, and a cell counts only above
    /// a real-area threshold, so boundary slivers can neither claim cells nor bridge a wall's mesh gap.
    /// Points in sub-threshold cells belong to no component — they are speckle. Components come back
    /// largest-first.
    static func horizontalComponents(_ pts: [(u: Float, v: Float, area: Float)],
                                     cellMeters: Float = quadSupportCellMeters,
                                     minCellAreaM2: Float = quadSupportCellMinAreaM2) -> [[Int]] {
        guard !pts.isEmpty else { return [] }
        var cellOf: [SIMD2<Int32>: [Int]] = [:]
        var cellArea: [SIMD2<Int32>: Float] = [:]
        for (i, p) in pts.enumerated() {
            let key = SIMD2(Int32((p.u / cellMeters).rounded(.down)),
                            Int32((p.v / cellMeters).rounded(.down)))
            cellOf[key, default: []].append(i)
            cellArea[key, default: 0] += p.area
        }
        let occupied = cellOf.filter { cellArea[$0.key]! >= minCellAreaM2 }
        var compOf: [SIMD2<Int32>: Int] = [:]
        var comps: [[Int]] = []
        for seed in occupied.keys where compOf[seed] == nil {
            var members: [Int] = []
            var stack = [seed]
            compOf[seed] = comps.count
            while let k = stack.popLast() {
                members.append(contentsOf: occupied[k] ?? [])
                for d in [SIMD2<Int32>(1, 0), SIMD2(-1, 0), SIMD2(0, 1), SIMD2(0, -1)] {
                    let nk = k &+ d
                    if occupied[nk] != nil, compOf[nk] == nil {
                        compOf[nk] = comps.count
                        stack.append(nk)
                    }
                }
            }
            comps.append(members)
        }
        return comps.sorted { a, b in
            a.reduce(Float(0)) { $0 + pts[$1].area } > b.reduce(Float(0)) { $0 + pts[$1].area }
        }
    }

    /// Which SUPPORT cell of `p` a world point falls in, or nil if it is off the rectangle or off the
    /// plane. The `+0.2` in-plane slack matches the rectangle coverage test it replaces.
    static func quadSupportCell(_ p: PlaneRegistration.Plane, _ point: SIMD3<Float>) -> (c: Int, r: Int)? {
        let d = point - p.center
        guard abs(simd_dot(d, p.normal)) <= ghostProxyQuadCoverageMeters else { return nil }
        let (cols, rows) = quadSupportGrid(p)
        let u = simd_dot(d, p.xAxis) + p.width / 2
        let v = simd_dot(d, p.yAxis) + p.height / 2
        guard u >= -0.2, u <= p.width + 0.2, v >= -0.2, v <= p.height + 0.2 else { return nil }
        let c = min(cols - 1, max(0, Int(u / (p.width / Float(cols)))))
        let r = min(rows - 1, max(0, Int(v / (p.height / Float(rows)))))
        return (c, r)
    }

    /// Build one support mask per plane from the faces whose CLASS matches that plane's family — walls
    /// backed by the wall family, floors/levels/ramps by floor-class faces.
    static func buildQuadSupport(planes: [PlaneRegistration.Plane], verts: [SIMD3<Float>],
                                 faces: [(Int, Int, Int)], faceClasses: Data,
                                 dilateBy: Int = quadSupportDilateCells) -> [QuadSupport] {
        let patches = classifyPatches(verts: verts, faces: faces, faceClasses: faceClasses)
        return buildQuadSupport(planes: planes, wallPatches: patches.walls,
                                floorPatches: patches.floors, dilateBy: dilateBy)
    }

    /// Patch-based core — the builder computes the class partition once and every mask consumer
    /// reuses it instead of re-sweeping the whole mesh.
    static func buildQuadSupport(planes: [PlaneRegistration.Plane],
                                 wallPatches: [SurfacePatch], floorPatches: [SurfacePatch],
                                 dilateBy: Int = quadSupportDilateCells) -> [QuadSupport] {
        let grids = planes.map { quadSupportGrid($0) }
        var sums = grids.map { [SIMD3<Float>](repeating: .zero, count: $0.cols * $0.rows) }
        var areas = grids.map { [Float](repeating: 0, count: $0.cols * $0.rows) }
        let wallIdx = planes.indices.filter { planes[$0].category == .wall }
        let floorIdx = planes.indices.filter { planes[$0].category == .floor }

        // COMPETITIVE assignment: the patch backs only the plane that explains it best (smallest
        // perpendicular distance), never every plane within tolerance. Where two planes of one family
        // meet — a ramp rising into a landing, wall facets at a corner — the tolerance bands overlap
        // for metres, and first-match let the landing claim the top of the ramp, square itself outward
        // over it, and subtract mesh the ramp quad should have owned. Best-fit assignment gives the
        // overlap to whichever surface it actually lies on.
        func accumulate(_ patches: [SurfacePatch], _ planeIdx: [Int]) {
            guard !planeIdx.isEmpty else { return }
            for patch in patches {
                var best: (i: Int, cell: (c: Int, r: Int), dist: Float)?
                for i in planeIdx {
                    guard let cell = quadSupportCell(planes[i], patch.c) else { continue }
                    let dist = abs(simd_dot(patch.c - planes[i].center, planes[i].normal))
                    if best == nil || dist < best!.dist { best = (i, cell, dist) }
                }
                guard let best else { continue }
                let p = planes[best.i]
                // Face winding is not trusted, so orient each normal toward the plane's before
                // summing — otherwise opposite windings on one surface would cancel to nothing.
                let oriented = simd_dot(patch.n, p.normal) < 0 ? -patch.n : patch.n
                let k = best.cell.r * grids[best.i].cols + best.cell.c
                sums[best.i][k] += oriented * patch.area
                areas[best.i][k] += patch.area
            }
        }
        accumulate(wallPatches, wallIdx)
        accumulate(floorPatches, floorIdx)

        return planes.indices.map { i in
            let p = planes[i]
            let (cols, rows) = grids[i]
            var mask = QuadSupport(cols: cols, rows: rows)
            // Floors need a tight bound: the surface they must not absorb is a shallow ramp, only degrees
            // away. Walls need a loose one: what they must not absorb is a differently-oriented surface,
            // tens of degrees away, so a tight bound there would only punish noise on a genuine wall.
            let toleranceDeg = p.category == .floor ? quadSupportFloorMeanTiltDeg : quadSupportWallMeanTiltDeg
            let minDot = cos(toleranceDeg * .pi / 180)
            // A cell needs real area behind it before its orientation means anything — a couple of
            // boundary slivers should not claim a quarter-metre of quad.
            for k in 0..<(cols * rows) where areas[i][k] >= quadSupportCellMinAreaM2 {
                let mean = sums[i][k] / areas[i][k]
                let len = simd_length(mean)
                guard len > 1e-6, simd_dot(mean / len, p.normal) >= minDot else { continue }
                mask.mark(k % cols, k / cols)
            }
            mask.dilate(by: dilateBy)
            return mask
        }
    }

    /// One classified surface patch: a mesh face reduced to what every derivation and mask consumer
    /// actually reads. Computed ONCE per build — the machinery used to re-derive class, cross product,
    /// area and centroid in up to nine separate full-mesh sweeps, which is where the build time went.
    /// Floor patches carry their normal oriented upward (winding is untrusted); wall patches keep the
    /// raw normal, since wall consumers orient against each plane's own normal.
    typealias SurfacePatch = (c: SIMD3<Float>, n: SIMD3<Float>, area: Float)

    /// Partition the mesh by class family, once. Content faces appear in neither list — no derivation
    /// or mask consumer reads them.
    static func classifyPatches(verts: [SIMD3<Float>], faces: [(Int, Int, Int)],
                                faceClasses: Data) -> (walls: [SurfacePatch], floors: [SurfacePatch]) {
        var walls: [SurfacePatch] = []
        var floors: [SurfacePatch] = []
        walls.reserveCapacity(faces.count / 3)
        floors.reserveCapacity(faces.count / 3)
        for (idx, f) in faces.enumerated() {
            guard idx < faceClasses.count,
                  f.0 >= 0, f.1 >= 0, f.2 >= 0,
                  f.0 < verts.count, f.1 < verts.count, f.2 < verts.count else { continue }
            let cls = faceClasses[faceClasses.startIndex + idx]
            guard cls == 1 || cls == 2 || cls == 6 || cls == 7 else { continue }
            let a = verts[f.0], b = verts[f.1], c = verts[f.2]
            let cross = simd_cross(b - a, c - a)
            let area = 0.5 * simd_length(cross)
            guard area > 1e-6 else { continue }
            let n = cross / (2 * area)
            let ctr = (a + b + c) / 3
            if cls == 2 {
                floors.append((c: ctr, n: n.y < 0 ? -n : n, area: area))
            } else {
                walls.append((c: ctr, n: n, area: area))
            }
        }
        return (walls, floors)
    }

    /// How well each quad MODELS the mesh in its own footprint: explained area / present area, where
    /// "present" is same-family mesh projecting into the rectangle within a generous perpendicular band
    /// and "explained" is the subset the plane actually accounts for (within coverage distance, at the
    /// family's orientation tolerance).
    ///
    /// This is the per-quad box-room detector. RoomPlan is built to emit neat boxes; on a curved wall it
    /// emits a straight chord, and even with cell gating the chord's tangency strip subtracts true
    /// curved mesh and bakes a flat lattice through it — a straight chop slicing the curve. A chord
    /// explains only its tangency strip (low ratio); a genuinely straight wall explains ~everything.
    /// Thin scanning does NOT lower the ratio, because both sides of it count only mesh that exists —
    /// an unscanned stretch contributes to neither.
    ///
    /// Deliberately non-competitive: a face may count as present for two overlapping quads. The
    /// question here is each quad's own fitness, not which quad owns the face.
    static func quadModelFitness(planes: [PlaneRegistration.Plane], verts: [SIMD3<Float>],
                                 faces: [(Int, Int, Int)], faceClasses: Data) -> [Float] {
        let patches = classifyPatches(verts: verts, faces: faces, faceClasses: faceClasses)
        return quadModelFitness(planes: planes, wallPatches: patches.walls, floorPatches: patches.floors)
    }

    /// Patch-based core — see the wrapper above for semantics.
    static func quadModelFitness(planes: [PlaneRegistration.Plane],
                                 wallPatches: [SurfacePatch], floorPatches: [SurfacePatch]) -> [Float] {
        var explained = [Float](repeating: 0, count: planes.count)
        var present = [Float](repeating: 0, count: planes.count)
        let wallIdx = planes.indices.filter { planes[$0].category == .wall }
        let floorIdx = planes.indices.filter { planes[$0].category == .floor }
        func tally(_ patches: [SurfacePatch], _ planeIdx: [Int], toleranceDeg: Float) {
            guard !planeIdx.isEmpty else { return }
            let minDot = cos(toleranceDeg * .pi / 180)
            for patch in patches {
                for i in planeIdx {
                    let p = planes[i]
                    let d = patch.c - p.center
                    let perp = abs(simd_dot(d, p.normal))
                    guard perp <= quadModelBandMeters,
                          abs(simd_dot(d, p.xAxis)) <= p.width / 2 + 0.2,
                          abs(simd_dot(d, p.yAxis)) <= p.height / 2 + 0.2 else { continue }
                    present[i] += patch.area
                    if perp <= ghostProxyQuadCoverageMeters,
                       abs(simd_dot(patch.n, p.normal)) >= minDot {
                        explained[i] += patch.area
                    }
                }
            }
        }
        tally(wallPatches, wallIdx, toleranceDeg: quadSupportWallMeanTiltDeg)
        tally(floorPatches, floorIdx, toleranceDeg: quadSupportFloorMeanTiltDeg)
        return planes.indices.map { i in
            // Too little mesh to judge either way → benefit of the doubt; with nothing to back it, the
            // cell masks keep it from baking anyway.
            present[i] >= quadModelMinMeshAreaM2 ? explained[i] / present[i] : 1
        }
    }

    /// Why a point is or is not covered by a quad. The two uncovered cases mean very different things
    /// for a floor, and the raw kept-count cannot tell them apart: `beyondExtent` is mesh at the right
    /// HEIGHT but outside the modelled footprint — floor seen through a doorway or past the room
    /// boundary, which is expected and correctly kept — while `offPlane` is mesh at a height no quad
    /// sits at, which is the landing/ledge/ramp signal, and in a room believed to be flat is a warning.
    enum QuadCoverage {
        case covered
        case beyondExtent
        case offPlane
    }

    /// `quadCovers` with the reason, for diagnostics. `support` gates on the per-cell mask when present,
    /// so a quad only claims the part of its rectangle that mesh actually backs.
    static func quadCoverage(_ planes: [PlaneRegistration.Plane], support: [QuadSupport]?,
                             _ p: SIMD3<Float>) -> QuadCoverage {
        // Mirrors the support builder's competitive rule: the point belongs to its best-fit plane, and
        // is covered iff THAT plane's cell is backed. First-match here would re-open the overlap the
        // builder just resolved — a point the ramp won could still be swallowed by the landing.
        var atRightHeight = false
        var best: (i: Int, cell: (c: Int, r: Int), dist: Float)?
        for (i, q) in planes.enumerated() {
            let d = p - q.center
            let dist = abs(simd_dot(d, q.normal))
            guard dist <= ghostProxyQuadCoverageMeters else { continue }
            atRightHeight = true
            guard let cell = quadSupportCell(q, p) else { continue }
            if best == nil || dist < best!.dist { best = (i, cell, dist) }
        }
        if let best {
            if let support, best.i < support.count {
                return support[best.i].isKept(best.cell.c, best.cell.r) ? .covered : .beyondExtent
            }
            return .covered
        }
        return atRightHeight ? .beyondExtent : .offPlane
    }

    /// Whether any of `planes` genuinely stands in for the point `p`: within
    /// `ghostProxyQuadCoverageMeters` of the plane and inside its rectangle (+20 cm margin for
    /// RoomPlan seating and extent error). Used both to subtract mesh faces a quad replaces and to
    /// decide what the quads so far have left unexplained.
    static func quadCovers(_ planes: [PlaneRegistration.Plane], support: [QuadSupport]? = nil,
                           _ p: SIMD3<Float>) -> Bool {
        quadCoverage(planes, support: support, p) == .covered
    }

    /// What the level search found, plus what it looked at and turned down. The rejections matter as
    /// much as the results: every gate is otherwise a silent skip, so from the outside "no landing at
    /// that height" is indistinguishable from "a landing that missed a threshold by a hair" — and those
    /// call for opposite responses (accept the room as-is vs. move a number).
    struct LevelDerivation {
        let levels: [PlaneRegistration.Plane]
        let candidates: [Candidate]

        enum Verdict: String {
            case accepted
            case belowMinArea       // not enough face area in the slab — a tread, or thin coverage
            case tooSloped          // coherent slope: a ramp, or a slice of one
            case tooNarrow          // a sliver along a wall, or a step nosing
        }

        struct Candidate {
            let y: Float
            let areaM2: Float
            let meanTiltDeg: Float
            let spanM: SIMD2<Float>
            let verdict: Verdict
        }

        /// One-line-per-candidate summary for the build log.
        var traceDescription: String {
            candidates.map { c in
                switch c.verdict {
                case .belowMinArea:
                    return String(format: "y=%+.2f %.1fm² %@", c.y, c.areaM2, c.verdict.rawValue)
                case .tooSloped:
                    return String(format: "y=%+.2f %.1fm² tilt=%.1f° %@", c.y, c.areaM2, c.meanTiltDeg, c.verdict.rawValue)
                default:
                    return String(format: "y=%+.2f %.1fm² tilt=%.1f° %.1f×%.1fm %@",
                                  c.y, c.areaM2, c.meanTiltDeg, c.spanM.x, c.spanM.y, c.verdict.rawValue)
                }
            }.joined(separator: ", ")
        }
    }

    /// Derive LEVEL planes — walkable horizontal surfaces at distinct heights — from the classified
    /// mesh. This is the landings a stairwell has and RoomPlan does not: RoomPlan emits exactly ONE
    /// floor plane per `CapturedRoom`, seated at the lowest adequately-covered horizontal surface, so
    /// every other level in the scan is unmodelled. Runs off the persisted `face_classes.bin`, which
    /// makes it retroactive over saved scans and needs no live RoomPlan session.
    ///
    /// Area-weighted mode-seeking over the floor-class faces' world Y:
    /// - only near-level faces vote (`levelFaceMaxPitchDeg`), so risers and the flight's tread/riser
    ///   junction geometry cannot smear a peak;
    /// - a candidate must gather `levelMinAreaM2` of face area INSIDE a thin
    ///   ±`levelSlabHalfThicknessMeters` slab. This single test does two jobs: it is the
    ///   tread-vs-landing discriminator (one 0.25 m-deep tread contributes ~0.25 m², a landing
    ///   several m²), and it is the flatness guard, since geometry spread over a metre of climb never
    ///   concentrates enough area in any one slab;
    /// - accepted or not, each candidate is cleared with a `levelSeparationMeters` margin, so
    ///   consecutive treads cannot each register as their own level;
    /// - the slab's area-weighted MEAN normal must be near-vertical (`levelMeanTiltMaxDeg`), which is
    ///   what stops a shallow ramp from being chopped into one level per 20 cm of rise — a thin slice
    ///   of a ramp passes every test above, and only the coherence of its normals gives it away.
    ///
    /// Extent is the bounding rectangle of the CONTRIBUTING faces in the reference frame's horizontal
    /// axes — tighter than RoomPlan's whole-footprint quad by construction, since only faces at that
    /// height contribute (the observed pathology was a mid-flight landing's floor quad stretching
    /// across the entire staircase).
    ///
    /// Deliberately class-2-only: admitting unclassified faces would let a table top or a stack of
    /// boxes register as a level. That means a level the classifier missed is simply not found —
    /// visible as a `floorKept` count with no matching level in the build log.
    ///
    /// Sloped surfaces are out of scope here: a ramp has no single Y and would need its own tilted
    /// plane fit. Until that exists, a ramp's faces just fail the pitch gate and survive as mesh.
    static func deriveLevelPlanes(verts: [SIMD3<Float>], faces: [(Int, Int, Int)], faceClasses: Data,
                                  reference: PlaneRegistration.Plane?) -> LevelDerivation {
        let patches = classifyPatches(verts: verts, faces: faces, faceClasses: faceClasses)
        return deriveLevelPlanes(floorPatches: patches.floors, reference: reference)
    }

    /// Patch-based core — the builder computes the class partition once and every consumer reuses it.
    static func deriveLevelPlanes(floorPatches: [SurfacePatch],
                                  reference: PlaneRegistration.Plane?) -> LevelDerivation {
        // One horizontal frame shared by every derived level, so they read as storeys of one building
        // rather than N independently-oriented slabs. RoomPlan's floor plane already carries the
        // room's orientation; world axes when there is none.
        var xAxis = SIMD3<Float>(1, 0, 0)
        var yAxis = SIMD3<Float>(0, 0, 1)
        if let r = reference {
            let fx = SIMD3<Float>(r.xAxis.x, 0, r.xAxis.z)
            let fy = SIMD3<Float>(r.yAxis.x, 0, r.yAxis.z)
            if simd_length(fx) > 0.1, simd_length(fy) > 0.1 {
                xAxis = simd_normalize(fx)
                yAxis = simd_normalize(fy)
            }
        }
        var candidates: [LevelDerivation.Candidate] = []

        // One vote per near-level floor face: its height, area, position in the frame, and normal
        // (sign-normalized upward, since face winding is not trusted — see the mean-tilt gate).
        let cosMaxPitch = cos(levelFaceMaxPitchDeg * .pi / 180)
        var votes: [(y: Float, area: Float, u: Float, v: Float, n: SIMD3<Float>)] = []
        votes.reserveCapacity(floorPatches.count)
        for p in floorPatches where p.n.y >= cosMaxPitch {
            votes.append((y: p.c.y, area: p.area, u: simd_dot(p.c, xAxis), v: simd_dot(p.c, yAxis), n: p.n))
        }
        guard let minY = votes.map(\.y).min(), let maxY = votes.map(\.y).max() else {
            return LevelDerivation(levels: [], candidates: [])
        }

        // Sorted votes + an area prefix sum turn "how much area lies within ±6 cm of this height?"
        // into two binary searches, so the slab test can be exact rather than approximated by whole
        // histogram bins (the histogram's 5 cm grid would not line up with the 6 cm slab).
        let sorted = votes.sorted { $0.y < $1.y }
        var prefix = [Float](repeating: 0, count: sorted.count + 1)
        for (i, v) in sorted.enumerated() { prefix[i + 1] = prefix[i] + v.area }
        /// First index whose height is >= `t`.
        func lowerBound(_ t: Float) -> Int {
            var lo = 0, hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sorted[mid].y < t { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        let bin = levelHistogramBinMeters
        let binCount = max(1, Int(((maxY - minY) / bin).rounded(.up)) + 1)
        var hist = [Float](repeating: 0, count: binCount)
        for v in votes {
            hist[min(binCount - 1, max(0, Int((v.y - minY) / bin)))] += v.area
        }

        // Greedy mode-seeking. The histogram only SELECTS candidate heights — coarse is fine, since
        // the slab below recenters on the true distribution — and gets cleared as levels are taken so
        // one surface cannot be found twice. Every iteration clears at least the separation window, so
        // this terminates whether or not the candidate is accepted.
        let clearBins = max(1, Int((levelSeparationMeters / bin).rounded(.up)))
        var out: [PlaneRegistration.Plane] = []
        while out.count < levelMaxCount {
            guard let peak = hist.indices.max(by: { hist[$0] < hist[$1] }), hist[peak] > 0 else { break }
            let peakY = minY + (Float(peak) + 0.5) * bin
            for i in max(0, peak - clearBins)...min(binCount - 1, peak + clearBins) { hist[i] = 0 }

            let lo = lowerBound(peakY - levelSlabHalfThicknessMeters)
            let hi = lowerBound(peakY + levelSlabHalfThicknessMeters + 1e-6)
            let slabArea = prefix[hi] - prefix[lo]

            // Record every candidate with real area behind it, accepted or not. Each gate below is
            // otherwise a silent `continue`, which makes "there is no landing at that height" and "the
            // landing missed a threshold by a hair" indistinguishable from outside — and those call for
            // opposite responses. Candidates under a quarter of the area bar are noise, not near-misses.
            let worthReporting = slabArea >= 0.25 * levelMinAreaM2
            func record(_ verdict: LevelDerivation.Verdict, tiltDeg: Float, span: SIMD2<Float>) {
                guard worthReporting else { return }
                candidates.append(LevelDerivation.Candidate(y: peakY, areaM2: slabArea,
                                                            meanTiltDeg: tiltDeg, spanM: span,
                                                            verdict: verdict))
            }
            guard slabArea >= levelMinAreaM2 else {
                record(.belowMinArea, tiltDeg: .nan, span: .zero)
                continue
            }

            let slab = Array(sorted[lo..<hi])

            // One level per in-plane CONNECTED COMPONENT of the slab, not one level per height. Two
            // same-height areas separated by a wall are different surfaces, and a single spanning
            // rectangle both draws through the wall and claims mesh next door (device: the landing
            // quad reaching into the adjacent space, over an off-angle staircase, and past the helix
            // wall). A wall's mesh gap breaks contiguity at the 0.25 m component grid; 4-connectivity
            // on purpose, since 8 would corner-leak across a thin gap.
            for compIdx in Self.horizontalComponents(slab.map { (u: $0.u, v: $0.v, area: $0.area) }) {
                guard out.count < levelMaxCount else { break }
                let comp = compIdx.map { slab[$0] }
                let compArea = comp.reduce(Float(0)) { $0 + $1.area }
                let compY = comp.reduce(Float(0)) { $0 + $1.y * $1.area } / max(compArea, 1e-6)
                func recordComp(_ verdict: LevelDerivation.Verdict, tiltDeg: Float, span: SIMD2<Float>) {
                    guard compArea >= 0.25 * levelMinAreaM2 else { return }
                    candidates.append(LevelDerivation.Candidate(y: compY, areaM2: compArea,
                                                                meanTiltDeg: tiltDeg, spanM: span,
                                                                verdict: verdict))
                }
                guard compArea >= levelMinAreaM2 else {
                    recordComp(.belowMinArea, tiltDeg: .nan, span: .zero)
                    continue
                }

                // Slope gate, per component. The slab test alone cannot tell a flat surface from a
                // SLICE of a ramp: a 6 m ADA ramp is under the per-face pitch gate and a 12 cm slice
                // of it holds metres², so a ramp would be chopped into a level every 20 cm of rise.
                // The discriminator is the MEAN normal — per-face noise on a real floor cancels,
                // coherent slope survives averaging — and judging it per component keeps one flat
                // landing from vouching for a sloped patch elsewhere at the same height.
                let meanN = comp.reduce(SIMD3<Float>.zero) { $0 + $1.n * $1.area } / compArea
                let meanLen = simd_length(meanN)
                let tiltDeg = meanLen > 1e-6 ? acos(min(abs(meanN.y) / meanLen, 1)) * 180 / .pi : Float.nan
                guard tiltDeg <= levelMeanTiltMaxDeg else {
                    recordComp(.tooSloped, tiltDeg: tiltDeg, span: .zero)
                    continue
                }

                guard let uMin = comp.map(\.u).min(), let uMax = comp.map(\.u).max(),
                      let vMin = comp.map(\.v).min(), let vMax = comp.map(\.v).max() else { continue }
                let width = uMax - uMin, height = vMax - vMin
                // A level thinner than this in plan view is a sliver along a wall or a mis-classified
                // step nosing, not a surface anyone stands on.
                guard width >= levelMinSpanMeters, height >= levelMinSpanMeters else {
                    recordComp(.tooNarrow, tiltDeg: tiltDeg, span: SIMD2(width, height))
                    continue
                }
                recordComp(.accepted, tiltDeg: tiltDeg, span: SIMD2(width, height))
                // Height is the component's area-weighted mean, not the peak bin's midpoint — the bin
                // is 5 cm and the levels feed a 15 cm coverage test, so the precision is free accuracy.
                out.append(PlaneRegistration.Plane(
                    center: xAxis * ((uMin + uMax) / 2) + yAxis * ((vMin + vMax) / 2) + SIMD3<Float>(0, compY, 0),
                    normal: SIMD3<Float>(0, 1, 0), xAxis: xAxis, yAxis: yAxis,
                    width: width, height: height, category: .floor))
            }
        }
        return LevelDerivation(levels: out.sorted { $0.center.y < $1.center.y },
                               candidates: candidates.sorted { $0.y < $1.y })
    }

    /// Fit a RAMP — one coherent tilted walkable plane — to the floor-class faces the level planes
    /// leave unexplained. Fitting the REMAINDER rather than a pitch band is what makes this safe: a
    /// ramp's own faces are near-level (an ADA ramp is under 5°), so a pitch band would either miss it
    /// or sweep in half of every real floor. What the levels could not account for is exactly the
    /// candidate set, and on a flat room that remainder is edge speckle the area gate rejects.
    ///
    /// Accepted only if the fit is genuinely a plane and genuinely a slope:
    /// - area-weighted RMS distance to the fitted plane within `rampMaxResidualMeters`. This is what
    ///   rejects a STAIRCASE, whose unexplained faces are the treads of the flight: flat, floor-class,
    ///   spread over a metre of climb, and nowhere near any single plane;
    /// - mean tilt at least `levelMeanTiltMaxDeg` — the same number that stops a ramp being read as a
    ///   level, so the two categories meet exactly, with no gap and no overlap — and at most
    ///   `rampMaxTiltDeg`, comfortably under a staircase's 30–37° effective slope.
    ///
    /// One trimmed re-fit runs before those gates: unrelated speckle in the remainder would otherwise
    /// drag both the normal and the residual of a real ramp.
    ///
    /// Candidates are grouped by normal DIRECTION before anything is fitted, and each group is fitted
    /// independently. One global fit was the original design and it fails outright on a real scene: a
    /// straight ramp, a helical ramp and a stair flight in one scan average into a normal that fits none
    /// of them, the residual blows the gate, and NOTHING is emitted — including the straight ramp that
    /// would have fitted perfectly on its own. Grouping is by the horizontal component of the normal
    /// rather than by azimuth, because a shallow ramp's horizontal component is small (an ADA ramp's is
    /// 0.08) which makes its azimuth extremely noisy; a radius in that plane degrades gracefully where
    /// an angle does not. Membership is tested against the group's SEED, not a running mean, so a
    /// continuously-curving surface cannot chain its way into one group that spans every direction.
    ///
    /// A `rampMinFillRatio` test makes "is this actually quad-like?" explicit rather than hoping the
    /// residual implies it. A curved ramp fitted per-direction produces annular-sector groups whose
    /// bounding rectangle is far larger than the surface inside it, so they are declined and the curve
    /// stays mesh — the right outcome, since a rectangle laid over a curve is exactly the "plane
    /// sticking into open space" failure. A ramp that is mostly a clean quad and then widens into a
    /// trapezoid still passes comfortably, which is the case worth capturing.
    /// What the ramp search found plus what it examined and turned down — the same legibility contract
    /// as `LevelDerivation`, for the same reason: every gate is otherwise a silent nil, and "no ramp
    /// exists" vs "a ramp missed one threshold" call for opposite responses.
    struct RampDerivation {
        let ramps: [PlaneRegistration.Plane]
        let groups: [Group]

        enum Verdict: String {
            case accepted
            case belowMinArea      // not enough candidate area in this direction
            case notPlanar         // residual too high: treads up a flight, or curvature
            case tooFlat           // mean tilt under the level threshold — level-like remainder
            case tooSteep          // past the walkable cap — flight-like
            case tooNarrow         // under the minimum span in some direction
            case poorFill          // planar and sloped, but fills too little of its rectangle: a curve
        }

        struct Group {
            let areaM2: Float
            let tiltDeg: Float
            let rmsM: Float
            let fill: Float        // area / bounding rectangle, NaN before it is computed
            let boxM: SIMD2<Float> // bounding rectangle dims, .zero before computed
            let verdict: Verdict
            /// In-plane occupancy map of the fitted component (rows of #/·), for the verdicts where the
            /// SHAPE is the question — fill and box numbers alone cannot distinguish an L, a diagonal
            /// band, or a strip with a speckle tail, and those call for different fixes.
            let shapeMap: String?
        }

        var traceDescription: String {
            groups.map { g in
                var parts = [String(format: "%.1fm²", g.areaM2)]
                if !g.tiltDeg.isNaN { parts.append(String(format: "tilt=%.1f°", g.tiltDeg)) }
                if !g.rmsM.isNaN { parts.append(String(format: "rms=%.0fmm", g.rmsM * 1000)) }
                if !g.fill.isNaN { parts.append(String(format: "fill=%.2f", g.fill)) }
                if g.boxM != .zero { parts.append(String(format: "box=%.1f×%.1fm", g.boxM.x, g.boxM.y)) }
                parts.append(g.verdict.rawValue)
                return parts.joined(separator: " ")
            }.joined(separator: ", ")
        }
    }

    static func deriveRampPlanes(verts: [SIMD3<Float>], faces: [(Int, Int, Int)], faceClasses: Data,
                                 explainedBy explained: [PlaneRegistration.Plane],
                                 support: [QuadSupport]? = nil) -> RampDerivation {
        let patches = classifyPatches(verts: verts, faces: faces, faceClasses: faceClasses)
        return deriveRampPlanes(floorPatches: patches.floors, explainedBy: explained, support: support)
    }

    /// Patch-based core — the builder computes the class partition once and every consumer reuses it.
    static func deriveRampPlanes(floorPatches: [SurfacePatch],
                                 explainedBy explained: [PlaneRegistration.Plane],
                                 support: [QuadSupport]? = nil) -> RampDerivation {
        typealias Patch = (c: SIMD3<Float>, area: Float, n: SIMD3<Float>)
        let cosMaxPitch = cos(rampFaceMaxPitchDeg * .pi / 180)
        var candidates: [Patch] = []
        for p in floorPatches {
            // Upper bound only — near-level faces MUST be admitted, since that is what a ramp is made
            // of. This just keeps near-vertical junk (a riser the classifier called floor) out.
            guard p.n.y >= cosMaxPitch else { continue }
            guard !quadCovers(explained, support: support, p.c) else { continue }
            candidates.append((c: p.c, area: p.area, n: p.n))
        }

        /// Area-weighted plane through a patch set, with the residual that says whether it IS a plane.
        /// The normal comes from POSITION least-squares, not the mean of mesh face normals: mesh
        /// normals at a ramp's ends are smoothed toward the flat surfaces it transitions into, which
        /// biased a whole fitted ramp shallow (device: top of the quad sitting a foot below the landing
        /// it meets). Positions are the geometry; normals are a derived, smoothed signal — good enough
        /// to seed and orient the solve, not to be the estimate.
        func fit(_ patches: [Patch]) -> (n: SIMD3<Float>, c: SIMD3<Float>, area: Float, rms: Float)? {
            let area = patches.reduce(Float(0)) { $0 + $1.area }
            guard area > 1e-6 else { return nil }
            let centroid = patches.reduce(SIMD3<Float>.zero) { $0 + $1.c * $1.area } / area
            let meanN = patches.reduce(SIMD3<Float>.zero) { $0 + $1.n * $1.area } / area
            guard simd_length(meanN) > 1e-6 else { return nil }
            // Smallest eigenvector of the area-weighted position covariance = best-fit plane normal.
            // Inverse iteration seeded by the mean normal: each solve amplifies the smallest-eigenvalue
            // component, and for a strip metres across with millimetres of thickness two or three
            // rounds are decisive. A tiny ridge keeps the inverse defined for a perfectly flat set.
            var m = simd_float3x3(0)
            for p in patches {
                let d = p.c - centroid
                m.columns.0 += d * (d.x * p.area)
                m.columns.1 += d * (d.y * p.area)
                m.columns.2 += d * (d.z * p.area)
            }
            let ridge = max(1e-9, 1e-6 * (m.columns.0.x + m.columns.1.y + m.columns.2.z))
            m.columns.0.x += ridge
            m.columns.1.y += ridge
            m.columns.2.z += ridge
            var n = simd_normalize(meanN)
            let inv = m.inverse
            for _ in 0..<3 {
                let next = inv * n
                let len = simd_length(next)
                guard len.isFinite, len > 1e-12 else { break }
                n = next / len
            }
            if simd_dot(n, meanN) < 0 { n = -n }
            let variance = patches.reduce(Float(0)) { acc, p in
                let d = simd_dot(p.c - centroid, n)
                return acc + p.area * d * d
            } / area
            return (n: n, c: centroid, area: area, rms: sqrt(variance))
        }

        /// Fit one direction-group to a single plane and gate it. The verdict carries the measurement
        /// that decided it either way.
        func fitRamp(_ patches: [Patch]) -> (plane: PlaneRegistration.Plane?, group: RampDerivation.Group) {
            func declined(_ v: RampDerivation.Verdict, area: Float, tilt: Float = .nan,
                          rms: Float = .nan, fill: Float = .nan, box: SIMD2<Float> = .zero,
                          shape: String? = nil) -> (PlaneRegistration.Plane?, RampDerivation.Group) {
                (nil, RampDerivation.Group(areaM2: area, tiltDeg: tilt, rmsM: rms, fill: fill,
                                           boxM: box, verdict: v, shapeMap: shape))
            }
            guard let rough = fit(patches), rough.area >= rampMinAreaM2 else {
                return declined(.belowMinArea, area: patches.reduce(0) { $0 + $1.area })
            }
            let trimmed = patches.filter {
                abs(simd_dot($0.c - rough.c, rough.n)) <= max(2 * rough.rms, rampTrimFloorMeters)
            }
            guard let f = fit(trimmed), f.area >= rampMinAreaM2 else {
                return declined(.belowMinArea, area: rough.area, rms: rough.rms)
            }
            let tiltDeg = acos(min(abs(f.n.y), 1)) * 180 / .pi
            guard f.rms <= rampMaxResidualMeters else {
                return declined(.notPlanar, area: f.area, tilt: tiltDeg, rms: f.rms)
            }
            guard tiltDeg >= levelMeanTiltMaxDeg else {
                return declined(.tooFlat, area: f.area, tilt: tiltDeg, rms: f.rms)
            }
            guard tiltDeg <= rampMaxTiltDeg else {
                return declined(.tooSteep, area: f.area, tilt: tiltDeg, rms: f.rms)
            }

            // In-plane frame. The provisional axes come from the slope (across / up-slope), but the BOX
            // must align with the surface's own long axis, not the tilt direction: real ramps carry
            // cross-slope (drainage fall — ~1° is normal), and at a shallow main slope even 1° rotates
            // the steepest-descent direction by ~15°, which skews a slope-aligned box off the walkway
            // and balloons it (device map: a clean constant-width strip lying diagonal in its frame,
            // 2.3 m box for a 1.5 m strip). Area-weighted in-plane PCA recovers the strip's axis; the
            // quad's frame just needs to be orthonormal in the plane, nothing downstream assumes
            // up-slope.
            let across = simd_cross(f.n, SIMD3<Float>(0, 1, 0))
            guard simd_length(across) > 1e-3 else {
                return declined(.tooFlat, area: f.area, tilt: tiltDeg, rms: f.rms)
            }
            let xAxis0 = simd_normalize(across)
            let yAxis0 = simd_normalize(simd_cross(xAxis0, f.n))
            let us0 = trimmed.map { simd_dot($0.c - f.c, xAxis0) }
            let vs0 = trimmed.map { simd_dot($0.c - f.c, yAxis0) }
            var suu: Float = 0, svv: Float = 0, suv: Float = 0
            for (i, p) in trimmed.enumerated() {
                suu += p.area * us0[i] * us0[i]
                svv += p.area * vs0[i] * vs0[i]
                suv += p.area * us0[i] * vs0[i]
            }
            // Angle of the principal (long) axis from the provisional u-axis.
            let theta = 0.5 * atan2(2 * suv, suu - svv)
            var major = xAxis0 * cos(theta) + yAxis0 * sin(theta)
            // Keep it pointing broadly up-slope so the map still reads bottom-to-top.
            if simd_dot(major, yAxis0) < 0 { major = -major }
            // The PCA angle diagonalizes but may hand back the minor axis; pick whichever direction
            // actually carries the larger spread.
            let minor = simd_normalize(simd_cross(f.n, major))
            var spreadMajor: Float = 0, spreadMinor: Float = 0
            for p in trimmed {
                let d = p.c - f.c
                let m = simd_dot(d, major), n2 = simd_dot(d, minor)
                spreadMajor += p.area * m * m
                spreadMinor += p.area * n2 * n2
            }
            let yAxis = spreadMajor >= spreadMinor ? simd_normalize(major) : simd_normalize(minor)
            let xAxis = simd_normalize(simd_cross(yAxis, f.n))
            let us = trimmed.map { simd_dot($0.c - f.c, xAxis) }
            let vs = trimmed.map { simd_dot($0.c - f.c, yAxis) }
            guard let uMin = us.min(), let uMax = us.max(), let vMin = vs.min(), let vMax = vs.max() else {
                return declined(.belowMinArea, area: f.area)
            }
            let width = uMax - uMin, height = vMax - vMin
            guard width >= levelMinSpanMeters, height >= levelMinSpanMeters else {
                return declined(.tooNarrow, area: f.area, tilt: tiltDeg, rms: f.rms)
            }
            // The quad-like test, stated outright: how much of the rectangle that would stand in for
            // this surface does the surface actually occupy? A curve fitted per-direction yields
            // annular-sector groups whose bounding rectangle is mostly empty space, and laying a quad
            // over that is precisely the "plane sticking out into open space" failure. A run that widens
            // into a trapezoid still fills most of its box, so the case worth keeping survives.
            // Fill by occupied CELLS, not raw face area: fill judges the SHAPE (does the surface occupy
            // its rectangle?), and face area double-penalizes internal classification holes — 5.9 m² of
            // faces on an ~11 m² strip read as poor fill even with the box tight on the strip.
            var occupied = Set<SIMD2<Int32>>()
            let fillCell = rampComponentCellMeters
            for (i, u) in us.enumerated() {
                occupied.insert(SIMD2(Int32(((u - uMin) / fillCell).rounded(.down)),
                                      Int32(((vs[i] - vMin) / fillCell).rounded(.down))))
            }
            let fill = min(1, Float(occupied.count) * fillCell * fillCell / (width * height))
            // Occupancy map in the fitted frame: which 0.5 m in-plane cells the component actually
            // touches. Downsampled toward ~24 columns for the log.
            func shapeMap() -> String {
                let cell = rampComponentCellMeters
                let cols0 = max(1, Int((width / cell).rounded(.up)))
                let rows0 = max(1, Int((height / cell).rounded(.up)))
                let step = max(1, (max(cols0, rows0) + 23) / 24)
                let cols = (cols0 + step - 1) / step, rows = (rows0 + step - 1) / step
                var grid = [Bool](repeating: false, count: cols * rows)
                for (i, u) in us.enumerated() {
                    let c = min(cols - 1, max(0, Int((u - uMin) / cell) / step))
                    let r = min(rows - 1, max(0, Int((vs[i] - vMin) / cell) / step))
                    grid[r * cols + c] = true
                }
                return (0..<rows).map { r in
                    String((0..<cols).map { grid[r * cols + $0] ? "#" : "·" })
                }.joined(separator: "\n")
            }
            guard fill >= rampMinFillRatio else {
                return declined(.poorFill, area: f.area, tilt: tiltDeg, rms: f.rms, fill: fill,
                                box: SIMD2(width, height), shape: shapeMap())
            }
            let plane = PlaneRegistration.Plane(
                center: f.c + xAxis * ((uMin + uMax) / 2) + yAxis * ((vMin + vMax) / 2),
                normal: f.n, xAxis: xAxis, yAxis: yAxis,
                width: width, height: height, category: .floor)
            return (plane, RampDerivation.Group(areaM2: f.area, tiltDeg: tiltDeg, rmsM: f.rms,
                                                fill: fill, boxM: SIMD2(width, height),
                                                verdict: .accepted, shapeMap: shapeMap()))
        }

        // Group by normal direction against each group's SEED (not a running mean, which would let a
        // continuously-curving surface chain into a single group spanning every direction).
        var groups: [(seed: SIMD2<Float>, area: Float, patches: [Patch])] = []
        for c in candidates {
            let h = SIMD2(c.n.x, c.n.z)
            if let i = groups.firstIndex(where: { simd_distance($0.seed, h) <= rampNormalGroupRadius }) {
                groups[i].area += c.area
                groups[i].patches.append(c)
            } else if groups.count < rampMaxGroups {
                groups.append((seed: h, area: c.area, patches: [c]))
            }
        }

        // Within one direction group, split by plane OFFSET before fitting. Direction alone cannot
        // separate parallel surfaces: a helix's tangent parallels a straight ramp somewhere on every
        // turn, so its fragments join the ramp's group at a different offset, the single fit straddles
        // both planes, and the residual reads bimodal — device-observed as an 8.3 m² group at the
        // ramp's exact tilt dying notPlanar at 94 mm RMS. A true plane's patches agree on offset to
        // ±3–5 cm of mesh noise; anything parallel-but-elsewhere sits decimetres away, so a 1D window
        // along the group normal separates them exactly the way the height slab separates levels.
        func offsetModes(_ patches: [Patch]) -> [[Patch]] {
            let totalArea = patches.reduce(Float(0)) { $0 + $1.area }
            guard totalArea > 1e-6 else { return [] }
            let meanN = patches.reduce(SIMD3<Float>.zero) { $0 + $1.n * $1.area } / totalArea
            guard simd_length(meanN) > 1e-6 else { return [] }
            let axis = simd_normalize(meanN)
            var remaining = patches
                .map { (patch: $0, d: simd_dot($0.c, axis)) }
                .sorted { $0.d < $1.d }
            var modes: [[Patch]] = []
            while modes.count < rampMaxOffsetModes, !remaining.isEmpty {
                // Two-pointer max-area window of fixed width — the offset analogue of the level slab.
                var bestArea: Float = 0
                var bestRange = 0..<0
                var lo = 0
                var windowArea: Float = 0
                var hi = 0
                while lo < remaining.count {
                    while hi < remaining.count,
                          remaining[hi].d - remaining[lo].d <= 2 * rampOffsetSlabHalfMeters {
                        windowArea += remaining[hi].patch.area
                        hi += 1
                    }
                    if windowArea > bestArea { bestArea = windowArea; bestRange = lo..<hi }
                    windowArea -= remaining[lo].patch.area
                    lo += 1
                    if hi < lo { hi = lo; windowArea = 0 }
                }
                guard bestArea >= 0.5 * rampMinAreaM2 else { break }
                modes.append(remaining[bestRange].map(\.patch))
                // Remove the window plus a margin, so the same plane's edges cannot re-seed a mode.
                let dLo = remaining[bestRange.lowerBound].d - rampOffsetSlabHalfMeters
                let dHi = remaining[bestRange.upperBound - 1].d + rampOffsetSlabHalfMeters
                remaining.removeAll { $0.d >= dLo && $0.d <= dHi }
            }
            return modes
        }

        // Within one offset mode, split by in-plane CONNECTivity before fitting. The offset window
        // cannot separate what is genuinely ON the plane: fragments coplanar with the ramp — a helix's
        // osculating patch, coplanar floor speckle across the hall — pass the offset test at zero
        // residual cost and only show up as a ballooned bounding rectangle (device-observed: rms down
        // to 9 mm but 6.2 m² filling 33% of its box, and a pure-speckle mode at 5%). A contiguous
        // strip is its own component and fills its box; coplanar-but-elsewhere fragments become
        // separate components that die on area.
        func components(_ patches: [Patch]) -> [[Patch]] {
            let totalArea = patches.reduce(Float(0)) { $0 + $1.area }
            guard totalArea > 1e-6 else { return [] }
            let meanN = patches.reduce(SIMD3<Float>.zero) { $0 + $1.n * $1.area } / totalArea
            guard simd_length(meanN) > 1e-6 else { return [patches] }
            let n = simd_normalize(meanN)
            let ref = abs(n.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
            let uAxis = simd_normalize(simd_cross(n, ref))
            let vAxis = simd_cross(n, uAxis)
            // Union by occupied grid cell, 8-connected: two patches connect when their cells touch.
            // A cell is OCCUPIED only above a real area threshold. Without it, sparse coplanar speckle
            // forms corner-touching chains that add almost no area (the fit stays tight) yet bridge the
            // component out to distant geometry — the box balloons while rms sits at mesh noise, which
            // is exactly the poorFill-at-9mm signature. Sub-threshold cells' patches are dropped
            // entirely: they are speckle, not surface.
            let cell = rampComponentCellMeters
            var cellOf: [SIMD2<Int32>: [Int]] = [:]
            var cellArea: [SIMD2<Int32>: Float] = [:]
            for (i, p) in patches.enumerated() {
                let key = SIMD2(Int32((simd_dot(p.c, uAxis) / cell).rounded(.down)),
                                Int32((simd_dot(p.c, vAxis) / cell).rounded(.down)))
                cellOf[key, default: []].append(i)
                cellArea[key, default: 0] += p.area
            }
            cellOf = cellOf.filter { cellArea[$0.key]! >= rampCellMinAreaM2 }
            var comp = [Int](repeating: -1, count: patches.count)
            var next = 0
            for key in cellOf.keys where comp[cellOf[key]![0]] == -1 {
                // BFS over adjacent occupied cells.
                var stack = [key]
                while let k = stack.popLast() {
                    guard let members = cellOf[k], comp[members[0]] == -1 else { continue }
                    for m in members { comp[m] = next }
                    for du in Int32(-1)...1 {
                        for dv in Int32(-1)...1 where du != 0 || dv != 0 {
                            let nk = SIMD2(k.x + du, k.y + dv)
                            if let ms = cellOf[nk], comp[ms[0]] == -1 { stack.append(nk) }
                        }
                    }
                }
                next += 1
            }
            var buckets = [[Patch]](repeating: [], count: next)
            // comp == -1 is a patch whose cell fell under the area threshold — speckle, dropped.
            for (i, p) in patches.enumerated() where comp[i] >= 0 { buckets[comp[i]].append(p) }
            return buckets.sorted {
                $0.reduce(Float(0)) { $0 + $1.area } > $1.reduce(Float(0)) { $0 + $1.area }
            }
        }

        // Largest first, so a cap keeps the surfaces that matter rather than whichever came first in
        // mesh order. Groups under half the area bar are noise, not near-misses — left out of the trace.
        var out: [PlaneRegistration.Plane] = []
        var trace: [RampDerivation.Group] = []
        for group in groups.sorted(by: { $0.area > $1.area }) where out.count < rampMaxCount {
            guard group.area >= 0.5 * rampMinAreaM2 else { continue }
            for mode in offsetModes(group.patches) where out.count < rampMaxCount {
                for component in components(mode) where out.count < rampMaxCount {
                    guard component.reduce(Float(0), { $0 + $1.area }) >= 0.5 * rampMinAreaM2 else { break }
                    let (plane, record) = fitRamp(component)
                    trace.append(record)
                    if let plane { out.append(plane) }
                }
            }
        }
        return RampDerivation(ramps: out, groups: trace)
    }

    /// Upper bound on a face's pitch for it to be a ramp candidate — keeps near-vertical geometry out
    /// while still admitting the near-level faces a real ramp is built from.
    static let rampFaceMaxPitchDeg: Float = 25
    /// Minimum fitted area for a ramp to be real.
    static let rampMinAreaM2: Float = 1.5
    /// How far the candidate faces may sit from the fitted plane, area-weighted RMS. The staircase
    /// test: treads scattered up a flight cannot be close to any single plane.
    static let rampMaxResidualMeters: Float = 0.06
    /// Trim band for the single robust re-fit, when 2×RMS would be tighter than mesh noise warrants.
    static let rampTrimFloorMeters: Float = 0.08
    /// Steepest mean tilt still considered a walkable ramp. Above generous built ramps (~10°) and well
    /// below a staircase's 30–37° effective slope.
    static let rampMaxTiltDeg: Float = 15
    /// Grouping radius in the HORIZONTAL component of the face normal — the up-slope direction. Not an
    /// angle: a shallow ramp's horizontal component is only ~0.08 long, so its azimuth is very noisy
    /// while its position in this plane is stable.
    static let rampNormalGroupRadius: Float = 0.06
    /// Cap on direction groups examined, so a curved surface cannot spawn unbounded work.
    static let rampMaxGroups = 32
    /// Half-width of the offset window that splits parallel surfaces within one direction group — the
    /// offset analogue of the level slab. Wide enough for a real plane's ±3–5 cm of patch noise, narrow
    /// against the ≥ riser-height gap to anything walkable that is parallel but elsewhere.
    static let rampOffsetSlabHalfMeters: Float = 0.08
    /// Cap on offset modes examined per direction group.
    static let rampMaxOffsetModes = 4
    /// Grid cell for the in-plane connectivity split. Patches whose cells touch (8-connected) are one
    /// component, so gaps under ~2 cells merge while a fragment metres away is its own component.
    static let rampComponentCellMeters: Float = 0.5
    /// Minimum face area for a connectivity cell to count as occupied. A fully-meshed 0.5 m cell holds
    /// ~0.25 m²; requiring a quarter of that stops sparse speckle chains from bridging components while
    /// never touching a genuinely-surfaced cell.
    static let rampCellMinAreaM2: Float = 0.06
    /// Cap on ramps emitted per scan.
    static let rampMaxCount = 4
    /// Support-analysis cell size. Finer than the bake lattice on purpose: at 1 m a cell straddling a
    /// landing's edge blends the landing with whatever lies beside it and the blend passes the tilt
    /// gate; at 0.25 m foreign surfaces read their own orientation and are rejected on their merits.
    static let quadSupportCellMeters: Float = 0.25
    /// Minimum face area for a support cell's orientation to count. A fully-meshed 0.25 m cell holds
    /// ~0.06 m²; a quarter of that keeps boundary slivers from claiming cells.
    static let quadSupportCellMinAreaM2: Float = 0.015
    /// Perpendicular band for the model-fitness "present" count: how far off a quad's plane same-family
    /// mesh may sit and still be considered part of what that quad is claiming to model. Wide enough to
    /// see a curve's sagitta bulging away from its chord.
    static let quadModelBandMeters: Float = 1.0
    /// Below this explained/present ratio, a RoomPlan quad is demoted: it neither subtracts nor bakes,
    /// and its mesh stays. A chord across a curve explains only its tangency strip; a real straight
    /// wall explains nearly everything, and thin scanning does not lower the ratio.
    static let quadModelMinExplainedRatio: Float = 0.5
    /// Minimum same-family mesh area near a quad before fitness is judged at all.
    static let quadModelMinMeshAreaM2: Float = 2.0
    /// How far a quad's backed region grows before unbacked cells are dropped, in SUPPORT cells
    /// (0.25 m). The size allowance that keeps a thinly-scanned wall solid while still cutting a quad
    /// off where it runs into open space.
    static let quadSupportDilateCells = 1
    /// How far a cell's area-weighted mean normal may sit from a FLOOR plane's normal and still count as
    /// part of it. Tight, because the surface a level must not absorb is a shallow ramp — an ADA ramp is
    /// only 4.8° away, and absorbing it both draws a lie and suppresses ramp detection.
    static let quadSupportFloorMeanTiltDeg: Float = 3
    /// The same for a WALL plane. Loose, because what a wall must not absorb is a differently-oriented
    /// surface tens of degrees away; tightening it would only punish noise on a genuine wall.
    static let quadSupportWallMeanTiltDeg: Float = 20
    /// Minimum share of its bounding rectangle a ramp must actually occupy. The explicit "quad-like"
    /// test — it is what declines a curve, whose sector-shaped groups leave most of the rectangle empty.
    static let rampMinFillRatio: Float = 0.6

    /// How far off horizontal a floor-class face may be and still vote for a level. Generous, because
    /// per-face normals on a real floor are noisy — coherent slope is rejected by the mean-tilt gate
    /// below, not here.
    static let levelFaceMaxPitchDeg: Float = 10
    /// How far off horizontal a candidate level's AREA-WEIGHTED MEAN normal may be. This is the
    /// flat-surface-vs-slice-of-a-ramp test, so it sits below the 4.76° ADA ramp maximum; floor
    /// flatness tolerances are an order of magnitude tighter than this, so real floors are unaffected.
    static let levelMeanTiltMaxDeg: Float = 2.5
    /// Bin width of the height histogram levels are sought in.
    static let levelHistogramBinMeters: Float = 0.05
    /// Half-thickness of the slab a candidate level's area must fit inside — the flatness test.
    static let levelSlabHalfThicknessMeters: Float = 0.06
    /// Minimum face area within the slab for a level to be real. Doubles as the tread/landing
    /// discriminator, and matches the `minArea` the plane-registration fit already uses.
    static let levelMinAreaM2: Float = 1.0
    /// Minimum height gap between two accepted levels. Above a typical 17–18 cm stair riser, so a
    /// flight cannot register tread-by-tread even if the treads were wide enough to pass on area.
    static let levelSeparationMeters: Float = 0.20
    /// Minimum plan-view span of a derived level in either horizontal direction.
    static let levelMinSpanMeters: Float = 0.6
    /// Cap on derived levels per scan — a backstop against a pathological histogram, not a real limit.
    static let levelMaxCount = 8

    /// Ghost-proxy artifact version header (start of mesh_proxy.obj line 1; the full line carries
    /// ` quadFaces=N` after it). Bump when the builder's output changes materially —
    /// ScanPostprocessor treats a proxy without the CURRENT version as not-yet-built, so older
    /// artifacts regenerate on the next Post-process. v2: RoomPlan quads tessellated to a ~1 m
    /// wireframe grid (v1 quads were invisible as wireframe). v3: quad-dims diagnostic. v4:
    /// header carries the trailing lattice face count so the renderer can draw the sparse lattice
    /// with THICK lines (1 mm lines are sub-pixel beyond ~1.5 m — the "wall lattice only reaches
    /// 1 m up" illusion was thickness falloff, not geometry). v5: floor faces are subtracted only
    /// where a floor quad actually covers them (was unconditional, which deleted stairs/landings/
    /// ramps and substituted the single flat full-extent quad). v6: levels RoomPlan never modelled
    /// (upper landings, platforms) are derived from the classified mesh and baked as their own quads.
    /// v7: a coherently sloped walkable surface is fitted as a tilted ramp quad. v8: no change to the
    /// artifact — the version is also the only "rebuild this" trigger there is, and the kept-floor
    /// tallies are computed during the build, so a corrected diagnostic needs the builder to re-run.
    /// v9: quads exist only where mesh actually backs them, per tessellation cell, for both drawing and
    /// subtraction — a rectangle no longer claims the open space it happens to span. v10: cell support is
    /// decided by the cell's area-weighted mean NORMAL, not mere presence, so a level stops absorbing a
    /// ramp that crosses its height (presence alone was circular — the ramp backed the cells that then
    /// excluded it). v11: derived levels outrank RoomPlan floors at the same height — RoomPlan's floor is
    /// seated on coverage, not geometry (measured 22 cm off), and under cell support a mis-seated plane
    /// backs zero cells, so deduping the level away left real floor with no quad at all. v12: ramp
    /// direction groups split by plane offset before fitting — direction alone cannot separate parallel
    /// surfaces, and helix fragments tangent to a straight ramp were blowing its residual (8.3 m² at the
    /// ramp's tilt dying notPlanar at 94 mm). v13: offset modes split by in-plane connectivity before
    /// fitting — coplanar-but-elsewhere fragments cost no residual and only balloon the bounding box
    /// (9 mm rms at 33% fill), so contiguity is the remaining separator. v14: connectivity cells need
    /// real area to count (speckle chains bridged the box open), and poorFill components log their
    /// in-plane occupancy map so the shape stops being inferred. v15: the box aligns with the strip's
    /// own PCA axis rather than the tilt direction (cross-slope rotates steepest-descent off the
    /// walkway — the map showed a clean strip lying diagonal in its box), and fill counts occupied
    /// cells rather than face area so classification holes stop reading as bad shape. v16: plane
    /// normals from position least-squares (mesh normals smooth toward adjacent flats and biased the
    /// ramp shallow — its top sat a foot under the landing), and ramp candidates selected against
    /// UNDILATED level masks (the 1 m dilation truncated the ramp's ends). v17: support and coverage
    /// assign each face to its BEST-fit plane instead of any plane within tolerance — first-match let a
    /// landing claim the top of the ramp rising into it and square itself outward over the slope.
    /// v18: support analysis runs on a 0.25 m grid decoupled from the 1 m bake lattice (blended
    /// boundary cells were passing the tilt gate and claiming a metre at a time over ramps, flights and
    /// through walls), and each level is one in-plane connected component rather than one height — two
    /// same-height areas separated by a wall are different surfaces. v19: a RoomPlan quad that explains
    /// too little of the mesh in its own footprint is demoted outright — neither subtracting nor baking
    /// — so a chord across a curved wall stops flattening even its tangency strip, and non-boxy rooms
    /// degrade per-quad to honest mesh instead of failing room-wide.
    static let ghostProxyVersionHeader = "# ghostproxy v19"
    /// Dynamic-mesh artifact version header (start of mesh_dynamic.obj line 1). Same staleness
    /// pattern as `ghostProxyVersionHeader` — ScanPostprocessor treats a dynamic mesh without
    /// the CURRENT version as not-yet-built. v1: initial content-only mesh (no walls/floors/
    /// ceilings, no RoomPlan quads). v2: compacted independently of the proxy, so the off-level
    /// floor faces the proxy started keeping in v5 stay out of the change-detection artifact. v3:
    /// uncovered wall-family faces excluded too — they had always fallen through into the artifact
    /// (dynamic == kept − floorKept exactly), and quad demotion made the contamination wholesale.
    static let dynamicMeshVersionHeader = "# dynamicmesh v3"
    /// Target grid cell size for the tessellated RoomPlan quads.
    static let ghostProxyQuadCellMeters: Float = 1.0
    /// How close a mesh face must be to a RoomPlan quad's PLANE for that quad to count as standing
    /// in for it. Absorbs mesh noise and RoomPlan seating error; also sets the floor-family blind
    /// spot, since a step/ledge shallower than this reads as coplanar and gets subtracted (a typical
    /// stair riser is 17–18 cm, so treads clear it — but a low curb or threshold does not).
    static let ghostProxyQuadCoverageMeters: Float = 0.15
    /// Wireframe line thickness for the proxy's RoomPlan lattice (the mesh remainder keeps the
    /// default 1 mm). Sparse 1 m grid lines need real thickness to survive viewing distance:
    /// 8 mm ≈ 6 px at 3 m — reads as architecture, not noise.
    static let ghostProxyQuadLineThickness: Float = 0.008
    /// Thickness for the synthesized room OUTLINE (plane-rect borders: wall-wall corners,
    /// wall-floor seams, ceiling line) — bolder than the interior lattice so the structural box
    /// reads at a glance.
    static let ghostProxyOutlineThickness: Float = 0.02

    /// Parse the `quadFaces=N` count from a proxy OBJ's version header (nil for legacy/full-mesh
    /// ghosts or older proxy versions). Reads only the first line.
    static func ghostProxyQuadFaceCount(from data: Data) -> Int? {
        let head = data.prefix(64)
        guard let line = String(data: head, encoding: .utf8)?
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first,
              line.hasPrefix(ghostProxyVersionHeader),
              let range = line.range(of: "quadFaces=") else { return nil }
        return Int(line[range.upperBound...].prefix(while: { $0.isNumber }))
    }

    /// A tiny single-triangle snapshot used only in developer/mock modes (e.g. Simulator) where no
    /// real ARMesh exists, so the save pipeline still has geometry to write. `buildMeshOBJ(from:)`
    /// turns it into the same OBJ the old dummy string produced: three vertices + one face.
    static func dummyMeshSnapshot() -> RawMeshSnapshot {
        let verts: [Float] = [-0.5, -0.5, -0.5, 0.5, -0.5, -0.5, 0.5, 0.5, -0.5]
        var vertexData = Data(capacity: verts.count * 4)
        for f in verts { withUnsafeBytes(of: f) { vertexData.append(contentsOf: $0) } }
        let indices: [UInt32] = [0, 1, 2]
        var faceData = Data(capacity: indices.count * 4)
        for i in indices { withUnsafeBytes(of: i) { faceData.append(contentsOf: $0) } }
        let anchor = RawMeshSnapshot.Anchor(
            transform: matrix_identity_float4x4,
            vertexData: vertexData, vertexCount: 3, vertexStride: 12,
            faceData: faceData, faceCount: 1, faceBytesPerPrimitive: 12, faceFormatValid: true,
            classificationData: nil, classificationStride: 0
        )
        return RawMeshSnapshot(
            anchors: [anchor], viewMatrix: matrix_identity_float4x4,
            projMatrix: matrix_identity_float4x4, segmentation: nil
        )
    }

    /// Convenience wrapper: snapshot + build on the calling thread. The Stop pipeline calls
    /// `snapshotMeshBuffers` (on main, co-framed) and `buildMeshOBJ(from:)` (off-main) separately so
    /// the heavy work can't freeze the UI; this single-call form is kept for other callers.
    static func exportMeshOBJ(from currentFrame: ARFrame?, privacyFilter: Bool = false) -> MeshExportResult? {
        guard let snapshot = snapshotMeshBuffers(from: currentFrame, privacyFilter: privacyFilter) else { return nil }
        return buildMeshOBJ(from: snapshot)
    }

    /// Returns a fresh ARWorldTrackingConfiguration with no scene reconstruction
    /// and automatic environment texturing. Used by extend/alignment flows to
    /// reset the AR session to a clean coordinate space.
    static func makeFreshConfiguration() -> ARWorldTrackingConfiguration {
        return makeConfiguration()
    }

    /// Centralized factory for `ARWorldTrackingConfiguration`.
    /// Consolidates LiDAR checks, world map loading, and frame semantics setup
    /// that was previously duplicated across multiple call sites.
    ///
    /// - Parameters:
    ///   - enableMeshReconstruction: When `true`, enables `.mesh` (or `.meshWithClassification`
    ///     if semantic labeling is active) scene reconstruction (requires LiDAR).
    ///   - worldMapURL: Optional URL to an `ARWorldMap` archive for relocalization continuity.
    ///   - enableFrameSemantics: When `true`, adds person segmentation and scene depth semantics.
    /// - Returns: A configured `ARWorldTrackingConfiguration` ready for `session.run()`.
    /// Scene-reconstruction mode. Production is `.meshWithClassification` (meshClassifier defaults ON —
    /// benched at no measurable CPU delta, ~70–100 MB memory; the per-face labels drive the wall/non-wall
    /// split for plane registration and the rescan reference mesh). The Developer-Mode toggle drops back
    /// to plain `.mesh` for re-running the A/B bench (compare the 1 Hz [MemDiag] cpu-by-thread / footprint
    /// timeline + RECORD-START→TEARDOWN deltas). Falls back to `.mesh` if the device can't classify.
    static func meshReconstructionMode() -> ARWorldTrackingConfiguration.SceneReconstruction {
        guard UserDefaults.standard.bool(forKey: AppConstants.Key.meshClassifier),
              ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification)
        else { return .mesh }
        return .meshWithClassification
    }

    static func makeConfiguration(
        enableMeshReconstruction: Bool = false,
        worldMapURL: URL? = nil,
        enableFrameSemantics: Bool = false,
        enablePlaneDetection: Bool = false
    ) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        if supportsLiDAR {
            if enableMeshReconstruction {
                // Plain `.mesh` in production; `.meshWithClassification` under the bench toggle.
                config.sceneReconstruction = meshReconstructionMode()
            } else {
                config.sceneReconstruction = []
            }
        }
        if enablePlaneDetection {
            // Ghost auto-align (alignment phase only): classified wall/floor ARPlaneAnchors are the
            // LIVE side of the plane fit that visually seats the ghost. Far cheaper than mesh
            // reconstruction; not enabled for recording (RoomPlan reconfigures the session there).
            config.planeDetection = [.horizontal, .vertical]
        }
        config.environmentTexturing = .automatic

        // ── Video format selection ──
        //
        // Goal: a 30fps format compatible with continuous AR + LiDAR mesh
        // reconstruction whose camera configuration delivers the highest-resolution
        // stills via captureHighResolutionFrame. 60fps doubles frame delivery without
        // improving mesh/VIO and starves ARKit's frame pool on older devices.
        //
        // Device landscape (verified on M-series iPad Pro, 2026):
        //   • hiRes 16:9 formats (3840×2160) break Recon3D mesh integration:
        //     vio_initialized never clears, producing zero mesh geometry.
        //   • hiRes 4:3 formats (1920×1440 [hiRes]) keep mesh integration intact
        //     AND bind the full photo sensor: captureHighResolutionFrame returns
        //     4032×3024 stills vs 2016×1512 on the standard format.
        //   • recommendedVideoFormatFor4KResolution returns hiRes 16:9 on iPads
        //     (M2/M4), so it cannot be trusted blindly.
        //
        // Selection priority:
        //   1. Highest hiRes 4:3 30fps — mesh-safe, full-sensor stills.
        //   2. Highest standard (non-hiRes) 30fps — typically 1920×1440 (4:3).
        //   3. Apple's 4K pick — last resort, better than ARKit default.
        //   4. ARKit default.
        //
        // Dev settings can force any format index via videoFormatIndex override.
        // The stored value is 1-based (0 = Auto sentinel): value N selects format N-1,
        // matching the picker tags in SettingsView and the [ARConfig] log numbering.
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        let preferredIndex = UserDefaults.standard.integer(forKey: AppConstants.Key.videoFormatIndex)
        if preferredIndex > 0, preferredIndex <= formats.count {
            // Dev override: user selected a specific format in settings
            config.videoFormat = formats[preferredIndex - 1]
        } else {
            let byPixelCount: (ARConfiguration.VideoFormat, ARConfiguration.VideoFormat) -> Bool = {
                $0.imageResolution.width * $0.imageResolution.height
                    < $1.imageResolution.width * $1.imageResolution.height
            }
            // 4:3 check with tolerance (imageResolution is exact, but stay robust).
            let isFourByThree: (ARConfiguration.VideoFormat) -> Bool = {
                abs(($0.imageResolution.width / $0.imageResolution.height) - 4.0 / 3.0) < 0.01
            }
            let bestHiRes43 = formats
                .filter { $0.framesPerSecond == 30 && $0.isRecommendedForHighResolutionFrameCapturing && isFourByThree($0) }
                .max(by: byPixelCount)
            let bestStandard30 = formats
                .filter { $0.framesPerSecond == 30 && !$0.isRecommendedForHighResolutionFrameCapturing }
                .max(by: byPixelCount)
            if let best = bestHiRes43 ?? bestStandard30 {
                config.videoFormat = best
            } else if let fourK = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution {
                config.videoFormat = fourK
            }
            // else: keep ARKit default
        }

        let fmt = config.videoFormat
        print("[ARConfig] Selected video format: \(Int(fmt.imageResolution.width))×\(Int(fmt.imageResolution.height)) @ \(fmt.framesPerSecond)fps")

        // Log all available formats once for device compatibility diagnostics
        if PerfDiag.enabled {
            for (i, f) in formats.enumerated() {
                let tag = f == config.videoFormat ? " ◀ SELECTED" : ""
                let hiRes = f.isRecommendedForHighResolutionFrameCapturing ? " [hiRes]" : ""
                print("[ARConfig]   [\(i)] \(Int(f.imageResolution.width))×\(Int(f.imageResolution.height)) @ \(f.framesPerSecond)fps\(hiRes)\(tag)")
            }
        }

        if let mapURL = worldMapURL,
           let data = try? Data(contentsOf: mapURL),
           let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
            config.initialWorldMap = worldMap
            LocalizationDiag.logMapStats(worldMap, context: mapURL.lastPathComponent) // 0.1: prove compounding/map growth
        }
        if enableFrameSemantics {
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                config.frameSemantics.insert(.personSegmentationWithDepth)
            }
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                config.frameSemantics.insert(.sceneDepth)
            }
        }
        return config
    }

}

// MARK: - Deferred RoomPlan Build  [DEFERRED-ROOMPLAN]

/// [DEFERRED-ROOMPLAN] grep this token for every site of the deferred-build feature: this box, the
/// coordinator storage + currentDeferredRoomBox, startRoomPlanSession (create),
/// startAnalysisRoomPlanSession (clear), didUpdate (recording metadata consume), didEndWith
/// (provide + stopping-session release), makeUIView (wire setRoomDataPersistDir),
/// ScanStore.setRoomDataPersistDir, the post-save hand-off in CaptureView+Recording, and
/// ScanPostprocessor (registration/proxy consume the roomplan this box writes).
///
/// DECISION 3, revised 2026-07-16: this box runs RoomBuilder as a FIRE-AND-FORGET POST-SAVE
/// continuation. The original DECISION-3 cut persisted the raw `CapturedRoomData` for a
/// postprocess-time build — but `CapturedRoomData` is Codable in signature only: BOTH
/// PropertyListEncoder and JSONEncoder throw at runtime ("isn't in the correct format"), so
/// persistence is impossible and the room MUST be built in the capture app-session. The
/// constraints that killed the old save-time build still hold, so:
/// - `provide` (didEndWith, RoomPlan delegate queue) delivers the data; `setPersistDirectory`
///   (called ONLY after saveScan completes) delivers the scan directory. Whichever arrives second
///   starts the build — so RoomBuilder can never overlap the pose-sensitive world-map export or
///   block the save (it isn't on the save path at all; the save never waits).
/// - On success it writes `roomplan.json` + `roomplan_raw.json` (scan dir + raw_data copy) —
///   exactly what ScanPostprocessor's registration/proxy steps consume from disk.
/// - One-shot, no retry loops (the 2026-07-16 OOM was a retry loop around the un-encodable
///   sidecar). Terminal failure leaves the scan roomless → the bad-scan recheck surfaces it.
/// - `buildsInFlight` (static, locked) lets the bad-scan grace check distinguish "build still
///   running" (re-check later) from "room is never coming" (warn redo).
///
/// If the app dies between save and build completion the room is lost (unavoidable without
/// persistence) — the scan then reads BAD at next launch and the redo warning applies.
final class DeferredRoomBuild: @unchecked Sendable {
    private let lock = NSLock()
    private var data: CapturedRoomData?
    private var persistDir: URL?
    private var started = false

    /// Scan directories with a RoomBuilder run currently in flight (paths, standardized).
    private static let inFlightLock = NSLock()
    private static var inFlight: Set<String> = []
    static func isBuildInFlight(scanDirectory: URL) -> Bool {
        inFlightLock.withLock { inFlight.contains(scanDirectory.standardizedFileURL.path) }
    }

    /// Stash the captured data (RoomPlan delegate queue). Cheap — no reconstruction, no wait.
    func provide(_ data: CapturedRoomData) {
        lock.lock()
        self.data = data
        lock.unlock()
        buildIfReady()
    }

    /// Tell the box where the saved scan lives (its scanDirectory). Call AFTER saveScan — this is
    /// what keeps RoomBuilder off the pose-sensitive save path.
    func setPersistDirectory(_ dir: URL) {
        lock.lock()
        persistDir = dir
        lock.unlock()
        buildIfReady()
    }

    /// Run RoomBuilder once both the data and the destination are known — call order is arbitrary
    /// (a throttled device can deliver didEndWith many seconds after the save finished). One-shot.
    private func buildIfReady() {
        lock.lock()
        guard !started, let captured = data, let dir = persistDir else { lock.unlock(); return }
        started = true
        data = nil   // the build holds the only reference; the box won't strand the buffer
        lock.unlock()

        let key = dir.standardizedFileURL.path
        Self.inFlightLock.withLock { _ = Self.inFlight.insert(key) }
        Self.log.info("Deferred RoomBuilder starting (post-save) → \(dir.lastPathComponent, privacy: .public)")

        DispatchQueue.global(qos: .utility).async {
            defer { Self.inFlightLock.withLock { _ = Self.inFlight.remove(key) } }
            guard let room = ScanPostprocessor.buildRoom(from: captured,
                                                         timeout: AppConstants.roomBuilderTimeoutSeconds) else {
                Self.log.warning("Deferred RoomBuilder produced no room — scan stays roomless (bad-scan check will surface it)")
                return
            }
            // Write to the scan dir top level (viewer / gates / registration target lookups) and
            // mirror into raw_data (export staging parity). saveScan's promotion already ran, so
            // this writes both itself.
            RoomPlanExporter.writeRoomPlan(room, to: dir)
            let rawDir = dir.appendingPathComponent("raw_data")
            if FileManager.default.fileExists(atPath: rawDir.path) {
                RoomPlanExporter.writeRoomPlan(room, to: rawDir)
            }
            Self.log.info("Deferred RoomBuilder finished — roomplan.json written")
        }
    }

    /// Always-on (NOT perfDiag-gated) logger, so a real RoomPlan no-data/failed-build case is
    /// diagnosable in the field without Developer Mode.
    private static let log = Logger(subsystem: PerfDiag.subsystem, category: "roomplan")
}

// MARK: - RoomCaptureSessionDelegate

/// RoomPlan delegate — receives real-time room structure updates. Runs on arbitrary queue.
extension ARCoverageView.Coordinator: RoomCaptureSessionDelegate {
    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        // This delegate runs on an arbitrary queue; latestCapturedRoom / the SwiftUI binding are
        // main-only, so hop once.
        //
        // DEFERRED BUILD: recording mode consumes the live room ONLY for cheap metadata (semantic
        // classes for the HUD/saved data + the room handed to ScanCoach) — NOT the outline geometry.
        // Building outlines (RealityKit mesh per surface every update) was the ~215 MB of contested
        // during-scan footprint that competed with VIO; that's gone. The export-quality room is
        // reconstructed by RoomBuilder from CapturedRoomData AFTER the scan (see below) — a better
        // model, built when tracking is done and there's nothing to starve. Analysis mode (pre-scan
        // SpaceAnalyzer) consumes the full room live: it's short, runs before the heavy mesh scan.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.isAnalysisRoomPlan {
                self.latestCapturedRoom = room
                self.scanStats?.analysisRoom = room
            } else {
                // [DEFERRED-ROOMPLAN] Tier-2 recording-mode consume: feed the live room to ScanCoach
                // (finalCapturedRoom) and extract semantic classes for the HUD + saved metadata — but
                // NOT the outline geometry (that was the ~215MB the migration removed). The live room
                // is overwritten at save by the RoomBuilder reconstruction (better geometry for export).
                self.latestCapturedRoom = room   // so stopRoomPlanSession's finalCapturedRoom hand-off isn't nil'd
                self.finalCapturedRoomBinding?.wrappedValue = room
                self.extractRoomMetadata(from: room)
                if self.loggedRoomPlanReady.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged {
                    // [MemDiag] First recording-mode room update = RoomPlan's CoreML models have run
                    // once and are resident. RP-START→RP-READY delta ≈ model-load cost (mesh still
                    // near-empty this early, so the delta is RoomPlan-dominated). See loggedRoomPlanReady.
                    PerfDiag.log("[MemDiag] EVENT RP-READY \(self.memMarker())")
                }
            }
        }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
        if let error = error {
            PerfDiag.log("RoomPlan session ended with error: \(error.localizedDescription)")
        } else {
            PerfDiag.log("RoomPlan session ended cleanly")
        }
        PerfDiag.log("[MemDiag] EVENT RP-DIDEND \(memMarker())")

        // Mid-scan RoomPlan failure (e.g. "World tracking failure" from drift under a fast
        // sweep) surfaces here with a non-nil error while recording is still active — the
        // intended-Stop path stores isRecording=false BEFORE calling stopRoomPlanSession, so
        // a clean stop won't enter this branch.
        //
        // CRUCIAL: RoomPlan (RSCaptureSession) runs its OWN SLAM that can fail independently
        // of the main ARKit session. RoomPlan dying does NOT by itself mean the scan is bad —
        // it just means we lose the structured-room data; the frames/mesh/poses from ARKit are
        // still good as long as ARKit's tracking is healthy. So only escalate to the
        // VIO-compromised halt when ARKit's OWN tracking is also degraded at this moment. If
        // ARKit is normal, log and keep scanning; the ARKit frame-gap/sustained-degradation
        // guard remains the backstop for genuine ARKit loss. (Checked on main, where arView
        // and the ARSession are owned.)
        if error != nil, isRecording.load(ordering: .relaxed) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.isRecording.load(ordering: .relaxed) else { return }
                let arTrackingNormal: Bool
                switch self.arView?.session.currentFrame?.camera.trackingState {
                case .normal: arTrackingNormal = true
                default: arTrackingNormal = false
                }
                if arTrackingNormal {
                    PerfDiag.log("RoomPlan world-tracking failure mid-scan, but ARKit tracking is normal — continuing (structured-room data lost, scan preserved)")
                } else {
                    PerfDiag.log("⛔️ RoomPlan failure + ARKit tracking degraded mid-scan — halting scan")
                    self.vioCompromisedBinding?.wrappedValue = true
                }
            }
        }

        // [DEFERRED-ROOMPLAN] DECISION 3 — STASH ONLY (no reconstruction here). Hand the raw
        // CapturedRoomData to the box; it runs RoomBuilder once the post-save hand-off also
        // delivers the scan directory (so the build can't overlap the world-map export) and
        // writes roomplan.json/_raw itself. `provide` is a no-op if no recording box exists
        // (analysis-mode / RoomPlan-off), so those ends are ignored.
        //
        // Identity guard: only accept data from the LIVE session or the one we just stopped (held
        // in stoppingRoomCaptureSession until this callback). A didEndWith so late that a NEW
        // recording already superseded it must not feed the new recording's box with the old
        // scan's room. (Both refs are written on main; a racy read here only widens/narrows a
        // guard whose miss window is a many-seconds-late callback — acceptable.)
        guard session === roomCaptureSession || session === stoppingRoomCaptureSession else {
            PerfDiag.log("RoomPlan didEndWith from a superseded session — dropped")
            return
        }
        currentDeferredRoomBox()?.provide(data)
        // The data is delivered — release the stopping-session hold (see stopRoomPlanSession).
        DispatchQueue.main.async { [weak self] in self?.stoppingRoomCaptureSession = nil }
    }

    func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration) {
        PerfDiag.log("RoomPlan session started scanning")
        // RoomPlan just reconfigured the shared ARSession, dropping the frame semantics we need for
        // depth/confidence capture and privacy segmentation. Re-assert them — but ONLY once tracking
        // is .normal. Re-running session.run() while tracking is still initializing destabilizes VIO
        // and makes RoomPlan fail with "world tracking failure" (zero frames) on cold first scans.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.arView?.session.currentFrame?.camera.trackingState == .normal {
                self.reassertFrameSemantics()
            } else {
                self.needsSemanticReassert.store(true, ordering: .relaxed) // deferred to tracking .normal
            }
        }
    }

    // iOS 17+ provides instruction updates — log them for debugging, ignore otherwise.
    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        PerfDiag.log("RoomPlan instruction: \(instruction)")
        DispatchQueue.main.async { [weak self] in
            self?.scanStats?.roomPlanInstruction = instruction
        }
    }
}
