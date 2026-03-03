import SwiftUI

struct DashboardView: View {
    @AppStorage("uploadURL") private var uploadURL = "https://wiselambda4.lan.cmu.edu/wisescan-uploads/"

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                // Background gradient
                LinearGradient(colors: [Color(white: 0.1), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("STATIC UPLOAD PATH")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .padding(.horizontal)

                        TextField("Upload URL", text: $uploadURL)
                            .padding()
                            .background(.ultraThinMaterial)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
                            .cornerRadius(16)
                            .padding(.horizontal)
                            .foregroundColor(.white)

                        Text("LOCAL SERVERS (mDNS)")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .padding(.horizontal)
                            .padding(.top, 16)

                        ServerCard(name: "Scanner_Pro_3D", model: "Alpha-9 | 192.168.1.45", isConnected: true)
                        ServerCard(name: "Studio_Scan_X", model: "X100 | 192.168.1.102", isConnected: false)
                        ServerCard(name: "Lab_Scanner_Beta", model: "Beta-3 | 192.168.1.115", isConnected: false)

                        Text("WEARABLE DEVICES")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .padding(.horizontal)
                            .padding(.top, 16)

                        WearableCard(name: "Vision Glass S", deviceId: "VG-S02948", isPaired: true)

                        Button(action: {}) {
                            HStack {
                                Image(systemName: "plus")
                                Text("Add Smart Glasses (Wearables)")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 16)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                            .cornerRadius(16)
                            .foregroundColor(.white)
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("Scan3D Connect")
            .navigationBarTitleDisplayMode(.large)
            .preferredColorScheme(.dark)
        }
    }
}

struct ServerCard: View {
    var name: String
    var model: String
    var isConnected: Bool

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
                    .background(isConnected ? Color.green.opacity(0.2) : Color.white.opacity(0.1))
                    .foregroundColor(isConnected ? .green : .white)
                    .cornerRadius(8)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isConnected ? Color.green.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1)
        )
        .cornerRadius(16)
        .padding(.horizontal)
    }
}

struct WearableCard: View {
    var name: String
    var deviceId: String
    var isPaired: Bool

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
                        Text("(Paired) ")
                            .font(.caption)
                            .foregroundColor(.gray)
                        + Text("●").foregroundColor(.green).font(.caption2)
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
                    .background(Color.green.opacity(0.8))
                    .foregroundColor(.black)
                    .cornerRadius(8)
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
    }
}

#Preview {
    DashboardView()
}
