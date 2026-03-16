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
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = []
        config.environmentTexturing = .automatic

        context.coordinator.scanStats = scanStats
        context.coordinator.arView = arView
        context.coordinator.privacyFilter = privacyFilter
        context.coordinator.isRecording = false

        arView.session.delegate = context.coordinator
        // No debug options in nominal mode (no wireframe overlay)

        arView.session.run(config)

        // Add a transparent overlay view for 2D coverage rendering
        let overlay = CoverageOverlayView(frame: arView.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        arView.addSubview(overlay)
        context.coordinator.overlayView = overlay

        DispatchQueue.main.async {
            self.arSession = arView.session
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.privacyFilter = privacyFilter

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
                context.coordinator.startCoverageTimer()

                // Background parse the ghost mesh if provided (Scan4D rescan)
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
                uiView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
                uiView.debugOptions.remove(.showSceneUnderstanding)
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

    /// Draws projected mesh anchor coverage as a negative mask (unscanned areas are tiled with the pattern).
    class CoverageOverlayView: UIView {
        /// Each element is an array of convex hull points for one anchor's coverage area.
        var coveragePolygons: [[CGPoint]] = []
        private var patternImage: UIImage?

        /// Toggle to enable or disable coverage pattern rendering. Set to false to hide it for now.
        var isCoverageEnabled: Bool = false

        override func draw(_ rect: CGRect) {
            guard isCoverageEnabled, let ctx = UIGraphicsGetCurrentContext() else { return }

            // Load the pattern image once
            if patternImage == nil {
                patternImage = UIImage(named: "CoverageMask")
            }
            guard let image = patternImage, let cgImage = image.cgImage else { return }

            ctx.saveGState()

            // 1. Add the full screen boundary rect to the path
            ctx.beginPath()
            ctx.addRect(bounds)

            // 2. Add all coverage polygons to the path
            for polygon in coveragePolygons {
                guard polygon.count >= 3 else { continue }
                ctx.move(to: polygon[0])
                for i in 1..<polygon.count {
                    ctx.addLine(to: polygon[i])
                }
                ctx.closePath()
            }

            // 3. Clip using even-odd rule.
            // The polygons are "holes" inside the outer full-screen rect.
            ctx.clip(using: .evenOdd)

            // 4. Draw the image across the entire view bounds (only unscanned areas will show)
            let tileSize = max(bounds.width, bounds.height)
            ctx.setAlpha(0.6) // slightly more opaque to encourage clearing it
            let cols = Int(ceil(bounds.width / tileSize))
            let rows = Int(ceil(bounds.height / tileSize))
            for row in 0...rows {
                for col in 0...cols {
                    let tileRect = CGRect(x: CGFloat(col) * tileSize, y: CGFloat(row) * tileSize, width: tileSize, height: tileSize)
                    ctx.saveGState()
                    ctx.translateBy(x: tileRect.minX, y: tileRect.maxY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: tileSize, height: tileSize))
                    ctx.restoreGState()
                }
            }

            ctx.restoreGState()
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, ARSessionDelegate {
        var scanStats: ScanStats?
        weak var arView: ARView?
        weak var overlayView: CoverageOverlayView?
        var privacyFilter: Bool = true
        var isUsingFrontCamera: Bool = false
        var isRecording: Bool = false
        private var coverageTimer: Timer?
        private var anchorUpdateCounts: [UUID: Int] = [:]

        // Session capacity tracking
        private var sessionStartTime: Date = Date()
        private var baselineMemoryMB: Double = ScanStats.currentMemoryUsageMB()
        private var trackingDegradationCount: Int = 0
        private var totalTrackingUpdates: Int = 0

        // Ghost Mesh properties
        var ghostAnchorEntity: AnchorEntity?
        private var hasAddedGhostMesh = false

        func startCoverageTimer() {
            coverageTimer?.invalidate()
            coverageTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                self?.updateCoverageOverlay()
            }
        }

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
            coverageTimer?.invalidate()
            coverageTimer = nil
            anchorUpdateCounts.removeAll()
            trackingDegradationCount = 0
            totalTrackingUpdates = 0

            // Remove ghost mesh if present
            ghostAnchorEntity?.removeFromParent()
            ghostAnchorEntity = nil
            hasAddedGhostMesh = false

            // Clear coverage overlay
            DispatchQueue.main.async { [weak self] in
                self?.overlayView?.coveragePolygons = []
                self?.overlayView?.setNeedsDisplay()

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

        deinit {
            coverageTimer?.invalidate()
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

        // MARK: - 2D Projection (Bounding-box approach)

        private func updateCoverageOverlay() {
            guard isRecording,
                  let arView = arView,
                  let overlay = overlayView,
                  let currentFrame = arView.session.currentFrame else { return }

            let camera = currentFrame.camera
            let viewportSize = arView.bounds.size
            let orientation = UIInterfaceOrientation.portrait

            var polygons = [[CGPoint]]()

            for anchor in currentFrame.anchors {
                guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
                let geometry = meshAnchor.geometry
                let transform = meshAnchor.transform
                let vertices = geometry.vertices

                // Compute axis-aligned bounding box in local space
                guard vertices.count > 0, vertices.stride > 0, vertices.buffer.length >= vertices.count * vertices.stride else { continue }
                var minV = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
                var maxV = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)

                for i in 0..<vertices.count {
                    let offset = i * vertices.stride
                    guard offset + MemoryLayout<SIMD3<Float>>.size <= vertices.buffer.length else { break }
                    let ptr = vertices.buffer.contents().advanced(by: offset)
                    let v = ptr.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                    minV = min(minV, v)
                    maxV = max(maxV, v)
                }

                // Generate 8 corners of the bounding box
                let corners: [SIMD3<Float>] = [
                    SIMD3(minV.x, minV.y, minV.z),
                    SIMD3(maxV.x, minV.y, minV.z),
                    SIMD3(maxV.x, maxV.y, minV.z),
                    SIMD3(minV.x, maxV.y, minV.z),
                    SIMD3(minV.x, minV.y, maxV.z),
                    SIMD3(maxV.x, minV.y, maxV.z),
                    SIMD3(maxV.x, maxV.y, maxV.z),
                    SIMD3(minV.x, maxV.y, maxV.z),
                ]

                // Project corners to screen space
                var screenPoints = [CGPoint]()
                for corner in corners {
                    let localPos = SIMD4<Float>(corner.x, corner.y, corner.z, 1.0)
                    let worldPos = transform * localPos
                    let wp = simd_float3(worldPos.x, worldPos.y, worldPos.z)
                    let screenPt = camera.projectPoint(wp, orientation: orientation, viewportSize: viewportSize)
                    let pt = CGPoint(x: CGFloat(screenPt.x), y: CGFloat(screenPt.y))
                    screenPoints.append(pt)
                }

                // Compute 2D convex hull of the projected points
                let hull = convexHull(screenPoints)
                if hull.count >= 3 {
                    // Check if hull is at least partially on screen
                    let hullMinX = hull.map(\.x).min()!
                    let hullMaxX = hull.map(\.x).max()!
                    let hullMinY = hull.map(\.y).min()!
                    let hullMaxY = hull.map(\.y).max()!

                    if hullMaxX >= 0 && hullMinX <= viewportSize.width &&
                       hullMaxY >= 0 && hullMinY <= viewportSize.height {
                        polygons.append(hull)
                    }
                }
            }

            DispatchQueue.main.async {
                overlay.coveragePolygons = polygons
                overlay.setNeedsDisplay()
            }
        }

        /// Compute 2D convex hull using Andrew's monotone chain algorithm.
        private func convexHull(_ points: [CGPoint]) -> [CGPoint] {
            let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
            if sorted.count <= 2 { return sorted }

            func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
                (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
            }

            var lower = [CGPoint]()
            for p in sorted {
                while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                    lower.removeLast()
                }
                lower.append(p)
            }

            var upper = [CGPoint]()
            for p in sorted.reversed() {
                while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                    upper.removeLast()
                }
                upper.append(p)
            }

            lower.removeLast()
            upper.removeLast()
            return lower + upper
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
        // (anchorUUID, vertexIndex) → accumulated RGB color
        private var colorMap: [String: SIMD3<Float>] = [:]
        private var sampleTimer: Timer?

        /// Start accumulating — call when recording begins.
        func start(session: ARSession) {
            colorMap = [:]
            sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak session] _ in
                guard let session = session else { return }
                self?.accumulate(from: session)
            }
        }

        /// Stop accumulating.
        func stop() {
            sampleTimer?.invalidate()
            sampleTimer = nil
        }

        /// Sample visible vertex colors from the current camera frame.
        private func accumulate(from session: ARSession) {
            guard let currentFrame = session.currentFrame else { return }
            let camera = currentFrame.camera
            let capturedImage = currentFrame.capturedImage
            let imgWidth = CVPixelBufferGetWidth(capturedImage)
            let imgHeight = CVPixelBufferGetHeight(capturedImage)
            let viewportSize = CGSize(width: CGFloat(imgWidth), height: CGFloat(imgHeight))

            CVPixelBufferLockBaseAddress(capturedImage, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(capturedImage, .readOnly) }

            guard let yBase = CVPixelBufferGetBaseAddressOfPlane(capturedImage, 0),
                  let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(capturedImage, 1) else { return }
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(capturedImage, 0)
            let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(capturedImage, 1)
            let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
            let cbcrPtr = cbcrBase.assumingMemoryBound(to: UInt8.self)

            for anchor in currentFrame.anchors {
                guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
                let geometry = meshAnchor.geometry
                let transform = meshAnchor.transform
                let anchorID = meshAnchor.identifier.uuidString

                for i in 0..<geometry.vertices.count {
                    let pointer = geometry.vertices.buffer.contents().advanced(by: i * geometry.vertices.stride)
                    let vertex = pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                    let localPos = SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                    let worldPos = transform * localPos
                    let worldPoint = simd_float3(worldPos.x, worldPos.y, worldPos.z)

                    let projected = camera.projectPoint(worldPoint, orientation: .landscapeRight, viewportSize: viewportSize)
                    let px = Int(projected.x)
                    let py = Int(projected.y)

                    // Only color vertices currently visible in the camera
                    if px >= 0 && px < imgWidth && py >= 0 && py < imgHeight {
                        let yVal = Float(yPtr[py * yStride + px]) / 255.0
                        let cx = (px / 2) * 2
                        let cy = py / 2
                        let cb = Float(cbcrPtr[cy * cbcrStride + cx]) / 255.0 - 0.5
                        let cr = Float(cbcrPtr[cy * cbcrStride + cx + 1]) / 255.0 - 0.5

                        let r = max(0, min(1, yVal + 1.402 * cr))
                        let g = max(0, min(1, yVal - 0.344136 * cb - 0.714136 * cr))
                        let b = max(0, min(1, yVal + 1.772 * cb))

                        let key = "\(anchorID)_\(i)"
                        colorMap[key] = SIMD3<Float>(r, g, b) // latest sample wins
                    }
                }
            }
        }

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

        /// Build the final vertex color Data by iterating anchors in the same order as exportMeshOBJ.
        func buildColorData(from session: ARSession?) -> Data? {
            guard let session = session,
                  let currentFrame = session.currentFrame else { return nil }

            var colors: [SIMD4<Float>] = []

            for anchor in currentFrame.anchors {
                guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
                let anchorID = meshAnchor.identifier.uuidString
                let geometry = meshAnchor.geometry

                for i in 0..<geometry.vertices.count {
                    let key = "\(anchorID)_\(i)"
                    if let rgb = colorMap[key] {
                        colors.append(SIMD4<Float>(rgb.x, rgb.y, rgb.z, 1.0))
                    } else {
                        colors.append(SIMD4<Float>(0.5, 0.5, 0.5, 1.0)) // unsampled → gray
                    }
                }
            }

            guard !colors.isEmpty else { return nil }
            return Data(bytes: colors, count: colors.count * MemoryLayout<SIMD4<Float>>.stride)
        }
    }
}
