import SwiftUI

struct DashboardView: View {
    @AppStorage(AppConstants.Key.uploadURL) private var uploadURL = AppConstants.uploadURL
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
                                .foregroundColor(uploadURL.isEmpty ? .orange : .gray)
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
                                    .foregroundColor(.gray)

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
                                    .foregroundColor(.gray)

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

// Kept for future use
struct ServerCard: View {
    var name: String
    var model: String
    var isConnected: Bool
    var isDisabled: Bool = false

    var body: some View {
        HStack {
            Image(systemName: isConnected ? "wifi" : "wifi.slash")
                .foregroundColor(isConnected ? .green : .gray)
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
                            .foregroundColor(.gray)
                    }
                }
                Text("Model: \(model)")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            Spacer()

            Button(action: {}) {
                Text(isConnected ? "Disconnect" : "Connect")
                    .font(.subheadline).bold()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(isDisabled ? Color.gray.opacity(0.3) : (isConnected ? Color.green.opacity(0.2) : Color.white.opacity(0.1)))
                    .foregroundColor(isDisabled ? .gray : (isConnected ? .green : .white))
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
                                .foregroundColor(.gray)
                            Text("●")
                                .foregroundColor(.green)
                                .font(.caption2)
                        }
                    }
                }
                Text("Device ID: \(deviceId)")
                    .font(.caption)
                    .foregroundColor(.gray)
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
                            .foregroundColor(.gray)
                            .lineLimit(1)
                        if let battery = manager.batteryLevel {
                            Text("· 🔋 \(Int(battery * 100))%")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                }
                Spacer()
            }

            // Device id (serial) — shown once connected.
            if let serial = manager.serialNumber {
                Text("Device ID: \(serial)")
                    .font(.caption2)
                    .foregroundColor(.gray)
                    .textSelection(.enabled)
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
                        .foregroundColor(.gray)
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
            }

            HStack(spacing: 12) {
                Button(action: { manager.refreshConnection() }, label: {
                    HStack {
                        if manager.state == .connecting {
                            ProgressView().tint(.white).padding(.trailing, 2)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Check Connection")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(10)
                    .foregroundColor(.white)
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
                        .foregroundColor(.gray)
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
                        .foregroundColor(.gray)
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
                    .foregroundColor(.gray)
                ForEach(Array(manager.events.prefix(6))) { event in
                    HStack(alignment: .top, spacing: 6) {
                        Text(event.date, format: .dateTime.hour().minute().second())
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.gray.opacity(0.6))
                        Text(event.message)
                            .font(.caption2)
                            .foregroundColor(.gray)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
            }

            Text("Join the camera's Wi‑Fi in Settings, then Check Connection.")
                .font(.caption2)
                .foregroundColor(.gray.opacity(0.7))
        }
        .padding()
        .background(.ultraThinMaterial)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .cornerRadius(16)
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
