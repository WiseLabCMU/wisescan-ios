import SwiftData
import SwiftUI

// MARK: - The sync badge (docs/design/sync-bundle.md, "The sync indicator")

/// How much of a space the Scan4D server holds, on its tile and its graph tile: nothing (no icon),
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
        case .map: return ("icloud", .white.opacity(0.85), "The Scan4D server has this space's map")
        case .everything: return ("checkmark.icloud.fill", .green, "The Scan4D server has everything in this space")
        case .uploading: return ("icloud.and.arrow.up", .cyan, "Sending this space's scans to the Scan4D server")
        case .failed: return ("exclamationmark.icloud", .yellow, "A scan of this space didn't reach the Scan4D server")
        }
    }
}

/// A scan card's one sync line: Map only, Everything, Uploading 40%, Waiting for Wi-Fi, Not
/// selected, or why it failed. Nothing when its space isn't synced. When the server wants the
/// scan's bundle but the checklist holds it back, the line offers Select, so the choice is made
/// where the line says it waits (a scan captured with the Privacy Filter off asks first).
struct SyncLine: View {
    let scan: CapturedScan
    /// Off in the pending checklist, whose own toggle selects.
    var selectable = true
    @State private var confirmUnblurred = false

    var body: some View {
        let bundles = BundleSync.shared
        let id: UUID = scan.id
        if let line = bundles.line(for: scan) {
            HStack(spacing: 4) {
                Image(systemName: line.failed ? "exclamationmark.icloud" : "icloud")
                Text(line.text).lineLimit(2)
                if selectable && bundles.awaitsSelection(id) {
                    Button("Select") {
                        if bundles.isHeldBack(id) {
                            confirmUnblurred = true
                        } else {
                            bundles.setSelected(id, true)
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2.bold())
                    .foregroundColor(.cyan)
                }
            }
            .font(.caption2)
            .foregroundColor(line.failed ? .yellow : .green.opacity(0.8))
            .unblurredBundleConsent(isPresented: $confirmUnblurred) { bundles.setSelected(id, true) }
        }
    }
}

extension View {
    /// Asks before a scan captured with the Privacy Filter off is selected for sync: its bundle
    /// carries its photos as captured, people unblurred.
    /// Always Send remembers the answer: such scans then go like any other, with no question,
    /// until the Server tab's "Ask before sending unblurred scans" is turned back on.
    func unblurredBundleConsent(isPresented: Binding<Bool>, send: @escaping () -> Void) -> some View {
        alert("Send photos with people unblurred?", isPresented: isPresented) {
            Button("Send", action: send)
            Button("Always Send") {
                BundleSync.shared.setHoldsBackFilterOff(false)
                send()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This scan was captured with the Privacy Filter off, so people in its photos aren't blurred. " +
                 "Its bundle goes to the Scan4D server as captured. Always Send sends every such scan " +
                 "without asking; turn that back off in the Server tab.")
        }
    }
}

// MARK: - The pending checklist

/// The Server tab's bundles: the Wi-Fi rule, then every synced scan whose bundle the Scan4D server
/// doesn't hold yet, by space. Selected by default, except a scan captured with the Privacy
/// Filter off, whose photos show people unblurred: it waits until the user selects it. A
/// deselected scan waits until selected again (deselecting one being sent stops it); a new scan
/// joins selected. A bundle the server couldn't unpack, or refused, waits for Retry. Sections of
/// the tab's List.
struct PendingBundlesSections: View {
    let locations: [ScanLocation]
    @AppStorage(AppConstants.Key.controlPlaneBundlesWifiOnly) private var wifiOnly = AppConstants.controlPlaneBundlesWifiOnly

