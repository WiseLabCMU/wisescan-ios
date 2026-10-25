import ARKit
import AVFoundation
import CoreMedia
import Foundation
import os

/// The exposure cap both capture modes put on ARKit's own camera (docs/design/capture-modes.md).
/// Auto exposure keeps metering; the cap only bounds how long it may expose, so it raises ISO
/// instead (`configurableCaptureDeviceForPrimaryCamera.activeMaxExposureDuration`).
///
/// The cap is short exposure: the shortest exposure the light allows at
/// `arStillShortExposureISOCeiling`, clamped between `arStillShortExposureFloorSeconds` and
/// `arStillMaxExposureSeconds` (1/120 s, one full 120 Hz mains-flicker cycle;
/// `ARStillCaptureGates.shortExposureCap`), re-evaluated every `arStillShortExposureUpdateSeconds`.
/// In dim light it settles on the 1/120 cap, so there is no separate fixed mode to fall back to;
/// `AppConstants.arStillShortExposure` = false holds 1/120 throughout, for a baseline.
///
/// A session re-run can hand the camera back with its default limit (RoomPlan re-runs the session
/// at record start), so each evaluation also checks the device still carries the cap and puts it
/// back if not.
///
/// Threading: `begin`, `report` and `restore` from any queue; `update` from the AR delegate queue
/// only, where its timing state lives. `begin` resets that state while the owner is not feeding
/// frames, the same pattern as the capture engine's gate state.
nonisolated final class CaptureExposurePolicy: @unchecked Sendable {

    struct Report: Equatable, Sendable {
        var appliedSeconds = 0.0
        var note = ""
    }

    /// Lines for the owner's event log (exposure-cap changes and re-applies).
    var onEvent: (@Sendable (String) -> Void)?

    private let applied = OSAllocatedUnfairLock(initialState: Report())

    // Delegate-queue-owned (reset by `begin`).
    private var capApplied = false
    private var lastUpdate: TimeInterval = -1

    var isShortExposure: Bool { AppConstants.arStillShortExposure }

    /// The cap in force and why (0 = none applied).
    var report: Report { applied.withLock { $0 } }

    /// The next `update` applies the cap from scratch. Call before frames start flowing.
    func begin() {
        capApplied = false
        lastUpdate = -1
        applied.withLock { $0 = Report() }
    }

    /// Per normally tracked frame (delegate queue). The 1/120 cap goes on first; the cap then
    /// follows the light.
    func update(at t: TimeInterval) {
        if !capApplied {
            applyFixedCap()
            lastUpdate = t
            return
        }
        guard AppConstants.arStillMaxExposureSeconds > 0,
              t - lastUpdate >= AppConstants.arStillShortExposureUpdateSeconds,
              let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        lastUpdate = t
        let current = applied.withLock { $0.appliedSeconds }
        let onDevice = CMTimeGetSeconds(device.activeMaxExposureDuration)
        if current > 0, onDevice.isFinite,
           abs(onDevice - current) / current > AppConstants.exposureCapReapplyTolerance {
            onEvent?(String(format: "exposure cap reset on the device (now %.6f s, wanted %.6f s): a session re-run? re-applying", onDevice, current))
            setMaxExposure(current, why: "re-applied after a reset")
            return
        }
        guard isShortExposure else { return }
        let exposure = CMTimeGetSeconds(device.exposureDuration)
        let iso = Double(device.iso)
        let offset = Double(device.exposureTargetOffset)
        let ceiling = min(AppConstants.arStillShortExposureISOCeiling, Double(device.activeFormat.maxISO))
        let floor = max(AppConstants.arStillShortExposureFloorSeconds, CMTimeGetSeconds(device.activeFormat.minExposureDuration))
        let target = ARStillCaptureGates.shortExposureCap(
            exposure: exposure, iso: iso, targetOffsetEV: offset, isoCeiling: ceiling,
            floor: floor, cap: AppConstants.arStillMaxExposureSeconds)
        guard current <= 0 || abs(target - current) / current > AppConstants.exposureCapChangeTolerance else { return }
        setMaxExposure(target, why: String(format: "short exposure: light %.4f (%.6f s x ISO %.0f, AE offset %+.2f EV), ISO ceiling %.0f", exposure * iso, exposure, iso, offset, ceiling))
    }

    /// Hands the camera back with auto exposure's own limit (an invalid time restores the default),
    /// so no cap leaks into later scans or the next capture's pre-record phase.
    func restore() {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
              (try? device.lockForConfiguration()) != nil else { return }
        device.activeMaxExposureDuration = .invalid
        device.unlockForConfiguration()
    }

    private func applyFixedCap() {
        capApplied = true
        let requested = AppConstants.arStillMaxExposureSeconds
        guard requested > 0 else { record(0, "cap disabled"); return }
        setMaxExposure(requested, why: "fixed cap")
    }

    /// Sets the longest exposure auto exposure may use, clamped to the active format.
    private func setMaxExposure(_ seconds: Double, why: String) {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else {
            record(0, "no configurable capture device")
            return
        }
        do {
            try device.lockForConfiguration()
            let format = device.activeFormat
            let wanted = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
            let range = CMTimeRange(start: format.minExposureDuration, end: format.maxExposureDuration)
            let clamped = CMTimeClampToRange(wanted, range: range)
            device.activeMaxExposureDuration = clamped
            let mode = device.exposureMode.rawValue
            device.unlockForConfiguration()
            let appliedSeconds = CMTimeGetSeconds(clamped)
            let shutter = String(format: "%.0f", 1 / appliedSeconds)
            record(appliedSeconds, "activeMaxExposureDuration 1/\(shutter) s (\(why); exposure mode \(mode))")
        } catch {
            record(0, "lockForConfiguration failed: \(error.localizedDescription)")
        }
    }

    private func record(_ seconds: Double, _ note: String) {
        applied.withLock { $0 = Report(appliedSeconds: seconds, note: note) }
        onEvent?("exposure cap: \(note)")
    }
}
