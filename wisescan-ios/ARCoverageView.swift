import SwiftUI
import RealityKit
import ARKit
import RoomPlan
import Synchronization

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

    /// Whether this device has LiDAR for scene reconstruction and depth capture.
    static let supportsLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

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
        context.coordinator.hasWorldMap = (config.initialWorldMap != nil)
        context.coordinator.scanStore = scanStore

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

        let modeChanged = (captureMode != context.coordinator.captureMode)
        let recordingChanged = (isRecording != context.coordinator.isRecording.load(ordering: .relaxed))

        if modeChanged {
            context.coordinator.captureMode = captureMode
        }

        let shouldShowVR = (captureMode == .vr && isRecording)
        let wasShowingVR = (context.coordinator.pointCloudManager != nil)

        if shouldShowVR && !wasShowingVR {
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

            // Re-configure session for sceneDepth if needed
            if let config = uiView.session.configuration as? ARWorldTrackingConfiguration {
                if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                    config.frameSemantics.insert(.sceneDepth)
                }
                uiView.session.run(config)
            }
            context.coordinator.removeAllMeshEntities()
        } else if !shouldShowVR && wasShowingVR {
            uiView.environment.background = .cameraFeed()
            context.coordinator.pointCloudManager?.destroy()
            context.coordinator.pointCloudManager = nil
            context.coordinator.vrAnchorEntity?.removeFromParent()
            context.coordinator.vrAnchorEntity = nil

            if captureMode == .vr {
                context.coordinator.removeAllMeshEntities()
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
            context.coordinator.hasAddedGhostMesh = false

            if let ghostData = initialGhostMeshData {
                // Load the world map for relocalization
                let config = Self.makeConfiguration(
                    enableMeshReconstruction: isRecording,
                    worldMapURL: initialWorldMapURL
                )

                let runOptions: ARSession.RunOptions = config.initialWorldMap != nil ? [.resetTracking, .removeExistingAnchors] : []
                context.coordinator.hasWorldMap = (config.initialWorldMap != nil)
                context.coordinator.hasSeenRelocalizing = false
                uiView.session.run(config, options: runOptions)

                // Background parse the new ghost mesh
                Self.loadGhostMesh(data: ghostData, coordinator: context.coordinator, arView: uiView)
            }
        }

        // Dismiss ghost mesh if requested
        if dismissGhostMesh, let ghostAnchor = context.coordinator.ghostAnchorEntity {
            uiView.scene.removeAnchor(ghostAnchor)
            context.coordinator.ghostAnchorEntity = nil
            context.coordinator.hasAddedGhostMesh = false
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
                // Upgrade to full scene reconstruction — preserve world map for coordinate continuity
                let config = ARWorldTrackingConfiguration()
                if Self.supportsLiDAR {
                    // RoomPlan handles semantic labeling; ARKit only needs raw mesh for reconstruction.
                    config.sceneReconstruction = .mesh
                }
                config.environmentTexturing = .automatic
                // Preserve the relocalized coordinate system by keeping the world map
                if let mapURL = initialWorldMapURL,
                   let data = try? Data(contentsOf: mapURL),
                   let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
                    config.initialWorldMap = worldMap
                }
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
                // Start RoomPlan session alongside ARKit (shares the same ARSession)
                context.coordinator.startRoomPlanSession(arSession: uiView.session)
                // Add coverage overlay green quad in AR mode
                if captureMode == .ar {
                    context.coordinator.addCoverageGreenQuad(to: uiView)
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
                // Stop RoomPlan and capture final CapturedRoom BEFORE reset clears state
                context.coordinator.stopRoomPlanSession()
                context.coordinator.resetForNominal()
                context.coordinator.removeCoverageGreenQuad()

                // Remove ghost mesh from scene (will be re-added on next recording if needed)
                if let ghostAnchor = context.coordinator.ghostAnchorEntity {
                    ghostAnchor.removeFromParent()
                }

                let config = Self.makeConfiguration()
                uiView.session.run(config)
                // Clear ALL debug options for pure passthrough (or VR background)
                uiView.debugOptions = []
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
                let material = UnlitMaterial(color: UIColor(
                    red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1.0
                ))

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
                let canAdd = !coordinator.hasWorldMap || coordinator.hasSeenRelocalizing
                if canAdd && arView.session.currentFrame?.camera.trackingState == .normal && !coordinator.hasAddedGhostMesh {
                    if let ghostAnchor = coordinator.ghostAnchorEntity {
                        print("Ghost mesh ready, adding immediately (hasWorldMap=\(coordinator.hasWorldMap), relocalized=\(coordinator.hasSeenRelocalizing))")
                        arView.scene.addAnchor(ghostAnchor)
                        coordinator.hasAddedGhostMesh = true
                    }
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

        // Active Mesh Wireframe properties
        /// One wireframe entity per ARMeshAnchor, keyed by anchor UUID.
        private var activeMeshEntities: [UUID: (anchor: AnchorEntity, model: Entity)] = [:]
        /// Throttle: last time wireframe was rebuilt for each anchor.
        private var lastAnchorWireframeTime: [UUID: Date] = [:]
        /// Minimum interval between wireframe rebuilds for the same anchor (seconds).
        private let wireframeThrottleInterval: TimeInterval = 0.5

        // RoomPlan: structured room detection alongside ARKit mesh
        /// Active RoomPlan session sharing our ARSession. Provides oriented surfaces/objects.
        private var roomCaptureSession: RoomCaptureSession?
        /// Latest room snapshot from RoomPlan (updated in real-time via delegate).
        private var latestCapturedRoom: CapturedRoom?
        /// Final CapturedRoom snapshot captured at recording stop (for export).
        var finalCapturedRoom: CapturedRoom?
        /// Single anchor holding all RoomPlan outline entities.
        private var roomPlanOutlineEntity: AnchorEntity?
        /// Throttle: last time RoomPlan outlines were rebuilt.
        private var lastRoomPlanOutlineTime: Date = .distantPast
        /// Accumulated set of detected semantic classes (published to ScanStats for HUD).
        private var detectedSemanticClasses: Set<String> = []

        // Coverage Overlay: 3D occlusion-based negative rendering
        /// The green background quad entity (far plane). Mesh occlusion punches holes.
        private var coverageGreenQuadAnchor: AnchorEntity?

        // Ghost Mesh properties
        var ghostAnchorEntity: AnchorEntity?
        var hasAddedGhostMesh = false
        var hasWorldMap = false
        var hasSeenRelocalizing = false
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
        var isRescanForConnectors = false
        var rescanConnectorsRendered = false

        /// Mirror the rescan connector set from updateUIView. Resets the render gate when the set
        /// changes so the new markers paint on the next relocalization check.
        func syncRescanConnectors(_ anchors: [ConnectorAnchor], isRescan: Bool) {
            let wanted = isRescan ? anchors : []
            if wanted.map(\.id) != rescanConnectorAnchors.map(\.id) {
                rescanConnectorAnchors = wanted
                rescanConnectorsRendered = false
            }
            isRescanForConnectors = isRescan
        }

        /// Renders the named connector markers once the session has relocalized to the saved world
        /// map (tracking `.normal`, and — if a map was loaded — relocalization confirmed). Idempotent
        /// and main-thread only (RealityKit scene mutation).
        func renderRescanConnectorsIfReady(arView: ARView) {
            guard isRescanForConnectors, !rescanConnectorsRendered, !rescanConnectorAnchors.isEmpty else { return }
            let relocalized = (!hasWorldMap || hasSeenRelocalizing)
                && arView.session.currentFrame?.camera.trackingState == .normal
            guard relocalized else { return }
            rescanConnectorsRendered = true
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
                self.sessionStartTime = Date()
                self.lastStatsUpdateTime = .distantPast // let the first stats update publish immediately
                // VIO guard: arm immediately if tracking is already normal at record start; otherwise
                // it arms on the first `.normal` frame (see session(_:didUpdate:)).
                self.vioGuardArmed = (self.arView?.session.currentFrame?.camera.trackingState == .normal)
                self.vioDegradedSince = 0
            }
            // Clear any stale wireframe entities from a previous recording (RealityKit → main)
            removeAllActiveMeshEntities()
            removeRoomPlanOutlines()
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
            rescanConnectorsRendered = false
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
            removeRoomPlanOutlines()
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
            rescanConnectorsRendered = false

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
        }

        /// Recolors all existing active mesh wireframe entities with the current activeMeshColor.
        /// Uses entity replacement (not in-place mutation) to avoid render thread races.
        func recolorActiveMeshEntities() {
            let c = activeMeshColor.toSIMD4Color
            let material = UnlitMaterial(color: UIColor(
                red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1.0
            ))
            for (_, entry) in activeMeshEntities {
                // The stored `model` is a container Entity. Iterate its children (the chunks).
                let children = entry.model.children.map { $0 }
                for child in children {
                    guard let modelEntity = child as? ModelEntity, let mesh = modelEntity.model?.mesh else { continue }
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

                DispatchQueue.main.async {
                    guard let self = self, let arView = self.arView, self.isRecording.load(ordering: .relaxed) else { return }

                    let c = colorStr.toSIMD4Color
                    let material = UnlitMaterial(color: UIColor(
                        red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1.0
                    ))

                    let containerEntity = Entity()

                    // Add wireframe edges
                    for desc in descriptors {
                        if let res = try? MeshResource.generate(from: [desc]) {
                            let model = ModelEntity(mesh: res, materials: [material])
                            containerEntity.addChild(model)
                        }
                    }

                    // Add filled occlusion mesh (invisible, writes depth to punch holes in green quad)
                    if self.captureMode == .ar,
                       let occlusionRes = try? MeshResource.generate(from: [filledDescriptor]) {
                        let occlusionEntity = ModelEntity(
                            mesh: occlusionRes,
                            materials: [OcclusionMaterial()]
                        )
                        containerEntity.addChild(occlusionEntity)
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

        /// Removes the RoomPlan outline entity from the AR scene.
        private func removeRoomPlanOutlines() {
            roomPlanOutlineEntity?.removeFromParent()
            roomPlanOutlineEntity = nil
        }

        /// Starts RoomPlan alongside the existing ARSession.
        /// Call on main thread after recording starts.
        func startRoomPlanSession(arSession: ARSession) {
            let semanticEnabled = UserDefaults.standard.bool(forKey: AppConstants.Key.semanticLabeling)
            guard semanticEnabled else { return }
            roomCaptureSession = RoomCaptureSession(arSession: arSession)
            roomCaptureSession?.delegate = self
            let config = RoomCaptureSession.Configuration()
            roomCaptureSession?.run(configuration: config)
            PerfDiag.log("RoomPlan session started (sharing ARSession)")
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
            PerfDiag.log("RoomPlan session stopped (ARSession preserved)")
        }

        /// Renders oriented bounding-box wireframes from the latest CapturedRoom.
        /// Each Surface/Object becomes a set of 12 colored edges (thin boxes) with the
        /// correct transform. Throttled to avoid per-frame rebuilds.
        private func renderRoomPlanOutlines() {
            guard let room = latestCapturedRoom, let arView = arView else { return }

            // Throttle: rebuild at most every 0.5s
            guard Date().timeIntervalSince(lastRoomPlanOutlineTime) >= AppConstants.semanticThrottleInterval else { return }
            lastRoomPlanOutlineTime = Date()

            // Remove old outlines
            roomPlanOutlineEntity?.removeFromParent()

            let anchorEntity = AnchorEntity(world: .zero)

            // Camera world position — used to lift surface outlines toward the
            // viewer so they draw on top of the co-planar occlusion mesh instead
            // of z-fighting with it. Objects get no lift so the mesh occludes them.
            let cameraPosition = arView.cameraTransform.translation

            // User-configurable filter: only render enabled classes as overlays.
            // All detected classes are still tracked in detectedSemanticClasses so
            // roomplan.json export contains full data regardless of capture-time filter.
            let enabledClasses = SemanticClassPreference.load()

            // Collect detected classes for HUD
            var classes = Set<String>()

            // Render surfaces (walls, floors, doors, windows, openings) — lifted
            // toward the camera so they always render on top of the scan mesh.
            for surface in room.walls + room.floors + room.doors + room.windows + room.openings {
                let semantic = SemanticClass.from(surface.category)
                guard semantic != .none else { continue }
                classes.insert(semantic.rawValue)
                guard enabledClasses.contains(semantic.rawValue) else { continue }
                Self.addWireframeEdges(
                    to: anchorEntity, dimensions: surface.dimensions,
                    transform: surface.transform, color: semantic.color,
                    liftTowardCamera: cameraPosition
                )
            }

            // Render objects (tables, chairs, beds, etc.) — no lift, so they are
            // naturally occluded by the scan mesh while scanning.
            for object in room.objects {
                let semantic = SemanticClass.from(object.category)
                guard semantic != .none else { continue }
                classes.insert(semantic.rawValue)
                guard enabledClasses.contains(semantic.rawValue) else { continue }
                Self.addWireframeEdges(
                    to: anchorEntity, dimensions: object.dimensions,
                    transform: object.transform, color: semantic.color,
                    liftTowardCamera: nil
                )
            }

            arView.scene.addAnchor(anchorEntity)
            roomPlanOutlineEntity = anchorEntity

            // Track all detected classes (for export) but only publish enabled ones to HUD.
            detectedSemanticClasses.formUnion(classes)
            let enabledForHUD = detectedSemanticClasses.filter { enabledClasses.contains($0) }
            DispatchQueue.main.async { [weak self] in
                self?.scanStats?.detectedClasses = enabledForHUD
            }
        }

        /// Edge thickness for RoomPlan wireframe outlines (10mm).
        private static let edgeThickness: Float = 0.01

        /// Adds 12 thin box entities representing the edges of an oriented bounding box.
        /// Each edge is a thin box with the given color.
        ///
        /// - Parameter liftTowardCamera: when non-nil (the camera world position),
        ///   the whole box is nudged along its dominant face normal toward the
        ///   camera by `AppConstants.surfaceOutlineLiftDistance`, so surface outlines draw on top of
        ///   the co-planar occlusion mesh. Pass `nil` for objects so they remain
        ///   embedded in the mesh and are occluded naturally.
        private static func addWireframeEdges(
            to parent: Entity,
            dimensions: SIMD3<Float>,
            transform: simd_float4x4,
            color: SIMD4<Float>,
            liftTowardCamera cameraPosition: SIMD3<Float>? = nil
        ) {
            let t = edgeThickness
            let w = max(dimensions.x, 0.001)
            let h = max(dimensions.y, 0.001)
            let d = max(dimensions.z, 0.001)
            let hw = w / 2, hh = h / 2, hd = d / 2

            let material = UnlitMaterial(color: UIColor(
                red: CGFloat(color.x), green: CGFloat(color.y),
                blue: CGFloat(color.z), alpha: 1.0
            ))

            // Container entity carries the RoomPlan transform
            let container = Entity()
            container.transform = Transform(matrix: transform)

            // Lift surface outlines toward the camera along the surface's normal.
            // RoomPlan surfaces are thin slabs whose normal is the local axis with
            // the smallest dimension; flip it to face the camera, then offset the
            // container in world space (parent anchor is at world origin).
            if let camera = cameraPosition {
                let xAxis = SIMD3<Float>(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
                let yAxis = SIMD3<Float>(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
                let zAxis = SIMD3<Float>(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
                let center = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)

                // Pick the local axis with the smallest extent as the slab normal.
                var normal = zAxis
                if d <= w && d <= h { normal = zAxis }
                else if h <= w && h <= d { normal = yAxis }
                else { normal = xAxis }
                normal = simd_normalize(normal)

                // Orient the normal toward the camera so the lift moves the outline
                // in front of the wall from wherever it's currently being viewed.
                if simd_dot(normal, camera - center) < 0 { normal = -normal }
                container.position += normal * AppConstants.surfaceOutlineLiftDistance
            }

            // 12 edges: 4 along each axis
            // Edges along X (width) — at the 4 vertical corners
            let xEdge = MeshResource.generateBox(width: w, height: t, depth: t)
            for (y, z) in [(-hh, -hd), (-hh, hd), (hh, -hd), (hh, hd)] as [(Float, Float)] {
                let e = ModelEntity(mesh: xEdge, materials: [material])
                e.position = SIMD3(0, y, z)
                container.addChild(e)
            }

            // Edges along Y (height) — at the 4 horizontal corners
            let yEdge = MeshResource.generateBox(width: t, height: h, depth: t)
            for (x, z) in [(-hw, -hd), (-hw, hd), (hw, -hd), (hw, hd)] as [(Float, Float)] {
                let e = ModelEntity(mesh: yEdge, materials: [material])
                e.position = SIMD3(x, 0, z)
                container.addChild(e)
            }

            // Edges along Z (depth) — at the 4 remaining corners
            let zEdge = MeshResource.generateBox(width: t, height: t, depth: d)
            for (x, y) in [(-hw, -hh), (-hw, hh), (hw, -hh), (hw, hh)] as [(Float, Float)] {
                let e = ModelEntity(mesh: zEdge, materials: [material])
                e.position = SIMD3(x, y, 0)
                container.addChild(e)
            }

            parent.addChild(container)
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
            var material = UnlitMaterial(color: UIColor(
                red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 0.3
            ))
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

            // Track relocalization state for ghost mesh placement
            if case .limited(.relocalizing) = camera.trackingState {
                if !hasSeenRelocalizing {
                    hasSeenRelocalizing = true
                    print("[GhostMesh] Session entered relocalizing state — will wait for .normal before placing ghost mesh")
                }
            }

            // Only add ghost mesh after confirmed relocalization (if world map was loaded)
            if camera.trackingState == .normal && !hasAddedGhostMesh {
                let canAdd = !hasWorldMap || hasSeenRelocalizing
                if canAdd, let ghostAnchor = ghostAnchorEntity, let arView = arView {
                    hasAddedGhostMesh = true // set on the delegate queue to prevent re-entry next frame
                    let sawReloc = hasSeenRelocalizing, hadMap = hasWorldMap
                    DispatchQueue.main.async { // RealityKit scene mutation must be on main
                        print("[GhostMesh] Session relocalized (hasWorldMap=\(hadMap), sawRelocalizing=\(sawReloc)). Adding Ghost Mesh overlay.")
                        arView.scene.addAnchor(ghostAnchor)
                    }
                } else if hasWorldMap && !hasSeenRelocalizing {
                    print("[GhostMesh] Tracking is .normal but relocalization not yet confirmed — deferring ghost mesh placement")
                }

                // Track C — same moment the ghost mesh is placed: the session has relocalized to the
                // saved world map, so the stored connector poses now line up with the live frame.
                // Hop to main and run the GATED render there — the connector array is written on main
                // by syncRescanConnectors, so it must never be read from this delegate queue (a
                // concurrent read during reassignment can race on the array's storage). The Bool gates
                // below are a cheap delegate-queue early-out only; `renderRescanConnectorsIfReady`
                // re-checks the gate and reads the array on main (one-shot; idempotent).
                if (!hasWorldMap || hasSeenRelocalizing),
                   isRescanForConnectors, !rescanConnectorsRendered,
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
            let worldMapWasRequested = phase == .loadingWorldMap || hasWorldMap

            if phase == .loadingWorldMap && !hasWorldMap {
                // The world map file was missing or corrupted and failed to load
                DispatchQueue.main.async { [weak self] in
                    self?.scanStore?.mapLoadFailed = true
                    self?.scanStore?.capturePhase = .idle
                }
                return
            }

            let isRelocalized = isTrackingNormal && (!worldMapWasRequested || hasSeenRelocalizing)

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
                // If tracking just went to relocalizing/initializing, the coordinate
                // system may have shifted. Clear accumulated voxels to prevent ghosting.
                if case .limited(let reason) = frame.camera.trackingState,
                   reason == .initializing || reason == .relocalizing {
                    DispatchQueue.main.async { [weak self] in
                        if let pcm = self?.pointCloudManager {
                            pcm.resetVoxels()
                            print("[VR] Tracking degraded (\(reason)) — cleared accumulated voxels")
                        }
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
                    DispatchQueue.main.async { [weak self] in
                        if let entry = self?.activeMeshEntities.removeValue(forKey: id) {
                            entry.anchor.removeFromParent()
                        }
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
            removeRoomPlanOutlines()
        }

        private func updateStats(in session: ARSession) {
            guard let scanStats = scanStats else { return }

            // Throttle to ~10 Hz. Delegate callbacks are serialized on the ARSession
            // queue, so this timestamp needs no synchronization. Resets (on stop) write
            // scanStats directly and bypass this path, so they remain immediate.
            let now = Date()
            guard now.timeIntervalSince(lastStatsUpdateTime) >= statsUpdateInterval else { return }
            lastStatsUpdateTime = now

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

            // Compute capacity metrics
            let duration = Date().timeIntervalSince(sessionStartTime)
            let memoryMB = ScanStats.currentMemoryUsageMB()
            let drift: Double = totalTrackingUpdates > 0
                ? min(Double(trackingDegradationCount) / Double(totalTrackingUpdates), 1.0)
                : 0

            DispatchQueue.main.async { [weak self] in
                scanStats.totalVertices = totalVerts
                scanStats.totalFaces = totalFaces
                scanStats.anchorCount = anchorCount
                scanStats.sessionDuration = duration
                scanStats.memoryUsageMB = memoryMB
                scanStats.baselineMemoryMB = self?.baselineMemoryMB ?? memoryMB
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

    // swiftlint:disable:next function_body_length
    static func exportMeshOBJ(from currentFrame: ARFrame?, privacyFilter: Bool = false) -> MeshExportResult? {
        guard let currentFrame = currentFrame else { return nil }

        // Get person segmentation for privacy filtering
        // swiftlint:disable:next large_tuple
        var personPixels: (buffer: CVPixelBuffer, width: Int, height: Int, stride: Int, base: UnsafeMutableRawPointer)?
        if privacyFilter, let segBuffer = currentFrame.segmentationBuffer {
            CVPixelBufferLockBaseAddress(segBuffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(segBuffer) {
                personPixels = (segBuffer, CVPixelBufferGetWidth(segBuffer), CVPixelBufferGetHeight(segBuffer),
                                CVPixelBufferGetBytesPerRow(segBuffer), base)
            }
        }

        let camera = currentFrame.camera
        // .landscapeRight is correct here because we're projecting mesh vertices into the
        // segmentation buffer's coordinate space, which is always in native sensor orientation
        // (landscape-right). This is independent of the device's display orientation or
        // capture mode. (This method is used for AR mode mesh export; VR mode uses
        // PointCloudManager for its own geometry pipeline.)
        // See FaceBlurOverlay.swift for full orientation architecture documentation.
        let viewMatrix = camera.viewMatrix(for: .landscapeRight)
        let imageRes = camera.imageResolution
        let projMatrix = camera.projectionMatrix(for: .landscapeRight, viewportSize: imageRes, zNear: 0.001, zFar: 100)

        // Write OBJ directly to a Data buffer to avoid intermediate [String] array
        // and the large joined String copy. For large meshes (~300K+ vertices) this
        // roughly halves peak memory vs the array-join approach.
        var objData = Data()
        objData.reserveCapacity(1024 * 1024) // Pre-allocate 1MB; grows as needed
        var vertexOffset = 1
        var totalVertices = 0
        var totalFaces = 0



        for anchor in currentFrame.anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            let geometry = meshAnchor.geometry
            let transform = meshAnchor.transform

            let vertices = geometry.vertices
            var isPersonVertex = [Bool](repeating: false, count: vertices.count)

            for idx in 0..<vertices.count {
                let pointer = vertices.buffer.contents().advanced(by: idx * vertices.stride)
                let vertex = pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let localPos = SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                let worldPos = transform * localPos

                objData.append(contentsOf: "v \(worldPos.x) \(worldPos.y) \(worldPos.z)\n".utf8)

                // Check person segmentation
                if let pp = personPixels {
                    let camPos = viewMatrix * worldPos
                    let clipPos = projMatrix * camPos
                    if clipPos.w > 0 {
                        let px = Int((clipPos.x / clipPos.w * 0.5 + 0.5) * Float(pp.width))
                        let py = Int((1.0 - (clipPos.y / clipPos.w * 0.5 + 0.5)) * Float(pp.height))
                        if px >= 0 && px < pp.width && py >= 0 && py < pp.height {
                            let pixel = pp.base.advanced(by: py * pp.stride + px).assumingMemoryBound(to: UInt8.self).pointee
                            isPersonVertex[idx] = pixel > 128
                        }
                    }
                }
            }
            totalVertices += vertices.count

            let faces = geometry.faces
            let faceBytes = faces.bytesPerIndex * faces.indexCountPerPrimitive

            // Validate face format before iterating
            guard faces.bytesPerIndex == 4, faces.indexCountPerPrimitive == 3 else {
                vertexOffset += vertices.count
                continue
            }

            for faceIdx in 0..<faces.count {
                let pointer = faces.buffer.contents().advanced(by: faceIdx * faceBytes)
                let indices = pointer.assumingMemoryBound(to: (UInt32, UInt32, UInt32).self).pointee


                // Skip person faces if privacy filter is on
                if privacyFilter {
                    let i0 = Int(indices.0)
                    let i1 = Int(indices.1)
                    let i2 = Int(indices.2)
                    if isPersonVertex[i0] || isPersonVertex[i1] || isPersonVertex[i2] {
                        continue
                    }
                }

                let v1 = Int(indices.0) + vertexOffset
                let v2 = Int(indices.1) + vertexOffset
                let v3 = Int(indices.2) + vertexOffset
                objData.append(contentsOf: "f \(v1) \(v2) \(v3)\n".utf8)
                totalFaces += 1
            }



            vertexOffset += vertices.count
        }

        if let pp = personPixels {
            CVPixelBufferUnlockBaseAddress(pp.buffer, .readOnly)
        }

        guard !objData.isEmpty else { return nil }

        return MeshExportResult(data: objData, vertexCount: totalVertices, faceCount: totalFaces)
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

// MARK: - RoomCaptureSessionDelegate

/// RoomPlan delegate — receives real-time room structure updates. Runs on arbitrary queue.
extension ARCoverageView.Coordinator: RoomCaptureSessionDelegate {
    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        latestCapturedRoom = room
        // Continuously push latest room to CaptureView so finishStopRecording can access it
        // before the isRecording→false transition triggers updateUIView.
        finalCapturedRoomBinding?.wrappedValue = room
        // Trigger outline re-render on main thread (MeshResource requires main/Metal context)
        DispatchQueue.main.async { [weak self] in
            self?.renderRoomPlanOutlines()
        }
    }

    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
        if let error = error {
            PerfDiag.log("RoomPlan session ended with error: \(error.localizedDescription)")
        } else {
            PerfDiag.log("RoomPlan session ended cleanly")
        }
    }

    func captureSession(_ session: RoomCaptureSession, didStartWith configuration: RoomCaptureSession.Configuration) {
        PerfDiag.log("RoomPlan session started scanning")
    }

    // iOS 17+ provides instruction updates — log them for debugging, ignore otherwise.
    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        PerfDiag.log("RoomPlan instruction: \(instruction)")
    }
}
