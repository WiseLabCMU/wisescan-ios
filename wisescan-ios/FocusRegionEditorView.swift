import SceneKit
import SwiftData
import SwiftUI
import simd

// MARK: - Focus region drawing (docs/design/capture-modes.md, MVP)

/// Draw the box a focus scan captures, on a room scan's mesh. Tap a RoomPlan object (a table, a
/// shelf) to take its box with a margin and headroom for what sits on it, or tap the mesh to drop
/// a default box on that surface; then adjust it with the sliders and pick the detail level.
/// Direct drag handles on the box are a later step.
///
/// The region is stored in the frame of this scan's `mesh.obj` (see `FocusRegion`): the viewer
/// draws the mesh shifted by the location's canonical room centre, and the editor adds it back.
struct FocusRegionEditorView: View {
    let scan: CapturedScan
    let onScan: (FocusRegion) -> Void
    let onCancel: () -> Void

    @State private var region: FocusRegion?
    /// Where the box was placed; the position sliders move it relative to this.
    @State private var anchor: SIMD3<Float> = .zero
    @State private var offset: SIMD3<Float> = .zero
    @State private var label = ""
    @State private var detail: FocusDetailLevel = .check
    @State private var sceneCentre: SIMD3<Float> = .zero
    @State private var frameIsCanonical = true
    @State private var loadFailed = false

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                FocusRegionSceneView(meshURL: scan.meshFileURL, colorsURL: scan.colorsFileURL,
                                     scanDirectory: scan.scanDirectory, sceneCentre: sceneCentre,
                                     region: adjustedRegion, onPick: place, onLoadFailed: { loadFailed = true })
                    .ignoresSafeArea(edges: .bottom)
                VStack(spacing: 0) {
                    if region == nil { hint } else { controls }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Focus region")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Scan") { if let region = finalRegion { onScan(region) } }
                        .bold()
                        .disabled(finalRegion == nil)
                }
            }
            .alert("No mesh to draw on", isPresented: $loadFailed) {
                Button("OK", action: onCancel)
            } message: {
                Text("This scan has no mesh, so a region cannot be drawn on it.")
            }
        }
        .onAppear {
            // Tiny JSON reads (the original's roomplan.json, this scan's registration.json).
            sceneCentre = MeshPreviewView.canonicalFrameCenter(for: scan.location) ?? .zero
            let isOriginal = ScanPostprocessor.original(of: scan)?.id == scan.id
            frameIsCanonical = isOriginal || SaveRegistration.appliedTransform(scanDirectory: scan.scanDirectory) != nil
        }
    }

    /// The placed region moved by the position sliders (what the scene draws).
    private var adjustedRegion: FocusRegion? {
        guard var region else { return nil }
        region.center = anchor + offset
        return region
    }

    /// The region as adjusted, labelled and levelled; nil until one is placed or when invalid.
    private var finalRegion: FocusRegion? {
        guard var region = adjustedRegion else { return nil }
        region.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        region.detail = detail
        return region.isValid ? region : nil
    }

    private var hint: some View {
        Label("Tap a table or object to select it, or tap the mesh to drop a box",
              systemImage: "hand.tap")
            .font(.subheadline)
            .foregroundColor(.white)
            .padding(12)
            .background(Color.black.opacity(AppConstants.focusHUDBackgroundOpacity))
            .cornerRadius(12)
            .padding(.bottom, 24)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Label (optional), e.g. work table", text: $label)
                .textFieldStyle(.roundedBorder)
            Picker("Detail", selection: $detail) {
                ForEach(FocusDetailLevel.allCases) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
            Text(detail.summary)
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
            sizeSlider("Width", axis: 0)
            sizeSlider("Depth", axis: 2)
            sizeSlider("Height", axis: 1)
            yawSlider
            offsetSlider("Left / right", axis: 0)
            offsetSlider("Forward / back", axis: 2)
            offsetSlider("Up / down", axis: 1)
        }
        .font(.caption)
        .foregroundColor(.white)
        .padding(14)
        .background(Color.black.opacity(AppConstants.focusEditorPanelOpacity))
        .cornerRadius(16)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private func sizeSlider(_ title: String, axis: Int) -> some View {
        let binding = Binding<Float>(
            get: { region?.size[axis] ?? AppConstants.focusRegionMinSizeM },
            set: { value in region?.size[axis] = value })
        return HStack {
            Text(title).frame(width: AppConstants.focusEditorLabelWidth, alignment: .leading)
            Slider(value: binding, in: AppConstants.focusRegionMinSizeM...AppConstants.focusRegionEditorMaxSizeM)
            Text(String(format: "%.2f m", binding.wrappedValue)).monospacedDigit()
                .frame(width: AppConstants.focusEditorValueWidth, alignment: .trailing)
        }
    }

    private var yawSlider: some View {
        let binding = Binding<Float>(
            get: { (region?.yaw ?? 0) * 180 / .pi },
            set: { value in region?.yaw = value * .pi / 180 })
        return HStack {
            Text("Turn").frame(width: AppConstants.focusEditorLabelWidth, alignment: .leading)
            Slider(value: binding, in: -180...180)
            Text(String(format: "%.0f°", binding.wrappedValue)).monospacedDigit()
                .frame(width: AppConstants.focusEditorValueWidth, alignment: .trailing)
        }
    }

    /// Moves the box along its own axes (so "forward" follows its turn), within a metre of where
    /// it was placed.
    private func offsetSlider(_ title: String, axis: Int) -> some View {
        let yaw = region?.yaw ?? 0
        let rotation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        var unit = SIMD3<Float>(repeating: 0)
        unit[axis] = 1
        let direction = axis == 1 ? unit : rotation.act(unit)
        let binding = Binding<Float>(
            get: { simd_dot(offset, direction) },
            set: { value in offset += direction * (value - simd_dot(offset, direction)) })
        let range = AppConstants.focusRegionEditorMoveRangeM
        return HStack {
            Text(title).frame(width: AppConstants.focusEditorLabelWidth, alignment: .leading)
            Slider(value: binding, in: -range...range)
            Text(String(format: "%+.2f m", binding.wrappedValue)).monospacedDigit()
                .frame(width: AppConstants.focusEditorValueWidth, alignment: .trailing)
        }
    }

    /// A tap from the scene: a new box replaces the old one and the position sliders re-centre.
    private func place(_ picked: FocusRegion) {
        var placed = picked
        placed.frameScanId = scan.id
        placed.frameIsCanonical = frameIsCanonical
        placed.locationId = scan.location?.id
        placed.detail = detail
        anchor = placed.center
        offset = .zero
        if label.isEmpty { label = placed.label }
        region = placed
    }
}

