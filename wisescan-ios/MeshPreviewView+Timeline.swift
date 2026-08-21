import SwiftUI
import SceneKit
import Combine

// Time scrubber for the single-scan mesh preview: every generation of a location's room, one
// visible at a time, in the ONE shared coordinate frame they already live in.
//
// There is no alignment math here on purpose. A rescan's `mesh.obj` is REWRITTEN into the
// location's canonical (original-scan) frame at save/postprocess time (see `SaveRegistration` —
// "what gets transformed vs. what stays raw"), so every generation's vertices are already
// co-registered on disk. The only placement a slot needs is the SAME centering offset the
// displayed generation resolved (`canonicalRoomFrame`), which is why the loader reuses
// `Coordinator.resolvedCenter` instead of each slot centering on its own bounding box — a
// per-slot bbox would silently absorb exactly the residual misalignment this view exists to show.
//
// The registration sidecar is still read, but only to flag the case where it did NOT apply: a
// rescan whose fit was refused keeps its own raw capture frame and can genuinely sit offset from
// its siblings, and the scrubber says so rather than let a real registration failure read as a
// room that moved.
//
// Extracted from MeshPreviewView to keep that file under the length limit (same reason as
// MeshPreviewView+KeyframeFrustums).

// MARK: - Timeline model

/// One generation on the preview timeline: the main-actor snapshot of everything the SceneKit
/// loader needs about a scan. Taken once at mount, on main, so the background slot loads never
/// reach back into a SwiftData `@Model` (the off-main `@Model` access bug class).
nonisolated struct TimelineScan: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let capturedAt: Date
    /// Whether the photo colorize ran for THIS generation — colorization is a per-scan fact, so
    /// the preview's color note has to follow the visible scan, not the one the viewer opened on.
    let isColored: Bool
    let scanDirectory: URL
    let meshURL: URL
    /// nil when `colors.bin` doesn't exist, so the loader can skip the read entirely.
    let colorsURL: URL?

    @MainActor
    init(_ scan: CapturedScan) {
        id = scan.id
        name = scan.name
        capturedAt = scan.capturedAt
        isColored = scan.isColored
        scanDirectory = scan.scanDirectory
        meshURL = scan.meshFileURL
        let colors = scan.colorsFileURL
        colorsURL = FileManager.default.fileExists(atPath: colors.path) ? colors : nil
    }

    /// "3d ago". Mirrors `CapturedScan.timeSinceCapture` rather than calling it: the scrubber
    /// renders from this snapshot, and reaching back into the `@Model` for a label would put a
    /// SwiftData read in every scrub frame.
    var relativeAge: String {
        let interval = Date().timeIntervalSince(capturedAt)
        if interval < 60 { return "\(max(0, Int(interval)))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        if interval < 31536000 { return "\(Int(interval / 86400))d ago" }
        return "\(Int(interval / 31536000))y ago"
    }
}

/// Which optional artifacts exist SOMEWHERE in the timeline. OR-only, never cleared: the toolbar
/// mode toggles are gated on this union so a toggle can't vanish under the user's finger when they
/// scrub onto a generation that lacks the artifact (per-scan absence is handled by falling that
/// slot back and captioning it, not by removing the control). Only populated for multi-scan
/// locations — a single-scan preview keeps gating on its own parse results exactly as before.
struct TimelineOffers: Equatable {
    var proxy = false
    var dynamic = false
    var semantics = false
    var keyframes = false
    var equirects = false
    var privacy = false
}

