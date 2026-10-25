import SwiftUI

/// Settings → Control plane: the lab server this phone reports its spaces, scans and stitches to
/// (`ControlPlaneSync`; scan4d-server README). One host field, no auth yet: the server lives on
/// the internal network.
struct ControlPlaneSettingsSection: View {
    @AppStorage(AppConstants.Key.controlPlaneHost) private var host = ""
    @AppStorage(AppConstants.Key.controlPlaneDeviceLabel) private var deviceLabel = ""
    @AppStorage(AppConstants.Key.controlPlaneSendPackages) private var sendPackages = AppConstants.controlPlaneSendPackages
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

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Send map packages", isOn: $sendPackages)
                    .foregroundColor(.white)
                Text("Each room scan's mesh, room layout, alignment and relocalization map (tens of MB), and each focus scan's box, so the lab can view and reuse them. Uploaded after a sync, one file at a time.")
                    .font(.caption)
                    .foregroundColor(.gray)
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
                    .disabled(host.isEmpty || isBusy)
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
            Text("Sends this phone's spaces, scans and stitches to the server: names, times, IDs, poses and focus regions, plus the map packages above when on. Never photos. Never during a scan.")
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
        .onChange(of: sendPackages) { _, _ in
            sync.requestSync(after: .seconds(1))
        }
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
        case .uploading(let done, let total): return "Uploading map files: \(done + 1) of \(total)…"
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
