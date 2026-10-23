import SwiftUI
import ARKit
import RealityKit
import SwiftData
import simd

// MARK: - AR Capture (EXPERIMENT): the capture-only branch of a rescan

/// AR Capture is the Rescan flow up to Start: same entry (LocationDetailView.startRescan with
/// `stillCapture`), same world map, gates, relocalization, ghost, alignment and manual nudge. Only
/// Start and Stop differ. Start computes the same manual-nudge bake as `startRecording`, then
/// raises `isStillCapturing`; ARCoverageView re-runs the session the way record-start does
/// (preserving the relocalized frame), applies the ICP and nudge bakes, drops mesh / planes /
/// RoomPlan / ghost, and starts feeding frames to the engine. Stop zips the stills for the share
/// sheet; nothing is saved into the scan store.
extension CaptureView {

    func toggleStillCapture() {
        if isStillCapturing {
            stopStillCapture()
            return
        }
        switch stillCapture.phase {
        case .running, .stopping: return
        case .idle, .done, .failed: break
        }
        // The same pre-start gates as a rescan's record tap (toggleRecording): tracking out of the
        // cold-init state, and (Perf Diagnostics) a short hold so the ICP correction can land and
        // bake, exactly as a rescan would get it.
        guard scanStats.trackingStatus.isReadyToStartRecording else {
            scanStore.reviveARSession?()
            showTransientMessage("Hold steady — establishing tracking…", duration: 3)
            return
        }
        let shouldAwaitAlignment = PerfDiag.enabled
            && cachedGhostMeshData != nil
            && scanStats.trackingStatus.isNormal
            && scanStore.icpAlignReady == nil
            && !isAwaitingAlignment
        guard shouldAwaitAlignment else {
            startStillCapture()
            return
        }
        isAwaitingAlignment = true
        Task { @MainActor in
            defer { isAwaitingAlignment = false }
            let deadline = Date().addingTimeInterval(8)
            while scanStore.icpAlignReady == nil, Date() < deadline {
                try? await Task.sleep(nanoseconds: 150_000_000) // 150 ms
            }
            startStillCapture()
        }
    }

    /// Start of the capture-only branch. The manual ghost-nudge bake is computed exactly as
    /// `startRecording` computes it (keep the two in sync); ARCoverageView applies it, after the
    /// ICP bake, on the `isStillCapturing` rising edge.
    func startStillCapture() {
        guard let session = currentARSession else {
            showTransientMessage("AR session not ready", duration: 3)
            return
        }
        if ghostXOffset != 0 || ghostYRotation != 0 || ghostZOffset != 0 {
            let rotation = simd_quatf(angle: ghostYRotation, axis: [0, 1, 0])
            let translation = SIMD3<Float>(ghostXOffset, 0, ghostZOffset)
            bakedGhostTransform = Transform(rotation: rotation, translation: translation).matrix
            ghostYRotation = 0
            ghostXOffset = 0
            ghostZOffset = 0
        } else {
            bakedGhostTransform = nil
        }
        showManualAdjust = false
        let context = stillCaptureFrameContext()
        guard stillCapture.begin(session: session, label: resolveCurrentLocationName(), context: context) else { return }
        isStillCapturing = true
    }

    func stopStillCapture() {
        guard isStillCapturing else { return }
        isStillCapturing = false
        stillCapture.stop()
    }

    /// After the zip is handed off: leave the rescan the way cancelling one does (clear the
    /// capture state and the ghost, reset the session to a fresh frame).
    func finishStillCapture() {
        stillCapture.reset()
        scanStore.resetCaptureState()
        cachedGhostMeshData = nil
        let fresh = ARCoverageView.makeFreshConfiguration()
        currentARSession?.run(fresh, options: [.resetTracking, .removeExistingAnchors])
        showTransientMessage("AR capture finished", duration: 3)
    }

    /// What the dump records about the frame: the world-map scan (the rescan's source), its
    /// `registration.json` (that scan's raw frame -> the original scan's canonical frame), and the
    /// manual nudge bake. The ICP bake is reported by ARCoverageView when it applies one.
    private func stillCaptureFrameContext() -> ARStillCaptureSession.FrameContext {
        var context = ARStillCaptureSession.FrameContext()
        context.manualNudgeBake = bakedGhostTransform
        if let scanId = scanStore.activeScanToExtend {
            let descriptor = FetchDescriptor<CapturedScan>(predicate: #Predicate { $0.id == scanId })
            if let scan = try? modelContext.fetch(descriptor).first {
                context.worldMapScan = scan.name
                context.worldMapScanId = scan.id.uuidString
                context.registrationFile = ScanPostprocessor.artifactURL("registration.json", in: scan)
                context.originalScanId = ScanPostprocessor.original(of: scan)?.id.uuidString ?? ""
            }
        }
        return context
    }

    // MARK: Views

    /// Debug panel mid-screen (the bottom of the capture view is busy), and the short-exposure
    /// experiment switch on the trailing edge at mid-height. The panel ignores touches; the switch
    /// is the only control here.
    @ViewBuilder var stillCaptureOverlay: some View {
        if scanStore.activeScanKind == .focus || stillCapture.phase != .idle {
            ZStack {
                ARStillCaptureOverlay(controller: stillCapture)
                HStack {
                    Spacer()
                    ARStillShortExposureToggle(controller: stillCapture)
                        .padding(.trailing, 12)
                }
            }
        }
    }

    var stillCaptureShareBinding: Binding<Bool> {
        Binding(get: { stillCapture.shareURL != nil },
                set: { presented in if !presented { finishStillCapture() } })
    }

    @ViewBuilder var stillCaptureShareSheet: some View {
        if let url = stillCapture.shareURL {
            ShareSheet(activityItems: [url])
        }
    }
}
