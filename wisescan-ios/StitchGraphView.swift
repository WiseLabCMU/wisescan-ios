import SwiftUI
import SwiftData
import simd

// MARK: - Stitch Graph View
//
// Toolbar-toggleable alternative to the grid in ScansListView. Renders stitched
// locations as an undirected graph: one node per location, a plain connector line
// between linked locations (links are bidirectional, so there is no direction to show).
// Each connected cluster offers a "Render together" action that composes the meshes.
// In edit mode, nodes become selectable for bulk operations; cluster headers gain
// a "Select All / Deselect" shortcut.

struct StitchGraphView: View {
    let locations: [ScanLocation]
    /// Owned by the parent (ScansListView) so the cover presents from the NavigationStack root.
    @Binding var renderRequest: ComponentRenderRequest?
    /// Shared edit-mode state from ScansListView (same bindings drive the grid view too).
    @Binding var isEditing: Bool
    @Binding var selectedLocations: Set<PersistentIdentifier>
    /// Set of PersistentIdentifiers for locations visible as graph nodes. Updated when the graph
    /// is rebuilt, so the parent can scope "Select All" to only the visible locations.
    @Binding var visibleLocationIds: Set<PersistentIdentifier>

    @State private var graph: StitchGraph?

    /// scanId → CapturedScan, for resolving mesh files during combined render.
    private var scanLookup: [UUID: CapturedScan] {
        Dictionary(locations.flatMap { $0.scans }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        ZStack {
            if let graph {
                if graph.isEmpty {
                    emptyState
                } else {
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 28) {
                            ForEach(Array(graph.components.enumerated()), id: \.offset) { _, component in
                                ClusterView(
                                    component: component,
                                    graph: graph,
                                    isEditing: isEditing,
                                    selectedLocations: $selectedLocations,
                                    onRender: { presentRender(for: component) }
                                )
                            }
                        }
                        .padding()
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: locations.map(\.id)) {
            graph = await StitchGraphBuilder.build(from: locations)
            // Publish which locations are visible as graph nodes so the parent's
            // "Select All" can scope to only visible items in graph mode.
            if let graph {
                let nodeLocations = graph.nodes.map { $0.location.persistentModelID }
                visibleLocationIds = Set(nodeLocations)
            } else {
                visibleLocationIds = []
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48))
                .foregroundColor(.gray)
            Text("No connected maps")
                .font(.headline)
                .foregroundColor(.gray)
            Text("Capture an adjacent space to connect maps together")
                .font(.caption)
                .foregroundColor(.gray.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 60)
    }

    private func presentRender(for component: [UUID]) {
        let placements = StitchGraphBuilder.placeScans(in: component, edges: graph?.edges(in: component) ?? [])
        let nodesById = graph?.nodesById ?? [:]
        var items: [CombinedMeshItem] = []
        for (idx, placed) in placements.enumerated() {
            guard let scan = scanLookup[placed.scanId] else { continue }
            let name = nodesById[placed.locationId]?.location.name ?? scan.name
            items.append(CombinedMeshItem(
                id: placed.scanId,
                name: name,
                meshURL: scan.meshFileURL,
                colorsURL: scan.colorsFileURL,
                transform: placed.transform,
                tint: CombinedMeshItem.palette[idx % CombinedMeshItem.palette.count]
            ))
        }
        let title = items.count == 1 ? (items.first?.name ?? "Combined") : "\(items.count) Maps"
        renderRequest = ComponentRenderRequest(title: title, items: items)
    }
}

struct ComponentRenderRequest: Identifiable {
    let id = UUID()
    let title: String
    let items: [CombinedMeshItem]
}

// MARK: - Cluster (one connected component)

private struct ClusterView: View {
    let component: [UUID]
    let graph: StitchGraph
    let isEditing: Bool
    @Binding var selectedLocations: Set<PersistentIdentifier>
    let onRender: () -> Void

    // Layout metrics
    private let nodeWidth: CGFloat = 150
    private let nodeHeight: CGFloat = 104
    private let colSpacing: CGFloat = 196
    private let rowSpacing: CGFloat = 140

    private var nodes: [StitchGraphNode] {
        let set = Set(component)
        return graph.nodes.filter { set.contains($0.id) }
    }
    private var edges: [StitchGraphEdge] { graph.edges(in: component) }

    private var maxLevel: Int { nodes.map(\.level).max() ?? 0 }
    private var maxOrder: Int { nodes.map(\.order).max() ?? 0 }

    private var canvasSize: CGSize {
        CGSize(
            width: CGFloat(maxLevel) * colSpacing + nodeWidth,
            height: CGFloat(maxOrder) * rowSpacing + nodeHeight
        )
    }

    private func center(of node: StitchGraphNode) -> CGPoint {
        CGPoint(
            x: CGFloat(node.level) * colSpacing + nodeWidth / 2,
            y: CGFloat(node.order) * rowSpacing + nodeHeight / 2
        )
    }

    private var positions: [UUID: CGPoint] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, center(of: $0)) })
    }

    /// Whether every location in this cluster is currently selected.
    private var allClusterSelected: Bool {
        let ids = nodes.map { $0.location.persistentModelID }
        return !ids.isEmpty && ids.allSatisfy { selectedLocations.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .foregroundColor(.green)
                    Text("\(nodes.count) connected \(nodes.count == 1 ? "map" : "maps")")
                        .foregroundColor(.white)
                }
                .font(.headline)

                if isEditing {
                    // Cluster-level Select All / Deselect shortcut
                    Button(action: toggleClusterSelection) {
                        HStack(spacing: 6) {
                            Image(systemName: allClusterSelected
                                  ? "checkmark.circle.fill" : "circle")
                            Text(allClusterSelected ? "Deselect Cluster" : "Select Cluster")
                        }
                        .font(.subheadline)
                        .foregroundColor(allClusterSelected ? .cyan : .gray)
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "cube.transparent")
                        Text("Render together")
                    }
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .foregroundColor(.cyan)
                    .background(Color.cyan.opacity(0.2))
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                    // A plain Button's tap competes with the two-axis ScrollView's pan and is
                    // dropped most of the time; a simultaneous tap gesture is recognized reliably.
                    .simultaneousGesture(TapGesture().onEnded { onRender() })
                    // The gesture above is invisible to assistive tech, so expose this as a button
                    // with an explicit action for VoiceOver / Switch Control without disturbing the
                    // gesture path used for touch.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Render together")
                    .accessibilityHint("Shows all connected maps in a single combined view")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { onRender() }
                }

                Spacer(minLength: 0)
            }
            // Pin the header to the visible width so the button never scrolls off-screen
            // when the canvas is wider than the screen.
            .frame(width: max(canvasSize.width, UIScreen.main.bounds.width - 60), alignment: .leading)

            // Breathing room between the tappable header and the node canvas so taps on the
            // header / render button don't accidentally land on the map tiles below.
            Divider()
                .overlay(Color.white.opacity(0.1))
                .padding(.top, 6)
                .padding(.bottom, 18)

            ZStack(alignment: .topLeading) {
                // Edges
                Canvas { ctx, _ in
                    let pos = positions
                    for edge in edges {
                        guard let from = pos[edge.from], let to = pos[edge.to] else { continue }
                        drawEdge(ctx: &ctx, fromCenter: from, toCenter: to)
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)

                // Nodes
                ForEach(nodes) { node in
                    let isSelected = selectedLocations.contains(node.location.persistentModelID)

                    if isEditing {
                        // In edit mode: tap toggles selection instead of navigating
                        CompactLocationTile(location: node.location, isEditing: true, isSelected: isSelected)
                            .frame(width: nodeWidth, height: nodeHeight)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let pid = node.location.persistentModelID
                                if selectedLocations.contains(pid) {
                                    selectedLocations.remove(pid)
                                } else {
                                    selectedLocations.insert(pid)
                                }
                            }
                            .position(center(of: node))
                    } else {
                        NavigationLink(value: node.location) {
                            CompactLocationTile(location: node.location, isEditing: false, isSelected: false)
                                .frame(width: nodeWidth, height: nodeHeight)
                        }
                        .buttonStyle(.plain)
                        .position(center(of: node))
                    }
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.green.opacity(0.25), lineWidth: 1))
        )
    }

    private func toggleClusterSelection() {
        let ids = nodes.map { $0.location.persistentModelID }
        if allClusterSelected {
            for pid in ids { selectedLocations.remove(pid) }
        } else {
            for pid in ids { selectedLocations.insert(pid) }
        }
    }

    /// Point on a node's rectangle boundary along the ray from its center toward `other`.
    private func boundaryPoint(from center: CGPoint, toward other: CGPoint) -> CGPoint {
        let dx = other.x - center.x, dy = other.y - center.y
        let hw = nodeWidth / 2, hh = nodeHeight / 2
        let sx = dx == 0 ? CGFloat.greatestFiniteMagnitude : hw / abs(dx)
        let sy = dy == 0 ? CGFloat.greatestFiniteMagnitude : hh / abs(dy)
        let s = min(sx, sy)
        return CGPoint(x: center.x + dx * s, y: center.y + dy * s)
    }

    /// Draws an undirected connector line between two nodes, stopping exactly at each node's
    /// rectangle edge (links are bidirectional, so there is no arrowhead).
    private func drawEdge(ctx: inout GraphicsContext, fromCenter: CGPoint, toCenter: CGPoint) {
        // Meet the rectangle boundaries; pull each end a few points off the tile so the line
        // sits in open space and is never clipped by the node drawn on top.
        let rawStart = boundaryPoint(from: fromCenter, toward: toCenter)
        let rawEnd = boundaryPoint(from: toCenter, toward: fromCenter)
        let rawDx = rawEnd.x - rawStart.x, rawDy = rawEnd.y - rawStart.y
        let rawLen = max(hypot(rawDx, rawDy), 0.001)
        let ux = rawDx / rawLen, uy = rawDy / rawLen
        let gap: CGFloat = 5
        let start = CGPoint(x: rawStart.x + ux * gap, y: rawStart.y + uy * gap)
        let end = CGPoint(x: rawEnd.x - ux * gap, y: rawEnd.y - uy * gap)

        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        ctx.stroke(line, with: .color(.cyan.opacity(0.7)), lineWidth: 2)
    }
}