// MARK: - Scene

/// The room scan's mesh in SceneKit with its RoomPlan objects as tap targets, and the region box.
/// Scene coordinates are mesh coordinates minus `sceneCentre` (the viewer's convention); picks
/// come back in mesh coordinates.
struct FocusRegionSceneView: UIViewRepresentable {
    let meshURL: URL
    let colorsURL: URL
    let scanDirectory: URL
    let sceneCentre: SIMD3<Float>
    let region: FocusRegion?
    let onPick: (FocusRegion) -> Void
    let onLoadFailed: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(white: 0.15, alpha: 1)
        view.allowsCameraControl = true
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = true
        let scene = SCNScene()
        view.scene = scene
        let container = SCNNode()
        container.simdPosition = -sceneCentre
        scene.rootNode.addChildNode(container)
        context.coordinator.container = container
        context.coordinator.view = view
        context.coordinator.parent = self

        // Same coexistence with SceneKit's camera recognizers as the scan viewer's tap-to-identify.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        for existing in view.gestureRecognizers ?? [] {
            if let multiTap = existing as? UITapGestureRecognizer, multiTap.numberOfTapsRequired > 1 {
                tap.require(toFail: multiTap)
            }
        }
        view.addGestureRecognizer(tap)

        let meshURL = meshURL, colorsURL = colorsURL, scanDirectory = scanDirectory
        let onLoadFailed = onLoadFailed
        DispatchQueue.global(qos: .userInitiated).async {
            let meshData = try? Data(contentsOf: meshURL)
            let colors = try? Data(contentsOf: colorsURL)
            let geometry = meshData.flatMap { MeshPreviewView.buildGeometry(from: $0, vertexColors: colors)?.0 }
            let objects = Self.roomPlanObjects(scanDirectory: scanDirectory)
            DispatchQueue.main.async {
                guard let geometry else {
                    onLoadFailed()
                    return
                }
                let mesh = SCNNode(geometry: geometry)
                mesh.name = Coordinator.meshName
                container.addChildNode(mesh)
                for (index, object) in objects.enumerated() {
                    container.addChildNode(Self.objectNode(object, index: index))
                }
                context.coordinator.objects = objects
            }
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.container?.simdPosition = -sceneCentre   // the centre arrives after makeUIView
        context.coordinator.showRegion(region)
    }

    // MARK: RoomPlan objects

    struct RoomObject {
        let category: String
        let transform: simd_float4x4
        let size: SIMD3<Float>
    }

    nonisolated static func roomPlanObjects(scanDirectory: URL) -> [RoomObject] {
        let candidates = [scanDirectory.appendingPathComponent("roomplan.json"),
                          scanDirectory.appendingPathComponent("raw_data").appendingPathComponent("roomplan.json")]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let room = try? JSONDecoder().decode(RoomPlanExportData.self, from: data) else { continue }
            return room.objects.compactMap { object in
                guard object.transform.count == 16 else { return nil }
                let t = object.transform
                let matrix = simd_float4x4(SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]),
                                           SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15]))
                return RoomObject(category: object.category, transform: matrix,
                                  size: SIMD3(object.dimensions.width, object.dimensions.height, object.dimensions.depth))
            }
        }
        return []
    }

    /// A faint box per object: visible enough to aim at, and the hit-test target.
    static func objectNode(_ object: RoomObject, index: Int) -> SCNNode {
        let box = SCNBox(width: CGFloat(object.size.x), height: CGFloat(object.size.y),
                         length: CGFloat(object.size.z), chamferRadius: 0)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.cyan.withAlphaComponent(AppConstants.focusEditorObjectOpacity)
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        box.materials = [material]
        let node = SCNNode(geometry: box)
        node.simdTransform = object.transform
        node.name = Coordinator.objectPrefix + String(index)
        return node
    }

    /// Box for a tapped object: its footprint plus a margin, its height plus headroom for what
    /// sits on it, gravity-aligned at the object's turn.
    static func region(for object: RoomObject) -> FocusRegion {
        let t = object.transform
        let yaw = atan2(t.columns.2.x, t.columns.2.z)
        let margin = AppConstants.focusRegionObjectMarginM
        let headroom = AppConstants.focusRegionObjectHeadroomM
        let size = SIMD3<Float>(object.size.x + 2 * margin, object.size.y + headroom, object.size.z + 2 * margin)
        let centre = SIMD3<Float>(t.columns.3.x, t.columns.3.y + headroom / 2, t.columns.3.z)
        return FocusRegion(center: centre, yaw: yaw, size: size, label: object.category, source: .roomplan)
    }

    /// Default box dropped on a mesh point: resting just below the tapped surface, turned to
    /// face the viewer.
    static func region(at point: SIMD3<Float>, viewerYaw: Float) -> FocusRegion {
        let size = AppConstants.focusRegionDefaultSizeM
        let centre = SIMD3<Float>(point.x, point.y + size.y / 2 - AppConstants.focusRegionDropSinkM, point.z)
        return FocusRegion(center: centre, yaw: viewerYaw, size: size, source: .user)
    }

    final class Coordinator: NSObject {
        static let meshName = "focus-mesh"
        static let objectPrefix = "focus-object-"
        static let regionName = "focus-region"

        weak var view: SCNView?
        var container: SCNNode?
        var objects: [RoomObject] = []
        var parent: FocusRegionSceneView?
        private var regionNode: SCNNode?
        private var shown: FocusRegion?

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view, let parent else { return }
            let point = gesture.location(in: view)
            let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.all.rawValue,
                                                    .ignoreHiddenNodes: true])
            for hit in hits {
                guard let name = hit.node.name, name != Self.regionName else { continue }
                if name.hasPrefix(Self.objectPrefix), let index = Int(name.dropFirst(Self.objectPrefix.count)),
                   index < objects.count {
                    parent.onPick(FocusRegionSceneView.region(for: objects[index]))
                    return
                }
                if name == Self.meshName {
                    let world = hit.simdWorldCoordinates + parent.sceneCentre   // scene -> mesh frame
                    let viewerYaw = view.pointOfView.map { atan2($0.simdWorldFront.x, $0.simdWorldFront.z) + .pi } ?? 0
                    parent.onPick(FocusRegionSceneView.region(at: world, viewerYaw: viewerYaw))
                    return
                }
            }
        }

        /// Rebuilds the region box when the region changes (main thread).
        func showRegion(_ region: FocusRegion?) {
            guard region != shown else { return }
            shown = region
            regionNode?.removeFromParentNode()
            regionNode = nil
            guard let region, let container else { return }
            let node = SCNNode()
            node.name = Self.regionName
            node.simdTransform = region.transform
            let fill = SCNBox(width: CGFloat(region.size.x), height: CGFloat(region.size.y),
                              length: CGFloat(region.size.z), chamferRadius: 0)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemYellow.withAlphaComponent(AppConstants.focusEditorRegionOpacity)
            material.isDoubleSided = true
            material.writesToDepthBuffer = false
            fill.materials = [material]
            let fillNode = SCNNode(geometry: fill)
            fillNode.name = Self.regionName
            node.addChildNode(fillNode)
            let edgeMaterial = SCNMaterial()
            edgeMaterial.diffuse.contents = UIColor.systemYellow
            edgeMaterial.lightingModel = .constant
            let h = region.halfExtents
            let thickness = CGFloat(AppConstants.focusEditorEdgeThicknessM)
            for axis in 0..<3 {
                let length = CGFloat(2 * h[axis])
                let edge = SCNBox(width: axis == 0 ? length : thickness, height: axis == 1 ? length : thickness,
                                  length: axis == 2 ? length : thickness, chamferRadius: 0)
                edge.materials = [edgeMaterial]
                let others = (0..<3).filter { $0 != axis }
                for a in [Float(-1), 1] {
                    for b in [Float(-1), 1] {
                        var position = SIMD3<Float>(repeating: 0)
                        position[others[0]] = a * h[others[0]]
                        position[others[1]] = b * h[others[1]]
                        let edgeNode = SCNNode(geometry: edge)
                        edgeNode.simdPosition = position
                        edgeNode.name = Self.regionName
                        node.addChildNode(edgeNode)
                    }
                }
            }
            container.addChildNode(node)
            regionNode = node
        }
    }
}

#Preview("Focus region editor (no mesh)") {
    // No mesh on disk in a preview: shows the "no mesh" alert over the empty scene.
    let container = try! ModelContainer(for: ScanLocation.self, CapturedScan.self, StitchLink.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let scan = CapturedScan(name: "Scan 1", vertexCount: 0, faceCount: 0)
    container.mainContext.insert(scan)
    return FocusRegionEditorView(scan: scan, onScan: { _ in }, onCancel: {})
        .modelContainer(container)
}
