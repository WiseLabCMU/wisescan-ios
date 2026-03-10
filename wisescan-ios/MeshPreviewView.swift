import SwiftUI
import SceneKit

/// Renders a 3D preview of captured OBJ mesh data using SceneKit.
struct MeshPreviewView: UIViewRepresentable {
    var meshFileURL: URL?
    var colorsFileURL: URL?

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = UIColor(white: 0.15, alpha: 1.0) // charcoal background
        scnView.allowsCameraControl = true // user can rotate/zoom
        scnView.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        scnView.scene = scene

        // Lighting setup for better visibility
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.color = UIColor(white: 0.4, alpha: 1.0)
        scene.rootNode.addChildNode(ambientLight)

        let directionalLight = SCNNode()
        directionalLight.light = SCNLight()
        directionalLight.light?.type = .directional
        directionalLight.light?.color = UIColor(white: 0.8, alpha: 1.0)
        directionalLight.light?.castsShadow = true
        directionalLight.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(directionalLight)

        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .directional
        fillLight.light?.color = UIColor(white: 0.3, alpha: 1.0)
        fillLight.eulerAngles = SCNVector3(Float.pi / 4, -Float.pi / 3, 0)
        scene.rootNode.addChildNode(fillLight)

        // Dispatch to background queue for loading files and parsing OBJ
        DispatchQueue.global(qos: .userInitiated).async {
            var meshData: Data? = nil
            var colorsData: Data? = nil

            if let meshURL = meshFileURL {
                meshData = try? Data(contentsOf: meshURL)
            }
            if let colorsURL = colorsFileURL {
                colorsData = try? Data(contentsOf: colorsURL)
            }

            if let md = meshData, let (geometry, _) = self.buildGeometry(from: md, vertexColors: colorsData) {
                DispatchQueue.main.async {
                    let node = SCNNode(geometry: geometry)

                    // Center the model
                    let (minBound, maxBound) = node.boundingBox
                    let center = SCNVector3(
                        (minBound.x + maxBound.x) / 2,
                        (minBound.y + maxBound.y) / 2,
                        (minBound.z + maxBound.z) / 2
                    )
                    node.position = SCNVector3(-center.x, -center.y, -center.z)

                    // Wrap in a parent to keep centering clean
                    let containerNode = SCNNode()
                    containerNode.addChildNode(node)
                    scene.rootNode.addChildNode(containerNode)

                    // Position camera based on model size
                    let size = SCNVector3(
                        maxBound.x - minBound.x,
                        maxBound.y - minBound.y,
                        maxBound.z - minBound.z
                    )
                    let maxDimension = max(size.x, max(size.y, size.z))

                    let cameraNode = SCNNode()
                    cameraNode.camera = SCNCamera()
                    cameraNode.camera?.automaticallyAdjustsZRange = true
                    cameraNode.position = SCNVector3(0, maxDimension * 0.3, maxDimension * 1.5)
                    cameraNode.look(at: SCNVector3Zero)
                    scene.rootNode.addChildNode(cameraNode)
                }
            }
        }

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    /// Parses OBJ data and creates geometry with vertex colors (camera-sampled or height-based fallback).
    private func buildGeometry(from data: Data, vertexColors: Data?) -> (SCNGeometry, Int)? {
        guard let objString = String(data: data, encoding: .utf8) else { return nil }

        var vertices: [SCNVector3] = []
        var indices: [UInt32] = []
        var minY: Float = .greatestFiniteMagnitude
        var maxY: Float = -.greatestFiniteMagnitude

        for line in objString.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard let prefix = parts.first else { continue }

            if prefix == "v" && parts.count >= 4 {
                if let x = Float(parts[1]),
                   let y = Float(parts[2]),
                   let z = Float(parts[3]) {
                    vertices.append(SCNVector3(x, y, z))
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            } else if prefix == "f" && parts.count >= 4 {
                if let i1 = UInt32(parts[1]),
                   let i2 = UInt32(parts[2]),
                   let i3 = UInt32(parts[3]) {
                    indices.append(i1 - 1)
                    indices.append(i2 - 1)
                    indices.append(i3 - 1)
                }
            }
        }

        guard !vertices.isEmpty && !indices.isEmpty else { return nil }

        // Use camera colors if available, otherwise height gradient
        var colors: [SIMD4<Float>]
        var hasCameraColors = false
        if let colorData = vertexColors {
            let count = colorData.count / MemoryLayout<SIMD4<Float>>.stride
            if count == vertices.count {
                colors = [SIMD4<Float>](repeating: .zero, count: count)
                _ = colors.withUnsafeMutableBytes { ptr in
                    colorData.copyBytes(to: ptr)
                }
                hasCameraColors = true
            } else {
                // Count mismatch — fall back to gradient
                colors = heightGradientColors(vertices: vertices, minY: minY, maxY: maxY)
            }
        } else {
            colors = heightGradientColors(vertices: vertices, minY: minY, maxY: maxY)
        }

        // Compute face normals and accumulate per-vertex for smooth shading
        var vertexNormals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        for i in stride(from: 0, to: indices.count, by: 3) {
            let i0 = Int(indices[i])
            let i1 = Int(indices[i + 1])
            let i2 = Int(indices[i + 2])
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }

            let v0 = SIMD3<Float>(vertices[i0].x, vertices[i0].y, vertices[i0].z)
            let v1 = SIMD3<Float>(vertices[i1].x, vertices[i1].y, vertices[i1].z)
            let v2 = SIMD3<Float>(vertices[i2].x, vertices[i2].y, vertices[i2].z)

            let normal = simd_normalize(simd_cross(v1 - v0, v2 - v0))
            vertexNormals[i0] += normal
            vertexNormals[i1] += normal
            vertexNormals[i2] += normal
        }
        // Normalize
        let normals = vertexNormals.map { simd_normalize($0) }
            .map { SCNVector3($0.x, $0.y, $0.z) }

        let vertexSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)

        // Color source
        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<SIMD4<Float>>.stride)
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )

        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<UInt32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [vertexSource, normalSource, colorSource], elements: [element])

        let material = SCNMaterial()
        if hasCameraColors {
            // Unlit rendering for camera colors — show actual sampled colors
            material.lightingModel = .constant
        } else {
            material.lightingModel = .physicallyBased
            material.roughness.contents = 0.6
            material.metalness.contents = 0.1
        }
        material.diffuse.contents = UIColor.white // vertex colors will modulate
        material.isDoubleSided = true
        geometry.materials = [material]

        return (geometry, vertices.count)
    }

    private func heightGradientColors(vertices: [SCNVector3], minY: Float, maxY: Float) -> [SIMD4<Float>] {
        let yRange = maxY - minY
        return vertices.map { v in
            let t = yRange > 0 ? (v.y - minY) / yRange : 0.5
            let r: Float = 0.0
            let g: Float = min(t * 1.5, 1.0)
            let b: Float = max(1.0 - t * 1.5, 0.2)
            return SIMD4<Float>(r, g, b, 1.0)
        }
    }
}
