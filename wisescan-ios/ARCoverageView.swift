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

        arView.session.run(config)
        arView.debugOptions.insert(.showSceneUnderstanding)

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

    class Coordinator: NSObject, ARSessionDelegate {
        private var meshEntities: [UUID: (entity: ModelEntity, updateCount: Int)] = [:]
        var scanStats: ScanStats?
        weak var arView: ARView?
        var privacyFilter: Bool = true

        func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
            processMeshAnchors(anchors, in: session)
        }

        func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
            processMeshAnchors(anchors, in: session)
        }

        func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
            for anchor in anchors {
                if let meshAnchor = anchor as? ARMeshAnchor {
                    if let (entity, _) = meshEntities[meshAnchor.identifier] {
                        entity.removeFromParent()
                        meshEntities.removeValue(forKey: meshAnchor.identifier)
                    }
                }
            }
            updateStats(in: session)
        }

        private func processMeshAnchors(_ anchors: [ARAnchor], in session: ARSession) {
            guard let arView = arView else { return }

            // Get person segmentation buffer for privacy filtering
            let segBuffer = privacyFilter ? session.currentFrame?.segmentationBuffer : nil
            let camera = session.currentFrame?.camera

            for anchor in anchors {
                guard let meshAnchor = anchor as? ARMeshAnchor else { continue }

                let currentCount = meshEntities[meshAnchor.identifier]?.updateCount ?? 0
                let newCount = currentCount + 1

                let geometry = meshAnchor.geometry
                do {
                    let meshResource: MeshResource
                    if privacyFilter, let segBuffer = segBuffer, let camera = camera {
                        meshResource = try generateFilteredMeshResource(
                            from: geometry, transform: meshAnchor.transform,
                            segmentation: segBuffer, camera: camera
                        )
                    } else {
                        meshResource = try generateMeshResource(from: geometry)
                    }

                    let blendFactor = min(CGFloat(newCount) / 10.0, 1.0)
                    let currentColor = UIColor(
                        red: 0.0,
                        green: blendFactor * 1.0,
                        blue: (1.0 - blendFactor) * 1.0,
                        alpha: 0.8
                    )

                    var material = SimpleMaterial(color: currentColor, isMetallic: false)
                    material.triangleFillMode = .lines

                    DispatchQueue.main.async {
                        if let existingRecord = self.meshEntities[meshAnchor.identifier] {
                            existingRecord.entity.model?.mesh = meshResource
                            existingRecord.entity.model?.materials = [material]
                            self.meshEntities[meshAnchor.identifier] = (existingRecord.entity, newCount)
                        } else {
                            let entity = ModelEntity(mesh: meshResource, materials: [material])
                            let anchorEntity = AnchorEntity(anchor: meshAnchor)
                            anchorEntity.addChild(entity)
                            arView.scene.addAnchor(anchorEntity)
                            self.meshEntities[meshAnchor.identifier] = (entity, newCount)
                        }
                    }

                } catch {
                    print("Error generating mesh: \(error)")
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

                if let record = meshEntities[meshAnchor.identifier] {
                    totalUpdates += record.updateCount
                }
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

        // Standard mesh resource (no filtering)
        private func generateMeshResource(from geometry: ARMeshGeometry) throws -> MeshResource {
            let vertices = geometry.vertices
            let faces = geometry.faces

            var vertexBuffer = [SIMD3<Float>]()
            vertexBuffer.reserveCapacity(vertices.count)
            for i in 0..<vertices.count {
                let pointer = vertices.buffer.contents().advanced(by: i * vertices.stride)
                let vertex = pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                vertexBuffer.append(vertex)
            }

            var faceBuffer = [UInt32]()
            faceBuffer.reserveCapacity(faces.count * 3)
            let faceBytes = faces.bytesPerIndex * faces.indexCountPerPrimitive
            for i in 0..<faces.count {
                let pointer = faces.buffer.contents().advanced(by: i * faceBytes)
                let indices = pointer.assumingMemoryBound(to: (UInt32, UInt32, UInt32).self).pointee
                faceBuffer.append(indices.0)
                faceBuffer.append(indices.1)
                faceBuffer.append(indices.2)
            }

            var descriptor = MeshDescriptor(name: "ARMeshGeometry")
            descriptor.positions = MeshBuffer(vertexBuffer)
            descriptor.primitives = .triangles(faceBuffer)
            return try MeshResource.generate(from: [descriptor])
        }

        // Privacy-filtered mesh: skip faces where vertices project onto person pixels
        private func generateFilteredMeshResource(
            from geometry: ARMeshGeometry,
            transform: simd_float4x4,
            segmentation: CVPixelBuffer,
            camera: ARCamera
        ) throws -> MeshResource {
            let vertices = geometry.vertices
            let faces = geometry.faces

            let segWidth = CVPixelBufferGetWidth(segmentation)
            let segHeight = CVPixelBufferGetHeight(segmentation)

            CVPixelBufferLockBaseAddress(segmentation, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(segmentation, .readOnly) }
            let segBase = CVPixelBufferGetBaseAddress(segmentation)
            let segStride = CVPixelBufferGetBytesPerRow(segmentation)

            // Read all vertices
            var vertexBuffer = [SIMD3<Float>]()
            vertexBuffer.reserveCapacity(vertices.count)
            for i in 0..<vertices.count {
                let pointer = vertices.buffer.contents().advanced(by: i * vertices.stride)
                let vertex = pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
                vertexBuffer.append(vertex)
            }

            // Precompute per-vertex "is person" flag by projecting to image space
            let viewMatrix = camera.viewMatrix(for: .landscapeRight)
            let imageResolution = camera.imageResolution
            let projMatrix = camera.projectionMatrix(for: .landscapeRight, viewportSize: imageResolution, zNear: 0.001, zFar: 100)

            var isPersonVertex = [Bool](repeating: false, count: vertices.count)
            for i in 0..<vertices.count {
                let localPos = SIMD4<Float>(vertexBuffer[i].x, vertexBuffer[i].y, vertexBuffer[i].z, 1.0)
                let worldPos = transform * localPos
                let camPos = viewMatrix * worldPos
                let clipPos = projMatrix * camPos

                guard clipPos.w > 0 else { continue }
                let ndcX = clipPos.x / clipPos.w
                let ndcY = clipPos.y / clipPos.w

                // NDC to pixel coordinates in segmentation buffer
                let px = Int((ndcX * 0.5 + 0.5) * Float(segWidth))
                let py = Int((1.0 - (ndcY * 0.5 + 0.5)) * Float(segHeight))

                if px >= 0 && px < segWidth && py >= 0 && py < segHeight,
                   let base = segBase {
                    let pixel = base.advanced(by: py * segStride + px).assumingMemoryBound(to: UInt8.self).pointee
                    isPersonVertex[i] = pixel > 128
                }
            }

            // Filter faces: skip if any vertex is person
            var faceBuffer = [UInt32]()
            let faceBytes = faces.bytesPerIndex * faces.indexCountPerPrimitive
            for i in 0..<faces.count {
                let pointer = faces.buffer.contents().advanced(by: i * faceBytes)
                let indices = pointer.assumingMemoryBound(to: (UInt32, UInt32, UInt32).self).pointee

                let i0 = Int(indices.0)
                let i1 = Int(indices.1)
                let i2 = Int(indices.2)

                // Skip face if any vertex is classified as person
                if isPersonVertex[i0] || isPersonVertex[i1] || isPersonVertex[i2] {
                    continue
                }

                faceBuffer.append(indices.0)
                faceBuffer.append(indices.1)
                faceBuffer.append(indices.2)
            }

            var descriptor = MeshDescriptor(name: "ARMeshGeometry")
            descriptor.positions = MeshBuffer(vertexBuffer)
            descriptor.primitives = .triangles(faceBuffer)
            return try MeshResource.generate(from: [descriptor])
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
