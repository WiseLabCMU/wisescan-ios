import SwiftUI
import ARKit

struct CaptureView: View {
    @Environment(ScanStore.self) private var scanStore
    @State private var scanStats = ScanStats()
    @State private var isPrivacyFilterOn = true
    @State private var mode = 1 // 0 = Streaming, 1 = Capture
    @State private var currentARSession: ARSession? = nil
    @State private var saveMessage: String? = nil
    @State private var isRecording = false
    @State private var recordingSeconds = 0
    @State private var recordingTimer: Timer? = nil
    @State private var frameCaptureSession = FrameCaptureSession()
    @AppStorage("rawOverlapMax") private var rawOverlapMax: Double = 60.0
    @AppStorage("rawRejectBlur") private var rawRejectBlur: Bool = true
    @Binding var selectedTab: Int

    var body: some View {
        ZStack {
            // Live ARKit Scene Reconstruction View
            ARCoverageView(arSession: $currentARSession, scanStats: scanStats, privacyFilter: isPrivacyFilterOn)
                .ignoresSafeArea()

            // Face blur overlay (shown when privacy filter is on)
            if isPrivacyFilterOn {
                FaceBlurOverlay(arSession: currentARSession)
                    .ignoresSafeArea()
            }

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

                    // Recording indicator
                    if isRecording {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 10, height: 10)
                            Text("REC \(formattedTime)")
                                .font(.caption).bold()
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.3))
                        .cornerRadius(20)
                    }

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
                    .disabled(isRecording)
                }
                .padding()

                Spacer()

                // Bottom HUD and Capture Button
                VStack {
                    ZStack(alignment: .bottom) {
                        // HUD background with live stats
                        HStack {
                            Text("\(scanStats.formattedSize) | \(scanStats.formattedPolygons) Polygons")
                                .font(.caption)
                                .foregroundColor(.white)

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                Text("Scan Quality: \(scanStats.qualityPercent)%")
                                    .font(.caption)
                                    .foregroundColor(.white)
                                // Quality bar
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Rectangle()
                                            .fill(Color.white.opacity(0.2))
                                            .frame(height: 4)
                                        Rectangle()
                                            .fill(qualityColor)
                                            .frame(width: geo.size.width * scanStats.averageQuality, height: 4)
                                    }
                                    .cornerRadius(2)
                                }
                                .frame(width: 60, height: 4)
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
                                toggleRecording()
                            }
                        }) {
                            ZStack {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .frame(width: 80, height: 80)
                                    .overlay(Circle().stroke(isRecording ? Color.red : Color.cyan, lineWidth: 2))

                                if isRecording {
                                    // Stop icon (rounded square)
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.red)
                                        .frame(width: 28, height: 28)
                                } else {
                                    Circle()
                                        .fill(mode == 1 ? Color.white : Color.red)
                                        .frame(width: 30, height: 30)
                                }

                                if let msg = saveMessage {
                                    Text(msg)
                                        .font(.caption2).bold()
                                        .foregroundColor(.white)
                                        .offset(y: 50)
                                } else {
                                    Text(isRecording ? "Tap to stop" : (mode == 1 ? "Tap to scan" : ""))
                                        .font(.caption2)
                                        .foregroundColor(.white.opacity(0.7))
                                        .offset(y: 50)
                                }
                            }
                        }
                        .offset(y: -20)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var qualityColor: Color {
        let q = scanStats.averageQuality
        if q < 0.3 { return .red }
        if q < 0.6 { return .yellow }
        return .green
    }

    private var formattedTime: String {
        let minutes = recordingSeconds / 60
        let seconds = recordingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        recordingSeconds = 0
        saveMessage = nil

        // Start frame capture for raw data export
        if let session = currentARSession {
            frameCaptureSession.start(session: session, overlapMax: rawOverlapMax, rejectBlur: rawRejectBlur, privacyFilter: isPrivacyFilterOn)
        }

        // Start a timer to track recording duration
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            recordingSeconds += 1
        }
    }

    private func stopRecording() {
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil

        // Stop frame capture and get raw data path
        let rawDataPath = frameCaptureSession.stop()

        // Export and save the scan (with privacy filtering)
        guard let result = ARCoverageView.exportMeshOBJ(from: currentARSession, privacyFilter: isPrivacyFilterOn),
              !result.data.isEmpty else {
            saveMessage = "No Mesh Data"
            clearMessage()
            return
        }

        let _ = scanStore.addScan(
            meshData: result.data,
            vertexCount: result.vertexCount,
            faceCount: result.faceCount,
            rawDataPath: rawDataPath
        )

        saveMessage = "Scan Saved!"

        // Switch to Workflows tab after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            selectedTab = 2
            saveMessage = nil
        }
    }

    private func clearMessage() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            saveMessage = nil
        }
    }
}

#Preview {
    CaptureView(selectedTab: .constant(1))
        .environment(ScanStore())
}
