import SwiftUI

/// Settings → Control plane: the lab server this phone reports its spaces, scans and stitches to
/// (`ControlPlaneSync`; scan4d-server README). One host field, no auth yet: the server lives on
/// the internal network.
struct ControlPlaneSettingsSection: View {
    @AppStorage(AppConstants.Key.controlPlaneHost) private var host = ""
    @AppStorage(AppConstants.Key.controlPlaneDeviceLabel) private var deviceLabel = ""
    @State private var connectionMessage: String?
    @State private var isTesting = false

    private var sync: ControlPlaneSync { ControlPlaneSync.shared }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                TextField("192.168.1.40:8000", text: $host)
                    .foregroundColor(.white)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                Text("The lab's Scan4D server, as host:port or a URL. No scheme means http. Leave empty to turn sync off.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                TextField("This phone's name, e.g. Lab iPhone 3", text: $deviceLabel)
                    .foregroundColor(.white)
                    .disableAutocorrection(true)
                Text("Device ID \(DeviceIdentity.id.uuidString)")
                    .font(.caption2.monospaced())
                    .foregroundColor(.gray)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)

            HStack(spacing: 8) {
                Image(systemName: statusSymbol)
                    .foregroundColor(statusColor)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            HStack {
                Button("Test connection") { testConnection() }
                    .disabled(host.isEmpty || isTesting)
                Spacer()
                Button("Sync now") { Task { await sync.syncNow() } }
                    .disabled(host.isEmpty || sync.status == .syncing)
            }
            .buttonStyle(.borderless)

            if let connectionMessage {
                Text(connectionMessage)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        } header: {
            Text("CONTROL PLANE")
        } footer: {
            Text("Sends this phone's spaces, scans and stitches to the server: names, times, IDs, poses and focus regions. No photos, meshes or maps. Never during a scan.")
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .listRowBackground(Color.white.opacity(0.05))
        // Typing coalesces into one sync once the field settles.
        .onChange(of: host) { _, _ in
            connectionMessage = nil
            sync.requestSync(after: .seconds(AppConstants.controlPlaneSyncDebounceS))
        }
        .onChange(of: deviceLabel) { _, _ in
            sync.requestSync(after: .seconds(AppConstants.controlPlaneSyncDebounceS))
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
