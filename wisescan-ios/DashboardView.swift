import SwiftUI

struct DashboardView: View {
    @AppStorage(AppConstants.Key.uploadURL) private var uploadURL = AppConstants.uploadURL
    @AppStorage(AppConstants.Key.developerMode) private var developerMode = false
    @State private var showSettings = false
    @State private var serverStatus: ServerStatus = .unknown
    @State private var wearableManager = MetaWearableManager.shared
    @State private var thetaManager = ThetaCameraManager.shared

    enum ServerStatus {
        case unknown, checking, available, unavailable
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                // Background gradient
                LinearGradient(colors: [Color(white: 0.1), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {

                        // Upload Server Status Card
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: serverStatusIcon)
                                    .foregroundColor(serverStatusColor)
                                    .font(.title2)
                                    .frame(width: 40)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Upload Server")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    Text(serverStatusLabel)
                                        .font(.caption)
                                        .foregroundColor(serverStatusColor)
                                }
                                Spacer()

                                Button(action: { checkServer() }) {
                                    HStack(spacing: 4) {
                                        if serverStatus == .checking {
                                            ProgressView()
                                                .scaleEffect(0.7)
                                                .tint(.cyan)
                                        }
                                        Text(serverStatus == .checking ? "Checking…" : "Test")
                                            .font(.subheadline).bold()
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(uploadURL.isEmpty ? Color.gray.opacity(0.2) : Color.cyan.opacity(0.2))
                                    .foregroundColor(uploadURL.isEmpty ? .gray : .cyan)
                                    .cornerRadius(8)
                                }
                                .disabled(serverStatus == .checking || uploadURL.isEmpty)
                            }

                            Text(uploadURL.isEmpty ? "No upload server configured — set in Settings" : uploadURL)
                                .font(.caption2)
                                .foregroundColor(uploadURL.isEmpty ? .orange : .white.opacity(0.7))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(serverStatusBorderColor, lineWidth: 1)
                        )
                        .cornerRadius(16)
                        .padding(.horizontal)

                        // Local Servers (mDNS) — not yet implemented
                        /*
                        Text("LOCAL SERVERS (mDNS)")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .padding(.horizontal)
                            .padding(.top, 16)

                        ServerCard(name: "Scanner_Pro_3D", model: "Alpha-9 | 192.168.1.45", isConnected: true, isDisabled: true)
                        ServerCard(name: "Studio_Scan_X", model: "X100 | 192.168.1.102", isConnected: false, isDisabled: true)
                        ServerCard(name: "Lab_Scanner_Beta", model: "Beta-3 | 192.168.1.115", isConnected: false, isDisabled: true)
                        */

                        Text("WEARABLE DEVICES (PROXY SCAN)")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .padding(.horizontal)
                            .padding(.top, 16)

