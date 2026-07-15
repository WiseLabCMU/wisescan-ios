import SwiftUI

/// Observation-scoping host for the reticle: reads the capture session's 10Hz
/// `stillnessProgress` inside THIS small body so only the reticle re-evaluates per
/// tick — reading it directly in CaptureView would re-run its multi-hundred-line
/// body at 10Hz for the whole recording.
struct StillnessReticleHost: View {
    let session: FrameCaptureSession

    var body: some View {
        StillnessReticle(
            progress: session.stillnessProgress,
            isStill: session.isCurrentlyStill
        )
    }
}

/// Center-screen capture reticle that teaches the pause-shoot-move scanning rhythm:
/// the ring fills as the device settles, then locks green with a camera glyph while
/// the device is confirmed still (the moment a sharp hi-res keyframe is captured).
struct StillnessReticle: View {
    /// Ring-fill progress (0 = moving, 1 = confirmed still).
    let progress: Double
    /// Whether the device is confirmed still.
    let isStill: Bool

    var body: some View {
        ZStack {
            // Track ring — always faintly visible while recording so the affordance
            // ("hold still to fill the ring") stays discoverable.
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: 3)

            // Progress ring — fills clockwise from 12 o'clock over the stillness
            // confirmation window, green once confirmed.
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    isStill ? Color.green : Color.white.opacity(0.9),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.12), value: progress)

            Image(systemName: "camera.fill")
                .font(.system(size: 15))
                .foregroundColor(.green)
                .opacity(isStill ? 1 : 0)
                .scaleEffect(isStill ? 1 : 0.6)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isStill)
        }
        .frame(width: 54, height: 54)
        .shadow(color: .black.opacity(0.4), radius: 2)
    }
}

#Preview("Moving") {
    ZStack {
        Color.gray
        StillnessReticle(progress: 0, isStill: false)
    }
}

#Preview("Settling") {
    ZStack {
        Color.gray
        StillnessReticle(progress: 0.6, isStill: false)
    }
}

#Preview("Still") {
    ZStack {
        Color.gray
        StillnessReticle(progress: 1, isStill: true)
    }
}