/// Published timeline state shared by the scrubber UI and the SceneKit loader — one observable
/// reference instead of another half-dozen bindings through `MeshPreviewView` (the same trick
/// `MarkerProjectionState` uses). Main-actor only.
final class ScanTimelineState: ObservableObject {
    /// Generations with geometry attached and ready to show.
    @Published var readyIDs: Set<UUID> = []
    /// Generations whose `mesh.obj` could not be read or parsed. Tracked separately from `readyIDs`
    /// because a missing mesh must end as "no mesh for this scan", not as a spinner that never stops.
    @Published var failedIDs: Set<UUID> = []
    /// Rescans still in their own RAW capture frame — save-time registration was refused, so this
    /// generation can sit visibly offset from its siblings (see `MeshPreviewView.isCanonicalFramed`).
    @Published var unregisteredIDs: Set<UUID> = []
    /// What the visible generation is ACTUALLY drawing, which is not always what the source toggle
    /// asks for (proxy/dynamic are per-scan postprocess outputs). The caption reads this.
    @Published var visibleSource: MeshSourceMode = .full
    /// Whether the visible generation has privacy anchors — the legend row follows the generation
    /// on screen, while the toolbar toggle is gated on the union (`offers.privacy`).
    @Published var visibleHasPrivacy = false
    /// Same per-generation split for the capture-pose markers: `hasKeyframeMarkers`/`hasEquirects`
    /// are written only by the PRIMARY load, so the Stills/Motion and 360° legend rows would
    /// otherwise assert markers a scrubbed-to sibling doesn't have (or stay silent about ones it
    /// does). Toolbar gating still uses the union — only the legend follows the visible scan.
    @Published var visibleHasKeyframes = false
    @Published var visibleHasEquirects = false
    /// The visible generation has nothing to draw in the CURRENT source mode — its slot exists but
    /// the variant that mode needs is still loading. `readyIDs` can't answer this: a slot that has
    /// only its proxy geometry is "ready" and still blank the moment you switch to the full mesh.
    @Published var visibleIsBlank = false
    @Published var offers = TimelineOffers()

    /// Set when the preview is dismissed. The prefetch chain re-arms itself from its own
    /// completion, so without this a dismissed viewer keeps parsing the rest of the location's
    /// meshes at `.userInitiated` and writing into torn-down view state. Read and written on MAIN
    /// only (`onDisappear`, the pump's guard, and the pump's main-queue completion), and
    /// deliberately NOT `@Published`: it must not re-render anything, least of all during
    /// teardown. Cleared on appear so a re-presented viewer can't inherit a stale cancellation.
    /// At most the one parse already in flight finishes — the chain stops at the next hop.
    var isCancelled = false

    /// Loaded or known-unloadable — either way the scrubber has nothing left to wait for.
    func isResolved(_ scan: TimelineScan) -> Bool {
        readyIDs.contains(scan.id) || failedIDs.contains(scan.id)
    }

    func resolvedCount(in timeline: [TimelineScan]) -> Int {
        timeline.filter { isResolved($0) }.count
    }
}

/// The two generations pinned for A/B comparison, as indices into the timeline. Which one is
/// showing is not stored here — `visibleIndex` stays the single source of truth for what's on
/// screen, and the flip control just moves it between the two sides.
struct ABComparison: Equatable {
    var sideA: Int
    var sideB: Int

    /// The other side of the pair — the flip target.
    func other(than index: Int) -> Int { index == sideB ? sideA : sideB }
    func contains(_ index: Int) -> Bool { index == sideA || index == sideB }
    func badge(for index: Int) -> String? { index == sideA ? "A" : (index == sideB ? "B" : nil) }
}

// MARK: - Slot loading

extension MeshPreviewView {

    /// One loaded generation's node set. The slot's `container` holds every geometry variant that
    /// generation has built so far plus its own semantic outlines and capture markers, so scrubbing
    /// is a single `isHidden` flip on the container — no reload, and the camera never moves.
    final class TimelineSlot {
        let scan: TimelineScan
        let container: SCNNode
        var meshNode: SCNNode?
        var proxyMeshNode: SCNNode?
        var dynamicMeshNode: SCNNode?
        var semanticsNode: SCNNode?
        var semanticFillsNode: SCNNode?
        var keyframeStillsNode: SCNNode?
        var keyframeMotionNode: SCNNode?
        var equirectFacesNode: SCNNode?
        /// This generation's privacy-marker anchors, already offset into scene coords. Swapped into
        /// `MarkerProjectionState` when the slot becomes visible.
        var faceAnchors: [SCNVector3] = []
        /// This generation's RoomPlan classes — the legend follows the visible scan, so a class list
        /// borrowed from a sibling would be a lie about what's on screen.
        var detectedClasses: [SemanticClass] = []
        /// Sources whose artifact has already been resolved (successfully or not). A generation with
        /// no `mesh_dynamic.obj` must not be re-attempted on every `updateUIView`.
        var attempted: Set<MeshSourceMode> = []

