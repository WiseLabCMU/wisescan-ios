import Foundation
import SwiftData
import simd
import UIKit

// MARK: - Stitch Graph Model
//
// Builds a graph of locations connected by stitch links. Links are read from the
// SwiftData object graph (`CapturedScan.linksAsA/linksAsB`) — the source of truth.
// Edges retain a source → target orientation for provenance/layout, but the relation
// is bidirectional (see `StitchLink`); the view renders connectors undirected.

/// A node in the stitch graph — one per location that participates in any link.
struct StitchGraphNode: Identifiable {
    let id: UUID            // locationId
    let location: ScanLocation
    /// Scans in this location that are referenced by an incident link.
    var scanIds: Set<UUID> = []
    /// Layered-layout coordinates (filled by the builder).
    var level: Int = 0
    var order: Int = 0
}

/// An edge between two locations. `from`/`to` carry the source → target provenance
/// orientation (used for layout); the underlying relation is bidirectional.
struct StitchGraphEdge: Identifiable {
    var id: UUID { link.id }
    let from: UUID   // source locationId
    let to: UUID     // target locationId
    let link: StitchLink
}

/// A scan placed into a shared coordinate frame for combined rendering.
struct PlacedScan {
    let locationId: UUID
    let scanId: UUID
    /// Transform mapping this scan's world-frame vertices into the component's shared frame.
    let transform: simd_float4x4
    /// The spanning-tree edge (link id) that placed this map — i.e. the join the manual adjuster
    /// edits to move THIS piece. `nil` for the root/base map, which defines the shared frame.
    let parentLinkId: UUID?
}

/// A stitch pin (the shared boundary point of one link) expressed in the component's shared frame,
/// so the combined render can drop a visible marker at each join.
struct StitchPoint: Identifiable {
    let id: UUID            // link id
    let position: SIMD3<Float>
    let sourceName: String
    let targetName: String
}

/// The full result of placing a component: per-map transforms plus the stitch-pin markers.
struct ComponentPlacement {
    var scans: [PlacedScan] = []
    var stitchPoints: [StitchPoint] = []
}

/// The assembled graph plus connected-component grouping and layout.
struct StitchGraph {
    var nodes: [StitchGraphNode]
    var edges: [StitchGraphEdge]
    /// Connected components (undirected), each a list of location IDs. Sorted largest-first.
    var components: [[UUID]]

    var nodesById: [UUID: StitchGraphNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }

    func edges(in component: [UUID]) -> [StitchGraphEdge] {
        let set = Set(component)
        return edges.filter { set.contains($0.from) && set.contains($0.to) }
    }

    var isEmpty: Bool { nodes.isEmpty }
}

// MARK: - Builder

enum StitchGraphBuilder {

