import SwiftUI
import RealityKit
import ARKit

struct ARCoverageView: UIViewRepresentable {
    @Binding var arSession: ARSession?
    @Binding var isRecording: Bool
    var scanStats: ScanStats
    var privacyFilter: Bool
    var useFrontCamera: Bool = false
    var initialWorldMapURL: URL? = nil // Support for Scan4D anchoring
    var initialGhostMeshData: Data? = nil // Raw OBJ data from the previous scan

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            print("Device does not support LiDAR scene reconstruction.")
            return arView
        }

        // Start in nominal mode: camera passthrough only, no scene reconstruction
        // EXCEPT if we are extending a scan, in which case we load the map right away
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = []
        config.environmentTexturing = .automatic
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

        arView.session.delegate = context.coordinator
        // No debug options in nominal mode (no wireframe overlay)

        arView.session.run(config, options: runOptions)

        // Background parse the ghost mesh if provided (Scan4D extend scan)
        if let ghostData = initialGhostMeshData {
            DispatchQueue.global(qos: .userInitiated).async {
                if let resource = MeshParser.generateMeshResource(from: ghostData) {
                    DispatchQueue.main.async {
                        var material = UnlitMaterial(color: .red)
                        material.blending = .transparent(opacity: 0.3)
                        let modelEntity = ModelEntity(mesh: resource, materials: [material])
                        let anchorEntity = AnchorEntity(world: .zero)
                        anchorEntity.addChild(modelEntity)
                        context.coordinator.ghostAnchorEntity = anchorEntity
                        
                        // Prevent race condition: If tracking is already normal before parser finished, add it now.
                        if arView.session.currentFrame?.camera.trackingState == .normal && !context.coordinator.hasAddedGhostMesh {
                            arView.scene.addAnchor(anchorEntity)
                            context.coordinator.hasAddedGhostMesh = true
                        }
                    }
                }
            }
        }

        DispatchQueue.main.async {
            self.arSession = arView.session
        }

        return arView
    }





    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.privacyFilter = privacyFilter

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
                config.sceneReconstruction = isRecording ? .mesh : []
                config.environmentTexturing = .automatic
                if let mapURL = initialWorldMapURL,
                   let data = try? Data(contentsOf: mapURL),
                   let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
                    config.initialWorldMap = worldMap
                }
                let runOptions: ARSession.RunOptions = config.initialWorldMap != nil ? [.resetTracking, .removeExistingAnchors] : []
                uiView.session.run(config, options: runOptions)

                // Background parse the new ghost mesh
                DispatchQueue.global(qos: .userInitiated).async {
                    if let resource = MeshParser.generateMeshResource(from: ghostData) {
                        DispatchQueue.main.async {
                            var material = UnlitMaterial(color: .red)
                            material.blending = .transparent(opacity: 0.3)
                            let modelEntity = ModelEntity(mesh: resource, materials: [material])
                            let anchorEntity = AnchorEntity(world: .zero)
                            anchorEntity.addChild(modelEntity)
                            context.coordinator.ghostAnchorEntity = anchorEntity

                            if uiView.session.currentFrame?.camera.trackingState == .normal && !context.coordinator.hasAddedGhostMesh {
                                uiView.scene.addAnchor(anchorEntity)
                                context.coordinator.hasAddedGhostMesh = true
                            }
                        }
                    }
                }
            }
        }

        // Detect recording state change → switch AR session config
        let wasRecording = context.coordinator.isRecording
        if isRecording != wasRecording {
            context.coordinator.isRecording = isRecording
            if isRecording {
                // Upgrade to full scene reconstruction
                let config = ARWorldTrackingConfiguration()
                config.sceneReconstruction = .mesh
                config.environmentTexturing = .automatic
                if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
                    config.frameSemantics.insert(.personSegmentationWithDepth)
                }
                if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                    config.frameSemantics.insert(.sceneDepth)
                }
                // Load initial world map for Scan4D relocalization
                if let mapURL = initialWorldMapURL,
                   let data = try? Data(contentsOf: mapURL),
                   let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
                    config.initialWorldMap = worldMap
                }
                let runOptions: ARSession.RunOptions = config.initialWorldMap != nil ? [.resetTracking, .removeExistingAnchors] : []
                uiView.session.run(config, options: runOptions)
                uiView.debugOptions.insert(.showSceneUnderstanding)
                context.coordinator.resetForRecording()

                // Background parse the ghost mesh if we didn't already load it in nominal mode
                if let ghostData = initialGhostMeshData, context.coordinator.ghostAnchorEntity == nil {
                    DispatchQueue.global(qos: .userInitiated).async {
                        if let resource = MeshParser.generateMeshResource(from: ghostData) {
                            DispatchQueue.main.async {
                                var material = UnlitMaterial(color: .red)
                                material.blending = .transparent(opacity: 0.3)
                                let modelEntity = ModelEntity(mesh: resource, materials: [material])
                                let anchorEntity = AnchorEntity(world: .zero)
                                anchorEntity.addChild(modelEntity)
                                context.coordinator.ghostAnchorEntity = anchorEntity
                                
                                if uiView.session.currentFrame?.camera.trackingState == .normal && !context.coordinator.hasAddedGhostMesh {
                                    uiView.scene.addAnchor(anchorEntity)
                                    context.coordinator.hasAddedGhostMesh = true
                                }
                            }
                        }
                    }
                }
            } else {
                // Downgrade to nominal: camera passthrough only
                context.coordinator.resetForNominal()
                let config = ARWorldTrackingConfiguration()
                config.sceneReconstruction = []
                config.environmentTexturing = .automatic
                // Preserve the world map if we are in an extend-scan scenario
                if let mapURL = initialWorldMapURL,
                   let data = try? Data(contentsOf: mapURL),
                   let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
                    config.initialWorldMap = worldMap
                }
                let runOptions: ARSession.RunOptions = config.initialWorldMap != nil ? [.resetTracking, .removeExistingAnchors] : [.resetTracking, .removeExistingAnchors]
                uiView.session.run(config, options: runOptions)
                uiView.debugOptions.remove(.showSceneUnderstanding)
                
                // Re-add ghost mesh if extending
                if initialGhostMeshData != nil {
                    if let ghostAnchor = context.coordinator.ghostAnchorEntity {
                        uiView.scene.addAnchor(ghostAnchor)
                        context.coordinator.hasAddedGhostMesh = true
                    }
                }
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
                config.sceneReconstruction = isRecording ? .mesh : []
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

    // MARK: - Coordinator

    class Coordinator: NSObject, ARSessionDelegate {
        var scanStats: ScanStats?
        weak var arView: ARView?
        var privacyFilter: Bool = true
        var isUsingFrontCamera: Bool = false
        var isRecording: Bool = false
        private var anchorUpdateCounts: [UUID: Int] = [:]

        // Session capacity tracking
        private var sessionStartTime: Date = Date()
        private var baselineMemoryMB: Double = ScanStats.currentMemoryUsageMB()
        private var trackingDegradationCount: Int = 0
        private var totalTrackingUpdates: Int = 0

        // Ghost Mesh properties
        var ghostAnchorEntity: AnchorEntity?
        var hasAddedGhostMesh = false
        var lastGhostMeshDataCount: Int? = nil // Track changes to ghost mesh data

        /// Reset coordinator state when entering recording mode.
        func resetForRecording() {
            anchorUpdateCounts.removeAll()
            trackingDegradationCount = 0
            totalTrackingUpdates = 0
            sessionStartTime = Date()
            baselineMemoryMB = ScanStats.currentMemoryUsageMB()
            hasAddedGhostMesh = false
        }

        /// Reset coordinator state when returning to nominal (idle) mode.
        func resetForNominal() {
            anchorUpdateCounts.removeAll()
            trackingDegradationCount = 0
            totalTrackingUpdates = 0

            // DO NOT explicitly remove the ghost mesh anymore, because nominal mode 
            // now supports displaying the ghost mesh if we are in an "Extend Scan" flow.
            // The coordinator retains the ghostAnchorEntity so it can be re-added if necessary.
            hasAddedGhostMesh = false

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
            if camera.trackingState == .normal && !hasAddedGhostMesh {
                if let ghostAnchor = ghostAnchorEntity, let arView = arView {
                    print("AR session relocalized successfully. Adding Ghost Mesh overlay.")
                    arView.scene.addAnchor(ghostAnchor)
                    hasAddedGhostMesh = true
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
            guard let scanStats = scanStats,
                  let currentFrame = session.currentFrame else { return }

            var totalVerts = 0
            var totalFaces = 0
            var totalUpdates = 0
            var anchorCount = 0

            for anchor in currentFrame.anchors {
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

        var objData = ""
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

                objData += "v \(worldPos.x) \(worldPos.y) \(worldPos.z)\n"

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
                objData += "f \(v1) \(v2) \(v3)\n"
                totalFaces += 1
            }

            vertexOffset += vertices.count
        }

        if let pp = personPixels {
            CVPixelBufferUnlockBaseAddress(pp.buffer, .readOnly)
        }

        guard let data = objData.data(using: .utf8), !data.isEmpty else { return nil }
        return (data, totalVertices, totalFaces)
    }

    /// Accumulates vertex colors from camera frames during recording for preview rendering.
    class VertexColorAccumulator {

        // MARK: - Export Helpers

        /// Exports the current ARWorldMap to a local URL.
        static func exportWorldMap(from session: ARSession?, completion: @escaping (URL?) -> Void) {
            guard let session = session else {
                completion(nil)
                return
            }

            session.getCurrentWorldMap { worldMap, error in
                guard let map = worldMap, error == nil else {
                    print("Error getting ARWorldMap: \(String(describing: error))")
                    completion(nil)
                    return
                }

                do {
                    let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                    let filename = "worldmap_\(UUID().uuidString.prefix(8)).worldmap"
                    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                    try data.write(to: fileURL)
                    completion(fileURL)
                } catch {
                    print("Error saving ARWorldMap: \(error)")
                    completion(nil)
                }
            }
        }

        /// Colorize OBJ mesh vertices using saved camera frames (post-processing).
        /// Reads saved JPEG images and camera JSON transforms from `rawDataDir`,
        /// parses vertices from `objData`, and projects each vertex into camera frames
        /// to sample RGB color.
        static func colorizeFromSavedFrames(objData: Data, rawDataDir: URL?) -> Data? {
            guard let rawDir = rawDataDir else { return nil }
            let fm = FileManager.default

            // Parse OBJ vertices
            guard let objString = String(data: objData, encoding: .utf8) else { return nil }
            var vertices: [SIMD3<Float>] = []
            for line in objString.components(separatedBy: .newlines) {
                let parts = line.split(separator: " ")
                guard parts.count >= 4, parts[0] == "v" else { continue }
                if let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) {
                    vertices.append(SIMD3<Float>(x, y, z))
                }
            }
            guard !vertices.isEmpty else { return nil }

            // Find saved camera JSONs
            let camerasDir = rawDir.appendingPathComponent("cameras")
            let imagesDir = rawDir.appendingPathComponent("images")
            guard fm.fileExists(atPath: camerasDir.path),
                  fm.fileExists(atPath: imagesDir.path) else { return nil }

            let cameraFiles = (try? fm.contentsOfDirectory(at: camerasDir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

            guard !cameraFiles.isEmpty else { return nil }

            // Sample up to 10 evenly-spaced frames for efficiency
            let maxFrames = min(cameraFiles.count, 10)
            let stride = max(1, cameraFiles.count / maxFrames)
            let sampledFiles = Swift.stride(from: 0, to: cameraFiles.count, by: stride).prefix(maxFrames).map { cameraFiles[$0] }

            // Initialize color array (gray default for unsampled vertices)
            var colors = [SIMD3<Float>](repeating: SIMD3<Float>(0.5, 0.5, 0.5), count: vertices.count)
            var colored = [Bool](repeating: false, count: vertices.count)

            for cameraFile in sampledFiles {
                // Parse camera JSON (Polycam format with t_XX transform and intrinsics)
                guard let jsonData = try? Data(contentsOf: cameraFile),
                      let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

                guard let fx = (json["fx"] as? NSNumber)?.floatValue,
                      let fy = (json["fy"] as? NSNumber)?.floatValue,
                      let cx = (json["cx"] as? NSNumber)?.floatValue,
                      let cy = (json["cy"] as? NSNumber)?.floatValue,
                      let imgW = (json["width"] as? NSNumber)?.intValue,
                      let imgH = (json["height"] as? NSNumber)?.intValue else { continue }

                // Reconstruct 4x4 camera-to-world transform (row-major t_XX values)
                guard let t00 = (json["t_00"] as? NSNumber)?.floatValue,
                      let t01 = (json["t_01"] as? NSNumber)?.floatValue,
                      let t02 = (json["t_02"] as? NSNumber)?.floatValue,
                      let t03 = (json["t_03"] as? NSNumber)?.floatValue,
                      let t10 = (json["t_10"] as? NSNumber)?.floatValue,
                      let t11 = (json["t_11"] as? NSNumber)?.floatValue,
                      let t12 = (json["t_12"] as? NSNumber)?.floatValue,
                      let t13 = (json["t_13"] as? NSNumber)?.floatValue,
                      let t20 = (json["t_20"] as? NSNumber)?.floatValue,
                      let t21 = (json["t_21"] as? NSNumber)?.floatValue,
                      let t22 = (json["t_22"] as? NSNumber)?.floatValue,
                      let t23 = (json["t_23"] as? NSNumber)?.floatValue else { continue }

                // Camera-to-world (row-major → column-major for simd)
                let cam2World = simd_float4x4(columns: (
                    SIMD4<Float>(t00, t10, t20, 0),
                    SIMD4<Float>(t01, t11, t21, 0),
                    SIMD4<Float>(t02, t12, t22, 0),
                    SIMD4<Float>(t03, t13, t23, 1)
                ))
                // World-to-camera
                let world2Cam = cam2World.inverse

                // Load corresponding image
                guard let imagePath = json["image_path"] as? String else { continue }
                let imageURL = rawDir.appendingPathComponent(imagePath)
                guard let imageData = try? Data(contentsOf: imageURL),
                      let uiImage = UIImage(data: imageData),
                      let cgImage = uiImage.cgImage else { continue }

                // Get pixel data
                let width = cgImage.width
                let height = cgImage.height
                guard let pixelData = cgImage.dataProvider?.data,
                      let ptr = CFDataGetBytePtr(pixelData) else { continue }
                let bytesPerRow = cgImage.bytesPerRow
                let bytesPerPixel = cgImage.bitsPerPixel / 8

                // Project each vertex into this camera frame
                for (i, vertex) in vertices.enumerated() {
                    let worldPos = SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                    let camPos = world2Cam * worldPos

                    // Must be in front of camera (z < 0 in camera space for ARKit convention)
                    guard camPos.z < 0 else { continue }

                    // Project using intrinsics: px = fx * X/Z + cx, py = fy * Y/Z + cy
                    let invZ = -1.0 / camPos.z
                    let px = Int(fx * camPos.x * invZ + cx)
                    let py = Int(fy * camPos.y * invZ + cy)

                    guard px >= 0 && px < imgW && py >= 0 && py < imgH else { continue }
                    guard px < width && py < height else { continue }

                    let offset = py * bytesPerRow + px * bytesPerPixel
                    let r = Float(ptr[offset]) / 255.0
                    let g = Float(ptr[offset + 1]) / 255.0
                    let b = Float(ptr[offset + 2]) / 255.0

                    // Latest frame with visibility wins (simple strategy)
                    colors[i] = SIMD3<Float>(r, g, b)
                    colored[i] = true
                }
            }

            let coloredCount = colored.filter { $0 }.count
            print("[VertexColor] Colored \(coloredCount)/\(vertices.count) vertices from \(sampledFiles.count) frames")

            // Convert to SIMD4<Float> with alpha=1 (matches buildColorData format)
            let rgba = colors.map { SIMD4<Float>($0.x, $0.y, $0.z, 1.0) }
            return Data(bytes: rgba, count: rgba.count * MemoryLayout<SIMD4<Float>>.stride)
        }
    }
}