        init(scan: TimelineScan, container: SCNNode) {
            self.scan = scan
            self.container = container
        }

        func node(for source: MeshSourceMode) -> SCNNode? {
            switch source {
            case .full:    return meshNode
            case .proxy:   return proxyMeshNode
            case .dynamic: return dynamicMeshNode
            }
        }

        /// The source this generation can honor: the requested one when its geometry is loaded,
        /// otherwise the full mesh. The graceful per-scan fallback — the caption reports it.
        func effectiveSource(for requested: MeshSourceMode) -> MeshSourceMode {
            node(for: requested) != nil ? requested : .full
        }

        var hasAnyGeometry: Bool { meshNode != nil || proxyMeshNode != nil || dynamicMeshNode != nil }

        /// Whether this generation has any capture-pose markers at all — same "any of the three"
        /// rule `KeyframeMarkerNodes.hasAny` uses for the primary's `hasKeyframeMarkers`, so the
        /// per-generation legend gate means exactly what the single-scan one does.
        var hasKeyframeMarkers: Bool {
            keyframeStillsNode != nil || keyframeMotionNode != nil || equirectFacesNode != nil
        }
        var hasEquirectFaces: Bool { equirectFacesNode != nil }
    }

    /// Everything one slot load produced, built entirely off-main.
    nonisolated struct TimelineSlotAssets {
        /// The source the load was ASKED for. Carried through so the attach can record it as
        /// resolved even when the artifact turned out to be missing.
        let requested: MeshSourceMode
        /// What `geometry` actually IS: the requested source, or `.full` when the requested
        /// artifact is missing or failed to parse.
        let source: MeshSourceMode
        let geometry: SCNGeometry?
        let outlines: SemanticOutlineResult?
        let markers: KeyframeMarkerNodes?
        let faceAnchors: [SCNVector3]
    }

    /// Builds one generation's geometry for `requested` (plus, on the slot's first load, its
    /// outlines / capture markers / privacy anchors). Runs on the timeline queue.
    ///
    /// Loads ONE geometry variant — not the set. `CombinedMeshView`'s loader eagerly builds up to
    /// six variants per mesh, which is affordable for one screen of a stitched cluster and is NOT
    /// affordable across a location's whole capture history; here a generation's alternate geometry
    /// is built the first time the source toggle actually asks that generation for it.
    ///
    /// `hasFullMesh` says the slot already holds this generation's full mesh, so the fallback below
    /// can be skipped: without it, toggling to `.proxy` in a location whose scans have no proxy
    /// artifact re-parses (and then discards) every generation's `mesh.obj` — the expensive half of
    /// the load, for no visible change.
    nonisolated static func loadTimelineSlot(scan: TimelineScan, requested: MeshSourceMode,
                                             isFirstLoad: Bool, hasFullMesh: Bool,
                                             rigProfile: RigProfile?) -> TimelineSlotAssets {
        var source = requested
        var geometry: SCNGeometry?
        switch requested {
        case .full:
            break
        case .proxy:
            if let url = proxyMeshURL(scanDirectoryURL: scan.scanDirectory),
               let data = try? Data(contentsOf: url) {
                geometry = buildGeometry(from: data, vertexColors: nil)?.0
            }
        case .dynamic:
            if let url = dynamicMeshURL(scanDirectoryURL: scan.scanDirectory),
               let data = try? Data(contentsOf: url) {
                geometry = buildGeometry(from: data, vertexColors: nil)?.0
            }
        }
        // Requested artifact absent (or unparseable) for this generation → fall back to its full
        // mesh so the slot is never empty (nothing to load when the slot already holds it). NO
        // vertex colors on the alternates: colors.bin is per-vertex against mesh.obj and the
        // proxy/dynamic artifacts compact vertices, exactly as in the primary load.
        if geometry == nil {
            source = .full
            if !hasFullMesh, let data = try? Data(contentsOf: scan.meshURL) {
                let colors = scan.colorsURL.flatMap { try? Data(contentsOf: $0) }
                geometry = buildGeometry(from: data, vertexColors: colors)?.0
            }
        }

        guard isFirstLoad else {
            return TimelineSlotAssets(requested: requested, source: source, geometry: geometry,
                                      outlines: nil, markers: nil, faceAnchors: [])
        }
        // Overlays are derived from small JSON sidecars rather than the mesh, so they ride the
        // slot's first load regardless of which geometry variant that load happened to want —
        // the lazy axis is geometry, which is where the memory is.
        return TimelineSlotAssets(
            requested: requested,
            source: source,
            geometry: geometry,
            outlines: buildRoomPlanOutlines(scanDirectoryURL: scan.scanDirectory),
            markers: buildKeyframeMarkerNodes(scanDirectoryURL: scan.scanDirectory, rigProfile: rigProfile),
            faceAnchors: faceAnchorPositions(scanDirectoryURL: scan.scanDirectory)
        )
    }

