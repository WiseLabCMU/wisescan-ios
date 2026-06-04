import SwiftUI
import simd

// MARK: - Stitch Graph View
//
// Toolbar-toggleable alternative to the grid in ScansListView. Renders stitched
// locations as a directed graph: one node per location, arrows source → target.
// Each connected cluster offers a "Render together" action that composes the meshes.

struct StitchGraphView: View {
    let locations: [ScanLocation]
    /// Owned by the parent (ScansListView) so the cover presents from the NavigationStack root.
    @Binding var renderRequest: ComponentRenderRequest?

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
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48))
                .foregroundColor(.gray)
            Text("No linked scans")
                .font(.headline)
                .foregroundColor(.gray)
            Text("Capture an adjacent space to link scans together")
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
        for (i, placed) in placements.enumerated() {
            guard let scan = scanLookup[placed.scanId] else { continue }
            let name = nodesById[placed.locationId]?.location.name ?? scan.name
            items.append(CombinedMeshItem(
                id: placed.scanId,
                name: name,
                meshURL: scan.meshFileURL,
                colorsURL: scan.colorsFileURL,
                transform: placed.transform,
                tint: CombinedMeshItem.palette[i % CombinedMeshItem.palette.count]
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .foregroundColor(.green)
                    Text("\(nodes.count) linked \(nodes.count == 1 ? "map" : "maps")")
                        .foregroundColor(.white)
                }
                .font(.headline)

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
                .accessibilityHint("Shows all linked maps in a single combined view")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { onRender() }

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
                        drawArrow(ctx: &ctx, fromCenter: from, toCenter: to)
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height)

                // Nodes
                ForEach(nodes) { node in
                    NavigationLink(value: node.location) {
                        CompactLocationTile(location: node.location)
                            .frame(width: nodeWidth, height: nodeHeight)
                    }
                    .buttonStyle(.plain)
                    .position(center(of: node))
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

    /// Point on a node's rectangle boundary along the ray from its center toward `other`.
    private func boundaryPoint(from center: CGPoint, toward other: CGPoint) -> CGPoint {
        let dx = other.x - center.x, dy = other.y - center.y
        let hw = nodeWidth / 2, hh = nodeHeight / 2
        let sx = dx == 0 ? CGFloat.greatestFiniteMagnitude : hw / abs(dx)
        let sy = dy == 0 ? CGFloat.greatestFiniteMagnitude : hh / abs(dy)
        let s = min(sx, sy)
        return CGPoint(x: center.x + dx * s, y: center.y + dy * s)
    }

    /// Draws a directed edge with an arrowhead, stopping exactly at each node's rectangle edge.
    private func drawArrow(ctx: inout GraphicsContext, fromCenter: CGPoint, toCenter: CGPoint) {
        // Meet the rectangle boundaries; pull the head a few points off the target tile so the
        // arrowhead always sits in open space and is never clipped by the node drawn on top.
        let start = boundaryPoint(from: fromCenter, toward: toCenter)
        let rawEnd = boundaryPoint(from: toCenter, toward: fromCenter)
        let rawDx = rawEnd.x - start.x, rawDy = rawEnd.y - start.y
        let rawLen = max(hypot(rawDx, rawDy), 0.001)
        let ux = rawDx / rawLen, uy = rawDy / rawLen
        let gap: CGFloat = 5
        let end = CGPoint(x: rawEnd.x - ux * gap, y: rawEnd.y - uy * gap)

        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        ctx.stroke(line, with: .color(.cyan.opacity(0.7)), lineWidth: 2)

        // Arrowhead
        let headLen: CGFloat = 12
        let angle = atan2(uy, ux)
        let a1 = angle + .pi * 0.85
        let a2 = angle - .pi * 0.85
        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x + cos(a1) * headLen, y: end.y + sin(a1) * headLen))
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x + cos(a2) * headLen, y: end.y + sin(a2) * headLen))
        ctx.stroke(head, with: .color(.cyan.opacity(0.9)), lineWidth: 2)
    }
}

// MARK: - Compact node tile

private struct CompactLocationTile: View {
    let location: ScanLocation
    @State private var thumbnail: UIImage?

    private var latestScan: CapturedScan? {
        location.scans.sorted(by: { $0.capturedAt > $1.capturedAt }).first
    }

    var body: some View {
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
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12), lineWidth: 1))
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
