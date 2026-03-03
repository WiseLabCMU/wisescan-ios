import SwiftUI
import RealityKit
import ARKit

struct ARCoverageView: UIViewRepresentable {
    // Expose the active session to the parent view for exporting
    @Binding var arSession: ARSession?

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
        arView.session.delegate = context.coordinator

        // Start the AR session
        arView.session.run(config)

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
        }

        private func processMeshAnchors(_ anchors: [ARAnchor], in session: ARSession) {
            guard let arView = session.delegate as? ARView else { return }

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

                    if let existingRecord = meshEntities[meshAnchor.identifier] {
                        // Update existing entity
                        existingRecord.entity.model?.mesh = meshResource
                        existingRecord.entity.model?.materials = [material]
                        existingRecord.entity.transform.matrix = meshAnchor.transform
                        meshEntities[meshAnchor.identifier] = (existingRecord.entity, newCount)
                    } else {
                        // Create new entity
                        let entity = ModelEntity(mesh: meshResource, materials: [material])
                        entity.transform.matrix = meshAnchor.transform

                        let anchorEntity = AnchorEntity(anchor: meshAnchor)
                        anchorEntity.addChild(entity)
                        arView.scene.addAnchor(anchorEntity)

                        meshEntities[meshAnchor.identifier] = (entity, newCount)
                    }

                } catch {
                    print("Error generating mesh from ARMeshAnchor: \(error)")
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
    static func exportPointCloudOBJ(from session: ARSession?) -> Data? {
        guard let session = session, let currentFrame = session.currentFrame else { return nil }

        var objData = ""
        var vertexOffset = 1

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

            vertexOffset += vertices.count
        }

        return objData.data(using: .utf8)
    }
}
