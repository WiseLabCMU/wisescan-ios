import SwiftUI

struct CaptureView: View {
    @State private var isPrivacyFilterOn = true
    @State private var mode = 1 // 0 = Streaming, 1 = Capture
    @State private var isUploading = false
    @State private var uploadMessage: String? = nil

    @AppStorage("uploadURL") private var uploadURL = "https://wiselambda4.lan.cmu.edu/wisescan-uploads/"

    var body: some View {
        ZStack {
            // Simulated Camera View
            Color.black.ignoresSafeArea()
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 100))
                .foregroundColor(Color.white.opacity(0.2))

            // Simulated AR Grid Heatmap Overlay
            Rectangle()
                .fill(
                    RadialGradient(gradient: Gradient(colors: [Color.green.opacity(0.3), Color.clear]), center: .center, startRadius: 50, endRadius: 200)
                )
                .ignoresSafeArea()

            VStack {
                // Top Controls
                HStack {
                    // Privacy Filter Toggle
                    HStack {
                        Text("Privacy Filter")
                            .font(.subheadline)
                            .foregroundColor(.white)
                        Toggle("", isOn: $isPrivacyFilterOn)
                            .labelsHidden()
                            .tint(.green)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)

                    Spacer()

                    // Mode Switcher
                    Picker("Mode", selection: $mode) {
                        Text("Streaming").tag(0)
                        Text("Capture").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                }
                .padding()

                Spacer()

                // Bottom HUD and Capture Button
                VStack {
                    ZStack(alignment: .bottom) {
                        // HUD background
                        HStack {
                            Text("18.4 MB | 124K Polygons")
                                .font(.caption)
                                .foregroundColor(.white)

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Scan Quality: 88%")
                                    .font(.caption)
                                    .foregroundColor(.white)
                                // Fake progress bar
                                HStack(spacing: 2) {
                                    Rectangle().fill(Color.cyan).frame(width: 20, height: 4)
                                    Rectangle().fill(Color.green).frame(width: 20, height: 4)
                                    Rectangle().fill(Color.yellow).frame(width: 20, height: 4)
                                }
                                .cornerRadius(2)
                            }
                        }
                        .padding()
                        .frame(height: 80)
                        .background(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                        .cornerRadius(24)
                        .padding(.horizontal)

                        // Capture Button overlaying HUD
                        Button(action: {
                            if mode == 1 {
                                uploadDummyData()
                            }
                        }) {
                            ZStack {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .frame(width: 80, height: 80)
                                    .overlay(Circle().stroke(Color.cyan, lineWidth: 2))

                                if isUploading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Circle()
                                        .fill(mode == 1 ? Color.white : Color.red)
                                        .frame(width: 30, height: 30)
                                }

                                if let msg = uploadMessage {
                                    Text(msg)
                                        .font(.caption2).bold()
                                        .foregroundColor(.white)
                                        .offset(y: 35)
                                } else {
                                    Text("00:14")
                                        .font(.caption2).bold()
                                        .foregroundColor(.white)
                                        .offset(y: 24)
                                }
                            }
                        }
                        .disabled(isUploading)
                        .offset(y: -20)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func uploadDummyData() {
        guard mode == 1 else { return } // Only upload in Capture mode
        isUploading = true
        uploadMessage = "Uploading..."

        let dummyData = "Dummy capture data from WiSEScan iOS".data(using: .utf8)!
        let filename = "wisescan_ios_capture_\(UUID().uuidString).txt"

        // Ensure the base URL ends with a slash before appending the filename
        let baseURLString = uploadURL.hasSuffix("/") ? uploadURL : uploadURL + "/"
        guard let url = URL(string: baseURLString + filename) else {
            uploadMessage = "Invalid URL"
            isUploading = false
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        let task = URLSession.shared.uploadTask(with: request, from: dummyData) { data, response, error in
            DispatchQueue.main.async {
                self.isUploading = false
                if let error = error {
                    self.uploadMessage = "Error"
                    print("Upload error: \(error.localizedDescription)")
                } else if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                    self.uploadMessage = "Success!"
                } else {
                    self.uploadMessage = "Failed"
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self.uploadMessage == "Success!" || self.uploadMessage == "Failed" || self.uploadMessage == "Error" {
                        self.uploadMessage = nil
                    }
                }
            }
        }
        task.resume()
    }
}

#Preview {
    CaptureView()
}
