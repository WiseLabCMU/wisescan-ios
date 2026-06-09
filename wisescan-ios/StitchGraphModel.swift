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
        var links: [StitchLink] = []
        var seenLinks = Set<UUID>()
        for loc in locations {
            for scan in loc.scans {
                for link in (scan.linksAsA + scan.linksAsB) where seenLinks.insert(link.id).inserted {
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

    // MARK: - Transform accumulation (for combined render)

    /// Computes, for one connected component, a placement transform per location that maps
    /// each scan's world-frame vertices into a single shared frame (the root's frame).
    ///
    /// For a link, a point in the **target** scan's frame maps into the **source** frame by
    /// `R = sourceAnchorTransform · inverse(targetAnchorTransform)` (the anchors are the same
    /// physical pin). A spanning-tree BFS propagates transforms from the root outward.
    @MainActor
    static func placeScans(in component: [UUID], edges componentEdges: [StitchGraphEdge]) -> [PlacedScan] {
        // Pick a deterministic root (smallest UUID) so combined-render placements are
        // stable across runs — component element order comes from non-deterministic
        // Dictionary iteration and must not drive the accumulated transform frame.
        guard let root = component.min(by: { $0.uuidString < $1.uuidString }) else { return [] }

        // Undirected adjacency carrying the link and traversal direction.
        var adj: [UUID: [(neighbor: UUID, link: StitchLink, forward: Bool)]] = [:]
        for e in componentEdges {
            adj[e.from, default: []].append((e.to, e.link, true))
            adj[e.to, default: []].append((e.from, e.link, false))
        }

        var world: [UUID: simd_float4x4] = [root: matrix_identity_float4x4]
        var scanForLocation: [UUID: UUID] = [:]

        // Seed the root's representative scan from any incident edge.
        if let first = adj[root]?.first,
           let seedScanId = (first.forward ? first.link.sourceScan?.id : first.link.targetScan?.id) {
            scanForLocation[root] = seedScanId
        }

        var queue: [UUID] = [root]
        var visited: Set<UUID> = [root]
        var head = 0
        while head < queue.count {
            let u = queue[head]; head += 1
            let worldU = world[u] ?? matrix_identity_float4x4
            for step in adj[u] ?? [] where !visited.contains(step.neighbor) {
                visited.insert(step.neighbor)
                let mSrc = step.link.sourceAnchorMatrix
                let mTgt = step.link.targetAnchorMatrix
                let r = mSrc * simd_inverse(mTgt)   // maps target-frame → source-frame
                if step.forward {
                    // u is the source, neighbor is the target.
                    world[step.neighbor] = worldU * r
                    if let sid = step.link.targetScan?.id { scanForLocation[step.neighbor] = sid }
                } else {
                    // u is the target, neighbor is the source.
                    world[step.neighbor] = worldU * simd_inverse(r)
                    if let sid = step.link.sourceScan?.id { scanForLocation[step.neighbor] = sid }
                }
                queue.append(step.neighbor)
            }
        }

        return component.compactMap { locId in
            guard let t = world[locId], let scanId = scanForLocation[locId] else { return nil }
            return PlacedScan(locationId: locId, scanId: scanId, transform: t)
        }
    }
}
