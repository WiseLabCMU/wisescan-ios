import SwiftUI
import SceneKit

// MARK: - Semantic label detail, legend filter, and tap-to-identify
//
// Everything here operates on nodes the loader ALREADY built. `buildRoomPlanOutlines` reads
// `roomplan.json` once per scan and hands out each box's rich `RoomPlanCategory` alongside the
// consolidated `SemanticClass` it was drawn in; the box's colour lives in one `SCNMaterial` and its
// label lives in `SCNNode.name`. So flipping coarse/full, filtering a label out, and identifying a
// tapped box are all node writes — no second loader, no second decode, no rebuild, and no disk read
// on any interaction.

/// What the user last tapped in the 3D preview. A value type, so `@State` can clear it to nil.
///
/// Deliberately identifies a LABEL rather than a specific detection: the read-out answers "what is
/// this?", and tapping anything with the same label again dismisses it (as does tapping empty
/// space). Per-detection identity would need a stable node reference in view state for no gain the
/// read-out actually shows.
///
/// `nonisolated`: a plain value referencing no actor-isolated state, matching the other new types
/// in this change (`RoomPlanCategory`) — this project builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an unannotated declaration would be implicitly
/// `@MainActor`. Every use today is on the main actor (`resolveSemanticTap` is `@MainActor`); the
/// annotation only keeps this type from being the one thing that pins a future non-isolated caller.
///
/// No `Equatable`: the dismiss rule compares `category` alone (see `MeshPreviewView.updateUIView`)
/// because two detections of one category can carry different confidences — so value equality,
/// confidence included, was never what anything wanted, and nothing else compares these values.
nonisolated struct TappedSemanticLabel {
    let category: RoomPlanCategory
    /// RoomPlan's own confidence for the detection (`roomplan.json`), when the box carried one.
    let confidence: String?
}

// MARK: - Shared legend row + tap read-out
//
// Both the single-scan preview and the stitched combined render print the same card: the label
// under the last tap, then one row per RoomPlan category present, each row a filter control. These
// two views are that card's parts, defined once so the two screens cannot drift into describing the
// same geometry differently. Only the card's own chrome differs (the preview uses a material, the
// combined render a flat scrim), which is the call site's business.

/// Sizing for the legend card, which is a panel of small tap targets floating over a 3D view.
///
/// Two sizes rather than one, keyed on horizontal size class. The compact numbers are what the card
/// has always used and are tuned for a phone, where screen space is the binding constraint. On a
/// regular-width screen — any iPad, and a large phone in landscape — the constraint is the opposite
/// one: there is room to spare and a 10pt swatch beside 11pt text is a fiddly target for a finger,
/// especially since a legend row is now a CONTROL rather than a key entry. Regular is ~45% larger
/// through the row, which is what it takes to make the rows comfortably separable without turning a
/// 21-category legend into something that fights the toolbar for the screen.
struct SemanticLegendMetrics {
    var swatch: CGFloat = 10
    var label: Font = .caption2
    var emphasis: Font = .caption
    var rowSpacing: CGFloat = 6
    var rowPadding: CGFloat = 2
    var stackSpacing: CGFloat = 4
    var cardPadding: CGFloat = 8

    static let compact = SemanticLegendMetrics()
    static let regular = SemanticLegendMetrics(swatch: 14, label: .caption, emphasis: .subheadline,
                                               rowSpacing: 8, rowPadding: 5, stackSpacing: 6,
                                               cardPadding: 12)

    static func forSizeClass(_ sizeClass: UserInterfaceSizeClass?) -> SemanticLegendMetrics {
        sizeClass == .regular ? .regular : .compact
    }
}