    /// Whether this generation's `mesh.obj` is in the frame the timeline draws in. The oldest scan
    /// DEFINES that frame (it owns the canonical roomplan the preview centers on); a rescan is in it
    /// only when its save-time registration applied, or when the solver found it already aligned
    /// inside the skip floor. A refused fit — or a rescan that never got postprocessed, hence has no
    /// sidecar — leaves the mesh in its own raw capture frame.
    ///
    /// `frameTarget` (from `timelineFrameTarget`) is checked against the sidecar's `targetScanId`:
    /// a rescan registered against a scan that ISN'T the one the preview is framed on is canonical
    /// to somebody else's frame, which is not the same thing as being aligned to what's on screen.
    ///
    /// Known limitation, deliberately not second-guessed here: `"already aligned"` is the
    /// pipeline's own verdict, and its floor is on TRANSLATION only (`Gate.minTransM`). A small yaw
    /// about a pivot near the frame origin has a sub-floor translation while still displacing
    /// distant walls, so a scan can be reported in-frame and still show a residual at the far end
    /// of the room. Re-deriving a stricter threshold in a viewer would put a second, divergent
    /// alignment policy in the UI layer; the fix belongs in the gate.
    ///
    /// Reuses the sidecar reader rather than re-parsing `registration.json`, which keeps it on the
    /// main actor. Called once per generation, on a few hundred bytes of JSON — the same "tiny
    /// decode, fine on main" trade the canonical-frame lookup makes.
    static func isCanonicalFramed(scanDirectory: URL, frameTarget: String) -> Bool {
        guard let sidecar = SaveRegistration.loadSidecar(scanDirectory: scanDirectory),
              sidecar.targetScanId == frameTarget else { return false }
        return sidecar.applied || sidecar.reason.hasPrefix("already aligned")
    }

    /// The scan id every generation has to be registered to for the timeline to be drawing them in
    /// ONE frame. Normally the frame owner's own id (the oldest scan, whose room the preview centers
    /// on). But when that owner is ITSELF a rescan whose registration applied, its mesh was rewritten
    /// into an older original's frame — that older scan has since been deleted, and the frame on
    /// screen is still its — so a sibling registered to the same ancestor is correctly placed. Using
    /// the owner's id alone would flag every remaining generation as offset after deleting a
    /// location's first scan, when in fact nothing moved.
    ///
    /// An owner whose own registration was REFUSED is in its own raw frame, so it becomes the target
    /// and siblings registered to the deleted ancestor ARE flagged — correctly: they really do sit
    /// offset from the geometry on screen.
    ///
    /// Resolution is ONE hop only: a sibling registered against the owner (rather than the owner's
    /// deleted ancestor) after such a deletion carries `targetScanId == owner.id`, fails the compare
    /// against the ancestor's id, and is flagged despite being correctly aligned. Fixing that needs
    /// either transitive chain resolution here or — better — re-pointing surviving sidecars at
    /// delete time in the pipeline, next to the existing stitch-link re-point.
    static func timelineFrameTarget(owner: TimelineScan) -> String {
        guard let sidecar = SaveRegistration.loadSidecar(scanDirectory: owner.scanDirectory),
              sidecar.applied || sidecar.reason.hasPrefix("already aligned") else {
            return owner.id.uuidString
        }
        return sidecar.targetScanId
    }

