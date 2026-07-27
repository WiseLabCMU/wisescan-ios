import Foundation
import SwiftData
import simd

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
        let yaw = String(format: "yaw %+.1f°→%@", c.yawDeg, c.appliedYaw ? "applied" : "held")
        let perp = c.appliedPerp ? String(format: "⊥ %.0fcm→applied", c.perpCm)
                                 : (c.doorwayPerpCm.map { String(format: "⊥ %.0fcm→held", $0) } ?? "⊥ n/a")
        print("[StitchResidual] \(src) ↔ \(tgt): \(yaw), \(perp) | compass \(compass) | walls \(c.srcWalls)/\(c.tgtWalls) near-∥ \(c.nearParallel)")
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
        let sW = SaveRegistration.canonicalFramePlanes(scanDirectory: src.scanDirectory).filter { $0.category == .wall }
        let tW = SaveRegistration.canonicalFramePlanes(scanDirectory: tgt.scanDirectory)
            .filter { $0.category == .wall }.map { PlaneRegistration.applying(r, to: $0) }
        guard !sW.isEmpty, !tW.isEmpty else { return nil }

        var out = StitchCorrection()
        out.srcWalls = sW.count; out.tgtWalls = tW.count
        // Compass certificate |C_A − C_B|.
        if let ca = link.sourceAnchorCompassHeading, let cb = link.targetAnchorCompassHeading {
            var d = abs(Float(ca) - Float(cb)).truncatingRemainder(dividingBy: 360); if d > 180 { d = 360 - d }
            out.compassDeg = d
        }

        // Global yaw = median near-∥ orientation delta (correspondence-free).
        var yaws: [Float] = []
        for s in sW { for t in tW {
            let nDot = simd_dot(s.normal, t.normal)
            guard acos(min(abs(nDot), 1)) * 180 / Float.pi < PlaneRegistration.matchAngleDeg else { continue }
            let nt = nDot < 0 ? -t.normal : t.normal
            yaws.append(atan2(s.normal.x * nt.z - s.normal.z * nt.x, s.normal.x * nt.x + s.normal.z * nt.z) * 180 / Float.pi)
        }}
        out.nearParallel = yaws.count
        guard !yaws.isEmpty else { return out }
        let yawFix = yaws.sorted()[yaws.count / 2]
        out.yawDeg = yawFix

        // Compass guardrail — the plane yaw must agree with |C_A−C_B| (≤15°, coarse) or the whole fit
        // is untrusted (a flip): touch nothing.
        let trustworthy = out.compassDeg.map { abs(abs(yawFix) - $0) <= 15 } ?? false
        guard trustworthy else { return out }

        // De-yaw sign is convention-ambiguous → pick the sign that ALIGNS opposite faces. Reused for
        // both the yaw matrix and the ⊥ measurement.
        func spinner(_ deg: Float) -> (SIMD3<Float>) -> SIMD3<Float> {
            let a = deg * Float.pi / 180, cA = cos(a), sA = sin(a)
            return { v in SIMD3(cA * v.x + sA * v.z, v.y, -sA * v.x + cA * v.z) }
        }
        func alignScore(_ deg: Float) -> Int {
            let sp = spinner(deg); var n = 0
            for s in sW { for t in tW {
                let nDot = simd_dot(s.normal, sp(t.normal))
                if acos(min(abs(nDot), 1)) * 180 / Float.pi < 10, nDot < 0 { n += 1 }
            }}
            return n
        }
        let signedYaw = alignScore(-yawFix) >= alignScore(yawFix) ? -yawFix : yawFix
        let spin = spinner(signedYaw)

        // C_yaw about the pin — applied only when the yaw is beyond noise (>1°).
        var C = matrix_identity_float4x4
        if abs(yawFix) > 1 {
            let a = signedYaw * Float.pi / 180, cA = cos(a), sA = sin(a)
            let R = simd_float4x4(SIMD4<Float>(cA, 0, -sA, 0), SIMD4<Float>(0, 1, 0, 0),
                                  SIMD4<Float>(sA, 0, cA, 0), SIMD4<Float>(0, 0, 0, 1))
            var Tp = matrix_identity_float4x4; Tp.columns.3 = SIMD4<Float>(anchor, 1)
            var Tn = matrix_identity_float4x4; Tn.columns.3 = SIMD4<Float>(-anchor, 1)
            C = Tp * R * Tn
            out.appliedYaw = true
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

    /// The effective correction for a link in the SOURCE scan's canonical frame — the auto
    /// correction (only when `autoCorrectEffective`) with the manual nudge composed on top, matching
    /// exactly what `placeScans` renders. Identity when nothing applies. Reads disk.
    @MainActor
    static func effectiveCorrection(for link: StitchLink) -> simd_float4x4 {
        let tSrc = (link.sourceScan?.scanDirectory).flatMap { SaveRegistration.appliedTransform(scanDirectory: $0) } ?? matrix_identity_float4x4
        let mSrc = tSrc * link.sourceAnchorMatrix
        var autoC = matrix_identity_float4x4
        #if canImport(RoomPlan)
        if link.autoCorrectEffective { autoC = stitchCorrection(link: link)?.transform ?? matrix_identity_float4x4 }
        #endif
        var cTotal = autoC
        let nudge = link.manualNudge
        if !nudge.isZero {
            let pin = autoC * mSrc.columns.3
            cTotal = nudge.matrix(pivot: SIMD3<Float>(pin.x, pin.y, pin.z)) * autoC
        }
        return cTotal
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
    /// - Parameters:
    ///   - autoCorrections: pre-solved Op-2 corrections (`computeAutoCorrections`). When `nil`,
    ///     solved here (reads disk). Pass the cache so live manual re-nudges stay in-memory.
    ///   - manualOverrides: in-progress adjuster values by link id; falls back to each link's stored
    ///     `manualNudge`. Composed on top of the auto seat: `r' = manual · C_auto · r`.
    /// - Parameters:
    ///   - autoApplied: per-link opt-in for the auto correction (in-flight adjuster state); falls
    ///     back to each link's `autoCorrectEffective` (its override, else the global pref). Auto no
    ///     longer applies unless effectively true — the render shows the raw pivot by default.
    @MainActor
    static func placeScans(in component: [UUID],
                           edges componentEdges: [StitchGraphEdge],
                           autoCorrections: [UUID: StitchCorrection]? = nil,
                           manualOverrides: [UUID: ManualNudge] = [:],
                           autoApplied: [UUID: Bool] = [:]) -> ComponentPlacement {
        // Pick a deterministic root (smallest UUID) so combined-render placements are
        // stable across runs — component element order comes from non-deterministic
        // Dictionary iteration and must not drive the accumulated transform frame.
        guard let root = component.min(by: { $0.uuidString < $1.uuidString }) else { return ComponentPlacement() }
        let autos = autoCorrections ?? computeAutoCorrections(for: componentEdges)

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
           let seedScanId = (first.forward ? first.link.sourceScan?.id : first.link.targetScan?.id) {
            scanForLocation[root] = seedScanId
        }

        // The relative edge target-canonical → source-canonical, with the Op-2 auto correction and
        // then the user's manual nudge composed IN (before the direction branch) so both BFS
        // directions inherit them and the child's whole subtree rides along. No disk / no prints.
        func correctedEdge(_ link: StitchLink) -> simd_float4x4 {
            let mSrc = appliedT(link.sourceScan) * link.sourceAnchorMatrix
            let mTgt = appliedT(link.targetScan) * link.targetAnchorMatrix
            var r = mSrc * simd_inverse(mTgt)
            let useAuto = autoApplied[link.id] ?? link.autoCorrectEffective
            let autoC = useAuto ? (autos[link.id]?.transform ?? matrix_identity_float4x4) : matrix_identity_float4x4
            r = autoC * r
            let nudge = manualOverrides[link.id] ?? link.manualNudge
            if !nudge.isZero {
                // Pivot the manual yaw about the pin AFTER the auto correction (source-canonical).
                let pin = autoC * mSrc.columns.3
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
                    if let sid = step.link.targetScan?.id { scanForLocation[step.neighbor] = sid }
                } else {
                    // u is the target, neighbor is the source.
                    world[step.neighbor] = worldU * simd_inverse(r)
                    if let sid = step.link.sourceScan?.id { scanForLocation[step.neighbor] = sid }
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
