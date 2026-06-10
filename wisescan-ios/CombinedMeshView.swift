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
    let scanDirectoryURL: URL?
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
    @State private var semanticViewMode: SemanticViewMode = .meshOnly
    @State private var detectedClasses: [SemanticClass] = []
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
                    CombinedMeshView(
                        items: presentItems, colorByMap: colorByMap,
                        semanticViewMode: semanticViewMode,
                        detectedClasses: $detectedClasses,
                        onLoaded: { isLoading = false }
                    )
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottomLeading) {
                        if semanticViewMode.showOutlines && !detectedClasses.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(detectedClasses, id: \.rawValue) { cls in
                                    HStack(spacing: 6) {
                                        Circle()
                                            .fill(cls.swiftUIDisplayColor)
                                            .frame(width: 10, height: 10)
                                        Text(cls.rawValue)
                                            .font(.caption2)
                                            .foregroundColor(.white)
                                    }
                                }
                            }
                            .padding(10)
                            .background(Color.black.opacity(0.7))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.leading, 16)
                            .padding(.bottom, 40)
                        }
                    }
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
                    HStack(spacing: 12) {
                        Button {
                            semanticViewMode = semanticViewMode.next
                        } label: {
                            Image(systemName: semanticViewMode.iconName)
                        }
                        .disabled(presentItems.isEmpty)

                        Button {
                            colorByMap.toggle()
                        } label: {
                            Image(systemName: colorByMap ? "paintpalette.fill" : "paintpalette")
                        }
                        .disabled(presentItems.isEmpty)
                    }
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
    let semanticViewMode: SemanticViewMode
    @Binding var detectedClasses: [SemanticClass]
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

        context.coordinator.load(
            into: scnView, items: items, colorByMap: colorByMap,
            semanticViewMode: semanticViewMode, detectedClassesBinding: $detectedClasses,
            onLoaded: onLoaded
        )
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // Re-tint in place when the toggle changes (no reload needed).
        context.coordinator.applyTint(colorByMap: colorByMap)
        context.coordinator.applyViewMode(semanticViewMode)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var meshNodes: [UUID: SCNNode] = [:]
        private var semanticsNode: SCNNode?
        private var semanticFillsNode: SCNNode?
        private var allDetectedClasses: [SemanticClass] = []
        private var detectedClassesBinding: Binding<[SemanticClass]>?
        // Two geometries per mesh, swapped on toggle (no runtime shader): the real per-vertex
        // colors, and a flat per-map color. The flat one omits the `.color` source so the map hue
        // isn't multiplied into the vertex/normal colors, but keeps `.normal` so it's still lit.
        private var coloredGeometries: [UUID: SCNGeometry] = [:]
        private var flatGeometries: [UUID: SCNGeometry] = [:]

        func load(into scnView: SCNView, items: [CombinedMeshItem], colorByMap: Bool,
                  semanticViewMode: SemanticViewMode, detectedClassesBinding: Binding<[SemanticClass]>,
                  onLoaded: @escaping () -> Void) {
            guard let scene = scnView.scene else { onLoaded(); return }
            self.detectedClassesBinding = detectedClassesBinding
            let contentNode = SCNNode()
            scene.rootNode.addChildNode(contentNode)

            DispatchQueue.global(qos: .userInitiated).async {
                var built: [(item: CombinedMeshItem, geometry: SCNGeometry, flat: SCNGeometry)] = []
                for item in items {
                    guard let data = try? Data(contentsOf: item.meshURL) else { continue }
                    let colors = item.colorsURL.flatMap { try? Data(contentsOf: $0) }
                    guard let (geometry, _) = MeshPreviewView.buildGeometry(from: data, vertexColors: colors) else { continue }
                    built.append((item, geometry, Self.makeFlatTinted(from: geometry, tint: item.tint)))
                }

                // Build RoomPlan outlines + fills for each scan
                var allOutlineNodes: [(wireNode: SCNNode, fillNode: SCNNode, transform: simd_float4x4)] = []
                var detectedSet = Set<SemanticClass>()
                for item in items {
                    if let result = MeshPreviewView.buildRoomPlanOutlines(
                        scanDirectoryURL: item.scanDirectoryURL
                    ) {
                        for outline in result.outlineNodes {
                            let wire = SCNNode(geometry: outline.geometry)
                            let fill = SCNNode(geometry: outline.fillGeometry)
                            allOutlineNodes.append((wire, fill, item.transform))
                        }
                        for cls in result.detectedClasses {
                            detectedSet.insert(cls)
                        }
                    }
                }

                DispatchQueue.main.async {
                    for entry in built {
                        let node = SCNNode(geometry: entry.geometry)
                        node.simdTransform = entry.item.transform
                        contentNode.addChildNode(node)
                        self.meshNodes[entry.item.id] = node
                        self.coloredGeometries[entry.item.id] = entry.geometry
                        self.flatGeometries[entry.item.id] = entry.flat
                    }

                    // Add semantics wireframes
                    let semNode = SCNNode()
                    let fillNode = SCNNode()
                    for entry in allOutlineNodes {
                        let wireWrapper = SCNNode()
                        wireWrapper.simdTransform = entry.transform
                        wireWrapper.addChildNode(entry.wireNode)
                        semNode.addChildNode(wireWrapper)

                        let fillWrapper = SCNNode()
                        fillWrapper.simdTransform = entry.transform
                        fillWrapper.addChildNode(entry.fillNode)
                        fillNode.addChildNode(fillWrapper)
                    }
                    semNode.isHidden = !semanticViewMode.showOutlines
                    fillNode.isHidden = !semanticViewMode.showFills
                    contentNode.addChildNode(semNode)
                    contentNode.addChildNode(fillNode)
                    self.semanticsNode = semNode
                    self.semanticFillsNode = fillNode

                    // Apply initial mesh visibility
                    if !semanticViewMode.showMesh {
                        for (_, node) in self.meshNodes { node.isHidden = true }
                    }

                    self.allDetectedClasses = SemanticClass.allCases.filter { detectedSet.contains($0) && $0 != .none }
                    detectedClassesBinding.wrappedValue = self.allDetectedClasses

                    self.applyTint(colorByMap: colorByMap)
                    self.frameCamera(scene: scene, contentNode: contentNode, scnView: scnView)
                    onLoaded()
                }
            }
        }

        /// Swaps each mesh between its real per-vertex colors and a single flat, *lit* per-map color
        /// (so seams between maps are obvious while shape/depth stay readable). We swap whole
        /// geometries rather than tinting the colored one — a `material.multiply` tint would multiply
        /// the map hue into the per-vertex colors, which over normals coloring reads as "shifted
        /// normals" instead of one discrete color.
        func applyTint(colorByMap: Bool) {
            for (id, node) in meshNodes {
                node.geometry = colorByMap ? flatGeometries[id] : coloredGeometries[id]
            }
        }

        /// Applies the 3-mode visibility: mesh, outlines, and fills.
        func applyViewMode(_ mode: SemanticViewMode) {
            for (_, node) in meshNodes { node.isHidden = !mode.showMesh }
            semanticsNode?.isHidden = !mode.showOutlines
            semanticFillsNode?.isHidden = !mode.showFills
        }

        /// A flat per-map variant of `geometry`: same vertices/normals/elements, but the per-vertex
        /// `.color` source dropped and a single lit diffuse color, so it renders as one discrete
        /// hue with normal shading (depth cues) — and needs no runtime Metal shader.
        private static func makeFlatTinted(from geometry: SCNGeometry, tint: UIColor) -> SCNGeometry {
            let sources = geometry.sources.filter { $0.semantic != .color }
            let flat = SCNGeometry(sources: sources, elements: geometry.elements)
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = tint
            material.isDoubleSided = false
            flat.materials = [material]
            return flat
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
        UIColor(red: 0.70, green: 0.60, blue: 1.00, alpha: 1.0) // violet
    ]
}
