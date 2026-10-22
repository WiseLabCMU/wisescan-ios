import ARKit
import SwiftUI
import simd

/// EXPERIMENT: presentation state for the capture-only branch of the Rescan flow (AR Capture).
/// Owned by CaptureView. The engine (`ARStillCaptureSession`) is fed frames by ARCoverageView's
/// session delegate; this class only starts/stops it, polls its counters, and holds the result.
@Observable
@MainActor
final class ARStillCaptureController {
    enum Phase: Equatable {
        case idle, running, stopping
        case done(URL)
        case failed(String)
    }

    let engine = ARStillCaptureSession()
    var phase: Phase = .idle
    var stats = ARStillCaptureSession.LiveStats()
    /// Short-exposure experiment toggle. Kept across captures in this session so an A/B pair
    /// is two taps apart; takes effect while capturing and is recorded per still.
    private(set) var shortExposure = false
    private var timer: Timer?

    func setShortExposure(_ on: Bool) {
        shortExposure = on
        engine.setShortExposure(on)
    }

    var shareURL: URL? {
        if case .done(let url) = phase { return url }
        return nil
    }

    func begin(session: ARSession, label: String, context: ARStillCaptureSession.FrameContext) -> Bool {
        do {
            try engine.begin(session: session, label: label, context: context)
            phase = .running
            startPolling()
            return true
        } catch {
            phase = .failed("Could not start: \(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        guard phase == .running else { return }
        phase = .stopping
        engine.stop { [weak self] url in
            Task { @MainActor [weak self] in
                guard let self else { return }
                stopPolling()
                stats = engine.liveStats()
                phase = url.map { .done($0) } ?? .failed("Zip failed; the capture directory was kept in Documents/\(AppConstants.arStillFolder)")
            }
        }
    }

    func reset() {
        stopPolling()
        phase = .idle
        stats = ARStillCaptureSession.LiveStats()
    }

    private func startPolling() {
        stopPolling()
        timer = Timer.scheduledTimer(withTimeInterval: AppConstants.arStillStatsRefreshSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                stats = engine.liveStats()
            }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}

/// Debug panel for AR Capture, drawn in the middle of the capture view (the bottom is busy).
/// The first line is the point of the experiment: the still resolution and the exposure the
/// stills actually got, against the cap.
struct ARStillCaptureOverlay: View {
    let controller: ARStillCaptureController

    var body: some View {
        let live = controller.stats
        let elapsed = max(live.elapsedSeconds, 0.001)
        let budget = live.blurBudgetPx
        let threshold = AppConstants.arStillViewpointThresholdDeg
        let smear = live.smearImageMotionPx
        return VStack(alignment: .leading, spacing: 3) {
            Text("AR CAPTURE  \(phaseLabel)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)
            Text("still \(live.lastStillDimensions.isEmpty ? "-" : live.lastStillDimensions)  exp \(exposure(live.lastStillExposureSeconds))  ISO \(fmt(live.lastStillISO, 0))")
                .font(.system(size: 17, weight: .bold, design: .monospaced))
            Text("stream \(live.streamDimensions)  exp \(exposure(live.streamExposureSeconds))  cap \(exposure(live.exposureCapAppliedSeconds))")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
            Text(shortExposureLine(live))
                .foregroundColor(live.shortExposure ? .yellow : .white.opacity(0.7))
            Text("stills\(live.stillsSaved)/\(live.stillsRequested)  fail \(live.stillsFailed)  w/depth \(live.stillsWithDepth)  \(fmt(Double(live.stillsSaved) / elapsed, 2))/s  pend \(live.pendingEncodes)\(live.inFlight ? " *" : "")")
            Text("last lat \(fmt(live.lastLatencySeconds, 2))s  why \(live.lastReason)  tracking \(live.tracking)")
            Text("held blur \(live.heldBlurFrames)  spacing \(live.heldSpacingFrames)  backlog \(live.heldBackpressureFrames)")
            Text("gyro \(fmt(live.angularRate, 2)) rad/s  side \(fmt(live.lateralSpeed, 2)) m/s  near \(fmt(live.gateDepth, 2)) m")
            Text("smear \(fmt(smear, 1)) / \(fmt(budget, 1)) px  (\(fmt(AppConstants.arStillBlurBudgetRad * 1000, 2)) mrad; rotation + sidestep)")
                .foregroundColor(smear > budget ? .orange : .white)
            Text("view turn \(fmt(live.rotationSinceStillDeg, 1)) / parallax \(fmt(live.parallaxSinceStillDeg, 1)) of \(fmt(threshold, 0)) deg")
            Text("frames \(live.framesLogged)  gyro \(live.gyroSamples)  t \(fmt(live.elapsedSeconds, 1))s  \(fmt(Double(live.bytesWritten) / 1_048_576, 1)) MB")
            if !live.exposureCapNote.isEmpty {
                Text(live.exposureCapNote).foregroundColor(.white.opacity(0.7))
            }
            if !live.lastError.isEmpty {
                Text(live.lastError).foregroundColor(.orange)
            }
            if case .failed(let reason) = controller.phase {
                Text(reason).foregroundColor(.orange)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.white)
        .padding(10)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Color.black.opacity(0.6))
        .cornerRadius(10)
        .padding(.horizontal, 12)
        .allowsHitTesting(false)
    }

    private var phaseLabel: String {
        switch controller.phase {
        case .idle: return "ready: align, then tap record"
        case .running: return "capturing"
        case .stopping: return "finishing stills, zipping"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    private func shortExposureLine(_ live: ARStillCaptureSession.LiveStats) -> String {
        guard live.shortExposure else {
            return "short exp off: fixed cap \(exposure(AppConstants.arStillMaxExposureSeconds))"
        }
        let ceiling = fmt(AppConstants.arStillShortExposureISOCeiling, 0)
        let floor = exposure(AppConstants.arStillShortExposureFloorSeconds)
        return "SHORT EXP ON: ISO <= \(ceiling), no shorter than \(floor)  (\(live.stillsShortExposure) stills)"
    }

    private func fmt(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    private func exposure(_ seconds: Double) -> String {
        guard seconds > 0 else { return "-" }
        return seconds >= 1 ? fmt(seconds, 2) + "s" : "1/" + String(Int((1 / seconds).rounded()))
    }
}

/// The short-exposure experiment switch, on the trailing edge at mid-height so it stays clear of
/// the busy bottom controls and the centred panel. Usable before Start and during a capture.
struct ARStillShortExposureToggle: View {
    let controller: ARStillCaptureController

    var body: some View {
        let on = controller.shortExposure
        Button {
            controller.setShortExposure(!on)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: on ? "timer.circle.fill" : "timer.circle")
                    .font(.system(size: 30))
                Text("SHORT\nEXP")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .multilineTextAlignment(.center)
                Text(on ? "ON" : "OFF")
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
            }
            .foregroundColor(on ? .black : .white)
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .background(on ? Color.yellow : Color.black.opacity(0.6))
            .cornerRadius(14)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.yellow, lineWidth: 2))
        }
        .accessibilityLabel("Short exposure experiment")
        .accessibilityValue(on ? "on" : "off")
    }
}