/// Show-all / hide-all for the whole legend, because the per-row toggle alone makes the two
/// commonest moves tedious: "show me only the stairs" is 20 taps without a hide-all, and undoing it
/// is 20 more.
///
/// TWO buttons rather than one that flips its label. A single control would have to guess what the
/// mixed state means, and the mixed state is the normal one — this card exists to be left with some
/// rows off. Each is disabled exactly when it would do nothing, so the pair also reads as a status:
/// both live means some labels are hidden and some are not.
struct SemanticLegendControls: View {
    let hiddenCount: Int
    let totalCount: Int
    let showAll: () -> Void
    let hideAll: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let metrics = SemanticLegendMetrics.forSizeClass(sizeClass)
        HStack(spacing: metrics.rowSpacing * 2) {
            button("Show all", enabled: hiddenCount > 0, metrics: metrics, action: showAll)
            button("Hide all", enabled: hiddenCount < totalCount, metrics: metrics, action: hideAll)
        }
        .padding(.vertical, metrics.rowPadding)
    }

    /// One control, dimmed and inert when it would be a no-op.
    ///
    /// The dimming is STATED, not inherited: `.buttonStyle(.plain)` with an explicit foreground
    /// colour — which this card needs, floating over a 3D scene rather than over a background
    /// SwiftUI can reason about — suppresses the automatic disabled appearance, so a dead button
    /// would otherwise look exactly like a live one.
    private func button(_ title: String, enabled: Bool, metrics: SemanticLegendMetrics,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(metrics.label.weight(.medium))
                .foregroundColor(enabled ? .white : .gray.opacity(0.6))
                .padding(.vertical, metrics.rowPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// One legend row: a colour swatch and the label's display name.
///
/// `toggle` nil means the row NAMES a label it cannot filter — the case where geometry is drawn
/// from a `roomplan.json` whose categories this build cannot parse, so there is no key for the
/// filter to hold. Rendered exactly like an unfiltered interactive row on purpose: it should read as
/// a key entry, which is what it is, rather than as a control that is refusing to work.
struct SemanticLegendRow: View {
    let color: Color
    let label: String
    var isFiltered = false
    var toggle: (() -> Void)?

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let metrics = SemanticLegendMetrics.forSizeClass(sizeClass)
        let row = HStack(spacing: metrics.rowSpacing) {
            Circle()
                .fill(isFiltered ? color.opacity(0.25) : color)
                .frame(width: metrics.swatch, height: metrics.swatch)
            Text(label)
                .font(metrics.label)
                .foregroundColor(isFiltered ? .gray : .white)
                .strikethrough(isFiltered, color: .gray)
        }
        // A swatch and one line of small text is not a finger-sized target on its own.
        .padding(.vertical, metrics.rowPadding)
        .contentShape(Rectangle())

        if let toggle {
            Button(action: toggle) { row }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityValue(isFiltered ? "Hidden" : "Shown")
                .accessibilityHint("Shows or hides this label in the 3D view")
        } else {
            row
        }
    }
}

/// The read-out for the last tapped box: what RoomPlan actually called it.
///
/// Sits above the colour key in the same card, so the swatch language matches and there is no second
/// floating panel to place around the toolbar and whatever else the screen has along its bottom.
struct TappedSemanticLabelReadout: View {
    let tapped: TappedSemanticLabel

    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let metrics = SemanticLegendMetrics.forSizeClass(sizeClass)
        VStack(alignment: .leading, spacing: metrics.stackSpacing) {
            HStack(spacing: metrics.rowSpacing) {
                Circle()
                    .fill(tapped.category.swiftUIFullDetailColor)
                    .frame(width: metrics.swatch, height: metrics.swatch)
                Text(tapped.category.displayName)
                    .font(metrics.emphasis.weight(.semibold))
                    .foregroundColor(.white)
                if let confidence = tapped.confidence {
                    // RoomPlan's own score for the detection, straight out of roomplan.json.
                    Text(confidence.capitalized)
                        .font(metrics.label)
                        .foregroundColor(.gray)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                }
            }
            // The colour is the GROUP's — every fixture is a shade of the same purple — and with no
            // coarse vocabulary in the UI any more, this line is the only place that group is named.
            // It is what connects a stove's shade to the "purple = fixture" language the user
            // guide's static legend and every existing screenshot still teach.
            Text("Drawn as \(tapped.category.coarseClass.rawValue.capitalized)")
                .font(metrics.label)
                .foregroundColor(.gray)
            Text("Tap empty space to dismiss")
                .font(metrics.label)
                .foregroundColor(.gray.opacity(0.7))
            Divider()
                .frame(width: 130)
                .overlay(Color.white.opacity(0.25))
        }
    }
}