                        if wearableManager.deviceUpdateRequired {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text("Firmware Update Required")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                }
                                Text("Your glasses firmware needs an update before they can be used reliably.")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))

                                Button(action: {
                                    wearableManager.openFirmwareUpdate()
                                }) {
                                    Text("Update in Meta View App")
                                        .font(.subheadline).bold()
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(Color.orange.opacity(0.8))
                                        .foregroundColor(.black)
                                        .cornerRadius(8)
                                }
                                .padding(.top, 4)
                            }
                            .padding()
                            .background(Color.orange.opacity(0.2))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.orange.opacity(0.5), lineWidth: 1)
                            )
                            .cornerRadius(16)
                            .padding(.horizontal)
                        }

                        // Show permission banner only if we've never been granted
                        // (reads from cache to avoid false flash on cold launch before SDK IPC resolves)
                        let cachedPermission = UserDefaults.standard.bool(forKey: AppConstants.Key.metaWearablesPermissionGranted)
                        if !wearableManager.connectedDevices.isEmpty && !cachedPermission && !wearableManager.permissionGranted {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.yellow)
                                    Text("Meta App Permission Required")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                }
                                Text("Camera access must be granted in the Meta AI companion app before streaming can start.")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.8))

                                Button(action: {
                                    wearableManager.requestPermissions()
                                }) {
                                    Text("Grant Permission in Meta AI")
                                        .font(.subheadline).bold()
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(Color.yellow.opacity(0.8))
                                        .foregroundColor(.black)
                                        .cornerRadius(8)
                                }
                                .padding(.top, 4)
                            }
                            .padding()
                            .background(Color.yellow.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.yellow.opacity(0.4), lineWidth: 1)
                            )
                            .cornerRadius(16)
                            .padding(.horizontal)
                        }

                        if wearableManager.connectedDevices.isEmpty {
                            Text("No paired devices found")
                                .font(.caption)
                                .foregroundColor(.gray)
                                .padding(.horizontal)
                        } else {
                            ForEach(wearableManager.connectedDevices) { device in
                                WearableCard(name: device.name, deviceId: device.id, isPaired: device.isConnected, isDisabled: false)
                            }
                        }

                        Button(action: { wearableManager.toggleScanning() }) {
                            HStack {
                                if wearableManager.isScanning {
                                    ProgressView().tint(.white).padding(.trailing, 4)
                                } else {
                                    Image(systemName: "plus")
                                }
                                Text(wearableManager.isScanning ? "Scanning..." : "Add Meta Smart Glasses")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(wearableManager.isScanning ? Color.cyan.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
                            )
                            .cornerRadius(16)
                            .foregroundColor(.white)
                        }
                        .padding(.horizontal)

                        // MARK: - 360° Still Source (Theta OSC spike)
                        Text("360° CAMERA (STILL SOURCE)")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .padding(.horizontal)
                            .padding(.top, 16)

                        ThetaCameraCard(manager: thetaManager)
                            .padding(.horizontal)

                        // BLE bootstrap probe bench (see ThetaBLEProbe) — dev only.
                        if developerMode { ThetaBLEProbeCard().padding(.horizontal) }
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("Scan4D Connect")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .preferredColorScheme(.dark)
            .onAppear {
                if !uploadURL.isEmpty { checkServer() }
                // Refresh wearable state when returning to this tab
                wearableManager.refreshDevices()
            }
        }
    }

    // MARK: - Server Status Helpers

    private var serverStatusIcon: String {
        switch serverStatus {
        case .unknown: return "questionmark.circle"
        case .checking: return "arrow.clockwise.circle"
        case .available: return "checkmark.circle.fill"
        case .unavailable: return "xmark.circle.fill"
        }
    }

    private var serverStatusColor: Color {
        switch serverStatus {
        case .unknown: return .gray
        case .checking: return .cyan
        case .available: return .green
        case .unavailable: return .red
        }
    }

    private var serverStatusBorderColor: Color {
        switch serverStatus {
        case .available: return Color.green.opacity(0.5)
        case .unavailable: return Color.red.opacity(0.3)
        default: return Color.white.opacity(0.1)
        }
    }

    private var serverStatusLabel: String {
        switch serverStatus {
        case .unknown: return "Not tested"
        case .checking: return "Checking…"
        case .available: return "Server reachable"
        case .unavailable: return "Server unreachable"
        }
    }

    private func checkServer() {
        guard !uploadURL.isEmpty, let url = URL(string: uploadURL) else {
            serverStatus = .unknown
            return
        }

        serverStatus = .checking

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { _, response, _ in
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse,
                   (200...499).contains(httpResponse.statusCode) {
                    // Any HTTP response means server is reachable
                    // (even 4xx means the server itself is running)
                    serverStatus = .available
                } else {
                    serverStatus = .unavailable
                }
            }
        }.resume()
    }
}

/// Developer-mode bench for the BLE bootstrap probe — surfaces ThetaBLEProbe's
/// discovery list, the three probe actions, and its live log. Field goals in the
/// probe's header doc; findings graduate into the production connect flow.
struct ThetaBLEProbeCard: View {
    private var probe: ThetaBLEProbe { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundColor(probe.connectedName != nil ? .green : .white.opacity(0.7))
                Text("360° BLE Probe")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button(probe.isScanning ? "Stop" : "Scan", action: {
                    probe.isScanning ? probe.stopScan() : probe.startScan()
                })
                .font(.subheadline).bold()
                .foregroundColor(.cyan)
            }

