import SwiftUI
import SceneKit
import SwiftData
import simd

// MARK: - Combined Mesh Render
//
// Loads every mesh in a stitched cluster and places it in a single shared coordinate
// frame using the per-location transforms from `StitchGraphBuilder.placeScans`. Reuses
// `MeshPreviewView.buildGeometry` for colored geometry, mirroring its lighting/camera rig.
//
// Step 2c adds, on top of that: a legend panel that names each map (with its tint) and its
// correction status, visible markers at each stitch pin, and a per-map manual rotate/translate
// adjuster whose slider values recompose the placement transforms live (in-memory — no disk) and
// persist to the link's stored `manualNudge`.

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

/// One row of the combined render's legend/adjuster panel: a map (piece) with its tint, name, and
/// correction status. `parentLinkId` is the join the adjuster edits to move this piece (nil = base).
private struct StitchRoomRow: Identifiable {
    let id: UUID              // locationId
    let name: String
    let tint: Color
    let parentLinkId: UUID?
    var yawDeg: Float = 0          // magnitude the solver found for this join (shown applied or not)
    var perpCm: Float = 0
    var autoAvailable = false      // solver found a trusted correction for this join
    var autoOn = false             // that correction is currently applied (effective)
    var hasManual = false
    var isBase: Bool { parentLinkId == nil }
}

struct CombinedMeshScreen: View {
    let request: ComponentRenderRequest

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var colorByMap = false
    @State private var semanticViewMode: SemanticViewMode = .meshOnly
    @State private var detectedClasses: [SemanticClass] = []
    @State private var isLoading = true
    @State private var showLegend = true
    /// Live adjuster values by link id (seeded from each link's stored nudge on appear). This is the
    /// single source of truth for the view while open; committed back to the links on Save.
    @State private var manualDrafts: [UUID: ManualNudge] = [:]
    /// Effective auto-correct state per join (render source). Seeded from each link's
    /// `autoCorrectEffective`; a toggle updates this AND persists the link's override.
    @State private var autoApplied: [UUID: Bool] = [:]
    @State private var editingLinkId: UUID?
    /// Global "always autocorrect" default (implicitly all joins, unless a per-join override wins).
    @AppStorage(StitchPrefs.alwaysAutocorrectKey) private var alwaysAutocorrect = false

    private var title: String { request.title }
    private var hasStitches: Bool { !request.edges.isEmpty && !request.component.isEmpty }

    /// Placement recomputed in-memory from the current drafts. Cheap (matrix math over a few edges);
    /// no disk because the Op-2 corrections are passed pre-solved in `request.autoCorrections`.
    private var livePlacement: ComponentPlacement {
        guard hasStitches else {
            return ComponentPlacement(scans: request.placements, stitchPoints: request.stitchPoints)
        }
        return StitchGraphBuilder.placeScans(
            in: request.component, edges: request.edges,
            autoCorrections: request.autoCorrections, manualOverrides: manualDrafts,
            autoApplied: autoApplied)
    }

    private func displayItems(from placement: ComponentPlacement) -> [CombinedMeshItem] {
        guard hasStitches else { return request.items }
        let tByScan = Dictionary(placement.scans.map { ($0.scanId, $0.transform) }, uniquingKeysWith: { a, _ in a })
        return request.items.map { $0.withTransform(tByScan[$0.id] ?? $0.transform) }
    }

    private func roomRows(from placement: ComponentPlacement, items: [CombinedMeshItem]) -> [StitchRoomRow] {
        let itemByScan = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return placement.scans.compactMap { p -> StitchRoomRow? in
            guard let item = itemByScan[p.scanId] else { return nil }
            let corr = p.parentLinkId.flatMap { request.autoCorrections[$0] }
            let available = (corr?.appliedYaw ?? false) || (corr?.appliedPerp ?? false)
            let draft = p.parentLinkId.flatMap { manualDrafts[$0] }
            let on = p.parentLinkId.flatMap { autoApplied[$0] } ?? false
            return StitchRoomRow(
                id: p.locationId, name: item.name, tint: Color(uiColor: item.tint),
                parentLinkId: p.parentLinkId,
                yawDeg: corr?.yawDeg ?? 0, perpCm: corr?.perpCm ?? 0,
                autoAvailable: available, autoOn: available && on,
                hasManual: !(draft ?? .zero).isZero)
        }
    }

    /// Items whose mesh file actually exists on disk.
    private func present(_ items: [CombinedMeshItem]) -> [CombinedMeshItem] {
        items.filter { FileManager.default.fileExists(atPath: $0.meshURL.path) }
    }

