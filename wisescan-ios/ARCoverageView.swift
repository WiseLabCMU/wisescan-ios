import SwiftUI
import RealityKit
import ARKit

struct ARCoverageView: UIViewRepresentable {
    // Expose the active session to the parent view for exporting
    @Binding var arSession: ARSession?
    var scanStats: ScanStats

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        // Ensure the device supports Scene Reconstruction (LiDAR required)
        guard ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else {
            print("Device does not support LiDAR scene reconstruction.")
            return arView
        }

        // Configure ARKit for environment meshing
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        config.environmentTexturing = .automatic

        // Attach the delegate to handle mesh updates
        context.coordinator.scanStats = scanStats
        context.coordinator.arView = arView
        arView.session.delegate = context.coordinator

        // Start the AR session
        arView.session.run(config)

        // Enable built-in scene understanding overlay
        arView.debugOptions.insert(.showSceneUnderstanding)

        // Pass the session back up via binding
        DispatchQueue.main.async {
            self.arSession = arView.session
        }

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, ARSessionDelegate {
        // Keep track of mesh anchors to visualize coverage improving
        // Key: Anchor ID, Value: (Entity, UpdateCount)
        private var meshEntities: [UUID: (entity: ModelEntity, updateCount: Int)] = [:]
        var scanStats: ScanStats?
        weak var arView: ARView?

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

            for anchor in anchors {
                guard let meshAnchor = anchor as? ARMeshAnchor else { continue }

                // Track how many times this mesh chunk has been updated
                let currentCount = meshEntities[meshAnchor.identifier]?.updateCount ?? 0
                let newCount = currentCount + 1

                // Generate geometry
                let geometry = meshAnchor.geometry
                do {
                    let meshResource = try generateMeshResource(from: geometry)

                    // Determine color based on update count (Simulating coverage improvement)
                    // Blue = newly discovered, Green = well scanned (updated multiple times)
                    let blendFactor = min(CGFloat(newCount) / 10.0, 1.0)
                    let currentColor = UIColor(
                        red: 0.0,
                        green: blendFactor * 1.0,  // Shifts towards green
                        blue: (1.0 - blendFactor) * 1.0, // Shifts away from blue
                        alpha: 0.8
                    )

                    var material = SimpleMaterial(color: currentColor, isMetallic: false)
                    material.triangleFillMode = .lines // Render as wireframe grid

                    DispatchQueue.main.async {
                        if let existingRecord = self.meshEntities[meshAnchor.identifier] {
                            // Update existing entity
                            existingRecord.entity.model?.mesh = meshResource
                            existingRecord.entity.model?.materials = [material]
                            self.meshEntities[meshAnchor.identifier] = (existingRecord.entity, newCount)
                        } else {
                            // Create new entity — no transform needed, AnchorEntity handles positioning
                            let entity = ModelEntity(mesh: meshResource, materials: [material])

                            let anchorEntity = AnchorEntity(anchor: meshAnchor)
                            anchorEntity.addChild(entity)
                            arView.scene.addAnchor(anchorEntity)

                            self.meshEntities[meshAnchor.identifier] = (entity, newCount)
                        }
                    }

                } catch {
                    print("Error generating mesh from ARMeshAnchor: \(error)")
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
                // Quality: average update count per anchor, capped at 10 updates = 100%
                if anchorCount > 0 {
                    let avgUpdates = Double(totalUpdates) / Double(anchorCount)
                    scanStats.averageQuality = min(avgUpdates / 10.0, 1.0)
                } else {
                    scanStats.averageQuality = 0.0
                }
            }
        }

        // Helper to convert ARMeshGeometry to RealityKit MeshResource
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
    }

    // Static helper to extract all active mesh geometry into an OBJ string
    static func exportMeshOBJ(from session: ARSession?) -> (data: Data, vertexCount: Int, faceCount: Int)? {
        guard let session = session, let currentFrame = session.currentFrame else { return nil }

        var objData = ""
        var vertexOffset = 1
        var totalVertices = 0
        var totalFaces = 0

        for anchor in currentFrame.anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            let geometry = meshAnchor.geometry
            let transform = meshAnchor.transform

            // Extract and transform vertices
            let vertices = geometry.vertices
            for i in 0..<vertices.count {
                let pointer = vertices.buffer.contents().advanced(by: i * vertices.stride)
                let vertex = pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee

                // Transform local vertex to world coordinate
                let localPos = SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                let worldPos = transform * localPos

                objData += "v \(worldPos.x) \(worldPos.y) \(worldPos.z)\n"
            }
            totalVertices += vertices.count

            // Extract faces
            let faces = geometry.faces
            let faceBytes = faces.bytesPerIndex * faces.indexCountPerPrimitive

            for i in 0..<faces.count {
                let pointer = faces.buffer.contents().advanced(by: i * faceBytes)
                let indices = pointer.assumingMemoryBound(to: (UInt32, UInt32, UInt32).self).pointee

                // OBJ indices are 1-based and need offset from previous anchors
                let v1 = Int(indices.0) + vertexOffset
                let v2 = Int(indices.1) + vertexOffset
                let v3 = Int(indices.2) + vertexOffset

                objData += "f \(v1) \(v2) \(v3)\n"
            }
            totalFaces += faces.count

            vertexOffset += vertices.count
        }

        guard let data = objData.data(using: .utf8), !data.isEmpty else { return nil }
        return (data, totalVertices, totalFaces)
    }
}
