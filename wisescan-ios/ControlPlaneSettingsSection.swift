import SwiftData
import SwiftUI

/// Settings → Control plane: the lab server this phone reports its spaces, scans and stitches to
/// (`ControlPlaneSync`; scan4d-server README). Its host, and the shared password it may want
/// (kept in the Keychain).
struct ControlPlaneSettingsSection: View {
    /// Opened for a tapped Sync whose server wants a password (ControlPlanePasswordPrompt): say so
    /// and put the cursor in the password field.
    var focusPassword = false

    @AppStorage(AppConstants.Key.controlPlaneHost) private var host = AppConstants.controlPlaneHost
    @AppStorage(AppConstants.Key.controlPlaneDeviceLabel) private var deviceLabel = ""
    @AppStorage(AppConstants.Key.controlPlaneBundlesWifiOnly) private var bundlesWifiOnly = AppConstants.controlPlaneBundlesWifiOnly
    @AppStorage(AppConstants.Key.controlPlaneAllowUntrusted) private var allowUntrusted = false
    @AppStorage(AppConstants.Key.controlPlaneAutoSync) private var autoSyncRaw = AppConstants.controlPlaneAutoSync
    /// For the pending count, read as the checklist reads its rows.
    @Query private var locations: [ScanLocation]
    @State private var password = ControlPlaneSecret.password
    @State private var connectionMessage: String?
    @State private var isTesting = false
    @FocusState private var passwordFocused: Bool

    private var sync: ControlPlaneSync { ControlPlaneSync.shared }

    var body: some View {
        Section {
            if focusPassword {
                Label(passwordRequestText, systemImage: "key.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

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
                    .focused($passwordFocused)
                    .onSubmit { savePassword() }
            }
            .padding(.vertical, 4)
            .task {
                // After the sheet has slid up and Settings has scrolled here.
                guard focusPassword else { return }
                try? await Task.sleep(for: .milliseconds(600))
                passwordFocused = true
            }

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
                Text("For servers on the lab's local network with their own (self-signed) certificate, reached by IP address or a .local name: accepted from this server, nowhere else.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Auto sync")
                        .foregroundColor(.white)
                    Spacer()
                    Picker("Auto sync", selection: $autoSyncRaw) {
                        ForEach(ControlPlaneAutoSync.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                Text("\(autoSyncCaption) Once synced, a space keeps syncing. \(sync.syncedSpaces.count) space(s) synced so far.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Upload data bundles only on Wi-Fi", isOn: $bundlesWifiOnly)
                    .foregroundColor(.white)
                    .onChange(of: bundlesWifiOnly) { _, _ in BundleSync.shared.wifiOnlyChanged() }
                Text("Each processed scan goes up as one bundle: everything it holds, photos included, hundreds of MB or more. The map itself and its room layout go on any network.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.vertical, 4)

            NavigationLink(destination: PendingBundlesView()) {
                HStack {
                    Text("Pending bundles")
                        .foregroundColor(.white)
                    Spacer()
                    Text("\(pendingBundles)")
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
            Text("Sends the spaces you sync to the server. First their map: names, times, IDs, poses, stitches, focus regions and each scan's room layout. Then each processed scan's bundle: everything it holds, photos included, with people blurred when the Privacy Filter is on. Other spaces stay on the phone. Never during a scan.")
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
        .onChange(of: autoSyncRaw) { _, _ in
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

    /// Why Settings opened at the password: the server asked, and what Done does next.
    private var passwordRequestText: String {
        let server = ControlPlaneClient.baseURL(fromHost: host)?.host() ?? "The control plane"
        return "\(server) needs its password. Enter it below, then tap Done to go on."
    }

    /// What Auto sync does in the chosen mode.
    private var autoSyncCaption: String {
        switch ControlPlaneAutoSync(rawValue: autoSyncRaw) ?? .new {
        case .all: return "Every space on this phone syncs on its own, those from before it joined too."
        case .new: return "Spaces started after this phone joined sync on their own; earlier ones go when you tap Sync to Lab Server in the space, or Sync on a stitched map in the graph view."
        case .off: return "Only the spaces you send with Sync to Lab Server in a space, or Sync on a stitched map in the graph view."
        }
    }

    /// The pending checklist's rows, counted by its own filter so the two always agree.
    private var pendingBundles: Int {
        PendingBundlesView.pending(in: locations).reduce(0) { $0 + $1.scans.count }
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
