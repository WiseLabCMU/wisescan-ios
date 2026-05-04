import SwiftUI
import RealityKit
import ARKit

struct ARCoverageView: UIViewRepresentable {
    @Binding var arSession: ARSession?
    @Binding var isRecording: Bool
    @Binding var isSessionReady: Bool
    var scanStats: ScanStats
    var privacyFilter: Bool
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
        context.coordinator.isRecording = false
        context.coordinator.isSessionReadyBinding = $isSessionReady
        context.coordinator.hasWorldMap = (config.initialWorldMap != nil)

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
        let wasRecording = context.coordinator.isRecording
        if isRecording != wasRecording {
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
                // Use RealityKit's built-in wireframe for active scan visualization
                uiView.debugOptions.insert(.showSceneUnderstanding)
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
                let config = ARWorldTrackingConfiguration()
                config.sceneReconstruction = (Self.supportsLiDAR && isRecording) ? .mesh : []
                config.environmentTexturing = .automatic
                if isRecording, ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                    config.frameSemantics.insert(.personSegmentationWithDepth)
                }
                if isRecording, ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                    config.frameSemantics.insert(.sceneDepth)
                }
                uiView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
                if isRecording {
                    uiView.debugOptions.insert(.showSceneUnderstanding)
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
            guard let resource = MeshParser.generateWireframeMeshResource(from: data) else { return }
            DispatchQueue.main.async {
                let ghostColorStr = UserDefaults.standard.string(forKey: AppConstants.Key.ghostMeshColor) ?? AppConstants.ghostMeshColor
                let c = ghostColorStr.toSIMD4Color
                // Fully opaque UnlitMaterial — the only stable material in ARView
                let material = UnlitMaterial(color: UIColor(
                    red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1.0
                ))
                let modelEntity = ModelEntity(mesh: resource, materials: [material])
                let anchorEntity = AnchorEntity(world: .zero)
                anchorEntity.addChild(modelEntity)
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
        var isUsingFrontCamera: Bool = false
        var isRecording: Bool = false
        var isSessionReadyBinding: Binding<Bool>?
        var hasSetSessionReady = false
        private var anchorUpdateCounts: [UUID: Int] = [:]

        // Session capacity tracking
        private var sessionStartTime: Date = Date()
        private var baselineMemoryMB: Double = ScanStats.currentMemoryUsageMB()
        private var trackingDegradationCount: Int = 0
        private var totalTrackingUpdates: Int = 0

        // Ghost Mesh properties
        var ghostAnchorEntity: AnchorEntity?
        var hasAddedGhostMesh = false
        var hasWorldMap = false
        var hasSeenRelocalizing = false
        var lastGhostMeshDataCount: Int? = nil // Track changes to ghost mesh data

        /// Reset coordinator state when entering recording mode.
        func resetForRecording() {
            anchorUpdateCounts.removeAll()
            trackingDegradationCount = 0
            totalTrackingUpdates = 0
            sessionStartTime = Date()
            baselineMemoryMB = ScanStats.currentMemoryUsageMB()
        }

        /// Reset coordinator state when returning to nominal (idle) mode.
        func resetForNominal() {
            anchorUpdateCounts.removeAll()
            trackingDegradationCount = 0
            totalTrackingUpdates = 0

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

        // Track anchor update counts via delegate
        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            guard isRecording else { return }
            for anchor in anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    anchorUpdateCounts[mesh.identifier] = 1
                }
            }
            updateStats(in: session)
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            guard isRecording else { return }
            for anchor in anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    anchorUpdateCounts[mesh.identifier, default: 0] += 1
                }
            }
            updateStats(in: session)
        }

        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            guard isRecording else { return }
            for anchor in anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    anchorUpdateCounts.removeValue(forKey: mesh.identifier)
                }
            }
            updateStats(in: session)
        }


        private func updateStats(in session: ARSession) {
            guard let scanStats = scanStats else { return }

            // Extract all data from the frame immediately, then release the reference.
            // This prevents ARKit's "retaining N ARFrames" warning caused by holding
            // strong references to ARFrame while dispatching to main thread.
            let frame = session.currentFrame
            guard let anchors = frame?.anchors else { return }
            
            // Extract ARKit's cumulative assessment of the map
            var statusStr = "notAvailable"
            if #available(iOS 12.0, *) {
                if let status = frame?.worldMappingStatus {
                    switch status {
                    case .mapped: statusStr = "mapped"
                    case .extending: statusStr = "extending"
                    case .limited: statusStr = "limited"
                    case .notAvailable: statusStr = "notAvailable"
                    @unknown default: statusStr = "notAvailable"
                    }
                }
            }
            // ARFrame reference is now released — only extracted values are retained

            var totalVerts = 0
            var totalFaces = 0
            var totalUpdates = 0
            var anchorCount = 0

            for anchor in anchors {
                guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
                totalVerts += meshAnchor.geometry.vertices.count
                totalFaces += meshAnchor.geometry.faces.count
                anchorCount += 1

                totalUpdates += anchorUpdateCounts[meshAnchor.identifier] ?? 0
            }

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
