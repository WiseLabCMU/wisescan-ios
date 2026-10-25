import SwiftUI

/// Settings → Control plane: the lab server this phone reports its spaces, scans and stitches to
/// (`ControlPlaneSync`; scan4d-server README). Its host, and the shared password it may want
/// (kept in the Keychain).
struct ControlPlaneSettingsSection: View {
    @AppStorage(AppConstants.Key.controlPlaneHost) private var host = ""
    @AppStorage(AppConstants.Key.controlPlaneDeviceLabel) private var deviceLabel = ""
    @AppStorage(AppConstants.Key.controlPlaneSendPackages) private var sendPackages = AppConstants.controlPlaneSendPackages
    @AppStorage(AppConstants.Key.controlPlaneAllowUntrusted) private var allowUntrusted = false
    @State private var password = ControlPlaneSecret.password
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
                SecureField("Server password", text: $password)
                    .foregroundColor(.white)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onSubmit { savePassword() }
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
                Text("For servers on the lab's local network with their own (self-signed) certificate, reached by IP address or a .local name: accepted from this server and the upload hosts it names, nowhere else.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Send map packages", isOn: $sendPackages)
                    .foregroundColor(.white)
                Text("What the server asks for: the small files it reads itself (alignment, room layout, feature cloud, coverage, focus box) after each sync; the mesh and relocalization map only when the lab needs them, and large files only over Wi-Fi.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.vertical, 4)

            if let uploads = uploadsLine {
                Label(uploads, systemImage: "arrow.up.doc")
                    .font(.caption)
                    .foregroundColor(.gray)
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
            Text("Sends this phone's spaces, scans and stitches to the server: names, times, IDs, poses and focus regions, plus the map package files it asks for when on. Never photos. Never during a scan.")
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
        .onChange(of: password) { _, _ in
            savePassword()
        }
    }

    /// Into the Keychain as typed (an empty field removes it), then a sync to try it.
    private func savePassword() {
        guard password != ControlPlaneSecret.password else { return }
        ControlPlaneSecret.setPassword(password)
        connectionMessage = nil
        sync.requestSync(after: .seconds(AppConstants.controlPlaneSyncDebounceS))
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