    /// Attaches a completed slot load to the scene. The slot's first load creates its container
    /// (with that generation's outlines and capture markers); later loads only add the geometry
    /// variant that was just built. Main actor — SceneKit graph mutation on the live scene.
    ///
    /// `center` is passed in (rather than re-read from the coordinator) so there is no "no center
    /// yet, give up" branch: an attach that silently created no slot would leave the pump re-picking
    /// the same generation and re-parsing its mesh forever.
    func attachTimelineSlot(_ assets: TimelineSlotAssets, scan: TimelineScan,
                            coordinator: Coordinator, scene: SCNScene, center: SCNVector3) {
        // Every generation rides the SAME offset the displayed one resolved — see the frame note at
        // the top of this file.
        let offset = SCNVector3(-center.x, -center.y, -center.z)

        let slot: TimelineSlot
        if let existing = coordinator.timelineSlots[scan.id] {
            slot = existing
        } else {
            slot = makeTimelineSlot(scan: scan, assets: assets, center: center, scene: scene)
            coordinator.timelineSlots[scan.id] = slot
        }

        // Both the requested source and the one actually built are resolved now — recording only
        // the built one would re-queue a missing artifact forever.
        slot.attempted.insert(assets.requested)
        slot.attempted.insert(assets.source)

        if let geometry = assets.geometry, slot.node(for: assets.source) == nil {
            let node = SCNNode(geometry: geometry)
            node.position = offset
            slot.container.addChildNode(node)
            switch assets.source {
            case .full:    slot.meshNode = node
            case .proxy:   slot.proxyMeshNode = node
            case .dynamic: slot.dynamicMeshNode = node
            }
        }

        if slot.hasAnyGeometry {
            timelineState.readyIDs.insert(scan.id)
            timelineState.failedIDs.remove(scan.id)
        } else {
            // mesh.obj itself is gone/unparseable — nothing more to try for this generation.
            timelineState.failedIDs.insert(scan.id)
        }

        addToOffers(slot)
    }

    /// Builds a generation's slot container from its first load: the overlays that belong to that
    /// scan (semantic outlines/fills, capture markers) plus its privacy anchors, all carrying the
    /// shared centering offset. Starts hidden — `applyTimelineVisibility` decides what shows.
    private func makeTimelineSlot(scan: TimelineScan, assets: TimelineSlotAssets,
                                  center: SCNVector3, scene: SCNScene) -> TimelineSlot {
        let offset = SCNVector3(-center.x, -center.y, -center.z)
        let container = SCNNode()
        container.name = "timelineSlot"
        container.isHidden = true
        scene.rootNode.addChildNode(container)
        let slot = TimelineSlot(scan: scan, container: container)

        if let outlines = assets.outlines {
            let semanticsNode = SCNNode()
            let fillsNode = SCNNode()
            for outline in outlines.outlineNodes {
                let wireNode = SCNNode(geometry: outline.geometry)
                wireNode.position = offset
                semanticsNode.addChildNode(wireNode)
                let fillNode = SCNNode(geometry: outline.fillGeometry)
                fillNode.position = offset
                fillsNode.addChildNode(fillNode)
            }
            container.addChildNode(semanticsNode)
            container.addChildNode(fillsNode)
            slot.semanticsNode = semanticsNode
            slot.semanticFillsNode = fillsNode
            slot.detectedClasses = outlines.detectedClasses
        }
        if let markers = assets.markers {
            // Deliberately NOT `attachKeyframeMarkers`: that publishes hasKeyframeMarkers /
            // hasEquirects for the scan it attached, which would make the toolbar toggle blink in
            // and out as you scrub. Slots only ever ADD to the OR-only `TimelineOffers`.
            for group in [markers.stills, markers.motion, markers.equirectFaces].compactMap({ $0 }) {
                group.position = offset
                container.addChildNode(group)
            }
            slot.keyframeStillsNode = markers.stills
            slot.keyframeMotionNode = markers.motion
            slot.equirectFacesNode = markers.equirectFaces
        }
        slot.faceAnchors = assets.faceAnchors.map {
            SCNVector3($0.x - center.x, $0.y - center.y, $0.z - center.z)
        }
        return slot
    }

