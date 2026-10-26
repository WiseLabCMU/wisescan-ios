import ARKit
import Foundation
import Observation

/// Presentation state for a focus scan's still capture (the still-capture branch of the Rescan
/// flow). Owned by CaptureView. The engine (`ARStillCaptureSession`) is fed frames by
/// ARCoverageView's session delegate; this class only starts/stops it, polls its counters, and
/// holds the result: the finished capture directory, which CaptureView files as a scan.
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
    private var timer: Timer?

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

    /// Drains and finalizes the capture; `onFinish` gets the outcome on main (`.done` with the
    /// capture directory, or `.failed`) whether or not the capture view is on screen.
    /// `privacyFilter` is the filter at Stop, which the export follows.
    func stop(privacyFilter: Bool? = nil, onFinish: (@MainActor (Phase) -> Void)? = nil) {
        guard phase == .running else { return }
        phase = .stopping
        engine.stop(privacyFilter: privacyFilter) { [weak self] url in
            Task { @MainActor [weak self] in
                guard let self else { return }
                stopPolling()
                stats = engine.liveStats()
                phase = url.map { .done($0) } ?? .failed("The capture folder was not created")
                onFinish?(phase)
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