    var body: some View {
        let placement = livePlacement
        let all = displayItems(from: placement)
        let presentItems = present(all)
        let missingCount = all.count - presentItems.count
        let rooms = roomRows(from: placement, items: all)

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
                        items: presentItems, stitchPoints: placement.stitchPoints,
                        colorByMap: colorByMap, semanticViewMode: semanticViewMode,
                        detectedClasses: $detectedClasses,
                        onLoaded: { isLoading = false }
                    )
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottomLeading) { semanticLegend }
                }

                if isLoading && !presentItems.isEmpty { loadingOverlay(count: presentItems.count) }
                if missingCount > 0 { missingBadge(missingCount) }

                // Room legend + per-map correction status (Step 2c). Tap a map to adjust its join.
                if hasStitches && rooms.count > 1 && showLegend && editingLinkId == nil {
                    StitchLegendPanel(
                        rooms: rooms,
                        alwaysAutocorrect: $alwaysAutocorrect,
                        anyAvailableOff: rooms.contains { $0.autoAvailable && !$0.autoOn },
                        anyAutoOn: rooms.contains { $0.autoOn },
                        onToggleAuto: { row in if let lid = row.parentLinkId { toggleAuto(lid) } },
                        onAutocorrectAll: autocorrectAll,
                        onClearAll: clearAllAuto,
                        onAdjust: { row in if let lid = row.parentLinkId { editingLinkId = lid } }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 8)
                    .padding(.trailing, 12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                // Manual rotate/translate adjuster for the selected map's join.
                if let lid = editingLinkId {
                    ManualAdjustPanel(
                        title: adjustTitle(forLink: lid, rooms: rooms),
                        nudge: draftBinding(lid),
                        onReset: { manualDrafts[lid] = .zero },
                        onCancel: { cancelEdit(lid) },
                        onSave: { commitEdit(lid) }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.move(edge: .bottom))
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent(present: presentItems) }
            .preferredColorScheme(.dark)
            .onAppear(perform: seedDrafts)
            .onChange(of: alwaysAutocorrect) { _, newVal in applyAlwaysChange(newVal) }
            .animation(.easeInOut(duration: 0.2), value: showLegend)
            .animation(.easeInOut(duration: 0.2), value: editingLinkId)
        }
    }

    // MARK: Overlays (extracted for the type-check budget)

    @ViewBuilder private var semanticLegend: some View {
        if semanticViewMode.showOutlines && !detectedClasses.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(detectedClasses, id: \.rawValue) { cls in
                    HStack(spacing: 6) {
                        Circle().fill(cls.swiftUIDisplayColor).frame(width: 10, height: 10)
                        Text(cls.rawValue).font(.caption2).foregroundColor(.white)
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

    private func loadingOverlay(count: Int) -> some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Loading \(count) mesh\(count == 1 ? "" : "es")…")
                .font(.caption).foregroundColor(.gray)
        }
        .padding(20)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func missingBadge(_ count: Int) -> some View {
        VStack {
            Spacer()
            Text("\(count) map\(count == 1 ? "" : "s") skipped (mesh file missing)")
                .font(.caption2).foregroundColor(.yellow)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.black.opacity(0.6))
                .clipShape(Capsule())
                .padding(.bottom, 24)
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(present: [CombinedMeshItem]) -> some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 12) {
                if hasStitches {
                    Button { showLegend.toggle() } label: {
                        Image(systemName: showLegend ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                    }
                }
                Button { semanticViewMode = semanticViewMode.next } label: {
                    Image(systemName: semanticViewMode.iconName)
                }
                .disabled(present.isEmpty)

                Button { colorByMap.toggle() } label: {
                    Image(systemName: colorByMap ? "paintpalette.fill" : "paintpalette")
                }
                .disabled(present.isEmpty)
            }
        }
    }

    // MARK: Adjuster plumbing

    private func seedDrafts() {
        guard manualDrafts.isEmpty else { return }
        for e in request.edges {
            manualDrafts[e.link.id] = e.link.manualNudge
            autoApplied[e.link.id] = e.link.autoCorrectEffective
        }
    }

    private func draftBinding(_ id: UUID) -> Binding<ManualNudge> {
        Binding(get: { manualDrafts[id] ?? .zero }, set: { manualDrafts[id] = $0 })
    }

    private func adjustTitle(forLink id: UUID, rooms: [StitchRoomRow]) -> String {
        rooms.first(where: { $0.parentLinkId == id })?.name ?? "map"
    }

    private func link(for id: UUID) -> StitchLink? {
        request.edges.first(where: { $0.link.id == id })?.link
    }

    private func cancelEdit(_ id: UUID) {
        if let link = link(for: id) { manualDrafts[id] = link.manualNudge }   // restore stored
        editingLinkId = nil
    }

    private func commitEdit(_ id: UUID) {
        if let link = link(for: id) {
            link.manualNudge = manualDrafts[id] ?? .zero
            do { try modelContext.save() }
            catch { print("[StitchCorrect] manual nudge save failed: \(error.localizedDescription)") }
        }
        editingLinkId = nil
    }

    // MARK: Auto-correct opt-in (per-join / all / always)

    /// Link ids whose join has a trusted correction the solver could apply.
    private func availableLinkIds() -> [UUID] {
        request.edges.compactMap { e in
            let c = request.autoCorrections[e.link.id]
            return (c?.appliedYaw == true || c?.appliedPerp == true) ? e.link.id : nil
        }
    }

    private func persist() {
        do { try modelContext.save() }
        catch { print("[StitchCorrect] auto-correct save failed: \(error.localizedDescription)") }
    }

    private func toggleAuto(_ id: UUID) {
        let new = !(autoApplied[id] ?? false)
        autoApplied[id] = new
        link(for: id)?.autoCorrectOverride = new     // explicit per-join override (wins over global)
        persist()
    }

    private func autocorrectAll() {
        for id in availableLinkIds() {
            autoApplied[id] = true
            link(for: id)?.autoCorrectOverride = true
        }
        persist()
    }

    private func clearAllAuto() {
        for e in request.edges {
            autoApplied[e.link.id] = false
            e.link.autoCorrectOverride = false
        }
        persist()
    }

    /// "Always autocorrect" changed: joins WITHOUT an explicit override follow the new global default.
    private func applyAlwaysChange(_ newVal: Bool) {
        for e in request.edges where e.link.autoCorrectOverride == nil {
            autoApplied[e.link.id] = newVal
        }
    }
}