    var body: some View {
        let bundles = BundleSync.shared
        let pending = Self.pending(in: locations)
        Section {
            Toggle("Upload data bundles only on Wi-Fi", isOn: $wifiOnly)
                .foregroundColor(.white)
                .onChange(of: wifiOnly) { _, _ in bundles.wifiOnlyChanged() }
            // On (the default): a scan captured with the Privacy Filter off waits for Select, which
            // asks first. Always Send in that question turns it off.
            Toggle("Ask before sending unblurred scans",
                   isOn: Binding(get: { bundles.holdsBackFilterOff }, set: { bundles.setHoldsBackFilterOff($0) }))
                .foregroundColor(.white)
            if pending.isEmpty {
                Text("Nothing waiting: the Scan4D server has every synced scan's bundle, or none is processed yet.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        } header: {
            Text("BUNDLES")
        } footer: {
            Text("A scan's bundle is everything it holds: its photos, depth, mesh and room layout, " +
                 "hundreds of MB or more. The map itself and its RoomPlan preview go on any network. A scan " +
                 "captured with the Privacy Filter off waits until you select it, unless Ask before sending " +
                 "unblurred scans is off.")
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .listRowBackground(Color.white.opacity(0.05))
        ForEach(pending) { space in
            Section {
                ForEach(space.scans, id: \.self) { scan in
                    PendingBundleRow(scan: scan)
                }
            } header: {
                Text(space.name)
            }
            .listRowBackground(Color.white.opacity(0.05))
        }
    }

    struct PendingSpace: Identifiable {
        let id: UUID
        let name: String
        let scans: [CapturedScan]
    }

    /// The checklist's rows, and Settings' count of them: scans of confirmed spaces whose bundle
    /// the server wants, couldn't unpack or refused, or that is being sent, oldest first. Nothing
    /// while the state on hand is another server's.
    static func pending(in locations: [ScanLocation]) -> [PendingSpace] {
        let bundles = BundleSync.shared
        let sync = ControlPlaneSync.shared
        guard sync.stateIsCurrent else { return [] }
        return locations.compactMap { location -> PendingSpace? in
            let spaceId: UUID = location.id
            guard sync.confirmedSpaces.contains(spaceId) else { return nil }
            let scans = location.scans.sorted(by: CapturedScan.canonicalOrder).filter { scan in
                let scanId: UUID = scan.id
                let state = bundles.remote[scanId]
                return state?.wanted == true || state?.state == "failed" || bundles.refusal(scanId) != nil
                    || bundles.isActive(scanId)
            }
            return scans.isEmpty ? nil : PendingSpace(id: spaceId, name: location.name, scans: scans)
        }
    }
}

private struct PendingBundleRow: View {
    let scan: CapturedScan
    @State private var confirmUnblurred = false

    var body: some View {
        let bundles = BundleSync.shared
        let id: UUID = scan.id
        let failed = bundles.remote[id]?.state == "failed" || bundles.failures[id] != nil || bundles.refusal(id) != nil
        HStack {
            Toggle(isOn: Binding(get: { bundles.isSelected(id) },
                                 set: { selected in
                                     // Selecting a scan captured with the Privacy Filter off asks first.
                                     if selected && bundles.isHeldBack(id) {
                                         confirmUnblurred = true
                                     } else {
                                         bundles.setSelected(id, selected)
                                     }
                                 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scan.name)
                    SyncLine(scan: scan, selectable: false)
                    if bundles.filterOff.contains(id) {
                        Label("Captured with the Privacy Filter off: people in its photos aren't blurred.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }
            // Not while its bundle is being built or sent: Retry deletes the cached zip.
            if failed && !bundles.isActive(id) {
                Button("Retry") { bundles.retry(id) }
                    .buttonStyle(.borderless)
            }
        }
        .unblurredBundleConsent(isPresented: $confirmUnblurred) { bundles.setSelected(id, true) }
    }
}

#Preview("Sync badges") {
    // Every state's look. A live SyncBadge shows only what BundleSync knows, which in a preview is
    // nothing (no Scan4D server is set).
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
    // A compile and smoke check: the line is empty until the scan's space syncs with a Scan4D server.
    // The User Guide's troubleshooting rows (UserGuideStatusIcons) show each line it can say.
    SyncLine(scan: CapturedScan(name: "Sample Scan", vertexCount: 1500, faceCount: 2000))
        .padding()
        .background(Color.black)
}

#Preview("Pending bundles") {
    // Empty: nothing is synced in a preview, so it shows the Wi-Fi rule and "Nothing waiting".
    NavigationStack {
        List { PendingBundlesSections(locations: []) }
            .scrollContentBackground(.hidden)
            .background(Color.black)
    }
    .preferredColorScheme(.dark)
}
