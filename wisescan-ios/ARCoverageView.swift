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
        // EXCEPT if we are extending a scan, in which case we load the map right away
        let config = Self.makeConfiguration(worldMapURL: initialWorldMapURL)
        let runOptions: ARSession.RunOptions = config.initialWorldMap != nil ? [.resetTracking, .removeExistingAnchors] : []

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
        // Let the stop flow end the recording-mode RoomPlan session promptly (see ScanStore). Weak
        // coordinator capture → no retain cycle; stopRoomPlanSession is idempotent + main-thread-only,
        // and the stop flow invokes this on the main thread.
        scanStore?.requestStopRoomPlan = { [weak coordinator = context.coordinator] in
            coordinator?.stopRoomPlanSession()
        }
        // [DEFERRED-ROOMPLAN] reconstruction hook, drained by the save pipeline off-main after pose capture.
        scanStore?.awaitDeferredRoomPlan = { [weak coordinator = context.coordinator] timeout in
            coordinator?.awaitAndBuildDeferredRoom(timeout: timeout)
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
            let resumeConfig = ARWorldTrackingConfiguration()
            if Self.supportsLiDAR { resumeConfig.sceneReconstruction = [] }
            uiView.session.run(resumeConfig)
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

            if let ghostData = initialGhostMeshData {
                // Load the world map for relocalization
                let config = Self.makeConfiguration(
                    enableMeshReconstruction: isRecording,
                    worldMapURL: initialWorldMapURL
                )

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

        // Apply manual alignment transform offset to ghost mesh
        if let ghostAnchor = context.coordinator.ghostAnchorEntity {
            if isRecording {
                // When recording, the offset is baked into the world origin, so the mesh stays at identity
                ghostAnchor.transform = Transform.identity
            } else {
                let rotation = simd_quatf(angle: ghostYRotation, axis: [0, 1, 0])
                let translation = SIMD3<Float>(ghostXOffset, 0, ghostZOffset)
                ghostAnchor.transform = Transform(rotation: rotation, translation: translation)
            }
        }

        // Detect recording state change → switch AR session config
        if recordingChanged {
            context.coordinator.isRecording.store(isRecording, ordering: .relaxed)
            if isRecording {
                // Upgrade to full scene reconstruction via makeConfiguration — ensures
                // consistent video format (avoiding a 30fps→60fps switch that confuses
                // Recon3D's internal SLAM on some devices, e.g. M2 iPad Pro).
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
                let runOptions: ARSession.RunOptions = config.initialWorldMap != nil ? [] : .removeExistingAnchors
                PerfDiag.log(config.initialWorldMap != nil
                    ? "record-start: extend → preserving anchors + world map"
                    : "record-start: new scan → .removeExistingAnchors (clear prior scan's mesh)")
                uiView.session.run(config, options: runOptions)

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
                let mode = "mode(semanticLabeling=\(sl ? "on" : "off") liveConsume=deferred)"
                PerfDiag.log("[MemDiag] EVENT RECORD-START \(context.coordinator.memMarker()) \(mode)")
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
                uiView.session.run(config)
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
        DispatchQueue.global(qos: .userInitiated).async {
            // Build procedural wireframe: thin 3D quads for each unique edge
            let descriptors = MeshParser.generateWireframeDescriptors(from: data)
            guard !descriptors.isEmpty else { return }

            DispatchQueue.main.async {
                let ghostColorStr = UserDefaults.standard.string(forKey: AppConstants.Key.ghostMeshColor) ?? AppConstants.ghostMeshColor
                let color = ghostColorStr.toSIMD4Color
                // Fully opaque UnlitMaterial — the only stable material in ARView
                let material = UnlitMaterial(rgb: color)

                let containerEntity = Entity()

                // Generating resources on the main thread, 1 chunk per MeshResource.
                // This bypasses RealityKit's multi-part internal buffers and concurrent background generation crashes.
                for desc in descriptors {
                    if let resource = try? MeshResource.generate(from: [desc]) {
                        let chunkModel = ModelEntity(mesh: resource, materials: [material])
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

        /// [DEFERRED-ROOMPLAN] build box for the current recording's RoomPlan capture. Created fresh in
        /// startRoomPlanSession, fed the CapturedRoomData at didEndWith, and drained by the save
        /// pipeline (which triggers RoomBuilder off-main, AFTER pose-sensitive capture). Guarded by a
        /// lock because it's written on main (start/analysis) and read on the RoomPlan + save queues.
        private let deferredRoomLock = NSLock()
        private var deferredRoomBuild: DeferredRoomBuild?
        /// The current recording box (nil for analysis-mode / RoomPlan-off). Thread-safe.
        func currentDeferredRoomBox() -> DeferredRoomBuild? { deferredRoomLock.withLock { deferredRoomBuild } }
        /// Called by the save pipeline on a background queue: waits for capture, runs RoomBuilder,
        /// returns the reconstructed room (or nil). Never touches main; never overlaps pose capture.
        func awaitAndBuildDeferredRoom(timeout: TimeInterval) -> CapturedRoom? {
            currentDeferredRoomBox()?.buildRoom(timeout: timeout)
        }
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
                self?.scanStats?.trackingStatus = .notAvailable
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

            // Transform vertices to world space (same math as exportMeshOBJ)
            var worldPositions = [SIMD3<Float>]()
            worldPositions.reserveCapacity(vertices.count)
            for i in 0..<vertices.count {
                let ptr = vertices.buffer.contents().advanced(by: i * vertices.stride)
                let local = ptr.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let worldPos = anchorTransform * SIMD4<Float>(local.x, local.y, local.z, 1.0)
                worldPositions.append(SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z))
            }

            let faceStride = faces.bytesPerIndex * faces.indexCountPerPrimitive
            var faceIndices = [(UInt32, UInt32, UInt32)]()
            faceIndices.reserveCapacity(faces.count)
            let vertexCount = worldPositions.count
            for i in 0..<faces.count {
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
            // [DEFERRED-ROOMPLAN] Fresh build box for this recording; didEndWith feeds it, save drains it.
            deferredRoomLock.withLock { deferredRoomBuild = DeferredRoomBuild() }
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
            guard changed else { return }
            session.run(config, options: []) // no reset → preserve tracking/world map and RoomPlan
            PerfDiag.log("Re-asserted frame semantics after RoomPlan (sceneDepth + personSegmentation)")
        }

        /// Stops RoomPlan and stores the final CapturedRoom for export.
        /// Call on main thread before recording cleanup.
        func stopRoomPlanSession() {
            guard let session = roomCaptureSession else { return }
            finalCapturedRoom = latestCapturedRoom
            // Push through binding so CaptureView.finishStopRecording can access it for export
            finalCapturedRoomBinding?.wrappedValue = finalCapturedRoom
            session.stop(pauseARSession: false) // keep ARKit alive
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
            if PerfDiag.enabled, frameGap > 0.1 {
                let normal = frame.camera.trackingState == .normal
                PerfDiag.log("ARKit frame gap \(Int(frameGap * 1000))ms (tracking \(normal ? "normal" : "degraded"))")
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
                    if sustainedDegraded || stalled {
                        vioGuardArmed = false // fire once per recording
                        vioDegradedSince = 0
                        let why = stalled ? "frame gap \(Int(frameGap * 1000))ms" : "tracking degraded >\(AppConstants.vioDegradedTripSeconds)s"
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

            guard isRecording.load(ordering: .relaxed) else { return }
            for anchor in anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    anchorUpdateCounts[mesh.identifier] = 1
                    anchorVertexCounts[mesh.identifier] = mesh.geometry.vertices.count
                    anchorFaceCounts[mesh.identifier] = mesh.geometry.faces.count
                    buildWireframeForAnchor(mesh)
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

            guard isRecording.load(ordering: .relaxed) else { return }
            for anchor in anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    anchorUpdateCounts[mesh.identifier, default: 0] += 1
                    anchorVertexCounts[mesh.identifier] = mesh.geometry.vertices.count
                    anchorFaceCounts[mesh.identifier] = mesh.geometry.faces.count
                    buildWireframeForAnchor(mesh)
                }
            }
            updateStats(in: session)
        }

        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
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

            anchors.append(RawMeshSnapshot.Anchor(
                transform: meshAnchor.transform,
                vertexData: vertexData,
                vertexCount: vertices.count,
                vertexStride: vertices.stride,
                faceData: faceData,
                faceCount: faces.count,
                faceBytesPerPrimitive: faceBytesPerPrimitive,
                faceFormatValid: faces.bytesPerIndex == 4 && faces.indexCountPerPrimitive == 3
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
                    totalFaces += 1
                }
            }

            vertexOffset += vCount
        }

        guard !objData.isEmpty else { return nil }

        return MeshExportResult(data: objData, vertexCount: totalVertices, faceCount: totalFaces)
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
            faceData: faceData, faceCount: 1, faceBytesPerPrimitive: 12, faceFormatValid: true
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
    static func makeConfiguration(
        enableMeshReconstruction: Bool = false,
        worldMapURL: URL? = nil,
        enableFrameSemantics: Bool = false
    ) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        if supportsLiDAR {
            if enableMeshReconstruction {
                // RoomPlan handles semantic labeling; ARKit only needs raw mesh.
                config.sceneReconstruction = .mesh
            } else {
                config.sceneReconstruction = []
            }
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
/// coordinator storage + currentDeferredRoomBox/awaitAndBuildDeferredRoom, startRoomPlanSession
/// (create), startAnalysisRoomPlanSession (clear), didUpdate (recording metadata consume), didEndWith (provide),
/// makeUIView (wire awaitDeferredRoomPlan), ScanStore.awaitDeferredRoomPlan, and the save-block build
/// trigger in CaptureView+Recording. Only the trigger is location-bound (must run after world-map
/// export); everything else is plumbing that stays put if the stage moves.
///
/// One-shot coordination box for the deferred RoomPlan reconstruction. Separates the cheap capture
/// (stash `CapturedRoomData` at `didEndWith`) from the expensive reconstruction (`RoomBuilder`), so
/// the build can be triggered by the save pipeline AFTER every pose-sensitive step (mesh snapshot +
/// world-map export) is finished — RoomBuilder never competes with pose capture for CPU.
///
/// A fresh box is created per recording (in `startRoomPlanSession`). `provide` is called once on the
/// RoomPlan delegate queue; `buildRoom` is called once on the save's BACKGROUND queue and blocks only
/// that queue (never main) while it waits for the data and runs the offline reconstruction.
final class DeferredRoomBuild: @unchecked Sendable {
    private let lock = NSLock()
    private var data: CapturedRoomData?
    private let dataReady = DispatchSemaphore(value: 0)
    private var signaled = false
    private var abandoned = false

    /// Stash the captured data (RoomPlan delegate queue). Cheap — no reconstruction.
    func provide(_ data: CapturedRoomData) {
        lock.lock()
        // If buildRoom already gave up (data-wait timeout), a late didEndWith would otherwise leave a
        // potentially large CapturedRoomData buffer lingering in the box until the next recording. Drop it.
        if abandoned { lock.unlock(); return }
        self.data = data
        let first = !signaled
        signaled = true
        lock.unlock()
        if first { dataReady.signal() }
    }

    /// Wait (bounded) for the captured data, then run `RoomBuilder` (offline reconstruction) and
    /// return the room. Call from a background queue AFTER pose-sensitive capture; blocks that queue
    /// only. Returns nil on timeout or reconstruction failure (→ scan saves without a room, no hang).
    func buildRoom(timeout: TimeInterval) -> CapturedRoom? {
        // TWO separate waits. The CapturedRoomData is provided at didEndWith (fires at Stop, well before
        // the save reaches here), so wait only briefly for it: if RoomPlan produced nothing this scan
        // (cold/failed session, didEndWith never fired) bail FAST instead of blocking the save queue for
        // the whole reconstruction timeout. The reconstruction itself then gets the full `timeout`.
        let dataWait = AppConstants.roomPlanDataWaitSeconds
        guard dataReady.wait(timeout: .now() + dataWait) == .success else {
            // Abandon the box so a late provide() (didEndWith firing after we gave up) discards its buffer
            // instead of stranding it in memory; drop anything a race already stashed.
            lock.withLock { abandoned = true; data = nil }
            Self.log.warning("Deferred RoomPlan: no CapturedRoomData within \(Int(dataWait))s — RoomPlan produced nothing this scan; saving without a room")
            return nil
        }
        // Take the data AND release the box's reference: RoomBuilder holds `captured` for the build, so
        // once we hand it off the (potentially large) CapturedRoomData buffer frees when this returns
        // instead of lingering in the box until the next recording.
        guard let captured = lock.withLock({ defer { data = nil }; return data }) else { return nil }

        // [MemDiag] Bracket RoomBuilder to quantify the deferred build's save-time overhead — the cost
        // run 3 (skip-consume + drop) never paid. wall = latency added to the save; cpu-seconds ÷ wall
        // = average cores busy; footprintΔ = its transient working set. Runs after OBJ/colorize, so the
        // app's CPU in this window is dominated by RoomBuilder (a fair attribution). The CPU/footprint
        // reads walk the thread list / hit task_info, so gate them behind PerfDiag so the production save
        // path stays syscall-free.
        let diag = PerfDiag.enabled
        let wall0 = Date()
        let cpu0 = diag ? ScanStats.currentCPUTimeSeconds() : 0
        let foot0 = diag ? ScanStats.currentFootprintMB() : 0
        if diag { PerfDiag.log(String(format: "[MemDiag] EVENT RP-BUILD-START footprint=%.0fMB", foot0)) }

        let done = DispatchSemaphore(value: 0)
        let result = ResultBox()
        let task = Task.detached {
            defer { done.signal() }
            result.value = try? await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: captured)
        }
        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        // Read result.value ONLY when done was signaled (!timedOut). On timeout the detached Task may
        // STILL be writing result.value (cooperative cancel doesn't guarantee it stopped), so touching
        // it here would be a data race — treat a timeout as no-room without reading the box.
        let builtRoom = timedOut ? nil : result.value
        if timedOut {
            // Cancel so a runaway RoomBuilder can't keep burning CPU/memory after the save moved on.
            task.cancel()
            Self.log.warning("Deferred RoomBuilder exceeded \(Int(timeout))s — cancelled; saving without a room")
        }

        if diag {
            let wall = Date().timeIntervalSince(wall0)
            let cpuSecs = ScanStats.currentCPUTimeSeconds() - cpu0
            let foot1 = ScanStats.currentFootprintMB()
            PerfDiag.log(String(format: "[MemDiag] EVENT RP-BUILD-END wall=%.1fs cpu=%.1fs (%.0f%% of 1 core)"
                                + " footprint=%.0fMB (Δ%+.0f) built=%@%@",
                                wall, cpuSecs, wall > 0.01 ? cpuSecs / wall * 100 : 0, foot1, foot1 - foot0,
                                builtRoom == nil ? "NO" : "yes", timedOut ? " (TIMEOUT→cancelled)" : ""))
        }
        return builtRoom
    }

    /// Always-on (NOT perfDiag-gated) logger for the two failure paths above, so a real RoomPlan
    /// stall/no-data is diagnosable in the field without Developer Mode.
    private static let log = Logger(subsystem: PerfDiag.subsystem, category: "roomplan")
    private final class ResultBox: @unchecked Sendable { var value: CapturedRoom? }
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

        // [DEFERRED-ROOMPLAN] step 1 — STASH ONLY (no reconstruction here). RoomBuilder is deliberately
        // NOT run at didEndWith: the world-map export (getCurrentWorldMap, the pose-sensitive save
        // step) runs slightly LATER than this callback, so building here would peg CPU during that
        // capture and risk a drifted/degraded world map. Instead we just hand the raw CapturedRoomData
        // to the box; the save pipeline triggers the actual build AFTER all pose-sensitive capture is
        // done (see CaptureView+Recording). `provide` is a no-op if no recording box exists
        // (analysis-mode / RoomPlan-off), so those ends are ignored.
        currentDeferredRoomBox()?.provide(data)
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
