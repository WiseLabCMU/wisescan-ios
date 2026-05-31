import SwiftUI
import RealityKit
import ARKit

struct ARCoverageView: UIViewRepresentable {
    @Binding var arSession: ARSession?
    @Binding var isRecording: Bool
    @Binding var isSessionReady: Bool
    var scanStats: ScanStats
    var privacyFilter: Bool
    var activeMeshColor: String = AppConstants.activeMeshColor
    var captureMode: AppConstants.CaptureMode
    var useFrontCamera: Bool = false
    var initialWorldMapURL: URL? = nil // Support for Scan4D anchoring
    var initialGhostMeshData: Data? = nil // Raw OBJ data from the previous scan

    /// Whether this device has LiDAR for scene reconstruction and depth capture.
    static let supportsLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // Start in nominal mode: camera passthrough only, no scene reconstruction
        // EXCEPT if we are extending a scan, in which case we load the map right away
        let config = ARWorldTrackingConfiguration()
        if Self.supportsLiDAR {
            config.sceneReconstruction = []
        }
        if let mapURL = initialWorldMapURL,
           let data = try? Data(contentsOf: mapURL),
           let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
            config.initialWorldMap = worldMap
        }
        let runOptions: ARSession.RunOptions = config.initialWorldMap != nil ? [.resetTracking, .removeExistingAnchors] : []

        context.coordinator.scanStats = scanStats
        context.coordinator.arView = arView
        context.coordinator.privacyFilter = privacyFilter
        context.coordinator.activeMeshColor = activeMeshColor
        context.coordinator.captureMode = captureMode
        context.coordinator.isRecording = false
        context.coordinator.isSessionReadyBinding = $isSessionReady
        context.coordinator.hasWorldMap = (config.initialWorldMap != nil)

        // Always start with the live camera feed — even in VR mode.
        // The VR point cloud + skybox are activated only when recording starts (in updateUIView).
        arView.environment.background = .cameraFeed()

        arView.session.delegate = context.coordinator
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

        // Live active mesh color update — recolor all existing wireframe entities
        if activeMeshColor != context.coordinator.activeMeshColor {
            context.coordinator.activeMeshColor = activeMeshColor
            context.coordinator.recolorActiveMeshEntities()
        }
        
        let modeChanged = (captureMode != context.coordinator.captureMode)
        let recordingChanged = (isRecording != context.coordinator.isRecording)
        
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

        // Detect ghost mesh data changes (e.g., user tapped "Extend Scan" after initial view creation)
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
                let config = ARWorldTrackingConfiguration()
                config.sceneReconstruction = (Self.supportsLiDAR && isRecording) ? .mesh : []
                config.environmentTexturing = .automatic
                if let mapURL = initialWorldMapURL,
                   let data = try? Data(contentsOf: mapURL),
                   let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
                    config.initialWorldMap = worldMap
                }
                let runOptions: ARSession.RunOptions = config.initialWorldMap != nil ? [.resetTracking, .removeExistingAnchors] : []
                context.coordinator.hasWorldMap = (config.initialWorldMap != nil)
                context.coordinator.hasSeenRelocalizing = false
                uiView.session.run(config, options: runOptions)

                // Background parse the new ghost mesh
                Self.loadGhostMesh(data: ghostData, coordinator: context.coordinator, arView: uiView)
            }
        }

        // Detect recording state change → switch AR session config
        if recordingChanged {
            context.coordinator.isRecording = isRecording
            if isRecording {
                // Upgrade to full scene reconstruction — preserve world map for coordinate continuity
                let config = ARWorldTrackingConfiguration()
                if Self.supportsLiDAR {
                    config.sceneReconstruction = .mesh
                }
                config.environmentTexturing = .automatic
                // Preserve the relocalized coordinate system by keeping the world map
                if let mapURL = initialWorldMapURL,
                   let data = try? Data(contentsOf: mapURL),
                   let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
                    config.initialWorldMap = worldMap
                }
                if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                    config.frameSemantics.insert(.personSegmentationWithDepth)
                }
                if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                    config.frameSemantics.insert(.sceneDepth)
                }
                // Don't reset tracking — preserve the current relocalized coordinate frame
                uiView.session.run(config)
                // Active wireframe is now rendered via procedural geometry (not .showSceneUnderstanding)
                // Entities are built incrementally in session(_:didAdd:) and session(_:didUpdate:)
                context.coordinator.resetForRecording()

                // Background parse the ghost mesh if we didn't already load it in nominal mode
                if let ghostData = initialGhostMeshData, context.coordinator.ghostAnchorEntity == nil {
                    Self.loadGhostMesh(data: ghostData, coordinator: context.coordinator, arView: uiView)
                }
            } else {
                // Downgrade to nominal: pure camera passthrough — no overlays
                context.coordinator.resetForNominal()

                // Remove ghost mesh from scene (will be re-added on next recording if needed)
                if let ghostAnchor = context.coordinator.ghostAnchorEntity {
                    ghostAnchor.removeFromParent()
                }

                let config = ARWorldTrackingConfiguration()
                if Self.supportsLiDAR {
                    config.sceneReconstruction = []
                }
                config.environmentTexturing = .automatic
                uiView.session.run(config)
                // Clear ALL debug options for pure passthrough (or VR background)
                uiView.debugOptions = []
            }
        }

        // Detect camera switch
        let currentlyUsingFront = context.coordinator.isUsingFrontCamera
        if useFrontCamera != currentlyUsingFront {
            context.coordinator.isUsingFrontCamera = useFrontCamera
            if useFrontCamera {
                if ARFaceTrackingConfiguration.isSupported {
                    let faceConfig = ARFaceTrackingConfiguration()
                    uiView.session.run(faceConfig, options: [.resetTracking, .removeExistingAnchors])
                }
            } else {
                // Switch back to rear camera — use recording-appropriate config
                let config = ARWorldTrackingConfiguration()
                config.sceneReconstruction = (Self.supportsLiDAR && isRecording) ? .mesh : []
                config.environmentTexturing = .automatic
                if isRecording, ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                    config.frameSemantics.insert(.personSegmentationWithDepth)
                }
                if isRecording, ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                    config.frameSemantics.insert(.sceneDepth)
                }
                if captureMode == .vr, ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                    config.frameSemantics.insert(.sceneDepth) // Always need sceneDepth in VR mode
                }
                uiView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
                // Active wireframe entities are rebuilt automatically by anchor delegate callbacks
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
                let c = ghostColorStr.toSIMD4Color
                // Fully opaque UnlitMaterial — the only stable material in ARView
                let material = UnlitMaterial(color: UIColor(
                    red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1.0
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
                
                let anchorEntity = AnchorEntity(world: .zero)
                anchorEntity.addChild(containerEntity)
                coordinator.ghostAnchorEntity = anchorEntity

                // Only add immediately if no world map is loaded (no relocalization needed)
                // or if the session has already relocalized.
                let canAdd = !coordinator.hasWorldMap || coordinator.hasSeenRelocalizing
                if canAdd && arView.session.currentFrame?.camera.trackingState == .normal && !coordinator.hasAddedGhostMesh {
                    print("Ghost mesh ready, adding immediately (hasWorldMap=\(coordinator.hasWorldMap), relocalized=\(coordinator.hasSeenRelocalizing))")
                    arView.scene.addAnchor(anchorEntity)
                    coordinator.hasAddedGhostMesh = true
                }
            }
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, ARSessionDelegate {
        weak var arView: ARView?
        var scanStats: ScanStats?
        let rootEntity = Entity()
        var privacyFilter: Bool = true
        var activeMeshColor: String = AppConstants.activeMeshColor
        var captureMode: AppConstants.CaptureMode = .ar
        var pointCloudManager: PointCloudManager?
        var vrAnchorEntity: AnchorEntity?
        var isUsingFrontCamera: Bool = false
        var isRecording: Bool = false
        /// Whether the VR black background has been applied (deferred until first frame)
        var vrBackgroundSet: Bool = false
        var isSessionReadyBinding: Binding<Bool>?
        var hasSetSessionReady = false
        private var anchorUpdateCounts: [UUID: Int] = [:]
        /// Coalescing flag: prevents queuing multiple main-actor dispatches
        /// that each hold CVPixelBuffer references → ARFrame retention.
        private var pendingVRUpdate = false
        /// Per-anchor vertex/face counts — avoids reading geometry from session.currentFrame
        /// which pins ARFrame memory alive and triggers "retaining N ARFrames" warnings.
        private var anchorVertexCounts: [UUID: Int] = [:]
        private var anchorFaceCounts: [UUID: Int] = [:]

        // Session capacity tracking
        private var sessionStartTime: Date = Date()
        private var baselineMemoryMB: Double = ScanStats.currentMemoryUsageMB()
        private var trackingDegradationCount: Int = 0
        private var totalTrackingUpdates: Int = 0

        // Active Mesh Wireframe properties
        /// One wireframe entity per ARMeshAnchor, keyed by anchor UUID.
        private var activeMeshEntities: [UUID: (anchor: AnchorEntity, model: Entity)] = [:]
        /// Throttle: last time wireframe was rebuilt for each anchor.
        private var lastAnchorWireframeTime: [UUID: Date] = [:]
        /// Minimum interval between wireframe rebuilds for the same anchor (seconds).
        private let wireframeThrottleInterval: TimeInterval = 0.5

        // Ghost Mesh properties
        var ghostAnchorEntity: AnchorEntity?
        var hasAddedGhostMesh = false
        var hasWorldMap = false
        var hasSeenRelocalizing = false
        var lastGhostMeshDataCount: Int? = nil // Track changes to ghost mesh data

        /// Reset coordinator state when entering recording mode.
        func resetForRecording() {
            anchorUpdateCounts.removeAll()
            anchorVertexCounts.removeAll()
            anchorFaceCounts.removeAll()
            trackingDegradationCount = 0
            totalTrackingUpdates = 0
            sessionStartTime = Date()
            baselineMemoryMB = ScanStats.currentMemoryUsageMB()
            // Clear any stale wireframe entities from a previous recording
            removeAllActiveMeshEntities()
        }

        /// Reset coordinator state when returning to nominal (idle) mode.
        func resetForNominal() {
            anchorUpdateCounts.removeAll()
            anchorVertexCounts.removeAll()
            anchorFaceCounts.removeAll()
            trackingDegradationCount = 0
            totalTrackingUpdates = 0

            // Remove all active mesh wireframe entities from the scene
            removeAllActiveMeshEntities()

            DispatchQueue.main.async { [weak self] in
                // Zero out scan stats
                self?.scanStats?.totalVertices = 0
                self?.scanStats?.totalFaces = 0
                self?.scanStats?.anchorCount = 0
                self?.scanStats?.sessionDuration = 0
                self?.scanStats?.memoryUsageMB = 0
                self?.scanStats?.baselineMemoryMB = 0
                self?.scanStats?.driftEstimate = 0
                self?.scanStats?.averageQuality = 0
                self?.scanStats?.trackingState = "notAvailable"
                self?.scanStats?.trackingReason = ""
            }
        }

        // MARK: - Active Mesh Wireframe

        /// Removes all active mesh wireframe entities from the AR scene.
        private func removeAllActiveMeshEntities() {
            for (_, entry) in activeMeshEntities {
                entry.anchor.removeFromParent()
            }
            activeMeshEntities.removeAll()
            lastAnchorWireframeTime.removeAll()
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

                DispatchQueue.main.async {
                    guard let self = self, let arView = self.arView, self.isRecording else { return }

                    let c = colorStr.toSIMD4Color
                    let material = UnlitMaterial(color: UIColor(
                        red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1.0
                    ))

                    let containerEntity = Entity()
                    for desc in descriptors {
                        if let res = try? MeshResource.generate(from: [desc]) {
                            let model = ModelEntity(mesh: res, materials: [material])
                            containerEntity.addChild(model)
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
                    print("[GhostMesh] Session relocalized (hasWorldMap=\(hasWorldMap), sawRelocalizing=\(hasSeenRelocalizing)). Adding Ghost Mesh overlay.")
                    arView.scene.addAnchor(ghostAnchor)
                    hasAddedGhostMesh = true
                } else if hasWorldMap && !hasSeenRelocalizing {
                    print("[GhostMesh] Tracking is .normal but relocalization not yet confirmed — deferring ghost mesh placement")
                }
            }

            // Track drift via tracking state transitions
            totalTrackingUpdates += 1
            var stateStr = "normal"
            var reasonStr = ""
            switch camera.trackingState {
            case .normal:
                stateStr = "normal"
            case .notAvailable:
                stateStr = "notAvailable"
                trackingDegradationCount += 1
            case .limited(let reason):
                stateStr = "limited"
                switch reason {
                case .excessiveMotion:
                    reasonStr = "Excessive Motion"
                    trackingDegradationCount += 1 // Real drift indicator
                case .insufficientFeatures:
                    reasonStr = "Insufficient Features"
                    trackingDegradationCount += 1 // Real drift indicator
                case .initializing:
                    reasonStr = "Initializing"
                    // Don't count as drift — normal startup
                case .relocalizing:
                    reasonStr = "Relocalizing"
                    // Don't count as drift — normal recovery
                @unknown default:
                    reasonStr = "Unknown"
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.scanStats?.trackingState = stateStr
                self?.scanStats?.trackingReason = reasonStr
            }
        }

        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // Update PointCloudManager in VR mode.
            // IMPORTANT: Extract pixel buffers and camera data HERE (on the delegate queue)
            // so the ARFrame reference is released immediately. Do NOT forward the ARFrame
            // to the main actor — that queues work and holds references to 10+ frames.
            guard captureMode == .vr, let pcm = pointCloudManager else { return }

            // Skip VR updates when tracking is degraded — prevents accumulating
            // voxels with wrong coordinates during SLAM re-initialization.
            guard frame.camera.trackingState == .normal else {
                // If tracking just went to relocalizing/initializing, the coordinate
                // system may have shifted. Clear accumulated voxels to prevent ghosting.
                if case .limited(let reason) = frame.camera.trackingState,
                   (reason == .initializing || reason == .relocalizing) {
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
                self?.pendingVRUpdate = false
                pcm.update(
                    depthMap: depthMap,
                    capturedImage: capturedImage,
                    segBuffer: segBuffer,
                    confidenceMap: confidenceMap,
                    cameraTransform: cameraTransform,
                    intrinsics: intrinsics,
                    privacyFilter: privFilter
                )
                // Seamless transition: flip camera feed → black background on first rendered frame.
                // This avoids showing an empty black scene before points appear.
                if !(self?.vrBackgroundSet ?? true),
                   pcm.hasRenderedFirstFrame,
                   let arView = self?.arView {
                    arView.environment.background = .color(.black)
                    self?.vrBackgroundSet = true
                }
            }
        }

        // Track anchor update counts via delegate + build active mesh wireframe
        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            guard isRecording else { return }
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
            guard isRecording else { return }
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
            guard isRecording else { return }
            for anchor in anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    anchorUpdateCounts.removeValue(forKey: mesh.identifier)
                    anchorVertexCounts.removeValue(forKey: mesh.identifier)
                    anchorFaceCounts.removeValue(forKey: mesh.identifier)
                    // Remove wireframe entity for this anchor
                    if let entry = activeMeshEntities.removeValue(forKey: mesh.identifier) {
                        entry.anchor.removeFromParent()
                    }
                    lastAnchorWireframeTime.removeValue(forKey: mesh.identifier)
                }
            }
            updateStats(in: session)
        }

        func removeAllMeshEntities() {
            for (_, entry) in activeMeshEntities {
                entry.anchor.removeFromParent()
            }
            activeMeshEntities.removeAll()
            lastAnchorWireframeTime.removeAll()
            anchorUpdateCounts.removeAll()
        }

        private func updateStats(in session: ARSession) {
            guard let scanStats = scanStats else { return }

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
    }

    // MARK: - Export

    static func exportMeshOBJ(from session: ARSession?, privacyFilter: Bool = false) -> (data: Data, vertexCount: Int, faceCount: Int)? {
        guard let session = session, let currentFrame = session.currentFrame else { return nil }

        // Get person segmentation for privacy filtering
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

        var objLines: [String] = []
        var vertexOffset = 1
        var totalVertices = 0
        var totalFaces = 0

        for anchor in currentFrame.anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            let geometry = meshAnchor.geometry
            let transform = meshAnchor.transform

            let vertices = geometry.vertices
            var isPersonVertex = [Bool](repeating: false, count: vertices.count)

            for i in 0..<vertices.count {
                let pointer = vertices.buffer.contents().advanced(by: i * vertices.stride)
                let vertex = pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                let localPos = SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                let worldPos = transform * localPos

                objLines.append("v \(worldPos.x) \(worldPos.y) \(worldPos.z)")

                // Check person segmentation
                if let pp = personPixels {
                    let camPos = viewMatrix * worldPos
                    let clipPos = projMatrix * camPos
                    if clipPos.w > 0 {
                        let px = Int((clipPos.x / clipPos.w * 0.5 + 0.5) * Float(pp.width))
                        let py = Int((1.0 - (clipPos.y / clipPos.w * 0.5 + 0.5)) * Float(pp.height))
                        if px >= 0 && px < pp.width && py >= 0 && py < pp.height {
                            let pixel = pp.base.advanced(by: py * pp.stride + px).assumingMemoryBound(to: UInt8.self).pointee
                            isPersonVertex[i] = pixel > 128
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

            for i in 0..<faces.count {
                let pointer = faces.buffer.contents().advanced(by: i * faceBytes)
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
                objLines.append("f \(v1) \(v2) \(v3)")
                totalFaces += 1
            }

            vertexOffset += vertices.count
        }

        if let pp = personPixels {
            CVPixelBufferUnlockBaseAddress(pp.buffer, .readOnly)
        }

        let objString = objLines.joined(separator: "\n") + "\n"
        guard let data = objString.data(using: .utf8), !data.isEmpty else { return nil }
        return (data, totalVertices, totalFaces)
    }

}
