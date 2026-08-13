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

/// World-Y span of the combined render's SHARED height ramp — one range across every placed map,
/// so a color means a height everywhere in the render. Drives the legend key; a gradient with no
/// key is guesswork. nil when nothing on screen is height-colored (fully photo-colorized set).
struct HeightKeyRange: Equatable {
    let min: Float
    let max: Float
}

/// How many of the combined render's maps have a usable ghost proxy and/or dynamic mesh.
/// Availability is per-scan (no `face_classes.bin`, no RoomPlan walls, or postprocess not run yet),
/// so the render can be mixed: maps without one keep their full mesh, and `missing`/`dynamicMissing`
/// drive a badge so that's never silent.
struct ProxyAvailability: Equatable {
    let available: Int
    let missing: Int
    let dynamicAvailable: Int
    let dynamicMissing: Int
    /// True when at least one alternate mesh (proxy or dynamic) exists.
    var any: Bool { available > 0 || dynamicAvailable > 0 }
}

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
    var nudge = ManualNudge.zero      // the SINGLE correction currently on this join
    var autoNudge = ManualNudge.zero  // the solver's fix on offer (may or may not be applied)
    var isAuto = false                // the current nudge matches the auto fix (seeded / in sync)
    var isBase: Bool { parentLinkId == nil }
    var autoAvailable: Bool { !autoNudge.isZero }
    var isCorrected: Bool { !nudge.isZero }
}

