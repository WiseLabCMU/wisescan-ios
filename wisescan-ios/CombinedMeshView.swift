import SwiftUI
import SceneKit
import simd

// MARK: - Combined Mesh Render
//
// Loads every mesh in a stitched cluster and places it in a single shared coordinate
// frame using the per-location transforms from `StitchGraphBuilder.placeScans`. Reuses
// `MeshPreviewView.buildGeometry` for colored geometry, mirroring its lighting/camera rig.

/// One mesh to compose into the shared scene.
struct CombinedMeshItem: Identifiable {
    let id: UUID            // scanId
    let name: String
    let meshURL: URL
    let colorsURL: URL?
    let transform: simd_float4x4
    /// Distinct hue used when "color by map" is enabled.
    let tint: UIColor
}

// MARK: - Container (presented modally)

struct CombinedMeshScreen: View {
    let title: String
    let items: [CombinedMeshItem]

    @Environment(\.dismiss) private var dismiss
    @State private var colorByMap = false
    @State private var isLoading = true

    /// Items whose mesh file actually exists on disk.
    private var presentItems: [CombinedMeshItem] {
        items.filter { FileManager.default.fileExists(atPath: $0.meshURL.path) }
    }
    private var missingCount: Int { items.count - presentItems.count }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(white: 0.15).ignoresSafeArea()

                if presentItems.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 44))
                            .foregroundColor(.gray)
                        Text("No meshes available")
                            .foregroundColor(.gray)
                    }
                } else {
                    CombinedMeshView(items: presentItems, colorByMap: colorByMap, onLoaded: { isLoading = false })
                        .ignoresSafeArea(edges: .bottom)
                }

                if isLoading && !presentItems.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        Text("Loading \(presentItems.count) mesh\(presentItems.count == 1 ? "" : "es")…")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    .padding(20)
                    .background(Color.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if missingCount > 0 {
                    VStack {
                        Spacer()
                        Text("\(missingCount) map\(missingCount == 1 ? "" : "s") skipped (mesh file missing)")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Capsule())
                            .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        colorByMap.toggle()
                    } label: {
                        Image(systemName: colorByMap ? "paintpalette.fill" : "paintpalette")
                    }
                    .disabled(presentItems.isEmpty)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - SceneKit view

struct CombinedMeshView: UIViewRepresentable {
    let items: [CombinedMeshItem]
    let colorByMap: Bool
    var onLoaded: () -> Void = {}

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = UIColor(white: 0.15, alpha: 1.0)
        scnView.allowsCameraControl = true
        scnView.antialiasingMode = .multisampling4X

        let scene = SCNScene()
        scnView.scene = scene

        // Lighting — same 3-light rig as MeshPreviewView.
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.color = UIColor(white: 0.4, alpha: 1.0)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.color = UIColor(white: 0.8, alpha: 1.0)
        key.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 4, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.color = UIColor(white: 0.3, alpha: 1.0)
        fill.eulerAngles = SCNVector3(Float.pi / 4, -Float.pi / 3, 0)
        scene.rootNode.addChildNode(fill)

        context.coordinator.load(into: scnView, items: items, colorByMap: colorByMap, onLoaded: onLoaded)
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // Re-tint in place when the toggle changes (no reload needed).
        context.coordinator.applyTint(colorByMap: colorByMap)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var meshNodes: [UUID: SCNNode] = [:]
        private var tints: [UUID: UIColor] = [:]

        func load(into scnView: SCNView, items: [CombinedMeshItem], colorByMap: Bool, onLoaded: @escaping () -> Void) {
            guard let scene = scnView.scene else { onLoaded(); return }
            let contentNode = SCNNode()
            scene.rootNode.addChildNode(contentNode)

            DispatchQueue.global(qos: .userInitiated).async {
                var built: [(item: CombinedMeshItem, geometry: SCNGeometry)] = []
                for item in items {
                    guard let data = try? Data(contentsOf: item.meshURL) else { continue }
                    let colors = item.colorsURL.flatMap { try? Data(contentsOf: $0) }
                    guard let (geometry, _) = MeshPreviewView.buildGeometry(from: data, vertexColors: colors) else { continue }
                    built.append((item, geometry))
                }

                DispatchQueue.main.async {
                    for entry in built {
                        let node = SCNNode(geometry: entry.geometry)
                        node.simdTransform = entry.item.transform
                        contentNode.addChildNode(node)
                        self.meshNodes[entry.item.id] = node
                        self.tints[entry.item.id] = entry.item.tint
                    }
                    self.applyTint(colorByMap: colorByMap)
                    self.frameCamera(scene: scene, contentNode: contentNode, scnView: scnView)
                    onLoaded()
                }
            }
        }

        /// Multiplies each mesh's color by its map tint (so seams between maps are visible),
        /// or clears the multiply to show the original sampled colors.
        func applyTint(colorByMap: Bool) {
            for (id, node) in meshNodes {
                guard let material = node.geometry?.materials.first else { continue }
                if colorByMap, let tint = tints[id] {
                    material.multiply.contents = tint
                } else {
                    material.multiply.contents = UIColor.white
                }
            }
        }

        /// Recenters the assembled cluster on its combined bounding box and frames the camera.
        private func frameCamera(scene: SCNScene, contentNode: SCNNode, scnView: SCNView) {
            guard let (minB, maxB) = combinedBounds(of: contentNode) else { return }
            let center = (minB + maxB) * 0.5
            contentNode.simdPosition = -center

            let size = maxB - minB
            let maxDim = max(size.x, max(size.y, size.z))

            let cameraNode = SCNNode()
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.automaticallyAdjustsZRange = true
            cameraNode.simdPosition = SIMD3<Float>(0, maxDim * 0.4, maxDim * 1.6)
            cameraNode.look(at: SCNVector3Zero)
            scene.rootNode.addChildNode(cameraNode)
            scnView.pointOfView = cameraNode
        }

        /// Union of all child mesh bounding boxes, expressed in `parent`'s coordinate space.
        private func combinedBounds(of parent: SCNNode) -> (SIMD3<Float>, SIMD3<Float>)? {
            var minB = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var maxB = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            var found = false
            for child in parent.childNodes {
                let (lo, hi) = child.boundingBox
                guard lo.x <= hi.x else { continue }
                found = true
                // Transform all 8 corners of the child's local box into parent space.
                for cx in [lo.x, hi.x] {
                    for cy in [lo.y, hi.y] {
                        for cz in [lo.z, hi.z] {
                            let local = SIMD4<Float>(Float(cx), Float(cy), Float(cz), 1)
                            let p = child.simdTransform * local
                            minB = simd_min(minB, SIMD3<Float>(p.x, p.y, p.z))
                            maxB = simd_max(maxB, SIMD3<Float>(p.x, p.y, p.z))
                        }
                    }
                }
            }
            return found ? (minB, maxB) : nil
        }
    }
}

// MARK: - Distinct tints

extension CombinedMeshItem {
    /// A small palette of high-contrast hues to assign per map.
    static let palette: [UIColor] = [
        UIColor(red: 0.40, green: 0.78, blue: 1.00, alpha: 1.0), // cyan
        UIColor(red: 1.00, green: 0.62, blue: 0.40, alpha: 1.0), // orange
        UIColor(red: 0.62, green: 1.00, blue: 0.55, alpha: 1.0), // green
        UIColor(red: 1.00, green: 0.55, blue: 0.85, alpha: 1.0), // pink
        UIColor(red: 0.85, green: 0.78, blue: 0.45, alpha: 1.0), // gold
        UIColor(red: 0.70, green: 0.60, blue: 1.00, alpha: 1.0), // violet
    ]
}