extension MeshPreviewView {

    // MARK: Applying detail + filter to built nodes

    /// Push the active label detail and legend filter onto every semantic box already in the scene.
    ///
    /// Cheap by construction: one `diffuse.contents` write and one `isHidden` write per box, over a
    /// few dozen boxes. Gated on an actual change (recorded on the coordinator) because
    /// `updateUIView` runs for every unrelated state change too.
    ///
    /// Covers the timeline's slots as well as the single-scan nodes, which the filter requires: its
    /// legend rows are built from the timeline-wide union, so a label switched off has to be off in
    /// EVERY generation, or scrubbing would bring back geometry the user just hid while its row
    /// still read as struck through.
    @MainActor
    func applySemanticLabelStyling(_ coordinator: Coordinator, force: Bool = false) {
        guard force
                || !coordinator.hasStyledLabels
                || coordinator.appliedHiddenLabels != hiddenLabels else { return }
        coordinator.hasStyledLabels = true
        coordinator.appliedHiddenLabels = hiddenLabels

        var containers: [SCNNode] = [coordinator.semanticsNode, coordinator.semanticFillsNode]
            .compactMap { $0 }
        for slot in coordinator.timelineSlots.values {
            containers.append(contentsOf: [slot.semanticsNode, slot.semanticFillsNode].compactMap { $0 })
        }
        // The primary generation's slot re-points at the coordinator's own nodes, so the same
        // container can appear twice. Styling is idempotent, but skipping the repeat is free.
        var seen = Set<ObjectIdentifier>()
        for container in containers {
            guard seen.insert(ObjectIdentifier(container)).inserted else { continue }
            for node in container.childNodes {
                Self.styleSemanticNode(node, hiddenLabels: hiddenLabels)
            }
        }
    }

    /// Colour + visibility for ONE semantic box, from the rich category stored in its `name`.
    ///
    /// The existing alpha is read back off the material rather than recomputed, which preserves
    /// exactly what the builder chose: 0.3 for the co-planar door/window fills that would otherwise
    /// z-fight, 0.75 for every other fill, 1.0 for the wireframes. A box with no name — a category
    /// string this build cannot parse — is left completely alone and keeps the coarse colour the
    /// builder gave it.
    @MainActor
    static func styleSemanticNode(_ node: SCNNode, hiddenLabels: Set<String>) {
        guard let raw = node.name, let category = RoomPlanCategory(rawValue: raw) else { return }
        node.isHidden = !RoomPlanCategory.isVisible(category: raw, hiddenLabels: hiddenLabels)
        guard let material = node.geometry?.firstMaterial else { return }
        let alpha = (material.diffuse.contents as? UIColor)?.cgColor.alpha
            ?? Self.builtAlpha(for: category, node: node)
        let rgba = RoomPlanCategory.color(forCategory: raw)
        material.diffuse.contents = UIColor(red: CGFloat(rgba.x), green: CGFloat(rgba.y),
                                            blue: CGFloat(rgba.z), alpha: alpha)
    }

    /// The alpha the loader would have given this box, reconstructed from the node itself — the
    /// fallback for the (not expected) case where the material's diffuse contents is not a
    /// `UIColor` to read an alpha back off. Derived from the geometry's primitive type rather than
    /// from a node name, because only the wireframe half is drawn as `.line`, and only the fills
    /// were ever translucent. Losing the door/window 0.3 would bring back the co-planar z-fighting
    /// the loader lowered it to avoid, so this is worth the six lines.
    @MainActor
    private static func builtAlpha(for category: RoomPlanCategory, node: SCNNode) -> CGFloat {
        if node.geometry?.elements.first?.primitiveType == .line { return 1 }
        let coarse = category.coarseClass
        return (coarse == .door || coarse == .window) ? 0.3 : 0.75
    }

