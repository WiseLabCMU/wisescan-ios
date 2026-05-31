import SwiftUI
import SwiftData
import SceneKit
import Combine

/// Wrapper that overlays 2D privacy markers on the SceneKit mesh preview.
/// Face anchor 3D positions are projected to screen coordinates each frame.
struct MeshPreviewContainer: View {
    var location: ScanLocation?
    var meshFileURL: URL?
    var colorsFileURL: URL?
    var scanDirectoryURL: URL?

    @StateObject private var markerState = MarkerProjectionState()
    @State private var isUpdating = false
    @State private var isViewerReady = false
    @State private var isMeshLoaded = false
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ZStack {
            if isViewerReady {
                MeshPreviewView(
                    meshFileURL: meshFileURL,
                    colorsFileURL: colorsFileURL,
                    scanDirectoryURL: scanDirectoryURL,
                    markerState: markerState,
                    isMeshLoaded: $isMeshLoaded
                )

                // 2D overlay icons projected from 3D face anchor positions
                ForEach(markerState.screenPositions.indices, id: \.self) { i in
                    let pos = markerState.screenPositions[i]
                    if pos.isVisible {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.red)
                            .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                            .position(x: pos.point.x, y: pos.point.y)
                    }
                }
            }

            // Show loading indicator until mesh is fully parsed and rendered
            if !isMeshLoaded {
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .gray))
                        .scaleEffect(1.5)
                    Text("Loading Mesh...")
                        .font(.headline)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.15))
                .transition(.opacity)
            }
            
            if isUpdating {
                VStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    Text("Updating Previews...")
                        .foregroundColor(.white)
                        .font(.caption)
                }
                .padding()
                .background(Color.black.opacity(0.8))
                .cornerRadius(12)
            }
        }
        .toolbar {
            if location != nil {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: savePoseAndUpdate) {
                        HStack {
                            Image(systemName: "camera.viewfinder")
                            Text("Set Default Pose")
                        }
                    }
                    .disabled(isUpdating || !isMeshLoaded)
                }
            }
        }
        .onAppear {
            // Defer the heavy OBJ parsing to ensure the fullScreenCover animation completes smoothly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isViewerReady = true
            }
        }
    }
    
    private func savePoseAndUpdate() {
        guard let location = location, let pose = markerState.currentPoseMatrix() else { return }
        location.imagingPoseMatrix = pose
        try? modelContext.save()
        isUpdating = true
        
        Task {
            let scans = location.scans
            for scan in scans {
                // Ensure mesh exists
                guard FileManager.default.fileExists(atPath: scan.meshFileURL.path) else { continue }
                if let img = await Task.detached(priority: .userInitiated, operation: {
                    MeshPreviewView.generateSnapshot(meshURL: scan.meshFileURL, colorsURL: scan.colorsFileURL, poseMatrix: pose)
                }).value, let data = img.jpegData(compressionQuality: 0.8) {
                    try? data.write(to: scan.modelPreviewURL)
                }
            }
            await MainActor.run {
                location.updatedAt = Date()
                isUpdating = false
            }
        }
    }
}

/// Published state for projected 2D marker positions.
class MarkerProjectionState: ObservableObject {
    struct MarkerScreenPos {
        var point: CGPoint
        var isVisible: Bool
    }

    @Published var screenPositions: [MarkerScreenPos] = []

    /// 3D anchor positions in scene-local coordinates (with center offset applied)
    var anchorPositions: [SCNVector3] = []
    /// Reference to the SCNView for projection
    weak var scnView: SCNView?

    func updateProjections() {
        guard let scnView = scnView else { return }
        DispatchQueue.main.async {
            guard scnView.pointOfView != nil else { return }
            var newPositions: [MarkerScreenPos] = []
            let boundsWidth = scnView.bounds.width
            let boundsHeight = scnView.bounds.height
            for anchor in self.anchorPositions {
                let projected = scnView.projectPoint(anchor)
                let screenPoint = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
                let visible = projected.z > 0 && projected.z < 1
                    && screenPoint.x >= 0 && screenPoint.x <= boundsWidth
                    && screenPoint.y >= 0 && screenPoint.y <= boundsHeight
                newPositions.append(MarkerScreenPos(point: screenPoint, isVisible: visible))
            }
            self.screenPositions = newPositions
        }
    }
    
    func currentPoseMatrix() -> [Float]? {
        guard let transform = scnView?.pointOfView?.transform else { return nil }
        return [
            transform.m11, transform.m12, transform.m13, transform.m14,
            transform.m21, transform.m22, transform.m23, transform.m24,
            transform.m31, transform.m32, transform.m33, transform.m34,
            transform.m41, transform.m42, transform.m43, transform.m44
        ]
    }
}