            if let connected = probe.connectedName {
                Text(connected)
                    .font(.caption.bold())
                    .foregroundColor(.green)
                HStack(spacing: 14) {
                    Button("Take Picture", action: { probe.takePicture() })
                    Button("Wake AP", action: { probe.wakeAP() })
                    Button("Disconnect", action: { probe.disconnect() })
                        .foregroundColor(.orange)
                }
                .font(.caption.bold())
                .foregroundColor(.cyan)
                HStack(spacing: 14) {
                    Button("Wake Camera", action: { probe.wakeCamera() })
                    Button("NetOpts", action: { probe.readNetworkOptions() })
                    Button("Wake+Drop BLE", action: { probe.wakeAPAndDropBLE() })
                }
                .font(.caption.bold())
                .foregroundColor(.cyan)
                // Z1/V path: register the probe UUID over Wi-Fi first, then auth over BLE.
                HStack(spacing: 14) {
                    Button("Register (Wi-Fi, Z1)", action: { probe.registerOverWiFi() })
                    Button("Auth (BLE, Z1)", action: { probe.writeAuth() })
                }
                .font(.caption.bold())
                .foregroundColor(.cyan)
            } else {
                ForEach(probe.found) { item in
                    Button(action: { probe.connect(item.id) }, label: {
                        HStack(spacing: 6) {
                            if item.isLikelyTheta {
                                Image(systemName: "camera.aperture").foregroundColor(.cyan)
                                Text(item.name).bold().foregroundColor(.cyan)
                                Text("Theta?").foregroundColor(.cyan.opacity(0.7))
                            } else {
                                Text(item.name).foregroundColor(.white)
                            }
                            Spacer()
                            Text("\(item.rssi) dBm").foregroundColor(.white.opacity(0.6))
                            Image(systemName: "chevron.right").foregroundColor(.white.opacity(0.4))
                        }
                        .font(.caption)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())   // whole row tappable — the Spacer gap ate taps
                    })
                    .buttonStyle(.plain)
                }
            }

            if !probe.logLines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(probe.logLines.suffix(12).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .cornerRadius(16)
    }
}

// Kept for future use
struct ServerCard: View {
    var name: String
    var model: String
    var isConnected: Bool
    var isDisabled: Bool = false

    var body: some View {
        HStack {
            Image(systemName: isConnected ? "wifi" : "wifi.slash")
                .foregroundColor(isConnected ? .green : .white.opacity(0.6))
                .font(.title2)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                        .font(.headline)
                        .foregroundColor(.white)
                    if isConnected {
                        Text("(Connected)")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Text("(Available)")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                Text("Model: \(model)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
            Spacer()

            Button(action: {}) {
                Text(isConnected ? "Disconnect" : "Connect")
                    .font(.subheadline).bold()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(isDisabled ? Color.gray.opacity(0.3) : (isConnected ? Color.green.opacity(0.2) : Color.white.opacity(0.1)))
                    .foregroundColor(isDisabled ? .white.opacity(0.45) : (isConnected ? .green : .white))
                    .cornerRadius(8)
            }
            .disabled(isDisabled)
        }
        .padding()
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isConnected ? Color.green.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
        )
        .cornerRadius(16)
        .padding(.horizontal)
        .opacity(isDisabled ? 0.6 : 1.0)
    }
}

struct WearableCard: View {
    var name: String
    var deviceId: String
    var isPaired: Bool
    var isDisabled: Bool = false