// MARK: - Compact node tile

private struct CompactLocationTile: View {
    let location: ScanLocation
    var isEditing: Bool = false
    var isSelected: Bool = false
    @State private var thumbnail: UIImage?

    private var latestScan: CapturedScan? {
        location.scans.max(by: { $0.capturedAt < $1.capturedAt })
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                ZStack {
                    Color.gray.opacity(0.2)
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo")
                            .foregroundColor(.gray.opacity(0.5))
                    }
                }
                .frame(height: 64)
                .clipped()

                VStack(alignment: .leading, spacing: 2) {
                    Text(location.name)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text("\(location.scans.count) scan\(location.scans.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isEditing && isSelected ? Color.cyan : Color.white.opacity(0.12),
                            lineWidth: isEditing && isSelected ? 2 : 1)
            )
            .opacity(isEditing ? 0.85 : 1.0)

            if isEditing {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(isSelected ? .cyan : .gray)
                    .background(Circle().fill(Color.black.opacity(0.6)).padding(-2))
                    .offset(x: 6, y: -6)
            }
        }
        .task(id: location.updatedAt) {
            guard let latest = latestScan else { thumbnail = nil; return }
            let fm = FileManager.default
            let url = [latest.modelPreviewURL, latest.thumbnailURL]
                .first(where: { fm.fileExists(atPath: $0.path) }) ?? latest.thumbnailURL
            thumbnail = await Task.detached(priority: .utility) {
                guard FileManager.default.fileExists(atPath: url.path),
                      let data = try? Data(contentsOf: url) else { return nil as UIImage? }
                return UIImage(data: data)
            }.value
        }
    }
}
