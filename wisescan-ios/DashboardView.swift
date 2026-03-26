import SwiftUI

struct DashboardView: View {
    @AppStorage(AppDefaults.Key.uploadURL) private var uploadURL = AppDefaults.uploadURL
    @State private var showSettings = false
    @State private var serverStatus: ServerStatus = .unknown
    @State private var wearableManager = MetaWearableManager.shared

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
                                    .background(Color.cyan.opacity(0.2))
                                    .foregroundColor(.cyan)
                                    .cornerRadius(8)
                                }
                                .disabled(serverStatus == .checking)
                            }

                            Text(uploadURL)
                                .font(.caption2)
                                .foregroundColor(.gray)
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
                                Text(wearableManager.isScanning ? "Scanning..." : "Add Smart Glasses (Wearables)")
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
            .onAppear { checkServer() }
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
        guard let url = URL(string: uploadURL) else {
            serverStatus = .unavailable
            return
        }

        serverStatus = .checking

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5

        URLSession.shared.dataTask(with: request) { _, response, error in
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

            Button(action: {}) {
                Text("Configure")
                    .font(.subheadline).bold()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(isDisabled ? Color.gray.opacity(0.3) : Color.green.opacity(0.8))
                    .foregroundColor(isDisabled ? .gray : .black)
                    .cornerRadius(8)
            }
            .disabled(isDisabled)
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

#Preview {
    DashboardView()
}
