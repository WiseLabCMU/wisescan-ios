import MediaAccessibility
import SwiftUI

// MARK: - The screen flash for a saved still

/// How the white screen flash looks for one saved still.
///
/// WHY EVERY STILL FLASHES: ARKit plays the system camera sound for each 12MP still, and the
/// silent switch mutes it in most regions. Operators who must keep a space quiet scan with the
/// sound off, and then nothing told them stills were landing. The flash shows for every saved
/// still whether the sound is on or not. A still dropped for blur still makes the system sound
/// but saves nothing and does not flash, so a run of sounds without flashes means slow down.
///
/// WHY TWO STRENGTHS: a tapped 360° rig still is a deliberate, occasional act and keeps the full
/// camera-app blink. Automatic room stills and focus-scan stills arrive up to about two a second,
/// where the full blink would wash out the AR view the operator is steering by, so theirs is
/// fainter and shorter. With Accessibility, Motion, Dim Flashing Lights on, every flash becomes a
/// faint, slower fade.
struct CaptureFlash: Equatable, Sendable {
    enum Kind: Sendable {
        /// A tapped 360° rig still, also announced with a click and a haptic.
        case announced
        /// An automatic room still or a focus-scan still.
        case automatic
    }

    let peakOpacity: Double
    let fadeSeconds: TimeInterval

    static func style(for kind: Kind, dimFlashingLights: Bool) -> CaptureFlash {
        if dimFlashingLights {
            return CaptureFlash(peakOpacity: AppConstants.captureFlashDimmedOpacity,
                                fadeSeconds: AppConstants.captureFlashDimmedDuration)
        }
        switch kind {
        case .announced:
            return CaptureFlash(peakOpacity: AppConstants.captureFlashOpacity,
                                fadeSeconds: AppConstants.captureFlashDuration)
        case .automatic:
            return CaptureFlash(peakOpacity: AppConstants.autoStillFlashOpacity,
                                fadeSeconds: AppConstants.autoStillFlashDuration)
        }
    }
}

/// The flash layer over the whole capture view. Observation-scoping host: it reads the still
/// counters inside THIS small body, so a flash up to twice a second re-evaluates only this view,
/// never CaptureView's multi-hundred-line body (same reason StillnessReticleHost exists).
struct CaptureFlashHost: View {
    var frameCaptureSession: FrameCaptureSession
    var stillCapture: ARStillCaptureController

    @State private var opacity: Double = 0

    var body: some View {
        Color.white
            .opacity(opacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            // Counters only grow during a session; a drop is a session-start reset, not a still.
            .onChange(of: frameCaptureSession.shutterFeedbackCount) { old, new in
                if new > old { flash(.announced) }
            }
            .onChange(of: frameCaptureSession.automaticStillCount) { old, new in
                if new > old { flash(.automatic) }
            }
            .onChange(of: stillCapture.savedStillCount) { old, new in
                if new > old { flash(.automatic) }
            }
    }

    private func flash(_ kind: CaptureFlash.Kind) {
        let style = CaptureFlash.style(for: kind, dimFlashingLights: MADimFlashingLightsEnabled())
        // Two-phase so the peak actually renders: commit the peak this update, then animate down
        // on the next runloop turn. Writing both in one transaction can coalesce to 0 to 0 and
        // skip the flash entirely.
        opacity = style.peakOpacity
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: style.fadeSeconds)) { opacity = 0 }
        }
    }
}

/// The two flash strengths at their peak, side by side, for visual review. The live host shows
/// nothing until a still is saved.
#Preview("Flash peaks") {
    HStack(spacing: 0) {
        ForEach([CaptureFlash.Kind.announced, .automatic], id: \.self) { kind in
            ZStack {
                Color.gray
                Color.white.opacity(CaptureFlash.style(for: kind, dimFlashingLights: false).peakOpacity)
                Text(kind == .announced ? "Tapped rig still" : "Automatic still")
                    .font(.caption).bold()
            }
        }
    }
}

#Preview("Host, idle") {
    ZStack {
        Color.gray
        CaptureFlashHost(frameCaptureSession: FrameCaptureSession(), stillCapture: ARStillCaptureController())
    }
}