    var body: some View {
        HStack {
            Image(systemName: "eyeglasses")
                .foregroundColor(.white)
                .font(.title2)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name)
                        .font(.headline)
                        .foregroundColor(.white)
                    if isPaired {
                        HStack(spacing: 2) {
                            Text("(Paired)")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                            Text("●")
                                .foregroundColor(.green)
                                .font(.caption2)
                        }
                    }
                }
                Text("Device ID: \(deviceId)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
            Spacer()

            VStack(spacing: 8) {
                Button(action: {
                    MetaWearableManager.shared.connect(to: deviceId)
                }) {
                    Text("Configure")
                        .font(.subheadline).bold()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(isDisabled ? Color.gray.opacity(0.3) : Color.green.opacity(0.8))
                        .foregroundColor(isDisabled ? .gray : .black)
                        .cornerRadius(8)
                }
                .disabled(isDisabled)

                Button(action: {
                    MetaWearableManager.shared.unregister()
                }) {
                    Text("Disconnect")
                        .font(.caption).bold()
                        .foregroundColor(.red)
                }
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .cornerRadius(16)
        .padding(.horizontal)
        .opacity(isDisabled ? 0.6 : 1.0)
    }
}

/// Dashboard card for the 360° still-source spike: shows Theta connection state and a
/// "Test Shutter" trigger. Wi‑Fi is joined manually (iOS Settings) for now, so connecting
/// is an explicit "Check Connection" tap rather than automatic on appear (keeps the iOS
/// Local Network permission prompt tied to a deliberate action). See ThetaCameraManager.
struct ThetaCameraCard: View {
    @Bindable var manager: ThetaCameraManager
    @State private var calibrationManager = RigCalibrationManager.shared
    @State private var showNetworkSheet = false
    @State private var sheetSSID = ""
    @State private var sheetPassphrase = ""
    /// Last value WE wrote into the password field (factory digits derived from the
    /// SSID) — lets the prefill keep tracking SSID edits without ever overwriting a
    /// password the user typed themselves.
    @State private var sheetPassAutoFill = ""
    @State private var bleAddBusy = false
    @State private var bleAddStatus: String?
    /// The sheet edits the ACTIVE camera (prefilled) or adds a NEW one (blank) —
    /// without this, a second camera could only overwrite the first (field: the Z1
    /// probe run kept trying the X's SSID because no add-another path existed).
    @State private var sheetIsAdding = false
    /// Camera storage panel: file count + bulk erase (the vendor apps make this
    /// painful, and a rig session leaves hundreds of stills behind).
    @State private var cameraFileCount: Int?
    @State private var storageBusy = false
    @State private var showEraseConfirm = false

    /// Wearables-style single action: what the primary button does right now.
    private enum PrimaryAction { case add, connectStored, disconnect }
    private var primaryAction: PrimaryAction {
        if manager.isConnected { return .disconnect }
        return manager.hasStoredNetwork ? .connectStored : .add
    }

