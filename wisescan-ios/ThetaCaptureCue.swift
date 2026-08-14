import AVFoundation
import SwiftUI

/// Observation-scoping host for the 360° capture cue: reads the manager's capture state
/// inside THIS small body so only the cue re-evaluates, never CaptureView's
/// multi-hundred-line body (same reason StillnessReticleHost exists).
struct ThetaCaptureCueHost: View {
    var manager: ThetaCameraManager

    var body: some View {
        ThetaCaptureCue(isCapturing: manager.isCapturing,
                        holdSeconds: manager.expectedHoldSeconds,
                        stillCount: manager.scanStillCount)
    }
}

/// Visual counterpart to the 360° audio cues.
///
/// WHY IT EXISTS: the cue sequence is audio-only, and on an iPad there is no vibration
/// motor and effectively no haptics — so with the volume down the operator gets no
/// signal at all that a still is exposing or has landed. This carries the same
/// information visually, and is shown ALWAYS (not only when muted), because it also
/// survives a noisy room.
///
/// WHAT IT TEACHES: the ring closes over the POSE-CRITICAL window — from the tap until
/// the shutter has certainly closed (learned per model: ack + latency + exposure,
/// ~0.35 s on the X, ~0.56 s on the Z1). That is the interval where movement corrupts
/// the baked pose; motion after it lands on an image already captured. So "hold until
/// the ring closes" is the literal rule, replacing "hold until the tone", which asks
/// for several seconds of stillness that the measurements say are not needed.
///
/// COST: a small SwiftUI overlay with two implicit animations. It never touches the
/// ARSession or RealityKit, so it adds nothing to the VIO path.
struct ThetaCaptureCue: View {
    let isCapturing: Bool
    /// How long the pose-critical hold lasts for the connected camera.
    let holdSeconds: TimeInterval
    let stillCount: Int

    @State private var ringProgress: CGFloat = 0
    @State private var holdComplete = false
    /// Drives the "landed in the bundle" flourish when a still finishes.
    @State private var savedPulse = false

    private var ringColor: Color { holdComplete ? .green : .orange }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.35), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))     // start the sweep at 12 o'clock
                Image(systemName: holdComplete ? "checkmark" : "camera.aperture")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(ringColor)
            }
            .frame(width: 74, height: 74)

            Text(holdComplete ? "OK to move" : "Hold still — exposing")
                .font(.caption2).bold()
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
                .cornerRadius(6)
        }
        .opacity(isCapturing || savedPulse ? 1 : 0)
        // The saved flourish: the cue drifts down and fades as the still lands in the
        // bundle — the operator sees WHERE it went without reading anything.
        .offset(y: savedPulse ? 42 : 0)
        .scaleEffect(savedPulse ? 0.75 : 1)
        .animation(.easeOut(duration: 0.45), value: savedPulse)
        .animation(.easeOut(duration: 0.2), value: isCapturing)
        .allowsHitTesting(false)
        .onChange(of: isCapturing) { _, capturing in
            if capturing { beginHold() } else { finishHold() }
        }
    }

    private func beginHold() {
        savedPulse = false
        holdComplete = false
        ringProgress = 0
        withAnimation(.linear(duration: holdSeconds)) { ringProgress = 1 }
        // Flip to "OK to move" when the pose-critical window has certainly passed.
        DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds) {
            if isCapturing { holdComplete = true }
        }
    }

    private func finishHold() {
        // The still landed: complete the ring (a capture faster than the estimate still
        // reads as finished, never as interrupted) and play the drift-away.
        withAnimation(.easeOut(duration: 0.15)) { ringProgress = 1 }
        holdComplete = true
        savedPulse = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            savedPulse = false
            ringProgress = 0
        }
    }
}

#Preview {
    ZStack {
        Color.black
        ThetaCaptureCue(isCapturing: true, holdSeconds: 0.4, stillCount: 3)
    }
}

/// One-shot check that the capture cues will actually be audible.
///
/// `AVAudioSession.outputVolume` is public API and needs no permission — reading it is
/// not a privacy imposition, and it answers the only question that matters: with the
/// volume down, the stillness chime, shutter click and 360° done tone are silent, and
/// on an iPad there is no haptic fallback. The silent SWITCH is deliberately not
/// probed: it is not reliably readable, and the visual cue covers that case anyway.
enum CaptureCueAudibility {
    /// Warned once per app run — a nag every record tap would be worse than the problem.
    private static var warned = false

    /// Returns a message when the operator should know the cues won't be heard.
    static func warningIfInaudible() -> String? {
        guard !warned else { return nil }
        let volume = AVAudioSession.sharedInstance().outputVolume
        guard volume < 0.05 else { return nil }
        warned = true
        return "🔇 Volume is off — capture cues won't be audible. The on-screen ring still "
            + "shows when to hold and when it's safe to move."
    }
}