/// Renders a 3D preview of captured OBJ mesh data using SceneKit.
struct MeshPreviewView: UIViewRepresentable {
    var meshFileURL: URL?
    var colorsFileURL: URL?
    var scanDirectoryURL: URL?
    var markerState: MarkerProjectionState
    @Binding var isMeshLoaded: Bool

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = UIColor(white: 0.15, alpha: 1.0) // charcoal background
        scnView.allowsCameraControl = true // user can rotate/zoom
        scnView.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        scnView.scene = scene
        scnView.delegate = context.coordinator

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

            var faceAnchors: [SCNVector3] = []
            if let scanDir = self.scanDirectoryURL {
                // Check both raw_data/ subdirectory and scan root (mirrors export logic)
                let candidates = [
                    scanDir.appendingPathComponent("raw_data").appendingPathComponent("scan4d_metadata.json"),
                    scanDir.appendingPathComponent("scan4d_metadata.json")
                ]
                for jsonURL in candidates {
                    if let data = try? Data(contentsOf: jsonURL),
                       let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let anchors = dict["face_anchors"] as? [[String: NSNumber]] {
                        for a in anchors {
                            if let x = a["x"]?.floatValue,
                               let y = a["y"]?.floatValue,
                               let z = a["z"]?.floatValue {
                                faceAnchors.append(SCNVector3(x, y, z))
                            }
                        }
                        break // found it, stop searching
                    }
                }
            }