    /// Folds one slot's artifacts into the OR-only toolbar union.
    private func addToOffers(_ slot: TimelineSlot) {
        var offers = timelineState.offers
        offers.proxy = offers.proxy || slot.proxyMeshNode != nil
        offers.dynamic = offers.dynamic || slot.dynamicMeshNode != nil
        offers.semantics = offers.semantics || !slot.detectedClasses.isEmpty
        offers.keyframes = offers.keyframes || slot.keyframeStillsNode != nil || slot.keyframeMotionNode != nil
        offers.equirects = offers.equirects || slot.equirectFacesNode != nil
        offers.privacy = offers.privacy || !slot.faceAnchors.isEmpty
        if offers != timelineState.offers { timelineState.offers = offers }
    }

    /// Registers the generation the viewer opened on as its own timeline slot, adopting the nodes
    /// the primary load already built (including the marker containers `attachKeyframeMarkers` just
    /// published onto the coordinator). From here on ONE visibility routine drives every generation.
    /// Inert for single-scan locations, which have an empty `timeline`.
    func registerPrimaryTimelineSlot(container: SCNNode, coordinator: Coordinator, center: SCNVector3) {
        coordinator.resolvedCenter = center
        guard timeline.indices.contains(primaryIndex) else { return }
        let scan = timeline[primaryIndex]
        let slot = TimelineSlot(scan: scan, container: container)
        slot.meshNode = coordinator.meshNode
        slot.proxyMeshNode = coordinator.proxyMeshNode
        slot.dynamicMeshNode = coordinator.dynamicMeshNode
        slot.semanticsNode = coordinator.semanticsNode
        slot.semanticFillsNode = coordinator.semanticFillsNode
        slot.keyframeStillsNode = coordinator.keyframeStillsNode
        slot.keyframeMotionNode = coordinator.keyframeMotionNode
        slot.equirectFacesNode = coordinator.equirectFacesNode
        slot.faceAnchors = markerState.anchorPositions
        slot.detectedClasses = detectedClasses
        // The primary load resolves all three variants up front (that's what makes hasProxyMesh /
        // hasDynamicMesh honest for the single-scan preview), so nothing here is left to attempt.
        slot.attempted = [.full, .proxy, .dynamic]
        coordinator.timelineSlots[scan.id] = slot

        guard timeline.count > 1 else { return }
        timelineState.readyIDs.insert(scan.id)
        addToOffers(slot)

        // Resolve the frame every generation is measured against ONCE — this runs before any pump
        // can (the pump needs `resolvedCenter`, set just above) — and check the OPENED generation
        // against it here. The pump only ever sees generations it loads itself, and this slot is
        // inserted synchronously, so without this the "may sit offset" warning would depend on
        // which scan card you entered the viewer by. Not inside a view update (this is the primary
        // load's main-queue completion), so the publish can be direct.
        let frameTarget = Self.timelineFrameTarget(owner: timeline[0])
        coordinator.timelineFrameTarget = frameTarget
        if primaryIndex != 0,
           !Self.isCanonicalFramed(scanDirectory: scan.scanDirectory, frameTarget: frameTarget) {
            timelineState.unregisteredIDs.insert(scan.id)
        }
    }

    // MARK: - Visibility + load pump

