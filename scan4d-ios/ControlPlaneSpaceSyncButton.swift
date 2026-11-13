import SwiftUI

/// A space's sync switch (selective sync; docs/design/sync-bundle.md, "Which spaces sync"). On:
/// the space goes to the Scan4D server, everything in it: its map at once, then each processed
/// scan's bundle (`BundleSync`), and its rescans, focus scans and stitches after. Off: it stays on
/// this device, and if it had synced, the server marks it gone and keeps what it has. A new space
/// starts as the naming prompt or Sync new spaces left it. The stitched map's Sync is in the graph
/// view (StitchGraphView). Shown only with a control plane set.
struct ControlPlaneSpaceSyncButton: View {
    let location: ScanLocation
    @State private var passwordPrompt: ControlPlanePendingAction?
    private var sync: ControlPlaneSync { ControlPlaneSync.shared }

    var body: some View {
        let id: UUID = location.id
        let on = sync.syncs(location)
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { on }, set: { turnOn in
                if turnOn {
                    // A server that wants a password this phone hasn't got asks for it first.
                    passwordPrompt = ControlPlanePendingAction.runOrHold(host: sync.host) { sync.setSyncing([id], true) }
                } else {
                    sync.setSyncing([id], false)
                }
            })) {
                Label("Sync to Scan4D Server", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.bold())
                    .foregroundColor(.white)
            }
            .tint(.teal)
            Text(caption(on: on, state: sync.state(of: [id])))
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding()
        .background(Color.teal.opacity(0.12))
        .cornerRadius(12)
        .controlPlanePasswordPrompt($passwordPrompt)
    }

    private func caption(on: Bool, state: ControlPlaneSync.SpaceState) -> String {
        guard on else {
            return "On this device only. Turn on to send it to the Scan4D server; its rescans and focus scans follow."
        }
        switch state {
        case .syncing: return "Syncing…"
        case .failed: return "The last sync didn't reach the server: the Server tab says why."
        default:
            return "Its rescans, focus scans and stitches go too. Turn off to keep it on this device; " +
                "the server then marks it gone and keeps what it has."
        }
    }
}

extension ControlPlaneSync.SpaceState {
    var isSynced: Bool { self != .notSynced && self != .partlySynced }

    var title: String {
        switch self {
        case .notSynced: return "Sync to Scan4D Server"
        case .partlySynced: return "Sync All to Scan4D Server"
        case .syncing: return "Syncing…"
        case .synced: return "Synced · Sync Now"
        case .failed: return "Sync Failed · Retry"
        }
    }

    var shortTitle: String {
        switch self {
        case .notSynced: return "Sync"
        case .partlySynced: return "Sync all"
        case .syncing: return "Syncing…"
        case .synced: return "Synced"
        case .failed: return "Retry sync"
        }
    }

    var symbol: String {
        switch self {
        case .notSynced, .partlySynced, .syncing: return "arrow.triangle.2.circlepath"
        case .synced: return "checkmark.circle"
        case .failed: return "exclamationmark.arrow.triangle.2.circlepath"
        }
    }
}
