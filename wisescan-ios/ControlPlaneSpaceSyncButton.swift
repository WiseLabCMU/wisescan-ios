import SwiftUI

/// Sync to Lab Server on a space: sends it to the control plane, as Upload sends an export. A
/// synced space keeps syncing (rescans, focus scans, stitches); tapping again syncs now. The
/// stitched map's version is the Sync row in the graph view (StitchGraphView). Shown only with a
/// control plane set.
struct ControlPlaneSpaceSyncButton: View {
    let spaceIds: [UUID]
    private var sync: ControlPlaneSync { ControlPlaneSync.shared }

    var body: some View {
        let state = sync.state(of: spaceIds)
        Button(action: { sync.sync(spaces: spaceIds) }, label: {
            HStack {
                Image(systemName: state.symbol)
                Text(state.title)
                    .font(.subheadline).bold()
            }
        })
        .buttonStyle(FilledActionButtonStyle(background: state.isSynced ? Color.teal.opacity(0.25) : Color.teal.opacity(0.8)))
        .disabled(state == .syncing)
    }
}

extension ControlPlaneSync.SpaceState {
    var isSynced: Bool { self != .notSynced && self != .partlySynced }

    var title: String {
        switch self {
        case .notSynced: return "Sync to Lab Server"
        case .partlySynced: return "Sync All to Lab Server"
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
