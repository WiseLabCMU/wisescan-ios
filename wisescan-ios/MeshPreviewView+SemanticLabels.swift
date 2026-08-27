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
/// `Equatable` here is VALUE equality, confidence included, so it is deliberately not what the
/// dismiss rule compares — that compares `category` alone (see `MeshPreviewView.updateUIView`).
/// Two detections of one category can be scored differently, and comparing the values would
/// replace the read-out where it should dismiss it.
struct TappedSemanticLabel: Equatable {
    let category: RoomPlanCategory
    /// RoomPlan's own confidence for the detection (`roomplan.json`), when the box carried one.
    let confidence: String?
}

extension MeshPreviewView {

    // MARK: Applying detail + filter to built nodes

    /// Push the active label detail and legend filter onto every semantic box already in the scene.
    ///
    /// Cheap by construction: one `diffuse.contents` write and one `isHidden` write per box, over a
    /// few dozen boxes. Gated on an actual change (recorded on the coordinator) because
    /// `updateUIView` runs for every unrelated state change too.
    ///
    /// Covers the timeline's slots as well as the single-scan nodes. That is not optional polish:
    /// the detail toggle is gated on `TimelineOffers.semantics`, so a multi-generation location
    /// shows the button, and a button that only recoloured one slot would be a dead control on
    /// every other generation. The FILTER is single-scan only — `hiddenLabels` stays empty while a
    /// timeline is active because the legend rows aren't tap targets there (see the legend's
    /// comment), so the same walk covers both without branching.
    @MainActor
    func applySemanticLabelStyling(_ coordinator: Coordinator, force: Bool = false) {
        guard force
                || coordinator.appliedLabelDetail != labelDetail
                || coordinator.appliedHiddenLabels != hiddenLabels else { return }
        coordinator.appliedLabelDetail = labelDetail
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
                Self.styleSemanticNode(node, detail: labelDetail, hiddenLabels: hiddenLabels)
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
    static func styleSemanticNode(_ node: SCNNode, detail: SemanticLabelDetail,
                                  hiddenLabels: Set<String>) {
        guard let raw = node.name, let category = RoomPlanCategory(rawValue: raw) else { return }
        node.isHidden = !RoomPlanCategory.isVisible(category: raw, detail: detail,
                                                    hiddenLabels: hiddenLabels)
        guard let material = node.geometry?.firstMaterial else { return }
        let alpha = (material.diffuse.contents as? UIColor)?.cgColor.alpha
            ?? Self.builtAlpha(for: category, node: node)
        let rgba = RoomPlanCategory.color(forCategory: raw, detail: detail)
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
                                  detail: SemanticLabelDetail,
                                  hiddenLabels: Set<String>,
                                  confidence: [ObjectIdentifier: String]) -> TappedSemanticLabel? {
        let options: [SCNHitTestOption: Any] = [
            .searchMode: SCNHitTestSearchMode.all.rawValue,
            .ignoreHiddenNodes: false,
            .backFaceCulling: false,
            .boundingBoxOnly: false
        ]
        for result in view.hitTest(point, options: options) {
            guard let (node, category) = semanticLabelOwner(of: result.node) else { continue }
            guard RoomPlanCategory.isVisible(category: category.rawValue, detail: detail,
                                             hiddenLabels: hiddenLabels) else { continue }
            return TappedSemanticLabel(category: category,
                                       confidence: confidence[ObjectIdentifier(node)])
        }
        return nil
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
