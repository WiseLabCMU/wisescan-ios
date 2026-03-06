import SwiftUI
import RealityKit
import ARKit

struct ARCoverageView: UIViewRepresentable {
    @Binding var arSession: ARSession?
    var scanStats: ScanStats
    var privacyFilter: Bool

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            print("Device does not support LiDAR scene reconstruction.")
            return arView
        }

        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        config.environmentTexturing = .automatic

        // Enable person segmentation for privacy filtering
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.personSegmentationWithDepth) {
            config.frameSemantics.insert(.personSegmentationWithDepth)
        }

        context.coordinator.scanStats = scanStats
        context.coordinator.arView = arView
        context.coordinator.privacyFilter = privacyFilter

        arView.session.delegate = context.coordinator
        arView.debugOptions.insert(.showSceneUnderstanding)
        arView.session.run(config)

        // Add a transparent overlay view for 2D coverage rendering
        let overlay = CoverageOverlayView(frame: arView.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        arView.addSubview(overlay)
        context.coordinator.overlayView = overlay
        context.coordinator.startCoverageTimer()

        DispatchQueue.main.async {
            self.arSession = arView.session
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.privacyFilter = privacyFilter
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
        private var coverageTimer: Timer?
        private var anchorUpdateCounts: [UUID: Int] = [:]

        func startCoverageTimer() {
            coverageTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                self?.updateCoverageOverlay()
            }
        }

        deinit {
            coverageTimer?.invalidate()
        }

        // Track anchor update counts via delegate
        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            for anchor in anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    anchorUpdateCounts[mesh.identifier] = 1
                }
            }
            updateStats(in: session)
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            for anchor in anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    anchorUpdateCounts[mesh.identifier, default: 0] += 1
                }
            }
            updateStats(in: session)
        }

        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            for anchor in anchors {
                if let mesh = anchor as? ARMeshAnchor {
                    anchorUpdateCounts.removeValue(forKey: mesh.identifier)
                }
            }
            updateStats(in: session)
        }

        // MARK: - 2D Projection (Bounding-box approach)

        private func updateCoverageOverlay() {
            guard let arView = arView,
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
                var minV = SIMD3<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
                var maxV = SIMD3<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)

                for i in 0..<vertices.count {
                    let ptr = vertices.buffer.contents().advanced(by: i * vertices.stride)
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

            DispatchQueue.main.async {
                scanStats.totalVertices = totalVerts
                scanStats.totalFaces = totalFaces
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
            sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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
