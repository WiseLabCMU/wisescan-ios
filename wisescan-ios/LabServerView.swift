import SwiftData
import SwiftUI

// MARK: - The Server tab

/// The lab server this phone syncs with (scan4d-server), in one place: how the last sync went,
/// with Sync now; the bundles waiting to go, with the Wi-Fi rule and the checklist; and the
/// connection (host, password, this phone's name, certificates, Auto sync). What the phone can
/// later pull down from the server (maps from other devices) belongs here too.
struct LabServerView: View {
    @Query(sort: \ScanLocation.name) private var locations: [ScanLocation]
    @AppStorage(AppConstants.Key.controlPlaneHost) private var host = AppConstants.controlPlaneHost

    var body: some View {
        NavigationStack {
            List {
                LabServerStatusSection()
                if ControlPlaneClient.baseURL(fromHost: host) != nil {
                    PendingBundlesSections(locations: locations)
                }
                ControlPlaneSettingsSection()
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Lab Server")
        }
    }
}

/// The tab's first section: the server, how its last sync went, and what it holds of this phone.
struct LabServerStatusSection: View {
    @AppStorage(AppConstants.Key.controlPlaneHost) private var host = AppConstants.controlPlaneHost
    @State private var connectionMessage: String?
    @State private var isTesting = false

    private var sync: ControlPlaneSync { ControlPlaneSync.shared }

    var body: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundColor(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ControlPlaneClient.baseURL(fromHost: host)?.host() ?? "No server set")
                        .foregroundColor(.white)
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            if sync.waitingForWiFi > 0 {
                Label("\(sync.waitingForWiFi) large map file(s) the lab asked for wait for Wi-Fi.", systemImage: "wifi")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            if !sync.openTasks.isEmpty {
                Label("\(sync.openTasks.count) focus scan request(s) in the to-do list on the Dashboard.", systemImage: "checklist")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            HStack {
                Button("Test connection") { testConnection() }
                    .disabled(host.isEmpty || isTesting)
                Spacer()
                Button("Sync now") { Task { await sync.syncNow() } }
                    .disabled(host.isEmpty || isBusy)
            }
            .buttonStyle(.borderless)

            if let connectionMessage {
                Text(connectionMessage)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        } header: {
            Text("STATUS")
        } footer: {
            if host.isEmpty {
                Text("Set the lab's server under Connection below to sync spaces to it.")
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
        }
        .listRowBackground(Color.white.opacity(0.05))
        .onChange(of: host) { _, _ in connectionMessage = nil }
    }

    private var isBusy: Bool {
        switch sync.status {
        case .syncing, .uploading: return true
        default: return false
        }
    }

    private func testConnection() {
        isTesting = true
        connectionMessage = "Testing…"
        Task {
            connectionMessage = await sync.testConnection()
            isTesting = false
        }
    }

    private var statusText: String {
        switch sync.status {
        case .off: return "Off: no server set."
        case .idle: return "Not synced yet."
        case .syncing: return "Syncing…"
        case .uploading(let done, let total): return "Uploading room layouts: \(done + 1) of \(total)…"
        case .synced(let date, let summary):
            return "Synced at \(date.formatted(date: .omitted, time: .shortened)): \(summary)."
        case .failed(let message): return message
        }
    }

    private var statusSymbol: String {
        switch sync.status {
        case .off: return "icloud.slash"
        case .idle: return "clock"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .uploading: return "arrow.up.circle"
        case .synced: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch sync.status {
        case .synced: return .green
        case .failed: return .orange
        default: return .gray
        }
    }
}

#Preview {
    LabServerView()
        .modelContainer(for: [ScanLocation.self, CapturedScan.self], inMemory: true)
        .preferredColorScheme(.dark)
}