    private var statusColor: Color {
        switch manager.state {
        case .connected: return .green
        case .connecting: return .cyan
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var statusLabel: String {
        switch manager.state {
        case .disconnected: return "Not connected"
        case .connecting: return "Checking…"
        case .connected(let model, let firmware): return "\(model) · \(firmware)"
        case .failed: return "Connection failed"
        }
    }

    /// The automatic add flow: BLE pair → identity → derived credentials → wake →
    /// patient Wi-Fi connect. Unknown models fall back to prefilled manual entry.
    private func addViaBluetooth() async {
        bleAddBusy = true
        defer { bleAddBusy = false }
        do {
            let identity = try await ThetaBLEManager.shared.pairNewCamera { step in
                bleAddStatus = step
            }
            guard let ssid = ThetaCameraManager.factorySSID(model: identity.model, serial: identity.serial) else {
                sheetSSID = ""
                sheetPassphrase = identity.serial
                bleAddStatus = "Paired \(identity.serial) — type the SSID shown on the camera's screen"
                return
            }
            manager.saveNetwork(ssid: ssid, passphrase: identity.serial)
            manager.upsertProfile(model: identity.model, serial: identity.serial,
                                  ssid: ssid, passphrase: identity.serial,
                                  bleID: UserDefaults.standard.string(forKey: AppConstants.Key.thetaBLEPeripheralID))
            bleAddStatus = nil
            showNetworkSheet = false
            manager.connect()
        } catch ThetaBLEManager.BLEError.needsWiFiSetup(let model, let serial) {
            // Not a failure: BLE identified the camera for free. Hand off to manual
            // setup prefilled with what we learned (SSID form is derived — the user
            // should confirm it against the camera's own Wi-Fi screen).
            sheetSSID = ThetaCameraManager.factorySSID(model: model, serial: serial) ?? ""
            sheetPassphrase = serial
            sheetPassAutoFill = serial
            bleAddStatus = "Found \(model) · \(serial). Bluetooth setup is THETA X only for now — check the SSID against the camera's Wi-Fi screen, then Save & Connect."
        } catch {
            bleAddStatus = "Bluetooth setup failed: \(error.localizedDescription)"
        }
    }

    /// First-run "Add Camera" sheet: stores the camera's Wi-Fi so Connect is one tap
    /// (NEHotspotConfiguration join — no Settings round-trip). Mirrors the wearables
    /// add-device flow.
    private var networkSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Button(action: { Task { await addViaBluetooth() } }, label: {
                        HStack {
                            if bleAddBusy { ProgressView().padding(.trailing, 4) } else {
                                Image(systemName: "dot.radiowaves.left.and.right")
                            }
                            Text(bleAddBusy ? (bleAddStatus ?? "Working…") : "Find Camera via Bluetooth")
                        }
                    })
                    .disabled(bleAddBusy)
                    if bleAddBusy {
                        Button("Cancel", role: .cancel) {
                            ThetaBLEManager.shared.teardown()
                        }
                    }
                    if !bleAddBusy, let status = bleAddStatus {
                        Text(status).font(.caption).foregroundColor(.orange)
                    }
                } header: {
                    Text("Automatic (Bluetooth)")
                } footer: {
                    Text("Turn Bluetooth ON in the camera's menu first. iOS asks for a pairing code once — read it from the camera's screen. Wi-Fi credentials, joining, and connecting are automatic from there.")
                }

                Section {
                    TextField("THETAYL12345678.OSC", text: $sheetSSID)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .onChange(of: sheetSSID) { _, newSSID in
                            // Factory password = the serial digits in the SSID; prefill
                            // while the field is empty or still holds our own prefill.
                            guard sheetPassphrase.isEmpty || sheetPassphrase == sheetPassAutoFill else { return }
                            if let factory = ThetaCameraManager.factoryPassphrase(fromSSID: newSSID) {
                                sheetPassphrase = factory
                                sheetPassAutoFill = factory
                            }
                        }
                    SecureField("Password", text: $sheetPassphrase)
                } header: {
                    Text("Camera Wi-Fi")
                } footer: {
                    Text("The SSID is printed on the camera (and shown on its screen under Wi-Fi). The factory password — the serial digits in the SSID — is prefilled when recognized; changing it on the camera is recommended, see the security notes. iOS may report the join failed for the camera's internet-less Wi-Fi even when it succeeded — the card status above is the truth: the app verifies the camera link directly.")
                }
                Section {
                    Button("Save & Connect") {
                        let ssid = sheetSSID.trimmingCharacters(in: .whitespaces)
                        // Adding: register in the roster and ACTIVATE (which clears the
                        // previous camera's BLE keys, so wake can't target the wrong body).
                        manager.upsertProfile(model: nil,
                                              serial: ThetaCameraManager.factoryPassphrase(fromSSID: ssid),
                                              ssid: ssid, passphrase: sheetPassphrase, bleID: nil)
                        showNetworkSheet = false
                        if sheetIsAdding, let added = manager.profiles.first(where: { $0.ssid == ssid }) {
                            manager.activateProfile(added)
                        } else {
                            manager.saveNetwork(ssid: ssid, passphrase: sheetPassphrase)
                            manager.connect()
                        }
                    }
                    .disabled(sheetSSID.trimmingCharacters(in: .whitespaces).isEmpty || sheetPassphrase.isEmpty)
                }

                if manager.hasStoredNetwork {
                    Section {
                        Button("Forget This Camera", role: .destructive) {
                            manager.forgetCamera()
                            sheetSSID = ""
                            sheetPassphrase = ""
                            sheetPassAutoFill = ""
                            bleAddStatus = nil
                            showNetworkSheet = false
                        }
                    } footer: {
                        Text("Clears the stored Wi-Fi credentials and Bluetooth pairing state. For a full reset, also remove the camera in iOS Settings → Bluetooth.")
                    }
                }
            }
            .navigationTitle(sheetIsAdding ? "Add 360° Camera" : "Camera Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showNetworkSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "camera.aperture")
                    .font(.title2)
                    .foregroundColor(manager.isConnected ? .green : .gray)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ricoh Theta")
                        .font(.headline)
                        .foregroundColor(.white)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(statusLabel)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                        if let battery = manager.batteryLevel {
                            Text("· 🔋 \(Int(battery * 100))%")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                }
                Spacer()
            }

