import AVFoundation
import SwiftUI
import UIKit

/// EXPERIMENT: the ARKit-free capture screen (Location detail > Raw Capture). Camera preview,
/// live counters from `RawCaptureSession`, Start / Stop, then a share sheet for the zip.
///
/// Debug surface: no persistence in the scan store, no pose, no coverage. The zip lands in
/// Documents/RawCaptures/ and is handed to the share sheet; the layout of its contents is in
/// docs/developer-tools.md ("Raw capture dump").
struct RawCaptureView: View {
    let locationName: String
    @Environment(\.dismiss) private var dismiss
    @State private var model = RawCaptureModel()
    @State private var showShare = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RawCapturePreview(session: model.session.captureSession)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Spacer()
                statsPanel
                controls
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.abandonIfRunning()
        }
        .sheet(isPresented: $showShare) {
            if case .done(let url) = model.phase {
                ShareSheet(activityItems: [url])
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Raw Capture").font(.headline)
                Text(locationName).font(.caption).foregroundColor(.white.opacity(0.7))
            }
            Spacer()
            Text(phaseLabel)
                .font(.caption.monospaced())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(phaseColor.opacity(0.25))
                .cornerRadius(6)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(.white.opacity(0.8))
            }
            .disabled(model.phase == .stopping)
        }
        .padding()
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var phaseLabel: String {
        switch model.phase {
        case .idle: return "idle"
        case .starting: return "starting"
        case .running: return "recording"
        case .stopping: return "zipping"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    private var phaseColor: Color {
        switch model.phase {
        case .running: return .red
        case .failed: return .orange
        case .done: return .green
        default: return .gray
        }
    }

    private var statsPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            if model.phase != .idle {
                Group {
                    Text("video \(model.setup.videoFormat)  photo \(model.setup.maxPhotoDimensions)  \(model.setup.photoCodec)/\(model.setup.qualityPrioritization)  raw \(model.setup.rawPhotoPixelFormats.isEmpty ? "n" : "y")")
                    Text("depth \(model.setup.depthFormat)  photo-depth \(flag(model.setup.depthDeliverySupported))/\(flag(model.setup.depthDeliveryEnabled))  responsive \(flag(model.setup.responsiveCaptureSupported))/\(flag(model.setup.responsiveCaptureEnabled))  K \(flag(model.setup.intrinsicsDeliveryEnabled))")
                }
                .foregroundColor(.cyan)
                Divider().background(Color.white.opacity(0.3))
            }
            let live = model.stats
            let elapsed = max(live.elapsedSeconds, 0.001)
            Text("t \(fmt(live.elapsedSeconds, 1))s  written \(fmt(Double(live.bytesWritten) / 1_048_576, 1)) MB")
            Text("photos \(live.photosSaved)/\(live.photosRequested) saved/req  fail \(live.photosFailed)  gated \(live.photosGated)  w/depth \(live.photosWithDepth)  \(fmt(Double(live.photosSaved) / elapsed, 2))/s")
            Text("last \(live.lastPhotoDimensions)  lat \(fmt(live.lastPhotoLatencySeconds, 2))s  exp \(exposure(live.lastExposureSeconds))  ISO \(live.lastISO)\(live.photoInFlight ? "  *" : "")")
            Text("depth \(live.depthFramesReceived) rx  drop \(live.depthFramesDropped)  saved \(live.depthFramesSaved)  \(live.lastDepthDimensions)  \(fmt(Double(live.depthFramesReceived) / elapsed, 1))/s  vdrop \(live.videoFramesDropped)")
            Text("imu gyro \(live.gyro.count)@\(fmt(live.gyro.hz, 0))Hz  acc \(live.accel.count)@\(fmt(live.accel.hz, 0))Hz  dm \(live.deviceMotion.count)@\(fmt(live.deviceMotion.hz, 0))Hz  mag \(live.magnetometer.count)@\(fmt(live.magnetometer.hz, 0))Hz")
            Text("ae \(exposure(live.aeExposureSeconds))  ISO \(fmt(live.aeISO, 0))  |w| \(fmt(live.rotationRateRadPerSec, 2)) rad/s  smear \(fmt(live.predictedSmearPx, 1))/\(fmt(model.setup.blurBudgetPx, 0)) px  cap \(exposure(model.setup.maxExposureCapSeconds))")
                .foregroundColor(live.predictedSmearPx > model.setup.blurBudgetPx ? .orange : .white)
            Text("space rot \(fmt(live.rotationSinceStillDeg, 1))/\(fmt(model.setup.stillSpacingRotationDeg, 0))°  shift \(fmt(live.shiftSinceStillFraction * 100, 0))/\(fmt(model.setup.stillSpacingShiftFraction * 100, 0))%  flow \(fmt(live.flowSpeedFractionPerSecond * 100, 0))%/s  held \(live.spacingHolds)  last \(live.lastSpacingReason)")
            if live.interruptions > 0 || live.runtimeErrors > 0 || !live.lastError.isEmpty {
                Text("interrupt \(live.interruptions)  rt-err \(live.runtimeErrors)  \(live.lastError)")
                    .foregroundColor(.orange)
            }
            if case .failed(let reason) = model.phase {
                Text(reason).foregroundColor(.orange)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.white)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.55))
        .cornerRadius(10)
        .padding(.horizontal, 12)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            switch model.phase {
            case .idle, .failed:
                Button {
                    model.start(label: locationName)
                } label: {
                    Label("Start", systemImage: "record.circle").font(.subheadline).bold()
                }
                .buttonStyle(FilledActionButtonStyle(background: Color.red.opacity(0.85)))
            case .starting:
                ProgressView().tint(.white).frame(maxWidth: .infinity)
            case .running:
                Button {
                    model.stop()
                } label: {
                    Label("Stop & Zip", systemImage: "stop.circle").font(.subheadline).bold()
                }
                .buttonStyle(FilledActionButtonStyle(background: Color.gray.opacity(0.85)))
            case .stopping:
                HStack {
                    ProgressView().tint(.white)
                    Text("Stopping, zipping…").font(.subheadline)
                }
                .frame(maxWidth: .infinity)
            case .done:
                Button {
                    showShare = true
                } label: {
                    Label("Share Zip", systemImage: "square.and.arrow.up").font(.subheadline).bold()
                }
                .buttonStyle(FilledActionButtonStyle(background: Color.green.opacity(0.8)))
                Button {
                    dismiss()
                } label: {
                    Text("Close").font(.subheadline).bold()
                }
                .buttonStyle(FilledActionButtonStyle(background: Color.white.opacity(0.15)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
    }

    private func flag(_ value: Bool) -> String { value ? "y" : "n" }

    private func fmt(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    private func exposure(_ seconds: Double) -> String {
        guard seconds > 0 else { return "-" }
        return seconds >= 1 ? fmt(seconds, 2) + "s" : "1/" + String(Int((1 / seconds).rounded()))
    }
}

/// Presentation state around a `RawCaptureSession`. Main-actor; the session itself is not.
@Observable
@MainActor
final class RawCaptureModel {
    enum Phase: Equatable {
        case idle, starting, running, stopping
        case done(URL)
        case failed(String)
    }

    let session = RawCaptureSession()
    var phase: Phase = .idle
    var setup = RawCaptureSession.Setup()
    var stats = RawCaptureSession.LiveStats()
    private var timer: Timer?

    func start(label: String) {
        phase = .starting
        Task { [self] in
            guard await Self.cameraAuthorized() else {
                phase = .failed("Camera access denied (Settings > Privacy > Camera)")
                return
            }
            // The capture tab's AR session is told to pause on the same tick this screen opens;
            // its pause runs in the next SwiftUI update. A short beat keeps the two from racing
            // for the camera. Debug build — a notification handshake is not worth it here.
            try? await Task.sleep(for: .milliseconds(400))
            session.start(label: label) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch result {
                    case .success(let setup):
                        self.setup = setup
                        phase = .running
                        startPolling()
                    case .failure(let error):
                        phase = .failed("\(error)")
                    }
                }
            }
        }
    }

    func stop() {
        guard phase == .running else { return }
        phase = .stopping
        stopPolling()
        stats = session.liveStats()
        session.stop { [weak self] url in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let url {
                    phase = .done(url)
                } else {
                    phase = .failed("Zip failed; the capture directory was kept in Documents/\(AppConstants.rawCaptureFolder)")
                }
            }
        }
    }

    /// Swiped away mid-recording: stop and keep the data (the zip stays in Documents).
    func abandonIfRunning() {
        if phase == .running { stop() }
    }

    private func startPolling() {
        stopPolling()
        timer = Timer.scheduledTimer(withTimeInterval: AppConstants.rawCaptureStatsRefreshSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                stats = session.liveStats()
            }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private static func cameraAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

/// `AVCaptureVideoPreviewLayer` host. Rotation follows the interface orientation once the
/// session is running (the connection does not exist before that).
private struct RawCapturePreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.attach(session)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        private var observer: NSObjectProtocol?

        private var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }

        func attach(_ session: AVCaptureSession) {
            previewLayer?.session = session
            previewLayer?.videoGravity = .resizeAspect
            observer = NotificationCenter.default.addObserver(
                forName: AVCaptureSession.didStartRunningNotification, object: session, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyRotation() }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyRotation()
        }

        private func applyRotation() {
            guard let connection = previewLayer?.connection else { return }
            let orientation = window?.windowScene?.interfaceOrientation ?? .portrait
            let angle: CGFloat
            switch orientation {
            case .landscapeRight: angle = 0
            case .landscapeLeft: angle = 180
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
