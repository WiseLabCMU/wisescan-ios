import SwiftUI

/// The Server tab's connection: the Scan4D server this phone reports its spaces, scans and stitches
/// to (`ControlPlaneSync`; scan4d-server README). Its host, the shared password it may want (kept
/// in the Keychain), this phone's name and the certificate override (which spaces sync is the tab's Spaces). Also what the
/// password prompt shows (`ControlPlanePasswordPrompt`).
struct ControlPlaneSettingsSection: View {
    /// Opened for a tapped Sync whose server wants a password (ControlPlanePasswordPrompt): say so
    /// and put the cursor in the password field.
    var focusPassword = false

    @AppStorage(AppConstants.Key.controlPlaneHost) private var host = AppConstants.controlPlaneHost
    @AppStorage(AppConstants.Key.controlPlaneDeviceLabel) private var deviceLabel = ""
    @AppStorage(AppConstants.Key.controlPlaneAllowUntrusted) private var allowUntrusted = false
    @State private var password = ControlPlaneSecret.password
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
                Text("The Scan4D server, as host:port or a URL. No scheme means http. Leave empty to turn sync off.")
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
                // After the sheet has slid up.
                guard focusPassword else { return }
                try? await Task.sleep(for: .milliseconds(600))
                passwordFocused = true
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField(DeviceIdentity.defaultLabel, text: $deviceLabel)
                    .foregroundColor(.white)
                    .disableAutocorrection(true)
                Text("This device's name on the server, e.g. Lab iPad 2. Left empty, it goes as \(DeviceIdentity.defaultLabel). The server files everything under the device ID, so renaming moves nothing.")
                    .font(.caption)
                    .foregroundColor(.gray)
                Text("Device ID \(DeviceIdentity.id.uuidString)")
                    .font(.caption2.monospaced())
                    .foregroundColor(.gray)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Allow untrusted certificates", isOn: $allowUntrusted)
                    .foregroundColor(.white)
                Text("For servers on your local network with their own (self-signed) certificate, reached by IP address or a .local name: accepted from this server, nowhere else.")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            .padding(.vertical, 4)

        } header: {
            Text("CONNECTION")
        } footer: {
            Text("Sends the spaces you sync to the server. First their map: names, times, IDs, poses, stitches, focus regions and each scan's room layout. Then each processed scan's bundle: everything it holds, photos included, with people blurred when the Privacy Filter is on. Other spaces stay on the phone. Never during a scan.")
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .listRowBackground(Color.white.opacity(0.05))
        // Typing coalesces into one sync once the field settles.
        .onChange(of: host) { _, _ in
            sync.requestSync(after: .seconds(AppConstants.controlPlaneSyncDebounceS))
        }
        .onChange(of: deviceLabel) { _, _ in
            sync.requestSync(after: .seconds(AppConstants.controlPlaneSyncDebounceS))
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
        sync.requestSync(after: .seconds(AppConstants.controlPlaneSyncDebounceS))
    }

    /// Why the sheet opened at the password: the server asked, and what Done does next.
    private var passwordRequestText: String {
        let server = ControlPlaneClient.baseURL(fromHost: host)?.host() ?? "The control plane"
        return "\(server) needs its password. Enter it below, then tap Done to go on."
    }
}

#Preview {
    NavigationStack {
        List { ControlPlaneSettingsSection() }
            .scrollContentBackground(.hidden)
            .background(Color.black)
    }
    .preferredColorScheme(.dark)
}
