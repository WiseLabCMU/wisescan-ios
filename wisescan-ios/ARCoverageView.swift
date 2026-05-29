import SwiftUI
import RealityKit
import ARKit

// swiftlint:disable type_body_length
struct ARCoverageView: UIViewRepresentable {
    @Binding var arSession: ARSession?
    @Binding var isRecording: Bool
    @Binding var isSessionReady: Bool
    var scanStats: ScanStats
    var privacyFilter: Bool
    var activeMeshColor: String = AppConstants.activeMeshColor
    var useFrontCamera: Bool = false
    var initialWorldMapURL: URL? = nil // Support for Scan4D anchoring
    var initialGhostMeshData: Data? = nil // Raw OBJ data from the previous scan
    var scanStore: ScanStore? = nil // Runtime state for boundary anchor tracking

    /// Well-known name for boundary anchors so they can be identified across sessions.
    static let boundaryAnchorName = "Scan4D_Boundary_Anchor"

    /// Whether this device has LiDAR for scene reconstruction and depth capture.
    static let supportsLiDAR = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // Start in nominal mode: camera passthrough only, no scene reconstruction
        // EXCEPT if we are extending a scan, in which case we load the map right away
        let config = Self.makeConfiguration(worldMapURL: initialWorldMapURL)
        let runOptions: ARSession.RunOptions = config.initialWorldMap != nil ? [.resetTracking, .removeExistingAnchors] : []

        context.coordinator.scanStats = scanStats
        context.coordinator.arView = arView
        context.coordinator.privacyFilter = privacyFilter
        context.coordinator.activeMeshColor = activeMeshColor
        context.coordinator.isRecording = false
        context.coordinator.isSessionReadyBinding = $isSessionReady
        context.coordinator.hasWorldMap = (config.initialWorldMap != nil)
        context.coordinator.scanStore = scanStore

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

        // If the session is already running (e.g. tab switch back) but isSessionReady
        // was reset in onDisappear, re-signal readiness immediately.
        if !isSessionReady && uiView.session.currentFrame != nil {
            DispatchQueue.main.async {
                self.isSessionReady = true
            }
            context.coordinator.hasSetSessionReady = true
        }

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

        // Detect recording state change → switch AR session config
        let wasRecording = context.coordinator.isRecording
        if isRecording != wasRecording {
            context.coordinator.isRecording = isRecording
            if isRecording {
                // Upgrade to full scene reconstruction — preserve world map for coordinate continuity
                let config = Self.makeConfiguration(
                    enableMeshReconstruction: true,
                    worldMapURL: initialWorldMapURL,
                    enableFrameSemantics: true
                )
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

                let config = Self.makeConfiguration()
                uiView.session.run(config)
                // Clear ALL debug options for pure passthrough
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
                let config = Self.makeConfiguration(
                    enableMeshReconstruction: isRecording,
                    enableFrameSemantics: isRecording
                )
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
        var scanStats: ScanStats?
        weak var arView: ARView?
        var privacyFilter: Bool = true
        var activeMeshColor: String = AppConstants.activeMeshColor
        var isUsingFrontCamera: Bool = false
        var isRecording: Bool = false
        var isSessionReadyBinding: Binding<Bool>?
        var hasSetSessionReady = false
        private var anchorUpdateCounts: [UUID: Int] = [:]
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

        // Boundary Anchor tracking
        weak var scanStore: ScanStore?
        var boundaryAnchorEntity: AnchorEntity?
        var boundaryAnchorId: UUID? = nil

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

            scanStats?.hasBoundaryAnchor = false

            // Remove boundary anchor visual from the scene — prevents stale marker
            // from appearing at wrong position after session/coordinate-frame reset.
            if let existing = boundaryAnchorEntity {
                existing.removeFromParent()
            }
            boundaryAnchorEntity = nil
            boundaryAnchorId = nil
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

            // Remove boundary anchor visual from the scene
            if let existing = boundaryAnchorEntity {
                existing.removeFromParent()
            }
            boundaryAnchorEntity = nil
            boundaryAnchorId = nil

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
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
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

        // Track anchor update counts via delegate + build active mesh wireframe
        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            // Detect boundary anchors from loaded ARWorldMap (visual marker only —
            // phase transitions are driven by tracking state in didUpdate frame).
            for anchor in anchors {
                if anchor.name == ARCoverageView.boundaryAnchorName {
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
            // Always refresh boundary anchor transform — ARKit refines anchor
            // positions during relocalization, and the alignment UI needs the
            // latest position even before recording starts.
            for anchor in anchors where anchor.name == ARCoverageView.boundaryAnchorName {
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

        // MARK: - Boundary Anchor Visual

        /// Adds a vibrant green sphere with a translucent glow at the boundary anchor location.
        func addBoundaryAnchorVisual(at transform: simd_float4x4, in arView: ARView) {
            // Remove existing boundary visual if any
            if let existing = boundaryAnchorEntity {
                existing.removeFromParent()
            }

            // Create a green sphere with pulsing animation
            let sphereMesh = MeshResource.generateSphere(radius: 0.04)
            let material = UnlitMaterial(color: UIColor(red: 0.0, green: 0.95, blue: 0.4, alpha: 1.0))
            let modelEntity = ModelEntity(mesh: sphereMesh, materials: [material])

            // Add a slightly larger translucent outer sphere for glow effect
            let outerMesh = MeshResource.generateSphere(radius: 0.06)
            let outerMaterial = UnlitMaterial(color: UIColor(red: 0.0, green: 0.95, blue: 0.4, alpha: 0.3))
            let outerEntity = ModelEntity(mesh: outerMesh, materials: [outerMaterial])
            modelEntity.addChild(outerEntity)

            // Place at the anchor's world position
            let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let anchorEntity = AnchorEntity(world: position)
            anchorEntity.addChild(modelEntity)

            arView.scene.addAnchor(anchorEntity)
            boundaryAnchorEntity = anchorEntity
        }
    }

    // MARK: - Export

    static func exportMeshOBJ(from session: ARSession?, privacyFilter: Bool = false) -> (data: Data, vertexCount: Int, faceCount: Int)? {
        guard let session = session, let currentFrame = session.currentFrame else { return nil }

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
        return (objData, totalVertices, totalFaces)
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
    ///   - enableMeshReconstruction: When `true`, enables `.mesh` scene reconstruction (requires LiDAR).
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
            config.sceneReconstruction = enableMeshReconstruction ? .mesh : []
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