            if let md = meshData, let (geometry, _) = Self.buildGeometry(from: md, vertexColors: colorsData) {
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

                    // Store face anchor positions for 2D projection (offset by center)
                    // Anchors are in the node's local space, which is shifted by -center
                    // projectPoint needs world-space coords, so final = anchor - center
                    self.markerState.anchorPositions = faceAnchors.map { a in
                        SCNVector3(a.x - center.x, a.y - center.y, a.z - center.z)
                    }
                    self.markerState.scnView = scnView

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
                    cameraNode.position = SCNVector3(0, maxDimension * 0.3, maxDimension * 0.4)
                    cameraNode.look(at: SCNVector3Zero)
                    scene.rootNode.addChildNode(cameraNode)

                    // Signal that mesh is ready
                    self.isMeshLoaded = true
                }
            }
        }

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(markerState: markerState)
    }

    class Coordinator: NSObject, SCNSceneRendererDelegate {
        let markerState: MarkerProjectionState

        init(markerState: MarkerProjectionState) {
            self.markerState = markerState
        }

        func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
            markerState.updateProjections()
        }
    }



    /// Parses OBJ data and creates geometry with vertex colors (camera-sampled or height-based fallback).
    nonisolated static func buildGeometry(from data: Data, vertexColors: Data?) -> (SCNGeometry, Int)? {
        guard let parsed = MeshParser.parseOBJ(from: data) else { return nil }

        let vertices: [SCNVector3] = parsed.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
        var indices: [UInt32] = []
        for face in parsed.faces {
            indices.append(contentsOf: [face.0, face.1, face.2])
        }

        var minY: Float = .greatestFiniteMagnitude
        var maxY: Float = -.greatestFiniteMagnitude
        for v in parsed.vertices {
            minY = min(minY, v.y)
            maxY = max(maxY, v.y)
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
        // Subdivide mesh for smoother vertex color interpolation
        // Each triangle → 4 sub-triangles via edge midpoints
        var subVertices = vertices
        var subColors = colors
        var subIndices = [UInt32]()
        // Cache: sorted edge pair → midpoint vertex index
        var edgeMidpoints: [UInt64: UInt32] = [:]

        func midpointIndex(_ a: UInt32, _ b: UInt32) -> UInt32 {
            let key: UInt64 = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
            if let existing = edgeMidpoints[key] { return existing }
            let va = subVertices[Int(a)]
            let vb = subVertices[Int(b)]
            let mid = SCNVector3((va.x + vb.x) / 2, (va.y + vb.y) / 2, (va.z + vb.z) / 2)
            let ca = subColors[Int(a)]
            let cb = subColors[Int(b)]
            let midColor = (ca + cb) / 2
            let idx = UInt32(subVertices.count)
            subVertices.append(mid)
            subColors.append(midColor)
            edgeMidpoints[key] = idx
            return idx
        }

        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = indices[i], b = indices[i + 1], c = indices[i + 2]
            let ab = midpointIndex(a, b)
            let bc = midpointIndex(b, c)
            let ca = midpointIndex(c, a)
            // 4 sub-triangles
            subIndices.append(contentsOf: [a, ab, ca])
            subIndices.append(contentsOf: [ab, b, bc])
            subIndices.append(contentsOf: [ca, bc, c])
            subIndices.append(contentsOf: [ab, bc, ca])
        }

        // Use subdivided data for rendering
        let finalVertices = subVertices
        let finalColors = subColors
        let finalIndices = subIndices

        // Compute face normals and accumulate per-vertex for smooth shading
        var vertexNormals = [SIMD3<Float>](repeating: .zero, count: finalVertices.count)
        for i in stride(from: 0, to: finalIndices.count, by: 3) {
            let i0 = Int(finalIndices[i])
            let i1 = Int(finalIndices[i + 1])
            let i2 = Int(finalIndices[i + 2])
            guard i0 < finalVertices.count, i1 < finalVertices.count, i2 < finalVertices.count else { continue }

            let v0 = SIMD3<Float>(finalVertices[i0].x, finalVertices[i0].y, finalVertices[i0].z)
            let v1 = SIMD3<Float>(finalVertices[i1].x, finalVertices[i1].y, finalVertices[i1].z)
            let v2 = SIMD3<Float>(finalVertices[i2].x, finalVertices[i2].y, finalVertices[i2].z)

            let normal = simd_normalize(simd_cross(v1 - v0, v2 - v0))
            vertexNormals[i0] += normal
            vertexNormals[i1] += normal
            vertexNormals[i2] += normal
        }
        // Normalize
        let normals = vertexNormals.map { simd_normalize($0) }
            .map { SCNVector3($0.x, $0.y, $0.z) }

        let vertexSource = SCNGeometrySource(vertices: finalVertices)
        let normalSource = SCNGeometrySource(normals: normals)

        // Color source
        let colorData = Data(bytes: finalColors, count: finalColors.count * MemoryLayout<SIMD4<Float>>.stride)
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: finalColors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )

        let indexData = Data(bytes: finalIndices, count: finalIndices.count * MemoryLayout<UInt32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: finalIndices.count / 3,
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
        material.isDoubleSided = false // Single-sided so you can see into rooms
        geometry.materials = [material]

        return (geometry, vertices.count)
    }

    nonisolated static func heightGradientColors(vertices: [SCNVector3], minY: Float, maxY: Float) -> [SIMD4<Float>] {
        let yRange = maxY - minY
        return vertices.map { v in
            let t = yRange > 0 ? (v.y - minY) / yRange : 0.5
            let r: Float = 0.0
            let g: Float = min(t * 1.5, 1.0)
            let b: Float = max(1.0 - t * 1.5, 0.2)
            return SIMD4<Float>(r, g, b, 1.0)
        }
    }
    
    /// Generates a 2D snapshot of the mesh using an offscreen renderer.
    nonisolated static func generateSnapshot(meshURL: URL, colorsURL: URL?, poseMatrix: [Float]? = nil) -> UIImage? {
        guard let meshData = try? Data(contentsOf: meshURL) else { return nil }
        let colorsData = colorsURL.flatMap { try? Data(contentsOf: $0) }
        guard let (geometry, _) = buildGeometry(from: meshData, vertexColors: colorsData) else { return nil }
        
        let node = SCNNode(geometry: geometry)
        let (minBound, maxBound) = node.boundingBox
        let center = SCNVector3((minBound.x + maxBound.x) / 2, (minBound.y + maxBound.y) / 2, (minBound.z + maxBound.z) / 2)
        node.position = SCNVector3(-center.x, -center.y, -center.z)
        
        let containerNode = SCNNode()
        containerNode.addChildNode(node)
        
        let scene = SCNScene()
        scene.background.contents = UIColor.black
        scene.rootNode.addChildNode(containerNode)
        
        // Lighting
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
        
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.automaticallyAdjustsZRange = true
        
        if let matrix = poseMatrix, matrix.count == 16 {
            let m = SCNMatrix4(
                m11: matrix[0], m12: matrix[1], m13: matrix[2], m14: matrix[3],
                m21: matrix[4], m22: matrix[5], m23: matrix[6], m24: matrix[7],
                m31: matrix[8], m32: matrix[9], m33: matrix[10], m34: matrix[11],
                m41: matrix[12], m42: matrix[13], m43: matrix[14], m44: matrix[15]
            )
            cameraNode.transform = m
        } else {
            let size = SCNVector3(maxBound.x - minBound.x, maxBound.y - minBound.y, maxBound.z - minBound.z)
            let maxDimension = max(size.x, max(size.y, size.z))
            cameraNode.position = SCNVector3(0, maxDimension * 0.3, maxDimension * 0.4)
            cameraNode.look(at: SCNVector3Zero)
        }
        scene.rootNode.addChildNode(cameraNode)
        
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false
        
        let size = CGSize(width: 512, height: 512)
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }
}

#Preview {
    NavigationView {
        MeshPreviewContainer()
            .ignoresSafeArea()
    }
}
