import AVFoundation
import AudioToolbox
import Foundation
import simd
import UIKit

// Exposure-sway measurement + guards for the 360° still source (REQ-033).
//
// The pose baked into a still is the TAP-time phone pose; the camera exposes shortly
// after the shutter command is ACKNOWLEDGED. Phone motion inside that ack-anchored
// window means the pose no longer matches the pano — motion later (stitch, transfer)
// is harmless. The probe records raw samples; the verdict applies the per-model
// window afterwards, and downloaded JPGs retro-annotate EXIF exposure time so field
// scans tune the window constants per camera model.
extension ThetaCameraManager {

    /// One motion-probe sample: seconds since the tap, and displacement vs the tap pose.
    struct MotionSample {
        let sinceTap: TimeInterval
        let meters: Float
        let deg: Float
    }

    /// Samples the phone pose every 250 ms until cancelled (cancel = camera listed the
    /// file), recording each displacement vs the tap pose. Raw samples — the verdict
    /// windows are applied after the trigger, when the shutter-ack instant is known.
    func makeStillMotionProbe(tapTransform: simd_float4x4,
                              sample: @escaping () -> simd_float4x4?) -> Task<[MotionSample], Never> {
        Task { @MainActor in
            let tapPos = SIMD3<Float>(tapTransform.columns.3.x,
                                      tapTransform.columns.3.y,
                                      tapTransform.columns.3.z)
            let tapRot = simd_quatf(tapTransform)
            var samples: [MotionSample] = []
            let probeStart = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds:
                    UInt64(AppConstants.thetaMotionSampleSeconds * 1_000_000_000))
                guard let pose = sample() else { continue }
                let pos = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
                let delta = (tapRot.inverse * simd_quatf(pose)).angle * 180 / .pi
                samples.append(MotionSample(sinceTap: Date().timeIntervalSince(probeStart),
                                            meters: simd_distance(tapPos, pos),
                                            deg: min(delta, 360 - delta)))
            }
            return samples
        }
    }

    /// Max phone motion vs the tap pose over the window that can corrupt the baked
    /// pose, plus the whole trigger window for context.
    ///
    /// THE WINDOW RUNS FROM THE TAP, NOT FROM THE ACK. The sidecar's pose is sampled at
    /// the tap; the shutter fires ~ack + latency later. Whatever the phone drifts in
    /// between is exactly how wrong that pose is by the time the pano is taken. Motion
    /// afterwards — stitch, transfer — cannot affect an image already captured.
    ///
    /// Field data (360update4, Theta X over BLE): ack at 164-232 ms, EXIF exposure
    /// 1/30 s, so the real window is ~250 ms. The first implementation measured
    /// [ack, ack+1 s] and would have flagged operators for drift long after the shutter
    /// closed — still #2 moved 8 mm inside the true window and 28 mm over the full
    /// trigger, nearly tripping a guard it should never have been near.
    struct StillMotion {
        var exposureM: Float = 0
        var exposureDeg: Float = 0
        var totalM: Float = 0
        var totalDeg: Float = 0
        let ackOffset: TimeInterval?
        /// End of the pose-corrupting window, seconds after the tap.
        let window: TimeInterval
        let samples: [MotionSample]

        /// `ackOffset` nil (ack never observed) falls back to a conservative allowance
        /// rather than no guard.
        init(samples: [MotionSample], ackOffset: TimeInterval?, exposure: TimeInterval) {
            self.samples = samples
            self.ackOffset = ackOffset
            let ack = ackOffset ?? AppConstants.thetaShutterLatencyAllowance
            self.window = ack + AppConstants.thetaShutterLatencyAllowance + exposure
            for sample in samples {
                totalM = max(totalM, sample.meters)
                totalDeg = max(totalDeg, sample.deg)
                if sample.sinceTap <= window {
                    exposureM = max(exposureM, sample.meters)
                    exposureDeg = max(exposureDeg, sample.deg)
                }
            }
        }

        var swayed: Bool {
            exposureM > AppConstants.thetaSwayWarnMeters || exposureDeg > AppConstants.thetaSwayWarnDegrees
        }
    }

    /// Exposure length to assume for this model's live verdict: the longest EXIF value
    /// its downloaded stills have reported, so a dim room widens the window on its own.
    /// Seeded with the daylight default until the first still lands.
    static func expectedExposureSeconds(forModel model: String) -> TimeInterval {
        let stored = UserDefaults.standard.double(
            forKey: "\(AppConstants.Key.thetaObservedExposurePrefix).\(model)")
        guard stored > 0 else { return AppConstants.thetaDefaultExposureSeconds }
        return min(max(stored, AppConstants.thetaDefaultExposureSeconds),
                   AppConstants.thetaMaxExposureSeconds)
    }

    /// Timing facts of one completed trigger, bundled for the motion verdict.
    struct TriggerTiming {
        let start: Date
        let shutterAck: Date?
        let model: String
        let triggerMs: Int
    }

    /// Builds the ack-anchored motion verdict for a completed trigger, logs it, and
    /// runs the capture-time sway guard (count, cue, operator-facing log line).
    func resolveStillMotion(probe: Task<[MotionSample], Never>?,
                            timing: TriggerTiming, seq: Int) async -> StillMotion? {
        guard let probe else { return nil }
        let motion = StillMotion(samples: await probe.value,
                                 ackOffset: timing.shutterAck?.timeIntervalSince(timing.start),
                                 exposure: Self.expectedExposureSeconds(forModel: timing.model))
        PerfDiag.log(String(format: "[360Still] motion: pose-window %.3f m / %.1f° (ack %+dms, window 0-%dms) · total %.3f m / %.1f° over %d ms",
                            motion.exposureM, motion.exposureDeg,
                            Int((motion.ackOffset ?? 0) * 1000), Int(motion.window * 1000),
                            motion.totalM, motion.totalDeg, timing.triggerMs))
        if motion.swayed {
            swayedStillCount += 1
            playThetaSwayWarnCue()
            log(.capture, String(format: "⚠️ Still #%d: moved %.0f cm / %.1f° during the exposure "
                + "window — its pose may not match the pano. Hold still until the done tone.",
                seq, motion.exposureM * 100, motion.exposureDeg))
        }
        return motion
    }

    /// OFF-MAIN persistence for a drained still: this runs DURING a scan, and an 8 MB
    /// write plus an 11K-equirect decode is 40-200 ms — landing on main it would jank
    /// live ARKit at exactly the wrong moment. Also retro-annotates the sidecar with
    /// the EXIF exposure time (sway-window tuning data).
    static func persistDrainedStill(data: Data, stillsDir: URL, sequence: Int) async -> UIImage? {
        let dst = stillsDir.appendingPathComponent(String(format: "still_%04d.JPG", sequence))
        let sidecar = stillsDir.appendingPathComponent(String(format: "still_%04d.json", sequence))
        return await Task.detached(priority: .utility) {
            try? data.write(to: dst)
            annotateExifExposure(jpegData: data, sidecarURL: sidecar)
            return downsampledImage(from: data, maxPixel: 1200)
        }.value
    }

    /// Warning cue for a swayed still — distinct from the done tone so the operator
    /// learns the difference between "finished clean" and "finished but you moved".
    /// Synthesized double low buzz (descending): the modern app/game "error" convention,
    /// no telephony-era referent required. Audio carries the whole message on iPads
    /// (no vibration motor, little/no haptics), so it must be unmistakable.
    func playThetaSwayWarnCue() {
        let audioOn = (UserDefaults.standard.object(forKey: AppConstants.Key.captureAudioEnabled) as? Bool) ?? true
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        guard audioOn, let player = Self.swayBuzzPlayer else { return }
        player.currentTime = 0
        player.play()
    }

    /// Two short descending low buzzes (~0.3 s total), synthesized once into an
    /// in-memory WAV. A couple of harmonics on the fundamental read as "buzz"
    /// rather than "beep".
    static let swayBuzzPlayer: AVAudioPlayer? = {
        let sampleRate = 22_050.0
        let notes: [(hz: Double, dur: Double)] = [(220, 0.12), (165, 0.16)]
        let gap = 0.04
        var pcm: [Int16] = []
        for (idx, note) in notes.enumerated() {
            let count = Int(sampleRate * note.dur)
            for frame in 0..<count {
                let time = Double(frame) / sampleRate
                let envelope = min(1, time / 0.005) * exp(-time * 14)
                let phase = 2.0 * Double.pi * note.hz * time
                let value = (sin(phase) + 0.35 * sin(2 * phase) + 0.2 * sin(3 * phase)) * envelope * 0.6
                pcm.append(Int16(max(-1, min(1, value)) * 32_000))
            }
            if idx == 0 { pcm.append(contentsOf: [Int16](repeating: 0, count: Int(sampleRate * gap))) }
        }
        var data = Data()
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(16)
        put16(1); put16(1)                                    // PCM, mono
        put(UInt32(sampleRate)); put(UInt32(sampleRate) * 2)  // sample rate, byte rate
        put16(2); put16(16)                                   // block align, bits
        data.append(contentsOf: Array("data".utf8)); put(byteCount)
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return try? AVAudioPlayer(data: data)
    }()
}
