import SwiftUI

/// Settings → Control plane: the lab server this phone reports its spaces, scans and stitches to
/// (`ControlPlaneSync`; scan4d-server README). One host field, no auth yet: the server lives on
/// the internal network.
struct ControlPlaneSettingsSection: View {
    @AppStorage(AppConstants.Key.controlPlaneHost) private var host = ""
    @AppStorage(AppConstants.Key.controlPlaneDeviceLabel) private var deviceLabel = ""
    @AppStorage(AppConstants.Key.controlPlaneSendPackages) private var sendPackages = AppConstants.controlPlaneSendPackages
    @AppStorage(AppConstants.Key.controlPlaneAllowUntrusted) private var allowUntrusted = false
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
                Toggle("Allow untrusted certificates", isOn: $allowUntrusted)
                    .foregroundColor(.white)
                Text("For a lab server with its own (self-signed) certificate: accepted from this server and the upload hosts it names, nowhere else.")
                    .font(.caption)
                    .foregroundColor(.gray)
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

            if let uploads = uploadsLine {
                Label(uploads, systemImage: "arrow.up.doc")
                    .font(.caption)
                    .foregroundColor(.gray)
            }

            ForEach(sync.openTasks) { task in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Focus scan requested: \(task.region.label.isEmpty ? "a region" : task.region.label)")
                            .font(.caption)
                            .foregroundColor(.white)
                        Text("\(task.mapName) · \(task.region.detail.title)\(task.reason.isEmpty ? "" : " · " + task.reason)")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    Button("Open") { sync.open(task) }
                        .buttonStyle(.borderless)
                }
            }

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
        .onChange(of: allowUntrusted) { _, _ in
            sync.requestSync(after: .seconds(1))
        }
    }

    /// Where the Upload buttons send exports, once a sync has said.
    private var uploadsLine: String? {
        guard !host.isEmpty, let target = sync.uploadTarget else { return nil }
        if target.revoked { return "Uploads are turned off for this device on the control plane." }
        if target.available { return "Exports upload to the lab bucket \(target.bucket ?? "") through the control plane." }
        return "The control plane has no upload target: exports use the upload URL above."
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