    /// Walks the SwiftData object graph and assembles the stitch graph.
    @MainActor
    static func build(from locations: [ScanLocation]) async -> StitchGraph {
        let byId = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, $0) })

        // Gather StitchLink objects incident to the given locations, de-duped by id. SwiftData's
        // cascade delete keeps these consistent, but a link's endpoint scan/location can still be
        // absent from `locations` (e.g. filtered view) — keep only links whose source AND target
        // scans both resolve to a location in this set, mirroring the old endpoint-existence guard.
        // Fetch-based incident query (see StitchLinkStore.incidentLinks) — the inverse arrays can
        // drop one direction, which would silently omit edges from the graph. Fetch ONCE into a
        // scan-id index rather than per scan (this walks every scan of every location).
        let linkIndex: [UUID: [StitchLink]]
        if let context = locations.first?.modelContext {
            linkIndex = StitchLinkStore.incidentLinksByScanId(in: context)
        } else {
            linkIndex = [:]
        }
        var links: [StitchLink] = []
        var seenLinks = Set<UUID>()
        for loc in locations {
            for scan in loc.scans {
                for link in (linkIndex[scan.id] ?? []) where seenLinks.insert(link.id).inserted {
                    guard let srcLoc = link.sourceScan?.location, let tgtLoc = link.targetScan?.location,
                          byId[srcLoc.id] != nil, byId[tgtLoc.id] != nil else { continue }
                    links.append(link)
                }
            }
        }

        // Build nodes for every location touched by a link.
        var nodes: [UUID: StitchGraphNode] = [:]
        func ensureNode(_ locId: UUID) {
            guard nodes[locId] == nil, let loc = byId[locId] else { return }
            nodes[locId] = StitchGraphNode(id: locId, location: loc)
        }

        var edges: [StitchGraphEdge] = []
        for link in links {
            guard let srcScan = link.sourceScan, let tgtScan = link.targetScan,
                  let srcLocId = srcScan.location?.id, let tgtLocId = tgtScan.location?.id else { continue }
            ensureNode(srcLocId)
            ensureNode(tgtLocId)
            nodes[srcLocId]?.scanIds.insert(srcScan.id)
            nodes[tgtLocId]?.scanIds.insert(tgtScan.id)
            edges.append(StitchGraphEdge(from: srcLocId, to: tgtLocId, link: link))
            // NOTE: the Op-2 residual/correction diag is intentionally NOT logged here. This runs on
            // the all-scans graph list (every rebuild); the diag belongs to the full combined render
            // only (StitchGraphView.presentRender), where the correction is actually applied and a
            // user is looking at the result. Kept PerfDiag-gated there.
        }

        // Sort edges deterministically: placeScans' spanning-tree BFS walks adjacency in edge order,
        // so an unstable `edges` order (it follows Dictionary/link discovery order) would make the
        // combined-render placements — and each map's chosen `parentLinkId` for the adjuster — vary
        // across runs, especially in cyclic graphs. Key on the stable link id.
        edges.sort { $0.link.id.uuidString < $1.link.id.uuidString }

        // Sort node ids/list deterministically — Dictionary iteration order is unstable
        // across runs, which would otherwise leak into component membership order and
        // the layered layout's `order` assignment.
        let sortedIds = nodes.keys.sorted { $0.uuidString < $1.uuidString }
        let components = connectedComponents(nodeIds: sortedIds, edges: edges)
        var nodeList = sortedIds.compactMap { nodes[$0] }
        layout(nodes: &nodeList, edges: edges, components: components)

        return StitchGraph(nodes: nodeList, edges: edges, components: components)
    }

    /// PerfDiag per-link log of the Op-2 decision — pure diagnostic, no mutation. Takes the
    /// PRE-COMPUTED correction (from `computeAutoCorrections`, so the render path solves once) and
    /// prints, by location name, what it decided: the measured yaw / ⊥, whether each was applied or
    /// held, the compass reading, and the wall / near-∥ counts. So a link that WASN'T corrected says
    /// why (untrusted vs. gated). Caller gates on `PerfDiag.enabled` and fires only from the full
    /// combined render (never the all-scans list).
    @MainActor
    static func logResidual(link: StitchLink, correction: StitchCorrection?) {
        #if canImport(RoomPlan)
        let src = link.sourceScan?.location?.name ?? "?", tgt = link.targetScan?.location?.name ?? "?"
        guard let c = correction else {
            print("[StitchResidual] \(src) ↔ \(tgt): skip — missing scan or canonical roomplan")
            return
        }
        let compass = c.compassDeg.map { String(format: "%.1f°", $0) } ?? "n/a"
        // When applied, report the SIGNED yaw actually baked in; when held, report the measured value
        // so the log says what was considered. (These now agree — the raw atan2 sign is used directly
        // — but they stay distinct so a future re-sign can't silently mislabel the log.)
        let yaw = String(format: "yaw %+.1f°→%@", c.appliedYaw ? c.yawSigned : c.yawDeg, c.appliedYaw ? "applied" : "held")
        let perp = c.appliedPerp ? String(format: "⊥ %.0fcm→applied", c.perpCm)
                                 : (c.doorwayPerpCm.map { String(format: "⊥ %.0fcm→held", $0) } ?? "⊥ n/a")
        // Vote span alongside MAD: a wide span with a small MAD is outliers, a wide span with a large
        // MAD is a split sample (two wall families). `far` counts pairs the angle gate accepted and
        // the proximity gate rejected — if that dominates, maxPairGapM is starving the sample.
        // The reported yaw/MAD are AREA-WEIGHTED (what's applied); `plain` is the unweighted median,
        // kept so the weighting's effect stays visible on device.
        let votes = String(format: "near-∥ %d(far %d) span %+.1f…%+.1f° MAD %.2f° | plain %+.2f°",
                           c.nearParallel, c.nearParallelFar,
                           c.yawVoteMinDeg, c.yawVoteMaxDeg, c.yawMADDeg, c.yawPlainDeg)
        print("[StitchResidual] \(src) ↔ \(tgt): \(yaw), \(perp) | compass \(compass) | walls \(c.srcWalls)/\(c.tgtWalls) \(votes)")
        #endif
    }

    // MARK: Connected components (union-find)

    private static func connectedComponents(nodeIds: [UUID], edges: [StitchGraphEdge]) -> [[UUID]] {
        var parent: [UUID: UUID] = Dictionary(uniqueKeysWithValues: nodeIds.map { ($0, $0) })

        func find(_ x: UUID) -> UUID {
            var root = x
            while parent[root] != root { root = parent[root]! }
            // path compression
            var cur = x
            while parent[cur] != root { let next = parent[cur]!; parent[cur] = root; cur = next }
            return root
        }
        func union(_ a: UUID, _ b: UUID) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        for e in edges { union(e.from, e.to) }

        var groups: [UUID: [UUID]] = [:]
        for id in nodeIds { groups[find(id), default: []].append(id) }
        // Largest-first; break ties by the (already-sorted) first element so equal-size
        // components keep a stable order across runs.
        return groups.values.map { $0 }.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0[0].uuidString < $1[0].uuidString
        }
    }

    // MARK: Layered layout

    /// Assigns each node a `level` (BFS depth from a source-side root) and an `order`
    /// within that level. Components are stacked by offsetting `level`-rows is left to
    /// the view; here we only need per-node level/order plus component membership.
    private static func layout(nodes: inout [StitchGraphNode], edges: [StitchGraphEdge], components: [[UUID]]) {
        // in-degree per node for root selection (prefer a source-side node)
        var inDegree: [UUID: Int] = [:]
        for e in edges {
            inDegree[e.to, default: 0] += 1
            inDegree[e.from] = inDegree[e.from] ?? 0
        }

        var level: [UUID: Int] = [:]
        for component in components {
            // Root: prefer a node with no incoming edges; otherwise the first.
            let root = component.first(where: { (inDegree[$0] ?? 0) == 0 }) ?? component.first
            guard let root else { continue }

            // BFS over the *undirected* graph for connectivity. Level changes by the
            // edge direction: +1 when following a directed source→target edge, -1 when
            // traversing it in reverse (negative levels are normalized to 0 below).
            var queue: [UUID] = [root]
            level[root] = 0
            var visited: Set<UUID> = [root]
            // build undirected adjacency restricted to this component
            let compSet = Set(component)
            var undirected: [UUID: [(UUID, Bool)]] = [:] // (neighbor, forward)
            for e in edges where compSet.contains(e.from) && compSet.contains(e.to) {
                undirected[e.from, default: []].append((e.to, true))
                undirected[e.to, default: []].append((e.from, false))
            }
            var head = 0
            while head < queue.count {
                let u = queue[head]; head += 1
                for (v, forward) in undirected[u] ?? [] where !visited.contains(v) {
                    visited.insert(v)
                    level[v] = (level[u] ?? 0) + (forward ? 1 : -1)
                    queue.append(v)
                }
            }
            // Normalize negative levels so the minimum is 0.
            let minLevel = component.compactMap { level[$0] }.min() ?? 0
            for id in component { level[id] = (level[id] ?? 0) - minLevel }
        }

        // Assign `order` per (component, level) by stable iteration.
        var orderCounter: [String: Int] = [:] // key: "\(componentIndex)-\(level)"
        var componentIndexById: [UUID: Int] = [:]
        for (i, comp) in components.enumerated() { for id in comp { componentIndexById[id] = i } }

        for i in nodes.indices {
            let id = nodes[i].id
            let lvl = level[id] ?? 0
            let comp = componentIndexById[id] ?? 0
            let key = "\(comp)-\(lvl)"
            let ord = orderCounter[key, default: 0]
            orderCounter[key] = ord + 1
            nodes[i].level = lvl
            nodes[i].order = ord
        }
    }

    // MARK: - Op-2: plane-derived edge correction

    /// The Op-2 decision for one link: the edge-correction transform plus the diagnostics behind it
    /// (so `logResidual` can report it without recomputing). `applied*` false ⇒ that DOF kept the pivot.
    struct StitchCorrection {
        var transform = matrix_identity_float4x4   // C: r_corrected = C · (mSrc·inv(mTgt))
        var yawDeg: Float = 0                       // measured pivot yaw error
        var appliedYaw = false
        var perpCm: Float = 0                        // applied through-doorway ⊥ correction magnitude (cm)
        var appliedPerp = false
        var compassDeg: Float?                       // |C_A − C_B|
        var srcWalls = 0
        var tgtWalls = 0
        var nearParallel = 0                         // # near-∥ wall pairs
        var doorwayPerpCm: Float?                    // de-yawed doorway-wall gap before correction (cm)
        var yawSigned: Float = 0                     // signed yaw ACTUALLY applied about the pin (0 if not)
        var transVec: SIMD3<Float> = .zero           // translation ACTUALLY applied, source-canonical (zero if not)
        var yawMADDeg: Float = 0                     // MAD of the yaw sample (dispersion diagnostic)
        var nearParallelFar = 0                      // pairs passing the ANGLE gate but dropped as too far apart
        /// Full span of the yaw votes. With the median and MAD this separates the two failures MAD
        /// alone conflates: a wide span with a small MAD is a few outliers, while a wide span with a
        /// large MAD is a genuinely split sample (two orientation families) — recoverable by picking
        /// the dominant mode, where a median just lands between them.
        var yawVoteMinDeg: Float = 0
        var yawVoteMaxDeg: Float = 0
        /// The UNWEIGHTED median, log-only. `yawDeg` carries the area-weighted value that is actually
        /// applied; keeping the plain one visible makes the weighting's effect auditable on device
        /// rather than something to take on trust.
        var yawPlainDeg: Float = 0

        /// The applied correction expressed as a `ManualNudge` (yaw about the pin + translation), so
        /// "Autocorrect" can transfer the solver's fix INTO the single manual correction rather than
        /// layering a separate transform under it. Reproduces `transform` exactly when the nudge is
        /// applied about the T-composed CANONICAL pin (`mSrc.columns.3`, i.e. `tSrc·sourceAnchor`) —
        /// the same pivot placeScans/effectiveCorrection use. (Not the true raw `sourceAnchor` pin;
        /// all three paths agree only because each pivots about this canonical point.)
        var asNudge: ManualNudge { ManualNudge(yawDeg: yawSigned, dx: transVec.x, dy: transVec.y, dz: transVec.z) }
    }

    // MARK: - Op-2 yaw tunables

    /// Weighted median: the value at which cumulative weight first reaches half the total. Falls back
    /// to the plain middle element for an empty/zero-weight set. (Not interpolated — the estimate is
    /// one of the observed angles, matching the unweighted median it's compared against.)
    static func weightedMedian(_ samples: [(deg: Float, w: Float)]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted { $0.deg < $1.deg }
        let total = sorted.reduce(Float(0)) { $0 + $1.w }
        guard total > 0 else { return sorted[sorted.count / 2].deg }
        var acc: Float = 0
        for s in sorted {
            acc += s.w
            if acc >= total / 2 { return s.deg }
        }
        return sorted[sorted.count - 1].deg
    }

    /// PROVISIONAL values pending real-scan tuning (same convention as `PlaneRegistration.Gate`).
    enum YawGate {
        /// Yaw noise floor. Kept at a small EPSILON rather than 0: sub-degree yaw is worth applying
        /// (0.5° across a 10 m wall is ~9 cm of lever-arm gap), but `ManualNudge.isZero` is exact
        /// equality, so a literal 0 floor makes every clean join carry a nudge — the legend's
        /// uncorrected "Aligned" state becomes unreachable and `nudgesApproxEqual`'s 0.05° tolerance
        /// ends up comparing against 0.02° auto values. This keeps "no meaningful correction"
        /// representable while still applying everything that actually shows.
        static let minApplyDeg: Float = 0.05
        /// ABSOLUTE ceiling on the yaw sample's MAD (median absolute deviation) — past this the
        /// sample is junk whatever the estimate. PROVISIONAL: 3° is generous for a well-sampled
        /// join (MAD < 1° typical) but catches the stairwell-class thin/fragmented scenario.
        static let maxYawMADDeg: Float = 3.0
        /// RELATIVE dispersion gate: the estimate must clear `minMADRatio × MAD` to be applied.
        ///
        /// An absolute MAD ceiling alone does not scale down with the signal, and all three of the
        /// other guards are simultaneously blind in the small-yaw regime: at yaw 0.3° / MAD 2.8°
        /// the apply floor passes, `maxYawMADDeg` passes, and the compass window (±15°) is vacuous
        /// — applying a point estimate ~10× smaller than its own dispersion. Signal-to-noise is
        /// what separates "small and clean" (apply) from "small and noisy" (decline).
        /// PROVISIONAL — calibrate from the device MAD on a join known to be bad.
        static let minMADRatio: Float = 2.0
        /// Noise floor clamped onto the MAD before the ratio test. Necessary because the MAD is now
        /// area-weighted: on a clean join the large walls agree to within hundredths of a degree
        /// (device: 0.00°, 0.00°, 0.06°), which would make `|yaw| ≥ ratio × MAD` vacuous and let any
        /// yaw above `minApplyDeg` through — including a spurious one. Clamping asserts we cannot
        /// claim precision finer than plane-fit noise, so the effective minimum applied yaw is
        /// `minMADRatio × madFloorDeg` (0.30°) and rises from there as real dispersion appears.
        /// PROVISIONAL.
        static let madFloorDeg: Float = 0.15
        /// Minimum near-∥ pair count before the dispersion gate means anything. At n = 1 the MAD is
        /// identically 0, which would satisfy ANY signal-to-noise test — so without this the
        /// relative gate above is trivially passable by the thinnest possible sample.
        /// PROVISIONAL — tune from the `near-∥` counts in `[StitchResidual]`.
        static let minNearParallel = 3
        /// Near-∥ admission angle for the YAW sample. Deliberately NOT
        /// `PlaneRegistration.matchAngleDeg` (25°), which was tuned for correspondence MATCHING in a
        /// solver that also uses plane position; here it is the sole admission test, and at 25° it
        /// cannot separate "same wall family, a few degrees of drift" from "different wall family,
        /// ~20° apart by design" — non-orthogonal architecture (angled wings, splayed corners,
        /// cubicle runs off the building grid) is common enough that this silently poisons the median.
        ///
        /// The gate has to sit inside (max expected yaw error, min architectural angle deviation):
        /// yaw errors run ~2° typical / 5.5° observed, and the smallest deliberate non-orthogonal
        /// feature seen on site is ~15°, so the usable window is roughly 6–14°. Note the corollary:
        /// a yaw error exceeding the smallest architectural angle is genuinely ambiguous and no gate
        /// recovers it.
        static let nearParallelDeg: Float = 10.0
        /// Max gap (m) at CLOSEST APPROACH between two walls that can still plausibly share an
        /// orientation family. Budgeted from the mechanics, not guessed: up to ~2 m of stitch-pin
        /// error (a user drifts that far at the pin despite the hold-still prompt) plus up to ~2 m of
        /// genuine separation between walls that are co-visible but not overlapping.
        ///
        /// Rationale: buildings are LOCALLY Manhattan even when globally they aren't, so proximity is
        /// a proxy for same-grid membership. It also bounds intra-scan ARKit drift — a room is not
        /// perfectly rigid, so a far wall can be slightly rotated relative to a near one *within one
        /// scan*, which breaks the "a yaw error rotates the room uniformly" premise independently of
        /// architecture. Measured extent-aware (bounding-sphere closest approach), so a long wall
        /// paired with a short one near its end still counts as adjacent.
        static let maxPairGapM: Float = 4.0
    }

    /// The scan whose canonical roomplan/mesh REPRESENTS a location: its canonical owner (gen-0,
    /// `canonicalOrder` first) — the registration reference whose frame *is* the location's canonical
    /// frame. Reading walls/mesh from here (not from whichever generation was current at stitch time)
    /// keeps the stitch room-to-room and rescan-stable: every generation's `mesh.obj`/`roomplan.json`
    /// already lives in this shared canonical frame, and gen-0 carries zero registration error (it
    /// defines the frame). Falls back to `scan` when the location/scan set is unavailable.
    @MainActor
    static func canonicalScan(for scan: CapturedScan) -> CapturedScan {
        scan.location?.scans.min(by: CapturedScan.canonicalOrder) ?? scan
    }

    /// Plane-derived correction to the T-composed pivot edge for one link (Op-2). Compose as
    /// `r_corrected = transform · (mSrc·inv(mTgt))`.
    /// - **Yaw** is *correspondence-free* — every near-∥ wall pair sees the same pivot yaw error, so
    ///   the median orientation delta IS the global fix — applied only within the compass window (a
    ///   plane yaw far from `|C_A−C_B|` is a bad fit / relocalization flip → reject).
    /// - **Through-doorway ⊥ translation** is the de-yawed **doorway wall**'s residual gap. The doorway
    ///   wall is the coplanar OPPOSITE-face pair with the **minimum** ⊥ (the genuinely-shared wall,
    ///   *not* the pin-nearest side wall), gated to a sane, well-separated magnitude. Room B is placed
    ///   on the side of the wall OPPOSITE the pin (room A) at a nominal thickness — the pin fixes the
    ///   side, so no reliance on a RoomPlan normal convention.
    /// `nil` only when a scan / canonical roomplan is missing; otherwise a struct whose `applied*`
    /// flags say what (if anything) was corrected — never-worse-than-the-pivot.
    @MainActor
    static func stitchCorrection(link: StitchLink) -> StitchCorrection? {
        #if canImport(RoomPlan)
        guard let src = link.sourceScan, let tgt = link.targetScan else { return nil }
        let tSrc = SaveRegistration.appliedTransform(scanDirectory: src.scanDirectory) ?? matrix_identity_float4x4
        let tTgt = SaveRegistration.appliedTransform(scanDirectory: tgt.scanDirectory) ?? matrix_identity_float4x4
        let mSrc = tSrc * link.sourceAnchorMatrix
        let r = mSrc * simd_inverse(tTgt * link.targetAnchorMatrix)
        let anchor = SIMD3<Float>(mSrc.columns.3.x, mSrc.columns.3.y, mSrc.columns.3.z)
        // Walls come from each LOCATION's canonical (gen-0) scan — the registration reference, in the
        // same canonical frame the pin was lifted into — NOT the stitch-time generation. Room-to-room
        // and rescan-stable. Falls back to the link's own scan if the canonical owner has no roomplan,
        // so we never lose auto availability a rescan happens to provide.
        func canonicalWalls(preferOwnerOf scan: CapturedScan) -> [PlaneRegistration.Plane] {
            let ownerDir = canonicalScan(for: scan).scanDirectory
            let owner = SaveRegistration.canonicalFramePlanes(scanDirectory: ownerDir).filter { $0.category == .wall }
            return owner.isEmpty
                ? SaveRegistration.canonicalFramePlanes(scanDirectory: scan.scanDirectory).filter { $0.category == .wall }
                : owner
        }
        let sW = canonicalWalls(preferOwnerOf: src)
        let tW = canonicalWalls(preferOwnerOf: tgt).map { PlaneRegistration.applying(r, to: $0) }
        guard !sW.isEmpty, !tW.isEmpty else { return nil }

        var out = StitchCorrection()
        out.srcWalls = sW.count; out.tgtWalls = tW.count
        // Compass certificate |C_A − C_B|.
        if let ca = link.sourceAnchorCompassHeading, let cb = link.targetAnchorCompassHeading {
            var d = abs(Float(ca) - Float(cb)).truncatingRemainder(dividingBy: 360); if d > 180 { d = 360 - d }
            out.compassDeg = d
        }

        // Global yaw = UNWEIGHTED median near-∥ orientation delta (correspondence-free).
        //
        // Area weighting was tried and measured worse (1.1° → 1.9° on the stairwell join), so this
        // stays unweighted and the dispersion gates below carry the safety. Two caveats on that
        // result, in case it's revisited: cross-pairs of PARALLEL walls give ~the same yaw by
        // design (that's the correspondence-free premise above), so amplifying them shouldn't bias
        // the estimate — the likelier culprit is that `matchAngleDeg` (25°, borrowed from
        // PlaneRegistration where it was tuned for correspondence MATCHING, not yaw ESTIMATION)
        // admits splayed wall families up to 25° off, whose garbage yaw area weighting then
        // amplifies. And the A/B was run before the `alignScore` sign bug was fixed, so it was
        // confounded. A retry would want a tighter Op-2-specific near-∥ gate (~10°, as the
        // ⊥ opposite-face test already uses) on top of the corrected sign.
        var yaws: [Float] = []
        var weighted: [(deg: Float, w: Float)] = []
        var farRejects = 0
        for s in sW { for t in tW {
            let nDot = simd_dot(s.normal, t.normal)
            guard acos(min(abs(nDot), 1)) * 180 / Float.pi < YawGate.nearParallelDeg else { continue }
            // Proximity gate (see `maxPairGapM`): closest approach of the two patches' bounding
            // spheres, so extent counts — a long wall paired near a short one's end reads as adjacent
            // rather than being judged on centre distance alone.
            let reachS = 0.5 * sqrt(s.width * s.width + s.height * s.height)
            let reachT = 0.5 * sqrt(t.width * t.width + t.height * t.height)
            guard max(0, simd_distance(s.center, t.center) - (reachS + reachT)) <= YawGate.maxPairGapM else {
                farRejects += 1
                continue
            }
            let nt = nDot < 0 ? -t.normal : t.normal
            let deg = atan2(s.normal.x * nt.z - s.normal.z * nt.x,
                            s.normal.x * nt.x + s.normal.z * nt.z) * 180 / Float.pi
            yaws.append(deg)
            // Area weight for the A/B below: min of the two, since a pair is only as trustworthy as
            // its WORSE normal — a large wall paired with a sliver is limited by the sliver. (Product
            // would double-count and over-amplify big×big pairs.)
            weighted.append((deg: deg, w: min(s.area, t.area)))
        }}
        out.nearParallel = yaws.count
        out.nearParallelFar = farRejects
        guard !yaws.isEmpty else { return out }
        yaws.sort()
        let plainYaw = yaws[yaws.count / 2]

        // AREA-WEIGHTED is the applied estimate; the plain median is kept for the log only.
        //
        // The first weighting attempt measured worse and was reverted, but that A/B was confounded: it
        // ran with the `alignScore` sign bug live and with the 25° near-∥ gate. With both fixed, a
        // device A/B over three joins was decisive — on the staircase join (truth −1.7°, hand-aligned
        // by making the TALL stairwell walls coplanar) the plain median read −1.1° with MAD 0.85°
        // while weighted read −1.87° with MAD 0.06°: error 0.6° → 0.17°, and the scatter collapsed,
        // i.e. the large walls agree tightly and every bit of the ±6° spread came from small
        // fragments. On the two already-good joins weighting moved the answer by 0.01° and 0.05°, so
        // there was no trade. (The original "1.9° wrong direction" reading was the right magnitude all
        // along — the sign bug made it look wrong.)
        let yawFix = Self.weightedMedian(weighted)
        out.yawPlainDeg = plainYaw

        // MAD (median absolute deviation) of the APPLIED estimate — dispersion diagnostic and gate.
        // Area-weighted to match the estimate it measures.
        let mad = Self.weightedMedian(weighted.map { (deg: abs($0.deg - yawFix), w: $0.w) })
        out.yawMADDeg = mad
        out.yawDeg = yawFix
        out.yawVoteMinDeg = yaws[0]                  // yaws is sorted
        out.yawVoteMaxDeg = yaws[yaws.count - 1]

        // Dispersion gate, three parts:
        //   1. enough pairs for a MAD to mean anything,
        //   2. an absolute ceiling on the spread,
        //   3. signal-to-noise — the estimate must stand clear of its own dispersion.
        //
        // Scoped to the YAW only — deliberately NOT an early return. ⊥ is an independent DOF: a join
        // can have an untrustworthy yaw and a perfectly good doorway gap, and at ~1° the de-yaw barely
        // moves the ⊥ measurement anyway. Returning here also silently disabled ⊥ (device-observed as
        // "⊥ n/a" on the staircase join, whose yaw was declined), which was a regression — before
        // these gates existed, ⊥ ran whenever the compass guardrail passed.
        let yawTrusted = yaws.count >= YawGate.minNearParallel
            && mad <= YawGate.maxYawMADDeg
            && abs(yawFix) >= YawGate.minMADRatio * max(mad, YawGate.madFloorDeg)

        // Compass guardrail — the plane yaw must agree with |C_A−C_B| (≤15°, coarse) or the whole fit
        // is untrusted (a flip): touch nothing. This one DOES bail outright, including ⊥ — a
        // relocalization flip invalidates the entire composed edge, not just its yaw. Fails closed
        // when no heading was recorded (compassDeg nil).
        let trustworthy = out.compassDeg.map { abs(abs(yawFix) - $0) <= 15 } ?? false
        guard trustworthy else { return out }

        // De-yaw spinner, reused for the yaw matrix and the ⊥ doorway measurement.
        func spinner(_ deg: Float) -> (SIMD3<Float>) -> SIMD3<Float> {
            let a = deg * Float.pi / 180, cA = cos(a), sA = sin(a)
            return { v in SIMD3(cA * v.x + sA * v.z, v.y, -sA * v.x + cA * v.z) }
        }
        // `yawFix` is ALREADY correctly signed: each pair's target normal is first flipped into
        // agreement with the source (`nt`, above), so the atan2 is the signed rotation carrying the
        // source orientation onto the target — sign included.
        //
        // This previously ran through an `alignScore` "tiebreak" that re-derived the sign by counting
        // opposite-facing pairs, on the belief the sign was convention-ambiguous. That was a bug, not
        // a safeguard: it selected `-yawFix` on `alignScore(-yawFix) >= alignScore(yawFix)`, so when
        // NEITHER sign found any opposite-facing pair — two rooms that don't physically overlap, e.g.
        // the cubicle join — the comparison was 0 >= 0 and it flipped a perfectly good sign
        // unconditionally. Device-confirmed: that join reported +1.5° and had -2.0° applied.
        //
        // Held at 0 when the dispersion gates distrust it, so the ⊥ measurement below proceeds in the
        // raw composed orientation rather than being skipped.
        let signedYaw = yawTrusted ? yawFix : 0
        let spin = spinner(signedYaw)

        // C_yaw about the pin — applied only when trusted AND clear of the noise floor.
        var C = matrix_identity_float4x4
        if yawTrusted, abs(yawFix) > YawGate.minApplyDeg {
            let a = signedYaw * Float.pi / 180, cA = cos(a), sA = sin(a)
            let R = simd_float4x4(SIMD4<Float>(cA, 0, -sA, 0), SIMD4<Float>(0, 1, 0, 0),
                                  SIMD4<Float>(sA, 0, cA, 0), SIMD4<Float>(0, 0, 0, 1))
            var Tp = matrix_identity_float4x4; Tp.columns.3 = SIMD4<Float>(anchor, 1)
            var Tn = matrix_identity_float4x4; Tn.columns.3 = SIMD4<Float>(-anchor, 1)
            C = Tp * R * Tn
            out.appliedYaw = true
            out.yawSigned = signedYaw
        }

        // ⊥ translation: doorway wall = de-yawed coplanar OPPOSITE pair with the MIN gap (not the
        // pin-nearest side wall). Gate: sane (<1 m) and clearly separated from the next.
        var opp: [(perp: Float, sp: Float, n: SIMD3<Float>, sc: SIMD3<Float>)] = []
        for s in sW { for t in tW {
            let tn = spin(t.normal); let nDot = simd_dot(s.normal, tn)
            guard acos(min(abs(nDot), 1)) * 180 / Float.pi < 10, nDot < 0 else { continue }
            let tc = anchor + spin(t.center - anchor)
            let signed = simd_dot(s.normal, tc - s.center)
            opp.append((abs(signed), signed, s.normal, s.center))
        }}
        opp.sort { $0.perp < $1.perp }
        if let d = opp.first { out.doorwayPerpCm = d.perp * 100 }
        if let d = opp.first, d.perp < 1.0, (opp.count < 2 || d.perp < 0.5 * opp[1].perp) {
            let thick: Float = 0.10
            // Room B belongs on the side of the doorway wall OPPOSITE the pin (room A), a nominal
            // thickness away. The pin fixes the side → convention-independent.
            let pinSide: Float = simd_dot(d.n, anchor - d.sc) >= 0 ? 1 : -1
            let delta = (-pinSide * thick) - d.sp        // scalar shift along the wall normal
            if abs(delta) < 1.0 {                          // sane correction magnitude
                var Tperp = matrix_identity_float4x4
                Tperp.columns.3 = SIMD4<Float>(delta * d.n, 1)
                C = Tperp * C                              // after the yaw (both source-canonical)
                out.perpCm = abs(delta) * 100
                out.appliedPerp = true
                out.transVec = delta * d.n
            }
        }
        out.transform = C
        return out
        #else
        return nil
        #endif
    }

    /// Solve the Op-2 auto correction for every edge in a component ONCE (this is the only part that
    /// reads canonical roomplans off disk). Pass the result into `placeScans` so live manual re-nudges
    /// recompose transforms purely in memory. Keyed by link id; a link absent from the map had no
    /// trusted correction (its edge keeps the raw pivot).
    @MainActor
    static func computeAutoCorrections(for edges: [StitchGraphEdge]) -> [UUID: StitchCorrection] {
        var out: [UUID: StitchCorrection] = [:]
        for e in edges { if let c = stitchCorrection(link: e.link) { out[e.link.id] = c } }
        return out
    }

    // MARK: - Export bake (make the correction authoritative, non-destructively)

    /// The SINGLE correction on a join as a `ManualNudge`: the stored nudge if set; else the solver's
    /// auto fix when "always autocorrect" is on and the join is untouched; else none. ("Autocorrect"
    /// / always-seeding in the UI transfers the auto fix INTO the stored nudge — this is the fallback
    /// so an as-yet-unopened render or an export still honors "always".) Reads disk only for the
    /// fallback (unset nudge + always on) — pass `precomputedAuto` (from `computeAutoCorrections`) to
    /// reuse an already-solved correction and avoid re-reading the canonical roomplans off disk.
    @MainActor
    static func effectiveNudge(for link: StitchLink, precomputedAuto: StitchCorrection? = nil) -> ManualNudge {
        if !link.manualNudge.isZero { return link.manualNudge }
        guard StitchPrefs.alwaysAutocorrect else { return .zero }
        if let precomputedAuto { return precomputedAuto.asNudge }
        #if canImport(RoomPlan)
        return stitchCorrection(link: link)?.asNudge ?? .zero
        #else
        return .zero
        #endif
    }

    /// The effective correction transform in the SOURCE scan's canonical frame — the single nudge
    /// applied about the T-composed canonical pin (`tSrc·sourceAnchor`), matching exactly what
    /// `placeScans` renders. Identity when none.
    @MainActor
    static func effectiveCorrection(for link: StitchLink) -> simd_float4x4 {
        let nudge = effectiveNudge(for: link)
        guard !nudge.isZero else { return matrix_identity_float4x4 }
        let tSrc = (link.sourceScan?.scanDirectory).flatMap { SaveRegistration.appliedTransform(scanDirectory: $0) } ?? matrix_identity_float4x4
        let pin = (tSrc * link.sourceAnchorMatrix).columns.3
        return nudge.matrix(pivot: SIMD3<Float>(pin.x, pin.y, pin.z))
    }

    /// The link's SOURCE anchor pose (raw frame, as stored) with the effective correction folded in,
    /// for EXPORT — so the serialized edge `bakedSource · inverse(target)` reproduces the corrected
    /// placement the combined render shows. Returns the untouched raw anchor when nothing applies.
    /// The correction lives in the source scan's CANONICAL frame, so it is conjugated by the source
    /// registration `T` back into the raw frame the DTO/world-map convention uses: `A' = inv(T)·C·T·A`.
    /// **Non-destructive** — the model's stored anchor matrices are never mutated; only the exported
    /// copy carries the correction.
    @MainActor
    static func bakedSourceAnchor(for link: StitchLink) -> simd_float4x4 {
        let cTotal = effectiveCorrection(for: link)
        guard cTotal != matrix_identity_float4x4 else { return link.sourceAnchorMatrix }
        let tSrc = (link.sourceScan?.scanDirectory).flatMap { SaveRegistration.appliedTransform(scanDirectory: $0) } ?? matrix_identity_float4x4
        return simd_inverse(tSrc) * cTotal * tSrc * link.sourceAnchorMatrix
    }

    // MARK: - Transform accumulation (for combined render)

    /// Computes, for one connected component, a placement transform per location that maps
    /// each scan's world-frame vertices into a single shared frame (the root's frame).
    ///
    /// For a link, a point in the **target** scan's *canonical* frame maps into the **source**
    /// scan's *canonical* frame by `R = (T_src·srcAnchor) · inverse(T_tgt·tgtAnchor)` — the anchors
    /// are the same physical pin, and each endpoint's raw→canonical registration `T` (identity when
    /// the scan saved raw / isn't processed) lifts its raw-frame anchor into the frame its baked
    /// `mesh.obj` now lives in (PR #28 moved geometry to the canonical frame but left anchor poses
    /// raw). Without the `T` composition the combined render seams by ~`T` (11–27 cm) on any stitch
    /// touching a registered or legacy scan. A spanning-tree BFS propagates transforms from the root
    /// outward; the root's identity thus *defines* the shared frame as its own canonical frame.
    /// - Parameter manualOverrides: in-progress adjuster values by link id — the SINGLE correction on
    ///   a join. The solver's "Autocorrect" seeds these values too, so there is NO separate auto
    ///   layer. Falls back to `effectiveNudge(for:)` (the link's stored nudge, or the auto fix when
    ///   "always autocorrect" is on and the join is untouched). Applied about the canonical pin: `r' = nudge · r`.
    /// - Parameter autoCorrections: pre-solved Op-2 corrections by link id (from
    ///   `computeAutoCorrections`). Passing them keeps the render path's disk read to that single
    ///   solve — the "always autocorrect" fallback reuses these instead of re-solving off disk.
    @MainActor
    static func placeScans(in component: [UUID],
                           edges componentEdges: [StitchGraphEdge],
                           manualOverrides: [UUID: ManualNudge] = [:],
                           autoCorrections: [UUID: StitchCorrection] = [:]) -> ComponentPlacement {
        // Pick a deterministic root (smallest UUID) so combined-render placements are
        // stable across runs — component element order comes from non-deterministic
        // Dictionary iteration and must not drive the accumulated transform frame.
        guard let root = component.min(by: { $0.uuidString < $1.uuidString }) else { return ComponentPlacement() }

        // Each endpoint's raw→canonical registration (PR #28): anchor poses are stored in the raw
        // capture frame, but the baked mesh.obj / roomplan the render draws are in the location's
        // canonical frame. Lift the anchors by `T` so every edge is canonical→canonical; identity
        // when a scan saved raw or isn't processed (self-heals mixed/legacy state — an unprocessed
        // endpoint has raw anchor + raw mesh, still consistent). Memoized: a scan can sit on several
        // incident edges, and this reads the on-disk sidecar.
        var tCache: [UUID: simd_float4x4] = [:]
        func appliedT(_ scan: CapturedScan?) -> simd_float4x4 {
            guard let scan else { return matrix_identity_float4x4 }
            if let cached = tCache[scan.id] { return cached }
            let t = SaveRegistration.appliedTransform(scanDirectory: scan.scanDirectory) ?? matrix_identity_float4x4
            tCache[scan.id] = t
            return t
        }

        // Undirected adjacency carrying the link and traversal direction.
        var adj: [UUID: [(neighbor: UUID, link: StitchLink, forward: Bool)]] = [:]
        for e in componentEdges {
            adj[e.from, default: []].append((e.to, e.link, true))
            adj[e.to, default: []].append((e.from, e.link, false))
        }

        var world: [UUID: simd_float4x4] = [root: matrix_identity_float4x4]
        var scanForLocation: [UUID: UUID] = [:]
        var parentLink: [UUID: UUID] = [:]   // locationId → the edge that placed it (root has none)

        // Seed the root's representative scan from any incident edge.
        if let first = adj[root]?.first,
           let seedScan = (first.forward ? first.link.sourceScan : first.link.targetScan) {
            scanForLocation[root] = canonicalScan(for: seedScan).id
        }

        // The relative edge target-canonical → source-canonical, with the Op-2 auto correction and
        // then the user's manual nudge composed IN (before the direction branch) so both BFS
        // directions inherit them and the child's whole subtree rides along. No disk / no prints.
        func correctedEdge(_ link: StitchLink) -> simd_float4x4 {
            let mSrc = appliedT(link.sourceScan) * link.sourceAnchorMatrix
            let mTgt = appliedT(link.targetScan) * link.targetAnchorMatrix
            var r = mSrc * simd_inverse(mTgt)
            // ONE correction: the join's nudge (the solver's "Autocorrect" seeds this same value —
            // no separate auto layer), pivoted about the canonical pin `mSrc.columns.3` (= tSrc·anchor,
            // the SAME pivot bakedSourceAnchor uses). In-flight overrides win; otherwise
            // the stored nudge, or the auto fix when "always autocorrect" seeds an untouched join.
            let nudge = manualOverrides[link.id] ?? effectiveNudge(for: link, precomputedAuto: autoCorrections[link.id])
            if !nudge.isZero {
                let pin = mSrc.columns.3
                r = nudge.matrix(pivot: SIMD3<Float>(pin.x, pin.y, pin.z)) * r
            }
            return r
        }

        var queue: [UUID] = [root]
        var visited: Set<UUID> = [root]
        var head = 0
        while head < queue.count {
            let u = queue[head]; head += 1
            let worldU = world[u] ?? matrix_identity_float4x4
            for step in adj[u] ?? [] where !visited.contains(step.neighbor) {
                visited.insert(step.neighbor)
                let r = correctedEdge(step.link)
                if step.forward {
                    // u is the source, neighbor is the target.
                    world[step.neighbor] = worldU * r
                    if let s = step.link.targetScan { scanForLocation[step.neighbor] = canonicalScan(for: s).id }
                } else {
                    // u is the target, neighbor is the source.
                    world[step.neighbor] = worldU * simd_inverse(r)
                    if let s = step.link.sourceScan { scanForLocation[step.neighbor] = canonicalScan(for: s).id }
                }
                parentLink[step.neighbor] = step.link.id
                queue.append(step.neighbor)
            }
        }

        let scans: [PlacedScan] = component.compactMap { locId in
            guard let t = world[locId], let scanId = scanForLocation[locId] else { return nil }
            return PlacedScan(locationId: locId, scanId: scanId, transform: t, parentLinkId: parentLink[locId])
        }

        // Stitch-pin markers: every edge's shared pin, taken on the SOURCE side and mapped into the
        // shared frame. Corrections move the TARGET geometry to meet this point, so the source-side
        // pin is the stable "join" location to mark.
        var stitchPoints: [StitchPoint] = []
        for e in componentEdges {
            guard let srcLocId = e.link.sourceScan?.location?.id, let wS = world[srcLocId] else { continue }
            let mSrc = appliedT(e.link.sourceScan) * e.link.sourceAnchorMatrix
            let p = wS * mSrc.columns.3
            stitchPoints.append(StitchPoint(
                id: e.link.id, position: SIMD3<Float>(p.x, p.y, p.z),
                sourceName: e.link.sourceScan?.location?.name ?? "?",
                targetName: e.link.targetScan?.location?.name ?? "?"))
        }

        return ComponentPlacement(scans: scans, stitchPoints: stitchPoints)
    }
}