    /// Exactly one generation on screen, and the current view modes applied to it. Cheap by
    /// construction (a handful of `isHidden` writes), which is what makes scrubbing instant.
    func applyTimelineVisibility(_ coordinator: Coordinator) {
        let visible = timeline.indices.contains(visibleIndex) ? timeline[visibleIndex] : nil
        let visibleSlot = visible.flatMap { coordinator.timelineSlots[$0.id] }
        for (id, slot) in coordinator.timelineSlots {
            slot.container.isHidden = (id != visibleSlot?.scan.id)
        }

        // Scrubbed onto a generation that hasn't loaded: nothing is drawn, so nothing may describe
        // it either. Without this the previous generation's privacy markers keep projecting over
        // an empty scene and the legend keeps naming its classes.
        guard let visibleSlot else {
            if coordinator.lastVisibleScanID != nil {
                coordinator.lastVisibleScanID = nil
                coordinator.enqueuedVisibleBlank = true
                markerState.anchorPositions = []
                DispatchQueue.main.async {
                    self.detectedClasses = []
                    self.timelineState.visibleHasPrivacy = false
                    self.timelineState.visibleHasKeyframes = false
                    self.timelineState.visibleHasEquirects = false
                    self.timelineState.visibleIsBlank = true
                }
            }
            return
        }

        let source = visibleSlot.effectiveSource(for: meshSourceMode)
        let showMesh = semanticViewMode.showMesh
        visibleSlot.meshNode?.isHidden = !(showMesh && source == .full)
        visibleSlot.proxyMeshNode?.isHidden = !(showMesh && source == .proxy)
        visibleSlot.dynamicMeshNode?.isHidden = !(showMesh && source == .dynamic)
        visibleSlot.semanticsNode?.isHidden = !semanticViewMode.showOutlines
        visibleSlot.semanticFillsNode?.isHidden = !semanticViewMode.showFills
        visibleSlot.keyframeStillsNode?.isHidden = !keyframeMarkerMode.showStills
        visibleSlot.keyframeMotionNode?.isHidden = !keyframeMarkerMode.showMotion
        visibleSlot.equirectFacesNode?.isHidden = !keyframeMarkerMode.showEquirectFaces

        publishVisibleGeneration(visibleSlot, source: source, coordinator: coordinator)
    }

    /// Republishes the state that describes ONE generation — privacy anchors, the semantic legend's
    /// classes, the capture-marker legend gates, the drawn source, and whether anything is drawn at
    /// all. Everything here is deferred off the view update this runs inside (a synchronous publish
    /// there is undefined behaviour) and gated on a change (an unconditional one would re-enter
    /// `updateUIView` forever).
    private func publishVisibleGeneration(_ slot: TimelineSlot, source: MeshSourceMode,
                                          coordinator: Coordinator) {
        if coordinator.lastVisibleScanID != slot.scan.id {
            coordinator.lastVisibleScanID = slot.scan.id
            markerState.anchorPositions = slot.faceAnchors
            let classes = slot.detectedClasses
            let hasPrivacy = !slot.faceAnchors.isEmpty
            let hasKeyframes = slot.hasKeyframeMarkers
            let hasEquirectFaces = slot.hasEquirectFaces
            DispatchQueue.main.async {
                self.detectedClasses = classes
                self.timelineState.visibleHasPrivacy = hasPrivacy
                self.timelineState.visibleHasKeyframes = hasKeyframes
                self.timelineState.visibleHasEquirects = hasEquirectFaces
            }
        }
        // Compared against the last value ENQUEUED, not the one currently published: these
        // publishes are deferred, so a value already on its way would be re-enqueued — and, worse,
        // a value that UNDOES one still in flight would be skipped, flashing the placeholder for a
        // frame.
        let blank = slot.node(for: source) == nil
        if coordinator.enqueuedVisibleSource != source {
            coordinator.enqueuedVisibleSource = source
            DispatchQueue.main.async { self.timelineState.visibleSource = source }
        }
        if coordinator.enqueuedVisibleBlank != blank {
            coordinator.enqueuedVisibleBlank = blank
            DispatchQueue.main.async { self.timelineState.visibleIsBlank = blank }
        }
    }