// MARK: - Legend / status panel

private struct StitchLegendPanel: View {
    let rooms: [StitchRoomRow]
    @Binding var alwaysAutocorrect: Bool
    let anyAvailableOff: Bool
    let anyAutoOn: Bool
    let onToggleAuto: (StitchRoomRow) -> Void
    let onAutocorrectAll: () -> Void
    let onClearAll: () -> Void
    let onAdjust: (StitchRoomRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                Text("Maps").font(.subheadline.weight(.semibold))
                Spacer()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider().overlay(Color.white.opacity(0.15))

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rooms) { room in
                        row(room)
                        if room.id != rooms.last?.id {
                            Divider().overlay(Color.white.opacity(0.08))
                        }
                    }
                }
            }
            .frame(maxHeight: 240)

            Divider().overlay(Color.white.opacity(0.15))
            footer
        }
        .frame(width: 260)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(radius: 8)
    }

    private func row(_ room: StitchRoomRow) -> some View {
        HStack(spacing: 8) {
            Circle().fill(room.tint).frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.white.opacity(0.5), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name).font(.caption.weight(.medium)).foregroundColor(.white).lineLimit(1)
                statusLine(room)
            }
            Spacer(minLength: 2)
            if room.autoAvailable {
                Button { onToggleAuto(room) } label: {
                    Text("Auto")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(room.autoOn ? Color.orange : Color.white.opacity(0.12))
                        .foregroundColor(room.autoOn ? .black : .white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if !room.isBase {
                Button { onAdjust(room) } label: {
                    Image(systemName: "slider.horizontal.3").font(.caption).foregroundColor(.cyan)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private func statusLine(_ room: StitchRoomRow) -> some View {
        if room.isBase {
            Text("Base map (reference)").font(.caption2).foregroundColor(.gray)
        } else if room.hasManual {
            Text("Manually adjusted").font(.caption2).foregroundColor(.cyan)
        } else if room.autoOn {
            Text("Auto-corrected · " + summary(room)).font(.caption2).foregroundColor(.orange).lineLimit(1)
        } else if room.autoAvailable {
            Text("Auto-fix available · " + summary(room)).font(.caption2).foregroundColor(.yellow).lineLimit(1)
        } else {
            Text("Aligned").font(.caption2).foregroundColor(.green.opacity(0.85))
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $alwaysAutocorrect) {
                Text("Always autocorrect").font(.caption).foregroundColor(.white)
            }
            .toggleStyle(SwitchToggleStyle(tint: .cyan))

            if anyAvailableOff || anyAutoOn {
                HStack(spacing: 8) {
                    if anyAvailableOff {
                        Button(action: onAutocorrectAll) {
                            Text("Autocorrect all").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.orange).foregroundColor(.black)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if anyAutoOn {
                        Button(action: onClearAll) {
                            Text("Clear").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.white.opacity(0.12)).foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func summary(_ room: StitchRoomRow) -> String {
        var parts: [String] = []
        if abs(room.yawDeg) >= 0.05 { parts.append(String(format: "yaw %+.1f°", room.yawDeg)) }
        if room.perpCm >= 0.5 { parts.append(String(format: "shift %.0f cm", room.perpCm)) }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }
}

// MARK: - Manual rotate/translate adjuster

private struct ManualAdjustPanel: View {
    let title: String
    @Binding var nudge: ManualNudge
    let onReset: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Adjust \(title)").font(.headline).foregroundColor(.white).lineLimit(1)
                    Text("Rotate & move this map to fine-tune the join")
                        .font(.caption2).foregroundColor(.gray)
                }
                Spacer()
                Button("Reset", action: onReset).font(.subheadline).foregroundColor(.orange)
            }

            slider("rotate.3d", "Rotate", $nudge.yawDeg, -30...30, "%.1f°")
            slider("arrow.left.and.right", "Left / Right", $nudge.dx, -2...2, "%.2f m")
            slider("arrow.up.and.down", "Fwd / Back", $nudge.dz, -2...2, "%.2f m")
            slider("arrow.up.arrow.down", "Up / Down", $nudge.dy, -2...2, "%.2f m")

            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Cancel").frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .foregroundColor(.white)
                Button(action: onSave) {
                    Text("Save").frame(maxWidth: .infinity).padding(.vertical, 10)
                        .background(Color.cyan)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .foregroundColor(.black)
            }
            .font(.subheadline.bold())
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    /// A nonlinear (signed-power) slider: the thumb travels a *linear* normalized position `p∈[-1,1]`
    /// but the bound value is `sign(p)·|p|^curve · max`, so the center of the travel gives fine
    /// control and the extremes reach the full (now large, ±2 m) range — you fine-tune most of the
    /// time yet can still dial out a big drift. `curve = 1` would be linear; `2` is a gentle ease.
    @ViewBuilder
    private func slider(_ icon: String, _ label: String, _ value: Binding<Float>,
                        _ range: ClosedRange<Float>, _ fmt: String, curve: Double = 2) -> some View {
        let maxAbs = Double(max(abs(range.lowerBound), abs(range.upperBound)))
        let position = Binding<Double>(
            get: {
                guard maxAbs > 0 else { return 0 }
                let n = min(1, max(-1, Double(value.wrappedValue) / maxAbs))
                return (n < 0 ? -1 : 1) * pow(abs(n), 1 / curve)
            },
            set: { p in
                value.wrappedValue = Float((p < 0 ? -1 : 1) * pow(abs(p), curve) * maxAbs)
            }
        )
        HStack {
            Image(systemName: icon).frame(width: 24).foregroundColor(.cyan)
            Text(label).font(.caption).frame(width: 84, alignment: .leading)
            Slider(value: position, in: -1...1)
            Text(String(format: fmt, value.wrappedValue))
                .font(.caption.monospacedDigit())
                .frame(width: 56, alignment: .trailing)
        }
        .foregroundColor(.white)
    }
}

// MARK: - SceneKit view

struct CombinedMeshView: UIViewRepresentable {
    let items: [CombinedMeshItem]
    var stitchPoints: [StitchPoint] = []
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
            into: scnView, items: items, stitchPoints: stitchPoints, colorByMap: colorByMap,
            semanticViewMode: semanticViewMode, detectedClassesBinding: $detectedClasses,
            onLoaded: onLoaded
        )
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // Re-tint in place when the toggle changes (no reload needed).
        context.coordinator.applyTint(colorByMap: colorByMap)
        context.coordinator.applyViewMode(semanticViewMode)
        // Live manual adjuster: move pieces + stitch markers to the recomputed transforms without
        // reloading meshes. No-ops until the async load has populated the nodes.
        context.coordinator.applyTransforms(from: items)
        context.coordinator.updateStitchPoints(stitchPoints)
        context.coordinator.updateLabels(from: items)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var meshNodes: [UUID: SCNNode] = [:]
        // RoomPlan outline/fill wrappers keyed by scanId so a live nudge moves them with the mesh.
        private var outlineWrappers: [UUID: [SCNNode]] = [:]
        private var fillWrappers: [UUID: [SCNNode]] = [:]
        // Stitch-pin markers keyed by link id.
        private var stitchMarkers: [UUID: SCNNode] = [:]
        // Floating name labels keyed by scanId, plus each mesh's local top-center anchor for
        // repositioning them as pieces move under a live nudge.
        private var labelNodes: [UUID: SCNNode] = [:]
        private var labelAnchors: [UUID: SIMD4<Float>] = [:]
        private var semanticsNode: SCNNode?
        private var semanticFillsNode: SCNNode?
        private var allDetectedClasses: [SemanticClass] = []
        private var detectedClassesBinding: Binding<[SemanticClass]>?
        // Two geometries per mesh, swapped on toggle (no runtime shader): the real per-vertex
        // colors, and a flat per-map color. The flat one omits the `.color` source so the map hue
        // isn't multiplied into the vertex/normal colors, but keeps `.normal` so it's still lit.
        private var coloredGeometries: [UUID: SCNGeometry] = [:]
        private var flatGeometries: [UUID: SCNGeometry] = [:]

        // swiftlint:disable:next function_parameter_count
        func load(into scnView: SCNView, items: [CombinedMeshItem], stitchPoints: [StitchPoint],
                  colorByMap: Bool, semanticViewMode: SemanticViewMode,
                  detectedClassesBinding: Binding<[SemanticClass]>, onLoaded: @escaping () -> Void) {
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

                // Build RoomPlan outlines + fills for each scan (tagged with the scan id so they can
                // be re-transformed together with the mesh during a live nudge).
                var allOutlineNodes: [(id: UUID, wireNode: SCNNode, fillNode: SCNNode, transform: simd_float4x4)] = []
                var detectedSet = Set<SemanticClass>()
                for item in items {
                    if let result = MeshPreviewView.buildRoomPlanOutlines(scanDirectoryURL: item.scanDirectoryURL) {
                        for outline in result.outlineNodes {
                            let wire = SCNNode(geometry: outline.geometry)
                            let fill = SCNNode(geometry: outline.fillGeometry)
                            allOutlineNodes.append((item.id, wire, fill, item.transform))
                        }
                        for cls in result.detectedClasses { detectedSet.insert(cls) }
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
                        // Local top-center of this mesh — where its floating name label anchors.
                        let (mn, mx) = node.boundingBox
                        self.labelAnchors[entry.item.id] = SIMD4<Float>((mn.x + mx.x) / 2, mx.y, (mn.z + mx.z) / 2, 1)
                    }

                    // Add semantics wireframes
                    let semNode = SCNNode()
                    let fillNode = SCNNode()
                    for entry in allOutlineNodes {
                        let wireWrapper = SCNNode()
                        wireWrapper.simdTransform = entry.transform
                        wireWrapper.addChildNode(entry.wireNode)
                        semNode.addChildNode(wireWrapper)
                        self.outlineWrappers[entry.id, default: []].append(wireWrapper)

                        let fillWrapper = SCNNode()
                        fillWrapper.simdTransform = entry.transform
                        fillWrapper.addChildNode(entry.fillNode)
                        fillNode.addChildNode(fillWrapper)
                        self.fillWrappers[entry.id, default: []].append(fillWrapper)
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

                    // Stitch-pin markers last, so their tiny spheres don't influence the camera framing.
                    for sp in stitchPoints {
                        let marker = Self.makeStitchMarker()
                        marker.simdPosition = sp.position
                        contentNode.addChildNode(marker)
                        self.stitchMarkers[sp.id] = marker
                    }

                    // Floating name labels at each map's centroid-top (billboarded, depth-independent).
                    for entry in built {
                        guard let anchor = self.labelAnchors[entry.item.id] else { continue }
                        let label = Self.makeLabel(entry.item.name)
                        let p = entry.item.transform * anchor
                        label.simdPosition = SIMD3<Float>(p.x, p.y, p.z) + SIMD3<Float>(0, 0.3, 0)
                        contentNode.addChildNode(label)
                        self.labelNodes[entry.item.id] = label
                    }

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

        /// Live manual adjuster: move each piece (mesh + its outline/fill wrappers) to a recomputed
        /// placement. No-op for ids not yet loaded, so an early `updateUIView` is harmless.
        func applyTransforms(from items: [CombinedMeshItem]) {
            for item in items {
                meshNodes[item.id]?.simdTransform = item.transform
                for w in outlineWrappers[item.id] ?? [] { w.simdTransform = item.transform }
                for w in fillWrappers[item.id] ?? [] { w.simdTransform = item.transform }
            }
        }

        /// Reposition stitch-pin markers as pieces move under a live nudge.
        func updateStitchPoints(_ points: [StitchPoint]) {
            for p in points { stitchMarkers[p.id]?.simdPosition = p.position }
        }

        /// Reposition floating name labels as pieces move under a live nudge.
        func updateLabels(from items: [CombinedMeshItem]) {
            for item in items {
                guard let anchor = labelAnchors[item.id], let node = labelNodes[item.id] else { continue }
                let p = item.transform * anchor
                node.simdPosition = SIMD3<Float>(p.x, p.y, p.z) + SIMD3<Float>(0, 0.3, 0)
            }
        }

        /// A floating, camera-facing name label with a dark backing plate for legibility against any
        /// mesh coloring (colorize / RoomPlan modes are already multi-colored, so tint alone can't
        /// identify a map). Depth-independent so it isn't hidden behind geometry.
        private static func makeLabel(_ text: String) -> SCNNode {
            let scnText = SCNText(string: text, extrusionDepth: 0)
            scnText.font = UIFont.systemFont(ofSize: 14, weight: .bold)
            scnText.flatness = 0.2
            let tm = SCNMaterial()
            tm.diffuse.contents = UIColor.white
            tm.lightingModel = .constant
            tm.isDoubleSided = true
            tm.readsFromDepthBuffer = false
            tm.writesToDepthBuffer = false
            scnText.materials = [tm]
            let textNode = SCNNode(geometry: scnText)
            let (tmn, tmx) = textNode.boundingBox
            textNode.pivot = SCNMatrix4MakeTranslation((tmn.x + tmx.x) / 2, (tmn.y + tmx.y) / 2, (tmn.z + tmx.z) / 2)
            let scale: Float = 0.01
            textNode.scale = SCNVector3(scale, scale, scale)
            textNode.renderingOrder = 21

            let w = CGFloat(tmx.x - tmn.x) * CGFloat(scale) + 0.14
            let h = CGFloat(tmx.y - tmn.y) * CGFloat(scale) + 0.08
            let plane = SCNPlane(width: w, height: h)
            plane.cornerRadius = h * 0.35
            let pm = SCNMaterial()
            pm.diffuse.contents = UIColor.black.withAlphaComponent(0.6)
            pm.lightingModel = .constant
            pm.isDoubleSided = true
            pm.readsFromDepthBuffer = false
            pm.writesToDepthBuffer = false
            plane.materials = [pm]
            let plateNode = SCNNode(geometry: plane)
            plateNode.position = SCNVector3(0, 0, -0.002)
            plateNode.renderingOrder = 20

            let container = SCNNode()
            container.addChildNode(plateNode)
            container.addChildNode(textNode)
            let bc = SCNBillboardConstraint()
            bc.freeAxes = .all
            container.constraints = [bc]
            return container
        }

        /// A small always-on-top emissive marker at a stitch pin, so the join is findable in the
        /// combined render (drawn ignoring depth so it isn't hidden behind a wall).
        private static func makeStitchMarker() -> SCNNode {
            let sphere = SCNSphere(radius: 0.06)
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = UIColor.systemRed
            m.emission.contents = UIColor.systemRed
            m.readsFromDepthBuffer = false
            m.writesToDepthBuffer = false
            sphere.materials = [m]
            let node = SCNNode(geometry: sphere)
            node.renderingOrder = 10
            return node
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
    /// A copy with a new placement transform — for the live manual adjuster, which recomputes
    /// transforms in-memory while reusing the mesh URLs / tint / name from the initial render.
    func withTransform(_ t: simd_float4x4) -> CombinedMeshItem {
        CombinedMeshItem(id: id, name: name, meshURL: meshURL, colorsURL: colorsURL,
                         scanDirectoryURL: scanDirectoryURL, transform: t, tint: tint)
    }

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

#Preview {
    // Empty state: no on-disk meshes, so the screen shows its "nothing to combine"
    // path. A populated preview would need real mesh files on disk.
    CombinedMeshScreen(request: ComponentRenderRequest(title: "Living Room + Kitchen", items: []))
}