    // MARK: Tap-to-identify

    /// Resolve a tap in the preview to the RoomPlan label under the finger, or nil for empty space.
    ///
    /// Hit-tests with `ignoreHiddenNodes: false` DELIBERATELY. In `.meshWithOutlines` the only
    /// visible semantic geometry is the wireframe boxes, and a wireframe is `.line` primitives —
    /// hairlines with no interior, which is not a tap target on a touch screen. The FILL boxes are
    /// the tap volumes, and they are hidden in that mode, so hidden nodes have to be hit-testable.
    ///
    /// Which means every exclusion is made explicitly HERE rather than delegated to SceneKit's
    /// option (whose behaviour with a hidden ANCESTOR this code cannot establish either way):
    ///   * the gesture is inert unless outlines are actually being drawn, so a `.meshOnly` preview
    ///     identifies nothing (`Coordinator.semanticTapEnabled`);
    ///   * while a timeline is active, only the VISIBLE generation's subtree counts — every other
    ///     generation is a hidden container full of hit-testable boxes, and `root` is what keeps a
    ///     tap from naming one of them (nil = no restriction, which is the single-scan case);
    ///   * a label the legend filter has switched off is skipped here, so a filtered-out category
    ///     is never identifiable;
    ///   * anything that is not RoomPlan geometry — the mesh itself, the capture markers — carries
    ///     no category and is skipped.
    ///
    /// `backFaceCulling: false` matters as much as the rest: standing inside a room, the near face
    /// of a wall box points away from the camera. Results come back sorted nearest-first, so the
    /// first acceptable one is the box in front.
    @MainActor
    static func resolveSemanticTap(in view: SCNView, at point: CGPoint,
                                  hiddenLabels: Set<String>,
                                  confidence: [ObjectIdentifier: String],
                                  within root: SCNNode? = nil) -> TappedSemanticLabel? {
        let options: [SCNHitTestOption: Any] = [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: false,
            .backFaceCulling: false,
            .boundingBoxOnly: false
        ]
        for result in view.hitTest(point, options: options) {
            if let root, !isDescendant(result.node, of: root) { continue }
            guard let (node, category) = semanticLabelOwner(of: result.node) else { continue }
            guard RoomPlanCategory.isVisible(category: category.rawValue,
                                             hiddenLabels: hiddenLabels) else { continue }
            return TappedSemanticLabel(category: category,
                                       confidence: confidence[ObjectIdentifier(node)])
        }
        return nil
    }

    /// Whether `node` sits anywhere under `root`. `SCNNode` has no such test of its own, and the
    /// walk is unbounded on purpose (unlike `semanticLabelOwner`'s): a false negative here would
    /// silently drop a legitimate hit, and the scene graph above a box is four levels deep.
    @MainActor
    static func isDescendant(_ node: SCNNode, of root: SCNNode) -> Bool {
        var current: SCNNode? = node
        while let candidate = current {
            if candidate === root { return true }
            current = candidate.parent
        }
        return false
    }

    /// The node that actually CARRIES the label, walking up from a hit-test result.
    ///
    /// `SCNHitTestResult.node` is the node owning the hit geometry, which today is exactly the
    /// wire/fill node this code names — but the walk is here rather than assumed, so that wrapping
    /// those boxes in a parent later cannot silently stop identification working. The walk is safe
    /// against the containers above them (`"semantics"`, `"semanticFills"`, `"timelineSlot"`,
    /// `"mesh"`): none of those names parses as a `RoomPlanCategory`. Bounded, so a deep hierarchy
    /// can't turn a tap into a climb to the root.
    @MainActor
    static func semanticLabelOwner(of node: SCNNode) -> (SCNNode, RoomPlanCategory)? {
        var current: SCNNode? = node
        var hops = 0
        while let candidate = current, hops < 4 {
            if let name = candidate.name, let category = RoomPlanCategory(rawValue: name) {
                return (candidate, category)
            }
            current = candidate.parent
            hops += 1
        }
        return nil
    }
}