struct CombinedMeshScreen: View {
    let request: ComponentRenderRequest
    /// Colorize request for the shown scans (ids). Provided by the presenter, which owns
    /// the models and the shared bulk-color path; nil hides the option. The screen
    /// dismisses on selection so the per-tile progress is visible.
    var onColor: (([UUID]) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var colorByMap = false
    /// Shared height-ramp span reported by the load; nil = nothing height-colored, so no key.
    @State private var heightKeyRange: HeightKeyRange?
    /// Which geometry the render draws — full mesh or ghost proxy. The proxy replaces lumpy mesh
    /// with RoomPlan wall quads, which is far easier to judge coplanarity against at a join.
    @State private var meshSourceMode: MeshSourceMode = .full
    @State private var proxyAvailability: ProxyAvailability?
    @State private var semanticViewMode: SemanticViewMode = .meshOnly
    @State private var detectedClasses: [SemanticClass] = []
    @State private var isLoading = true
    @State private var showLegend = true
    /// Live adjuster values by link id (seeded from each link's stored nudge on appear). This is the
    /// single source of truth for the view while open; committed back to the links on Save.
    @State private var manualDrafts: [UUID: ManualNudge] = [:]
    @State private var editingLinkId: UUID?
    /// Global "always autocorrect" default (implicitly all joins, unless a per-join override wins).
    // Default MUST match `StitchPrefs.alwaysAutocorrect` (on) — see the reasoning there. If these
    // disagree the toggle shows one state while render/export honour the other.
    @AppStorage(StitchPrefs.alwaysAutocorrectKey) private var alwaysAutocorrect = true

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
            manualOverrides: manualDrafts, autoCorrections: request.autoCorrections)
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
            let autoNudge = p.parentLinkId.flatMap { request.autoCorrections[$0]?.asNudge } ?? .zero
            let nudge = p.parentLinkId.flatMap { manualDrafts[$0] } ?? .zero
            return StitchRoomRow(
                id: p.locationId, name: item.name, tint: Color(uiColor: item.tint),
                parentLinkId: p.parentLinkId,
                nudge: nudge, autoNudge: autoNudge,
                isAuto: !autoNudge.isZero && Self.nudgesApproxEqual(nudge, autoNudge))
        }
    }

    /// Approx-equality so a seeded nudge reads as "in sync with Auto" despite float noise.
    static func nudgesApproxEqual(_ a: ManualNudge, _ b: ManualNudge) -> Bool {
        abs(a.yawDeg - b.yawDeg) < 0.05 && abs(a.dx - b.dx) < 0.005
            && abs(a.dy - b.dy) < 0.005 && abs(a.dz - b.dz) < 0.005
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
                        heightKeyRange: $heightKeyRange,
                        proxyAvailability: $proxyAvailability,
                        meshSourceMode: meshSourceMode,
                        onLoaded: { isLoading = false }
                    )
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 8) {
                            heightKey
                            semanticLegend
                        }
                    }
                }

                if isLoading && !presentItems.isEmpty { loadingOverlay(count: presentItems.count) }
                if missingCount > 0 { missingBadge(missingCount) }
                // Mixed render: never let "some maps aren't proxies" be silent.
                if meshSourceMode == .proxy, let p = proxyAvailability, p.missing > 0 {
                    proxyMixedBadge("proxy", p.missing)
                }
                if meshSourceMode == .dynamic, let p = proxyAvailability, p.dynamicMissing > 0 {
                    proxyMixedBadge("dynamic", p.dynamicMissing)
                }

                // Room legend + per-map correction status (Step 2c). Stays visible while adjusting
                // (top-right; the adjuster is bottom) — the edited map's row is highlighted, and any
                // row's adjust button switches the target. Tap a map to adjust its join.
                if hasStitches && rooms.count > 1 && showLegend {
                    StitchLegendPanel(
                        rooms: rooms,
                        editingLinkId: editingLinkId,
                        alwaysAutocorrect: $alwaysAutocorrect,
                        anyAutoOfferable: rooms.contains { $0.autoAvailable && !$0.isAuto },
                        anyCorrected: rooms.contains { $0.isCorrected },
                        onToggleAuto: { row in if let lid = row.parentLinkId { toggleAuto(lid) } },
                        onAutocorrectAll: autocorrectAll,
                        onClearAll: clearAll,
                        onAdjust: { row in if let lid = row.parentLinkId { editingLinkId = lid } }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 8)
                    .padding(.trailing, 12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                // Manual rotate/translate adjuster for the selected map's join. Live-persists (slider
                // release / Auto / Reset all write through), so switching maps or dismissing is safe.
                if let lid = editingLinkId {
                    let editingRow = rooms.first { $0.parentLinkId == lid }
                    ManualAdjustPanel(
                        title: editingRow?.name ?? "map",
                        autoAvailable: editingRow?.autoAvailable ?? false,
                        isAuto: editingRow?.isAuto ?? false,
                        nudge: draftBinding(lid),
                        onToggleAuto: { toggleAuto(lid) },
                        onReset: { setNudge(lid, .zero); persist() },
                        onCommit: { persistEdit(lid) },
                        onDone: { persistEdit(lid); editingLinkId = nil }
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

    /// Key for the shared height ramp. Only meaningful when height colors are what's on screen:
    /// "color by map" replaces them with flat tints, and `.semanticOnly` hides the mesh entirely.
    @ViewBuilder private var heightKey: some View {
        if let range = heightKeyRange, !colorByMap, semanticViewMode.showMesh {
            HStack(spacing: 6) {
                // Top of the bar = top of the range, matching the ramp (red highest).
                LinearGradient(colors: [.red, .yellow, .green, .cyan, .blue],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: 8, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                VStack(alignment: .leading, spacing: 0) {
                    Text(String(format: "%.1f m", range.max))
                    Spacer()
                    Text(String(format: "%.1f m", range.min))
                }
                .font(.caption2)
                .foregroundColor(.white)
                .frame(height: 54)
            }
            .padding(10)
            .background(Color.black.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.leading, 16)
        }
    }

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

    /// Proxy view with some maps falling back to their full mesh (no `face_classes.bin`, no RoomPlan
    /// walls, or postprocess not run) — say so, since a mixed render otherwise reads as one style.
    private func proxyMixedBadge(_ label: String, _ count: Int) -> some View {
        VStack {
            Spacer()
            Text("\(count) map\(count == 1 ? "" : "s") have no \(label) — showing full mesh")
                .font(.caption2).foregroundColor(.yellow)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.black.opacity(0.6))
                .clipShape(Capsule())
                .padding(.bottom, 48)
        }
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

    /// Color the shown scans through the presenter's shared bulk path: direct when one
    /// map is shown, all-maps + per-map menu when several. Dismisses so tile progress shows.
    @ViewBuilder
    private func colorButton(present: [CombinedMeshItem], onColor: @escaping ([UUID]) -> Void) -> some View {
        if present.count == 1 {
            Button {
                onColor(present.map(\.id))
                dismiss()
            } label: {
                Image(systemName: "paintbrush")
            }
        } else {
            Menu {
                Button {
                    onColor(present.map(\.id))
                    dismiss()
                } label: {
                    Label("Color All \(present.count) Maps", systemImage: "paintbrush.fill")
                }
                Divider()
                ForEach(present) { item in
                    Button {
                        onColor([item.id])
                        dismiss()
                    } label: {
                        Text("Color \(item.name)")
                    }
                }
            } label: {
                Image(systemName: "paintbrush")
            }
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
                if let onColor, !present.isEmpty {
                    colorButton(present: present, onColor: onColor)
                }

                Button { semanticViewMode = semanticViewMode.next } label: {
                    Image(systemName: semanticViewMode.iconName)
                }
                .disabled(present.isEmpty)

                Button { colorByMap.toggle() } label: {
                    Image(systemName: colorByMap ? "paintpalette.fill" : "paintpalette")
                }
                .disabled(present.isEmpty)

                if proxyAvailability?.any == true {
                    Button { meshSourceMode = meshSourceMode.next } label: {
                        Image(systemName: meshSourceMode.iconName)
                            .foregroundColor(meshSourceMode == .full ? .gray : .yellow)
                    }
                    .accessibilityLabel(meshSourceMode.accessibilityLabel)
                }
            }
        }
    }

    // MARK: Adjuster plumbing

    private func seedDrafts() {
        guard manualDrafts.isEmpty else { return }
        var seededAny = false
        for e in request.edges {
            var nudge = e.link.manualNudge
            // "Always autocorrect": transfer the solver's fix INTO an untouched join's nudge (and
            // persist), so the value is real from here on and survives toggling always off.
            if nudge.isZero, alwaysAutocorrect,
               let auto = request.autoCorrections[e.link.id]?.asNudge, !auto.isZero {
                nudge = auto
                e.link.manualNudge = auto
                seededAny = true
            }
            manualDrafts[e.link.id] = nudge
        }
        if seededAny { persist() }
    }

    private func draftBinding(_ id: UUID) -> Binding<ManualNudge> {
        Binding(get: { manualDrafts[id] ?? .zero }, set: { manualDrafts[id] = $0 })
    }

    private func link(for id: UUID) -> StitchLink? {
        request.edges.first(where: { $0.link.id == id })?.link
    }

    /// The manual adjuster's live-persist: sync a join's live draft to its link and save (called on
    /// slider release / Done), so what you see is always what's stored and exported.
    private func persistEdit(_ id: UUID) {
        link(for: id)?.manualNudge = manualDrafts[id] ?? .zero
        persist()
    }

    // MARK: Auto-correct = seed the single nudge (per-join / all / always)

    private func persist() {
        do { try modelContext.save() }
        catch { print("[StitchCorrect] stitch correction save failed: \(error.localizedDescription)") }
    }

    private func setNudge(_ id: UUID, _ nudge: ManualNudge) {
        manualDrafts[id] = nudge
        link(for: id)?.manualNudge = nudge
    }

    /// The "Auto" chip: transfer the solver's fix into the join's nudge (so the sliders show it) —
    /// or, if already in sync with Auto, clear it. Lets you flip a join corrected/raw to judge it.
    private func toggleAuto(_ id: UUID) {
        guard let auto = request.autoCorrections[id]?.asNudge, !auto.isZero else { return }
        let cur = manualDrafts[id] ?? .zero
        setNudge(id, Self.nudgesApproxEqual(cur, auto) ? .zero : auto)
        persist()
    }

    private func autocorrectAll() {
        for e in request.edges {
            guard let auto = request.autoCorrections[e.link.id]?.asNudge, !auto.isZero else { continue }
            setNudge(e.link.id, auto)
        }
        persist()
    }

    private func clearAll() {
        for e in request.edges { setNudge(e.link.id, .zero) }
        persist()
    }

    /// "Always autocorrect" turned on: transfer the solver's fix into every untouched join. Turning
    /// it off leaves already-transferred values in place (they're real corrections now).
    private func applyAlwaysChange(_ newVal: Bool) {
        guard newVal else { return }
        for e in request.edges {
            guard (manualDrafts[e.link.id] ?? .zero).isZero,
                  let auto = request.autoCorrections[e.link.id]?.asNudge, !auto.isZero else { continue }
            setNudge(e.link.id, auto)
        }
        persist()
    }
}

// MARK: - Legend / status panel

private struct StitchLegendPanel: View {
    let rooms: [StitchRoomRow]
    let editingLinkId: UUID?
    @Binding var alwaysAutocorrect: Bool
    let anyAutoOfferable: Bool
    let anyCorrected: Bool
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
                        .background(room.isAuto ? Color.orange : Color.white.opacity(0.12))
                        .foregroundColor(room.isAuto ? .black : .white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            if !room.isBase {
                Button { onAdjust(room) } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption)
                        .foregroundColor(room.parentLinkId == editingLinkId ? .white : .cyan)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(room.parentLinkId != nil && room.parentLinkId == editingLinkId
                    ? Color.cyan.opacity(0.18) : Color.clear)
    }

    @ViewBuilder private func statusLine(_ room: StitchRoomRow) -> some View {
        if room.isBase {
            Text("Base map (reference)").font(.caption2).foregroundColor(.gray)
        } else if room.isAuto {
            Text("Auto-corrected · " + summary(room.nudge)).font(.caption2).foregroundColor(.orange).lineLimit(1)
        } else if room.isCorrected {
            Text("Adjusted · " + summary(room.nudge)).font(.caption2).foregroundColor(.cyan).lineLimit(1)
        } else if room.autoAvailable {
            Text("Auto-fix available · " + summary(room.autoNudge)).font(.caption2).foregroundColor(.yellow).lineLimit(1)
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

            if anyAutoOfferable || anyCorrected {
                HStack(spacing: 8) {
                    if anyAutoOfferable {
                        Button(action: onAutocorrectAll) {
                            Text("Autocorrect all").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.orange).foregroundColor(.black)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if anyCorrected {
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

    private func summary(_ n: ManualNudge) -> String {
        var parts: [String] = []
        if abs(n.yawDeg) >= 0.05 { parts.append(String(format: "yaw %+.1f°", n.yawDeg)) }
        let d = sqrt(n.dx * n.dx + n.dy * n.dy + n.dz * n.dz)
        if d >= 0.005 { parts.append(String(format: "shift %.0f cm", d * 100)) }
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }
}

// MARK: - Manual rotate/translate adjuster

private struct ManualAdjustPanel: View {
    let title: String
    let autoAvailable: Bool
    let isAuto: Bool
    @Binding var nudge: ManualNudge
    let onToggleAuto: () -> Void
    let onReset: () -> Void
    let onCommit: () -> Void      // persist current values (slider release / Done) — live, no Save/Cancel
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Adjust \(title)").font(.headline).foregroundColor(.white).lineLimit(1)
                    Text("Rotate & move this map to fine-tune the join")
                        .font(.caption2).foregroundColor(.gray)
                }
                Spacer(minLength: 4)
                // Auto lives here too (near Reset) so you can flip the join corrected/raw without
                // leaving the sliders — it seeds/clears the same values the sliders show.
                if autoAvailable {
                    Button(action: onToggleAuto) {
                        Text("Auto")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(isAuto ? Color.orange : Color.white.opacity(0.12))
                            .foregroundColor(isAuto ? .black : .white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Button("Reset", action: onReset).font(.subheadline).foregroundColor(.orange)
            }

            slider("rotate.3d", "Rotate", $nudge.yawDeg, -30...30, "%.1f°")
            slider("arrow.left.and.right", "Left / Right", $nudge.dx, -2...2, "%.2f m")
            slider("arrow.up.and.down", "Fwd / Back", $nudge.dz, -2...2, "%.2f m")
            slider("arrow.up.arrow.down", "Up / Down", $nudge.dy, -2...2, "%.2f m")

            Button(action: onDone) {
                Text("Done").frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(Color.cyan)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .foregroundColor(.black)
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
            Slider(value: position, in: -1...1, onEditingChanged: { editing in if !editing { onCommit() } })
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
    /// Set by the load once it knows the shared ramp range (and whether anything used it).
    @Binding var heightKeyRange: HeightKeyRange?
    /// Set by the load once it knows how many maps have a usable ghost proxy.
    @Binding var proxyAvailability: ProxyAvailability?
    let meshSourceMode: MeshSourceMode
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

        scnView.delegate = context.coordinator   // per-frame label rescale (constant on-screen size)
        context.coordinator.load(
            into: scnView, items: items, stitchPoints: stitchPoints, colorByMap: colorByMap,
            semanticViewMode: semanticViewMode, detectedClassesBinding: $detectedClasses,
            heightKeyBinding: $heightKeyRange, proxyBinding: $proxyAvailability,
            meshSourceMode: meshSourceMode, onLoaded: onLoaded
        )
        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        // Re-tint in place when the toggle changes (no reload needed).
        // Cache the viewport size here (main thread) for the render-thread label sizing.
        context.coordinator.viewportSize = uiView.bounds.size
        context.coordinator.applyTint(colorByMap: colorByMap, source: meshSourceMode)
        context.coordinator.applyViewMode(semanticViewMode)
        // Live manual adjuster: move pieces + stitch markers to the recomputed transforms without
        // reloading meshes. No-ops until the async load has populated the nodes.
        context.coordinator.applyTransforms(from: items)
        context.coordinator.updateStitchPoints(stitchPoints)
        context.coordinator.updateLabels(from: items)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
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
        // World height (at container scale 1) of each label's backing plate, keyed by scanId. Plate
        // height depends on the glyphs in the name (ascenders/descenders), so it is stored PER label;
        // each frame the label is rescaled so ITS plate covers a fixed fraction of the viewport.
        private var labelBaseHeights: [UUID: Float] = [:]
        // Target on-screen height of a label plate, as a fraction of the viewport height.
        private let labelScreenFraction: Float = 0.035
        // Viewport size cached from the MAIN thread (updateUIView sets it). `willRenderScene` runs on
        // SceneKit's render thread, where touching the UIView's `bounds` would be a UIKit threading
        // violation — so we read the size from here instead. Internal so updateUIView can set it.
        var viewportSize: CGSize = .zero
        private var semanticsNode: SCNNode?
        private var semanticFillsNode: SCNNode?
        private var allDetectedClasses: [SemanticClass] = []
        private var detectedClassesBinding: Binding<[SemanticClass]>?
        // Two geometries per mesh, swapped on toggle (no runtime shader): the real per-vertex
        // colors, and a flat per-map color. The flat one omits the `.color` source so the map hue
        // isn't multiplied into the vertex/normal colors, but keeps `.normal` so it's still lit.
        private var coloredGeometries: [UUID: SCNGeometry] = [:]
        private var flatGeometries: [UUID: SCNGeometry] = [:]
        // Same pair again for the ghost proxy — the source toggle is a geometry swap, not a reload,
        // so the camera framing survives. A map with no proxy artifact is simply ABSENT from these,
        // and falls back to its full mesh.
        private var proxyColoredGeometries: [UUID: SCNGeometry] = [:]
        private var proxyFlatGeometries: [UUID: SCNGeometry] = [:]
        // Same pair for the dynamic (content-only) mesh.
        private var dynamicColoredGeometries: [UUID: SCNGeometry] = [:]
        private var dynamicFlatGeometries: [UUID: SCNGeometry] = [:]

        // swiftlint:disable:next function_parameter_count
        func load(into scnView: SCNView, items: [CombinedMeshItem], stitchPoints: [StitchPoint],
                  colorByMap: Bool, semanticViewMode: SemanticViewMode,
                  detectedClassesBinding: Binding<[SemanticClass]>,
                  heightKeyBinding: Binding<HeightKeyRange?>,
                  proxyBinding: Binding<ProxyAvailability?>,
                  meshSourceMode: MeshSourceMode, onLoaded: @escaping () -> Void) {
            guard let scene = scnView.scene else { onLoaded(); return }
            self.detectedClassesBinding = detectedClassesBinding
            let contentNode = SCNNode()
            scene.rootNode.addChildNode(contentNode)

            DispatchQueue.global(qos: .userInitiated).async {
                // PASS 1 — the SHARED height-ramp range: the union of every map's world-Y extent.
                // Two reasons it can't be left to buildGeometry's per-mesh default. Each map's
                // geometry is LOCAL (node.simdTransform places it), so a map stitched a floor up
                // would otherwise repeat the ground floor's colors; and each map normalizing to its
                // own extent means the same physical height is a different color per map — actively
                // misleading for judging whether two landings sit at the same level.
                //
                // Deliberately re-parses in pass 2 rather than holding every parsed mesh in memory
                // at once: N large meshes resident is the worse trade on device, and this runs
                // off-main behind the existing "Loading N meshes…" overlay.
                var unionMin = Float.greatestFiniteMagnitude
                var unionMax = -Float.greatestFiniteMagnitude
                for item in items {
                    guard let data = try? Data(contentsOf: item.meshURL),
                          let parsed = MeshParser.parseOBJ(from: data),
                          let r = MeshPreviewView.worldHeightRange(parsed: parsed, transform: item.transform)
                    else { continue }
                    unionMin = min(unionMin, r.min)
                    unionMax = max(unionMax, r.max)
                }
                let sharedRange: (min: Float, max: Float)? =
                    unionMin <= unionMax ? (min: unionMin, max: unionMax) : nil

                // PASS 2 — build. `heightTransform` lifts each map's local vertices into the shared
                // world-Y range for coloring only; the geometry itself stays local.
                var built: [(item: CombinedMeshItem, geometry: SCNGeometry, flat: SCNGeometry,
                             proxy: SCNGeometry?, proxyFlat: SCNGeometry?,
                             dynamic: SCNGeometry?, dynamicFlat: SCNGeometry?)] = []
                var usedHeightRamp = false
                var proxyAvailable = 0
                var proxyMissing = 0
                var dynamicAvailable = 0
                var dynamicMissing = 0
                for item in items {
                    guard let data = try? Data(contentsOf: item.meshURL) else { continue }
                    let colors = item.colorsURL.flatMap { try? Data(contentsOf: $0) }
                    if colors == nil { usedHeightRamp = true }
                    guard let (geometry, _) = MeshPreviewView.buildGeometry(
                        from: data, vertexColors: colors,
                        heightRange: sharedRange, heightTransform: item.transform
                    ) else { continue }

                    // Ghost proxy for this map, built alongside and cached so the source toggle is a
                    // geometry swap (like applyTint) rather than a reload — a reload would re-run
                    // frameCamera and lose the framing you set on a join, which is the whole point
                    // of looking at the proxy here. Cheap-ish: makeFlatTinted shares buffers, and
                    // the proxy is lighter than the full mesh by construction.
                    //
                    // Same sharedRange (derived from the FULL meshes) so toggling source never
                    // changes the color↔height mapping. No vertex colors — colors.bin is aligned to
                    // mesh.obj, which the proxy compacts.
                    var proxyGeom: SCNGeometry?
                    if let proxyURL = MeshPreviewView.proxyMeshURL(scanDirectoryURL: item.scanDirectoryURL),
                       let proxyData = try? Data(contentsOf: proxyURL) {
                        proxyGeom = MeshPreviewView.buildGeometry(
                            from: proxyData, vertexColors: nil,
                            heightRange: sharedRange, heightTransform: item.transform
                        )?.0
                    }
                    if proxyGeom != nil { proxyAvailable += 1 } else { proxyMissing += 1 }

                    // Dynamic mesh (content only, no infrastructure) — same pattern as proxy.
                    var dynamicGeom: SCNGeometry?
                    if let dynamicURL = MeshPreviewView.dynamicMeshURL(scanDirectoryURL: item.scanDirectoryURL),
                       let dynamicData = try? Data(contentsOf: dynamicURL) {
                        dynamicGeom = MeshPreviewView.buildGeometry(
                            from: dynamicData, vertexColors: nil,
                            heightRange: sharedRange, heightTransform: item.transform
                        )?.0
                    }
                    if dynamicGeom != nil { dynamicAvailable += 1 } else { dynamicMissing += 1 }

                    built.append((item, geometry, Self.makeFlatTinted(from: geometry, tint: item.tint),
                                  proxyGeom, proxyGeom.map { Self.makeFlatTinted(from: $0, tint: item.tint) },
                                  dynamicGeom, dynamicGeom.map { Self.makeFlatTinted(from: $0, tint: item.tint) }))
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
                    // Publish the ramp range for the legend key — only when something actually
                    // rendered with it (a fully photo-colorized set shows no height colors, so a
                    // key would be describing a ramp that isn't on screen).
                    heightKeyBinding.wrappedValue = usedHeightRamp
                        ? sharedRange.map { HeightKeyRange(min: $0.min, max: $0.max) } : nil
                    proxyBinding.wrappedValue = ProxyAvailability(available: proxyAvailable,
                                                                 missing: proxyMissing,
                                                                 dynamicAvailable: dynamicAvailable,
                                                                 dynamicMissing: dynamicMissing)
                    for entry in built {
                        let node = SCNNode(geometry: entry.geometry)
                        node.simdTransform = entry.item.transform
                        contentNode.addChildNode(node)
                        self.meshNodes[entry.item.id] = node
                        self.coloredGeometries[entry.item.id] = entry.geometry
                        self.flatGeometries[entry.item.id] = entry.flat
                        self.proxyColoredGeometries[entry.item.id] = entry.proxy
                        self.proxyFlatGeometries[entry.item.id] = entry.proxyFlat
                        self.dynamicColoredGeometries[entry.item.id] = entry.dynamic
                        self.dynamicFlatGeometries[entry.item.id] = entry.dynamicFlat
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

                    self.applyTint(colorByMap: colorByMap, source: meshSourceMode)
                    self.frameCamera(scene: scene, contentNode: contentNode, scnView: scnView)

                    // Stitch-pin markers last, so their tiny spheres don't influence the camera framing.
                    // Build each dictionary into a local and publish it in ONE assignment: the render
                    // thread enumerates `labelNodes` in `willRenderScene`, so incrementally inserting
                    // into the shared dictionary here would race and can crash with "collection was
                    // mutated while being enumerated". A single assignment lets the render thread see
                    // either the empty dictionary or the fully-built one.
                    var markers: [UUID: SCNNode] = [:]
                    for sp in stitchPoints {
                        let marker = Self.makeStitchMarker()
                        marker.simdPosition = sp.position
                        contentNode.addChildNode(marker)
                        markers[sp.id] = marker
                    }
                    self.stitchMarkers = markers

                    // Floating name labels at each map's centroid-top (billboarded, depth-independent).
                    var labels: [UUID: SCNNode] = [:]
                    var baseHeights: [UUID: Float] = [:]
                    for entry in built {
                        guard let anchor = self.labelAnchors[entry.item.id] else { continue }
                        let (label, plateHeight) = Self.makeLabel(entry.item.name)
                        baseHeights[entry.item.id] = plateHeight
                        let p = entry.item.transform * anchor
                        label.simdPosition = SIMD3<Float>(p.x, p.y, p.z) + SIMD3<Float>(0, 0.3, 0)
                        contentNode.addChildNode(label)
                        labels[entry.item.id] = label
                    }
                    self.labelBaseHeights = baseHeights   // publish heights before nodes...
                    self.labelNodes = labels              // ...so the render thread never sees nodes without heights

                    onLoaded()
                }
            }
        }

        /// Swaps each mesh between its real per-vertex colors and a single flat, *lit* per-map color
        /// (so seams between maps are obvious while shape/depth stay readable). We swap whole
        /// geometries rather than tinting the colored one — a `material.multiply` tint would multiply
        /// the map hue into the per-vertex colors, which over normals coloring reads as "shifted
        /// normals" instead of one discrete color.
        /// Picks each map's geometry across BOTH axes: tint (per-vertex vs flat per-map) and source
        /// (full mesh vs ghost proxy). A map with no proxy falls back to its full mesh, so a mixed
        /// render still shows every map (the missing count drives a badge).
        func applyTint(colorByMap: Bool, source: MeshSourceMode) {
            for (id, node) in meshNodes {
                let proxy = colorByMap ? proxyFlatGeometries[id] : proxyColoredGeometries[id]
                let dynamic = colorByMap ? dynamicFlatGeometries[id] : dynamicColoredGeometries[id]
                let full = colorByMap ? flatGeometries[id] : coloredGeometries[id]
                switch source {
                case .proxy:   node.geometry = proxy ?? full
                case .dynamic: node.geometry = dynamic ?? full
                case .full:    node.geometry = full
                }
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

        /// Per-frame (render thread): hold each name label at a constant ON-SCREEN size — labels are
        /// 3D geometry, so without this they grow when you zoom in and shrink when you zoom out. We
        /// size each so its backing plate spans a fixed fraction of the viewport height, derived from
        /// the live projection matrix and camera distance so it's correct whether the camera control
        /// zooms by dollying (distance changes) or by field of view (projection changes), and for any
        /// aspect ratio. This lives in `willRenderScene` (not `updateAtTime`) because that update
        /// phase does not fire on an on-demand SCNView's camera-control redraws — `willRenderScene`
        /// runs on every rendered frame. Only reads camera/projection and writes label scale; the
        /// billboard constraint (orientation) is untouched.
        func renderer(_ renderer: SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
            // Snapshot the shared dictionaries once: they are (re)assigned wholesale on the main thread
            // as the async load publishes labels, so enumerating a local copy insulates this render
            // thread from a concurrent reassignment (iterating the live property could crash).
            let labels = labelNodes
            let bases = labelBaseHeights
            guard !labels.isEmpty, let pov = renderer.pointOfView, let cam = pov.camera else { return }
            // Viewport comes from the main-thread cache (never UIView.bounds off this render thread).
            // Zero until the first updateUIView after layout — skip sizing until then.
            let vp = viewportSize
            guard vp.width > 0, vp.height > 0 else { return }
            // Vertical projection scale fy = cot(fovY/2): an object of world height H at camera
            // distance d covers fraction (fy·H)/(2·d) of the viewport height. Solve for the H that
            // hits our target fraction, then scale each label's own plate (its base height) to match.
            let fy = simd_float4x4(cam.projectionTransform(withViewportSize: vp)).columns.1.y
            guard fy != 0 else { return }
            let camPos = pov.simdWorldPosition
            for (id, label) in labels {
                let base = max(0.05, bases[id] ?? 0.24)   // sane floor guards a missing/zero plate height
                let d = simd_distance(camPos, label.simdWorldPosition)
                let worldH = 2 * labelScreenFraction * d / fy
                label.simdScale = SIMD3<Float>(repeating: max(0.001, worldH / base))
            }
        }

        /// A floating, camera-facing name label with a dark backing plate for legibility against any
        /// mesh coloring (colorize / RoomPlan modes are already multi-colored, so tint alone can't
        /// identify a map). Depth-independent so it isn't hidden behind geometry.
        private static func makeLabel(_ text: String) -> (node: SCNNode, plateHeight: Float) {
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
            return (container, Float(h))
        }

        /// Bright connector accent — matches the IN-SESSION connector marker (`ARCoverageView`), so the
        /// stitch join reads with the same color/glyph here as during capture.
        private static let connectorAccent = UIColor(red: 0.15, green: 1.0, blue: 0.55, alpha: 1.0)

        /// The "link" SF Symbol baked once, tinted the connector accent and centered in a SQUARE
        /// transparent canvas (the glyph is wider than tall) for the stitch-marker glyph plane.
        private static let connectorGlyphImage: UIImage? = {
            let side: CGFloat = 128
            let config = UIImage.SymbolConfiguration(pointSize: side * 0.62, weight: .bold)
            guard let symbol = UIImage(systemName: "link", withConfiguration: config)?
                .withTintColor(connectorAccent, renderingMode: .alwaysOriginal) else { return nil }
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            format.scale = 1
            return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
                let origin = CGPoint(x: (side - symbol.size.width) / 2, y: (side - symbol.size.height) / 2)
                symbol.draw(in: CGRect(origin: origin, size: symbol.size))
            }
        }()

        /// A stitch-pin marker styled like the IN-SESSION connector: a dark disc scrim with a bright
        /// "link" glyph, billboarded, at a real-world size (~13 cm, matching AR) so it reads the same
        /// way here as during capture — NOT screen-constant like the name labels. Depth-independent so
        /// the join stays findable behind geometry.
        private static func makeStitchMarker() -> SCNNode {
            let iconSize: CGFloat = 0.266   // 2× the in-session connector size — reads better in the combined render
            let container = SCNNode()

            let disc = SCNPlane(width: iconSize, height: iconSize)
            disc.cornerRadius = iconSize / 2                     // → circle
            let dm = SCNMaterial()
            dm.lightingModel = .constant
            dm.diffuse.contents = UIColor.black.withAlphaComponent(0.72)
            dm.isDoubleSided = true
            dm.readsFromDepthBuffer = false
            dm.writesToDepthBuffer = false
            disc.materials = [dm]
            let discNode = SCNNode(geometry: disc)
            discNode.renderingOrder = 15
            container.addChildNode(discNode)

            if let glyph = connectorGlyphImage {
                let glyphPlane = SCNPlane(width: iconSize, height: iconSize)
                let gm = SCNMaterial()
                gm.lightingModel = .constant
                gm.diffuse.contents = glyph                      // green-tinted, transparent elsewhere
                gm.isDoubleSided = true
                gm.readsFromDepthBuffer = false
                gm.writesToDepthBuffer = false
                glyphPlane.materials = [gm]
                let glyphNode = SCNNode(geometry: glyphPlane)
                glyphNode.position = SCNVector3(0, 0, 0.001)     // just in front of the disc
                glyphNode.renderingOrder = 16
                container.addChildNode(glyphNode)
            }

            let bc = SCNBillboardConstraint()
            bc.freeAxes = .all
            container.constraints = [bc]
            return container
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
