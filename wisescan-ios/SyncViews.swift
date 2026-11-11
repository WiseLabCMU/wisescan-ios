import SwiftData
import SwiftUI

// MARK: - The sync badge (docs/design/sync-bundle.md, "The sync indicator")

/// How much of a space the lab server holds, on its tile and its graph tile: nothing (no icon),
/// its map (the JSON and the RoomPlan preview: an outline cloud), or everything (every scan's
/// bundle, extracted: a green check). While a bundle goes up or is unpacked, an upload arrow; when
/// one failed, a yellow warning. Only what the server confirmed counts.
struct SyncBadge: View {
    let location: ScanLocation
    /// The graph tile's smaller size.
    var compact = false

    var body: some View {
        if let look = Self.look(BundleSync.shared.spaceState(location)) {
            Self.icon(look, compact: compact)
        }
    }

    static func icon(_ look: (symbol: String, color: Color, label: String), compact: Bool) -> some View {
        Image(systemName: look.symbol)
            .font(compact ? .system(size: 10) : .caption)
            .foregroundColor(look.color)
            .padding(compact ? 4 : 6)
            .background(Color.black.opacity(0.5))
            .clipShape(Circle())
            .padding(compact ? 4 : 8)
            .accessibilityLabel(look.label)
    }

    static func look(_ state: BundleSync.SpaceState) -> (symbol: String, color: Color, label: String)? {
        switch state {
        case .off: return nil
        case .map: return ("icloud", .white.opacity(0.85), "The lab server has this space's map")
        case .everything: return ("checkmark.icloud.fill", .green, "The lab server has everything in this space")
        case .uploading: return ("icloud.and.arrow.up", .cyan, "Sending this space's scans to the lab server")
        case .failed: return ("exclamationmark.icloud", .yellow, "A scan of this space didn't reach the lab server")
        }
    }
}

/// A scan card's one sync line: Map only, Everything, Uploading 40%, Waiting for Wi-Fi, Not
/// selected, or why it failed. Nothing when its space isn't synced.
struct SyncLine: View {
    let scan: CapturedScan

    var body: some View {
        if let line = BundleSync.shared.line(for: scan) {
            HStack(spacing: 4) {
                Image(systemName: line.failed ? "exclamationmark.icloud" : "icloud")
                Text(line.text).lineLimit(2)
            }
            .font(.caption2)
            .foregroundColor(line.failed ? .yellow : .green.opacity(0.8))
        }
    }
}

// MARK: - The pending checklist

/// Every synced scan whose bundle the lab server doesn't hold yet, all selected by default: the
/// user decides what goes, and whether it waits for Wi-Fi. A deselected scan waits until selected
/// again; a new scan joins selected. A bundle the server couldn't unpack waits for Retry.
struct PendingBundlesView: View {
    @Query(sort: \ScanLocation.name) private var locations: [ScanLocation]
    @AppStorage(AppConstants.Key.controlPlaneBundlesWifiOnly) private var wifiOnly = AppConstants.controlPlaneBundlesWifiOnly

    var body: some View {
        let bundles = BundleSync.shared
        let pending = pendingBySpace()
        List {
            Section {
                Toggle("Upload data bundles only on Wi-Fi", isOn: $wifiOnly)
                    .onChange(of: wifiOnly) { _, _ in bundles.wifiOnlyChanged() }
            } footer: {
                Text("A scan's bundle is everything it holds: its photos, depth, mesh and room layout, " +
                     "hundreds of MB or more. The map itself and its RoomPlan preview go on any network.")
            }
            if pending.isEmpty {
                Section {
                    Text("Nothing waiting: the lab server has every synced scan's bundle, or none is processed yet.")
                        .foregroundColor(.secondary)
                }
            }
            ForEach(pending) { space in
                Section(space.name) {
                    ForEach(space.scans, id: \.self) { scan in
                        PendingBundleRow(scan: scan)
                    }
                }
            }
        }
        .navigationTitle("Pending Bundles")
    }

    private struct PendingSpace: Identifiable {
        let id: UUID
        let name: String
        let scans: [CapturedScan]
    }

    /// Scans of confirmed spaces the server wants a bundle of, or failed to unpack, oldest first.
    private func pendingBySpace() -> [PendingSpace] {
        let bundles = BundleSync.shared
        let confirmed = ControlPlaneSync.shared.confirmedSpaces
        return locations.compactMap { location -> PendingSpace? in
            let spaceId: UUID = location.id
            guard confirmed.contains(spaceId) else { return nil }
            let scans = location.scans.sorted(by: CapturedScan.canonicalOrder).filter { scan in
                let scanId: UUID = scan.id
                let state = bundles.remote[scanId]
                return state?.wanted == true || state?.state == "failed" || bundles.active?.scanId == scanId
            }
            return scans.isEmpty ? nil : PendingSpace(id: spaceId, name: location.name, scans: scans)
        }
    }
}

private struct PendingBundleRow: View {
    let scan: CapturedScan

    var body: some View {
        let bundles = BundleSync.shared
        let failed = bundles.remote[scan.id]?.state == "failed"
        HStack {
            Toggle(isOn: Binding(get: { bundles.isSelected(scan.id) },
                                 set: { bundles.setSelected(scan.id, $0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scan.name)
                    SyncLine(scan: scan)
                }
            }
            .disabled(bundles.active?.scanId == scan.id)
            if failed || bundles.failures[scan.id] != nil {
                Button("Retry") { bundles.retry(scan.id) }
                    .buttonStyle(.borderless)
            }
        }
    }
}

#Preview("Sync badges") {
    // Every state's look. A live SyncBadge shows only what BundleSync knows, which in a preview is
    // nothing (no lab server is set).
    let looks = [BundleSync.SpaceState.map, .everything, .uploading, .failed].compactMap(SyncBadge.look)
    return HStack {
        ForEach(looks.indices, id: \.self) { index in
            SyncBadge.icon(looks[index], compact: false)
            SyncBadge.icon(looks[index], compact: true)
        }
    }
    .padding()
    .background(Color.gray)
}

#Preview("Sync line") {
    // A compile and smoke check: the line is empty until the scan's space syncs with a lab server.
    // The User Guide's troubleshooting rows (UserGuideStatusIcons) show each line it can say.
    SyncLine(scan: CapturedScan(name: "Sample Scan", vertexCount: 1500, faceCount: 2000))
        .padding()
        .background(Color.black)
}

#Preview("Pending bundles") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    // swiftlint:disable:next force_try
    let container = try! ModelContainer(for: ScanLocation.self, CapturedScan.self, configurations: config)
    return NavigationStack { PendingBundlesView() }
        .modelContainer(container)
}