    /// Drives the sibling loads: one generation at a time on a serial queue, nearest to the scrub
    /// position first — so the scan the user is waiting on jumps the queue and its neighbours come
    /// next. Called from `updateUIView` and again from each completion; idempotent, so a pump with
    /// nothing left to do just returns.
    ///
    /// CAPACITY (future work — deliberately no eviction code here). N resident generations is fine
    /// for the handful of rescans a room accumulates in practice, and NOT fine indefinitely: each
    /// slot holds a full `buildGeometry` result, which subdivides every triangle into four for
    /// smooth vertex-color interpolation. When a location's history outgrows memory, this is the
    /// place to bound it:
    ///   - unload slots far from the scrub position (drop the container, keep the snapshot, and
    ///     reload on approach — the `attempted` set already makes a reload idempotent);
    ///   - cap the resident geometry variants per slot (e.g. keep the current source only, dropping
    ///     the others on a source change instead of accumulating all three);
    ///   - degrade distant generations to the cheaper representation — the ghost proxy where one
    ///     exists, and height-shaded (no colors.bin) geometry, which halves the per-vertex payload;
    ///   - refuse to prefetch at all under `os_proc_available_memory` pressure (see
    ///     `ScanStats.memoryPressure`) and load strictly on demand.
    /// The eviction policy wants a device memory profile to pick between those, which is why this
    /// is a note and not an implementation.
    func pumpTimelineLoads(_ coordinator: Coordinator, scene: SCNScene?) {
        // `isCancelled` first: the viewer is gone, and this chain re-arms itself.
        guard !timelineState.isCancelled, timeline.count > 1, let scene,
              let center = coordinator.resolvedCenter,
              !coordinator.timelineLoadInFlight else { return }
        guard let next = nextTimelineLoad(coordinator) else { return }

        coordinator.timelineLoadInFlight = true
        let scan = next.scan
        let requested = meshSourceMode
        let slot = coordinator.timelineSlots[scan.id]
        let isFirstLoad = slot == nil
        let hasFullMesh = slot?.meshNode != nil
        // Read on main (it touches UserDefaults-backed profile state), same as the primary load.
        let rigProfile = RigProfile.load()
        // Index 0 owns the frame the preview centers on, so only the later generations can be
        // off-frame (the opened generation is checked in `registerPrimaryTimelineSlot`). Checked in
        // the completion, not here: this runs inside a view update, where publishing to
        // `unregisteredIDs` synchronously is undefined behaviour.
        let frameTarget = coordinator.timelineFrameTarget
        let checkFrame = isFirstLoad && next.index != 0

        coordinator.timelineQueue.async { [rigProfile] in
            let assets = Self.loadTimelineSlot(scan: scan, requested: requested,
                                               isFirstLoad: isFirstLoad, hasFullMesh: hasFullMesh,
                                               rigProfile: rigProfile)
            DispatchQueue.main.async {
                // Dismissed while this one was parsing: drop the result on the floor rather than
                // mutate a torn-down scene / write into dead view state, and do NOT re-arm.
                guard !self.timelineState.isCancelled else {
                    coordinator.timelineLoadInFlight = false
                    return
                }
                // `self` is a struct, but its bindings read live view state — so the modes applied
                // here are the CURRENT ones even if the user changed them mid-load.
                if checkFrame, let frameTarget,
                   !Self.isCanonicalFramed(scanDirectory: scan.scanDirectory, frameTarget: frameTarget) {
                    self.timelineState.unregisteredIDs.insert(scan.id)
                }
                self.attachTimelineSlot(assets, scan: scan, coordinator: coordinator,
                                        scene: scene, center: center)
                coordinator.timelineLoadInFlight = false
                self.applyTimelineVisibility(coordinator)
                self.pumpTimelineLoads(coordinator, scene: scene)
            }
        }
    }

    /// The next generation to load: the visible one first, then outward from the scrub position.
    /// A generation is "needed" when it has no slot yet, or when the current source mode asks it
    /// for a variant it has never been asked for.
    private func nextTimelineLoad(_ coordinator: Coordinator) -> (index: Int, scan: TimelineScan)? {
        let anchor = timeline.indices.contains(visibleIndex) ? visibleIndex : primaryIndex
        let byDistance = timeline.indices.sorted { abs($0 - anchor) < abs($1 - anchor) }
        for index in byDistance {
            let scan = timeline[index]
            guard let slot = coordinator.timelineSlots[scan.id] else { return (index, scan) }
            if !slot.attempted.contains(meshSourceMode) { return (index, scan) }
        }
        return nil
    }
}