            // Device id (serial) — shown once connected.
            if let serial = manager.serialNumber {
                Text("Device ID: \(serial)")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
                    .textSelection(.enabled)
            }

            if ThetaBLEManager.shared.isLinkReady {
                HStack(spacing: 4) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text("Bluetooth link active — shutter rides BLE")
                }
                .font(.caption2)
                .foregroundColor(.cyan)
            }

            // Camera storage: count on demand, erase with confirmation. Distinct from
            // the per-scan security sweep — this wipes EVERYTHING on the camera.
            if manager.isConnected {
                HStack(spacing: 10) {
                    Image(systemName: "internaldrive")
                    if let count = cameraFileCount {
                        Text("\(count) file\(count == 1 ? "" : "s") on camera")
                    } else {
                        Text("Camera storage")
                    }
                    Spacer()
                    if storageBusy {
                        ProgressView()
                    } else {
                        Button("Count") {
                            Task {
                                storageBusy = true
                                cameraFileCount = await manager.cameraFileCount()
                                storageBusy = false
                            }
                        }
                        if (cameraFileCount ?? 0) > 0 {
                            Button("Erase All", role: .destructive) { showEraseConfirm = true }
                                .foregroundColor(.red)
                        }
                    }
                }
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
                .confirmationDialog("Erase the camera?", isPresented: $showEraseConfirm, titleVisibility: .visible) {
                    Button("Erase \(cameraFileCount ?? 0) file(s)", role: .destructive) {
                        Task {
                            storageBusy = true
                            _ = await manager.deleteAllCameraFiles()
                            cameraFileCount = await manager.cameraFileCount()
                            storageBusy = false
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Permanently deletes every photo and video on the camera — including anything not yet transferred to this device. This cannot be undone.")
                }
            }

            // Multi-camera switcher (X for texture, Z1 for low light — per collection).
            if manager.profiles.count > 1 {
                Menu {
                    ForEach(manager.profiles) { profile in
                        Button(action: { manager.activateProfile(profile) }, label: {
                            if profile.id == manager.activeProfile?.id {
                                Label(profile.displayName, systemImage: "checkmark")
                            } else {
                                Text(profile.displayName)
                            }
                        })
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                        Text(manager.activeProfile?.displayName ?? "Choose camera")
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .font(.caption)
                    .foregroundColor(.cyan)
                }
            }

            if case .failed(let message) = manager.state {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            // Still resolution — read from the camera, changeable via a preset menu.
            if manager.isConnected {
                HStack {
                    Text("Still resolution")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Menu {
                        ForEach(manager.stillFormatMenu, id: \.label) { format in
                            Button("\(format.label) · \(format.megapixels) MP") {
                                manager.setStillFormat(format)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(manager.currentStillFormat.map { "\($0.label) · \($0.megapixels) MP" } ?? "Set…")
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .font(.caption)
                        .foregroundColor(.cyan)
                    }
                }

                // Rig calibration section
                rigCalibrationSection
            }

            HStack(spacing: 12) {
                // Wearables-style one-button flow: Add Camera… (first run, opens the
                // network sheet) → Connect (joins the stored Wi-Fi + probes, no Settings
                // round-trip) → Disconnect (restores camera auto-sleep, releases Wi-Fi).
                Button(action: {
                    switch primaryAction {
                    case .add:
                        sheetIsAdding = true
                        sheetSSID = ""
                        sheetPassphrase = ""
                        sheetPassAutoFill = ""
                        bleAddStatus = nil
                        showNetworkSheet = true
                    case .connectStored:
                        manager.connect()
                    case .disconnect:
                        manager.disconnect()
                    }
                }, label: {
                    HStack {
                        if manager.state == .connecting {
                            ProgressView().tint(.white).padding(.trailing, 2)
                        } else {
                            Image(systemName: primaryAction == .disconnect ? "xmark.circle"
                                  : primaryAction == .add ? "plus.circle" : "wifi")
                        }
                        Text(primaryAction == .disconnect ? "Disconnect"
                             : primaryAction == .add ? "Add Camera…" : "Connect")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .foregroundColor(primaryAction == .disconnect ? .orange : .white)
                })
                .disabled(manager.state == .connecting)

                Button(action: { manager.takePicture() }, label: {
                    HStack {
                        if manager.isCapturing {
                            ProgressView().tint(.black).padding(.trailing, 2)
                        } else {
                            Image(systemName: "camera.fill")
                        }
                        Text("Test Shutter")
                            .font(.subheadline).bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(manager.isConnected ? Color.cyan.opacity(0.85) : Color.gray.opacity(0.3))
                    .cornerRadius(10)
                    .foregroundColor(manager.isConnected ? .black : .gray)
                })
                .disabled(!manager.isConnected || manager.isCapturing)
            }

            // Last trigger result — the P2 spike's headline number (round-trip latency).
            if let capture = manager.lastCapture {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Captured in \(capture.roundTripMs) ms")
                        .font(.caption).foregroundColor(.white)
                }
                // The camera returns an absolute http URL to the JPEG; while the phone is on
                // the camera's Wi‑Fi, tapping opens it in Safari to view/save the shot.
                if let url = URL(string: capture.fileURL) {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Image(systemName: "photo")
                            Text(capture.fileURL)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.caption2)
                        .foregroundColor(.cyan)
                    }
                } else {
                    Text(capture.fileURL)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                // Download the still on-device (measures P2 transfer time) + preview it.
                Button(action: { manager.downloadLastCapture() }, label: {
                    HStack {
                        if manager.isDownloading {
                            ProgressView().tint(.white).padding(.trailing, 2)
                        } else {
                            Image(systemName: "arrow.down.circle")
                        }
                        Text(manager.isDownloading ? "Downloading…" : "Download & Preview")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .foregroundColor(.white)
                })
                .disabled(manager.isDownloading)

                if let download = manager.lastDownload {
                    Text(String(format: "Downloaded %.1f MB in %d ms (%.1f MB/s)",
                                download.megabytes, download.elapsedMs, download.megabytesPerSecond))
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                }
                if let preview = manager.previewImage {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            } else if let error = manager.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text(error)
                        .font(.caption).foregroundColor(.orange)
                }
            }

            // Recent spike events (connect/disconnect, captures, transfer metrics).
            if !manager.events.isEmpty {
                Divider().background(Color.white.opacity(0.1))
                Text("RECENT EVENTS")
                    .font(.caption2).bold()
                    .foregroundColor(.white.opacity(0.7))
                ForEach(Array(manager.events.prefix(6))) { event in
                    HStack(alignment: .top, spacing: 6) {
                        Text(event.date, format: .dateTime.hour().minute().second())
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                        Text(event.message)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
            }

            if manager.hasStoredNetwork, !manager.isConnected {
                HStack(spacing: 14) {
                    Button("Edit camera network…") {
                        sheetIsAdding = false
                        sheetSSID = UserDefaults.standard.string(forKey: AppConstants.Key.thetaSSID) ?? ""
                        sheetPassphrase = UserDefaults.standard.string(forKey: AppConstants.Key.thetaPassphrase) ?? ""
                        sheetPassAutoFill = ""
                        bleAddStatus = nil
                        showNetworkSheet = true
                    }
                    Button("Add another camera…") {
                        sheetIsAdding = true
                        sheetSSID = ""
                        sheetPassphrase = ""
                        sheetPassAutoFill = ""
                        bleAddStatus = nil
                        showNetworkSheet = true
                    }
                }
                .font(.caption2)
                .foregroundColor(.white.opacity(0.6))
            }
        }
        .sheet(isPresented: $showNetworkSheet) { networkSheet }
        .padding()
        .background(.ultraThinMaterial)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .cornerRadius(16)
    }

    // MARK: - Rig Calibration Section (dev diagnostics bench)
    //
    // Post-process pivot (2026-07-30): production calibration happens in the Process
    // step from each scan's own stills — no pre-scan ritual. This walk-3-positions
    // bench remains for solver diagnostics (controlled captures, alignment overlays,
    // input bundles) and is Developer-Mode only.

    @ViewBuilder
    private var rigCalibrationSection: some View {
      if UserDefaults.standard.bool(forKey: AppConstants.Key.developerMode) {
        Divider().background(Color.white.opacity(0.1))

        switch calibrationManager.state {
        case .idle:
            idleCalibrationRow
        case .capturing(let count):
            capturingCalibrationRow(count: count)
        case .solving:
            HStack(spacing: 8) {
                ProgressView().tint(.cyan)
                Text("Solving rig calibration…")
                    .font(.caption)
                    .foregroundColor(.white)
            }
        case .review(let residualPx, _):
            reviewCalibrationRow(residualPx: residualPx)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Button("Try Again") { calibrationManager.beginCalibration() }
                    .font(.caption.bold())
                    .foregroundColor(.cyan)
            }
        }
      }
    }

    private var idleCalibrationRow: some View {
        HStack(spacing: 8) {
            if let profile = calibrationManager.currentProfile, profile.isSolved {
                Circle()
                    .fill(profile.residualPx <= AppConstants.calibrationResidualGreenPx ? .green
                          : profile.residualPx <= AppConstants.calibrationResidualYellowPx ? .yellow
                          : .red)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Rig calibrated")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                    if let age = calibrationManager.calibrationAgeDescription {
                        Text("\(age) · \(String(format: "%.1f", profile.residualPx)) px residual")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                Spacer()
                Button("Re-calibrate") { calibrationManager.beginCalibration() }
                    .font(.caption.bold())
                    .foregroundColor(.cyan)
            } else {
                Circle().fill(Color.orange).frame(width: 8, height: 8)
                Text("No rig calibration")
                    .font(.caption)
                    .foregroundColor(.orange)
                Spacer()
                Button("Calibrate") { calibrationManager.beginCalibration() }
                    .font(.caption.bold())
                    .foregroundColor(.cyan)
            }
        }
    }

    private func capturingCalibrationRow(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "scope")
                    .foregroundColor(.cyan)
                Text("Calibration: still \(count)/\(AppConstants.calibrationStillCount)")
                    .font(.caption.bold())
                    .foregroundColor(.white)
                Spacer()
                Button("Cancel") { calibrationManager.cancelCalibration() }
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
            Text("Walk to \(AppConstants.calibrationStillCount) positions (~1–2 m apart), pause at each to capture.")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))

            if !calibrationManager.isEnvironmentSufficient {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.yellow)
                    Text("Low mesh density — move to an area with more visible surfaces.")
                        .font(.caption2)
                        .foregroundColor(.yellow)
                }
            }
        }
    }

    private func reviewCalibrationRow(residualPx: Float) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(residualPx <= AppConstants.calibrationResidualGreenPx ? .green
                          : residualPx <= AppConstants.calibrationResidualYellowPx ? .yellow
                          : .red)
                    .frame(width: 8, height: 8)
                Text(String(format: "Calibration residual: %.1f px", residualPx))
                    .font(.caption.bold())
                    .foregroundColor(.white)
            }
            if residualPx > AppConstants.calibrationResidualYellowPx {
                Text("High residual — consider re-adjusting the rig and re-calibrating.")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
            HStack(spacing: 12) {
                Button(action: { calibrationManager.acceptCalibration() }) {
                    Text("Accept")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.3))
                        .cornerRadius(8)
                        .foregroundColor(.green)
                }
                Button(action: { calibrationManager.redoCalibration() }) {
                    Text("Redo")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .foregroundColor(.white)
                }
                // Discard the result, keep the previously saved calibration (if any).
                Button(action: { calibrationManager.cancelCalibration() }) {
                    Text("Cancel")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
    }
}

#Preview {
    DashboardView()
}

#Preview("ThetaCameraCard") {
    ZStack {
        Color.black
        ThetaCameraCard(manager: ThetaCameraManager.shared)
            .padding()
    }
}
