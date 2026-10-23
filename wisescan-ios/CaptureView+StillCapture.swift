import SwiftUI
import ARKit
import RealityKit
import SwiftData
import simd

// MARK: - Focus scan: the still-capture branch of a rescan (docs/design/capture-modes.md)

/// Where a focus capture files: snapshotted at Start, because leaving the capture tab resets the
/// capture state while the stills are still draining.
struct FocusScanTarget: Equatable {
    var locationId: UUID
    var region: FocusRegion
    var parentScanId: UUID?
}

/// A focus scan is the Rescan flow up to Start: same entry (LocationDetailView.startRescan with a
/// focus request), same world map, gates, relocalization, ghost, alignment and manual nudge. Only
/// Start and Stop differ. Start computes the same manual-nudge bake as `startRecording`, then
/// raises `isStillCapturing`; ARCoverageView re-runs the session the way record-start does
/// (preserving the relocalized frame), applies the ICP and nudge bakes, drops mesh / planes /
/// RoomPlan / ghost, places the region, and starts feeding frames to the engine. Stop drains the
/// engine and files its directory as a focus scan of the location.
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
        guard scanStore.activeFocusRequest != nil else {
            showTransientMessage("No focus region: start a focus scan from the space's Rescan button", duration: 4,
                                 systemImage: "exclamationmark.triangle.fill", tint: .orange)
            return
        }
        // The same pre-start gates as a rescan's record tap (toggleRecording): tracking out of the
        // cold-init state, and (Perf Diagnostics) a short hold so the ICP correction can land and
        // bake, exactly as a rescan would get it.
        guard scanStats.trackingStatus.isReadyToStartRecording else {
            scanStore.reviveARSession?()
            showTransientMessage("Hold steady — establishing tracking…", duration: 3)
            return
        }
        guard focusStartIsInMapFrame() else { return }
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

    /// Start of the still-capture branch. The manual ghost-nudge bake is computed exactly as
    /// `startRecording` computes it (keep the two in sync); ARCoverageView applies it, after the
    /// ICP bake, on the `isStillCapturing` rising edge.
    func startStillCapture() {
        guard let session = currentARSession else {
            showTransientMessage("AR session not ready", duration: 3)
            return
        }
        guard focusStartIsInMapFrame() else { return }   // again: the alignment wait can span a loss
        guard let locationId = scanStore.activeLocationForScan, let region = scanStore.activeFocusRequest?.region else {
            showTransientMessage("No focus region: start a focus scan from the space's Rescan button", duration: 4,
                                 systemImage: "exclamationmark.triangle.fill", tint: .orange)
            return
        }
        let nudged = ghostXOffset != 0 || ghostYRotation != 0 || ghostZOffset != 0
        if nudged {
            let rotation = simd_quatf(angle: ghostYRotation, axis: [0, 1, 0])
            let translation = SIMD3<Float>(ghostXOffset, 0, ghostZOffset)
            bakedGhostTransform = Transform(rotation: rotation, translation: translation).matrix
        } else {
            bakedGhostTransform = nil
        }
        let context = stillCaptureFrameContext()
        guard stillCapture.begin(session: session, label: resolveCurrentLocationName(), context: context) else {
            // Nothing started: keep the operator's nudge (the sliders still hold it) for a retry.
            if case .failed(let reason) = stillCapture.phase {
                showTransientMessage("Focus scan: \(reason)", duration: 5,
                                     systemImage: "xmark.octagon.fill", tint: .red)
            }
            stillCapture.reset()
            bakedGhostTransform = nil
            return
        }
        // The nudge is baked at Start (ARCoverageView.beginStillCapture), so the sliders zero now.
        if nudged {
            ghostYRotation = 0
            ghostXOffset = 0
            ghostZOffset = 0
        }
        showManualAdjust = false
        focusScanTarget = FocusScanTarget(locationId: locationId, region: region, parentScanId: scanStore.activeScanToExtend)
        isStillCapturing = true
    }

    /// The region and every still must share the room scan's frame. A rescan may start while still
    /// relocalizing (its save re-registers the mesh); a focus scan has nothing to re-register, so
    /// it waits until the session has relocalized into the map, the moment the ghost appears.
    private func focusStartIsInMapFrame() -> Bool {
        guard scanStore.sessionInMapFrame else {
            showTransientMessage("Not localized in the room scan yet: look around until the ghost mesh appears",
                                 duration: 4, systemImage: "location.magnifyingglass", tint: .yellow)
            return false
        }
        return true
    }

    /// The engine took no more stills because the session may have left the map's frame: stop,
    /// keeping the stills taken before it (they and the region are still in that frame).
    func handleFocusFrameLost(_ reason: String) {
        guard !reason.isEmpty, isStillCapturing else { return }
        stopStillCapture()
    }

    /// Drains the engine; its completion files the scan (on main, even off-screen).
    func stopStillCapture() {
        guard isStillCapturing else { return }
        isStillCapturing = false
        stillCapture.stop { phase in handleStillCapturePhase(phase) }
    }

    /// Check finishes by itself at its target; the other levels run until the operator stops.
    func finishFocusScanIfTargetReached(_ saved: Int) {
        guard isStillCapturing, let level = scanStore.activeFocusRequest?.region.detail,
              level.finishesAtTarget, saved >= level.targetStills else { return }
        stopStillCapture()
        showTransientMessage("Got \(saved) photos, saving", duration: 3,
                             systemImage: "checkmark.circle.fill", tint: .green)
    }

    /// The engine finished (or failed): file the capture as a focus scan.
    func handleStillCapturePhase(_ phase: ARStillCaptureController.Phase) {
        switch phase {
        case .done(let directory):
            saveFocusCapture(directory)
        case .failed(let reason):
            // The focus setup (map, region, alignment) stays, so a tap on record retries.
            showTransientMessage("Focus scan failed: \(reason)", duration: 5,
                                 systemImage: "xmark.octagon.fill", tint: .red)
            stillCapture.reset()
            focusScanTarget = nil
        case .idle, .running, .stopping:
            break
        }
    }

    /// Files the finished capture into the location and takes the operator to it, as a room
    /// scan's save does. A capture with no stills is discarded.
    private func saveFocusCapture(_ directory: URL) {
        let stills = stillCapture.stats.stillsSaved
        guard let target = focusScanTarget else {
            // Not reachable (Start always snapshots); the stills stay in the staging folder.
            showTransientMessage("Focus scan not saved: the capture lost its space", duration: 5,
                                 systemImage: "exclamationmark.triangle.fill", tint: .orange)
            finishStillCapture()
            return
        }
        focusScanTarget = nil
        let locationId = target.locationId, region = target.region
        // Still the active flow? Leaving the tab mid-drain already ran the leave-tab teardown (state
        // reset, ghost cleared, map released), and the operator may have armed or started another
        // scan since: then nothing here may reset the session or switch tabs.
        let stillOurs = !isRecording && scanStore.activeFocusRequest?.region == region
        guard stills > 0 else {
            try? FileManager.default.removeItem(at: directory)
            showTransientMessage(stillCapture.stats.frameLost.isEmpty ? "No photos were taken, nothing saved"
                                    : "Tracking was lost before any photo was taken, nothing saved", duration: 4,
                                 systemImage: "camera.badge.ellipsis", tint: .yellow)
            finishStillCapture(resetCaptureState: stillOurs)
            return
        }
        let result = ScanFileManager.shared.saveFocusScan(
            context: modelContext, locationId: locationId, parentScanId: target.parentScanId,
            region: region, captureDirectory: directory, stillCount: stills,
            hardwareDeviceModel: UIDevice.current.name)
        switch result {
        case .success(let scan):
            if stillCapture.stats.frameLost.isEmpty {
                showTransientMessage("Focus scan saved: \(stills) photos", duration: 3,
                                     systemImage: "checkmark.circle.fill", tint: .green)
            } else {
                showTransientMessage("Tracking was lost, so the scan stopped: saved the \(stills) photos taken before it",
                                     duration: 5, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }
            let location = scan.location
            finishStillCapture(resetCaptureState: stillOurs)
            guard stillOurs, selectedTab == 1 else { return }   // no jump away from another flow or tab
            saveNavigationTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1000))
                guard !Task.isCancelled else { return }
                selectedTab = 2
                if let location {
                    scanStore.navigationPath = NavigationPath()
                    scanStore.navigationPath.append(location)
                }
            }
        case .failure(let error):
            showTransientMessage(error.localizedDescription, duration: 6,
                                 systemImage: "xmark.octagon.fill", tint: .red)
            finishStillCapture(resetCaptureState: stillOurs)
        }
    }

    /// After the scan is filed: leave the rescan the way cancelling one does (clear the capture
    /// state and the ghost, reset the session to a fresh frame). `resetCaptureState: false` when
    /// another flow owns the capture state by now (see saveFocusCapture).
    func finishStillCapture(resetCaptureState: Bool = true) {
        stillCapture.reset()
        focusScanTarget = nil
        guard resetCaptureState else { return }
        scanStore.resetCaptureState()
        cachedGhostMeshData = nil
        // Swapping onto a map-less config drops the session's reference to the world map;
        // releasing the cache drops the other (~50 MB).
        let fresh = ARCoverageView.makeFreshConfiguration()
        currentARSession?.run(fresh, options: [.resetTracking, .removeExistingAnchors])
        ARCoverageView.releaseCachedWorldMap()
    }

    /// The region's box in the raw frame of the map being relocalized into (`activeScanToExtend`'s).
    /// Reads that scan's registration sidecar, so it runs on changes, not in the body.
    func refreshFocusBoxPlacement() {
        guard let region = scanStore.activeFocusRequest?.region, let mapScanId = scanStore.activeScanToExtend else {
            focusBoxPlacement = nil
            return
        }
        let descriptor = FetchDescriptor<CapturedScan>(predicate: #Predicate { $0.id == mapScanId })
        let mapScan = try? modelContext.fetch(descriptor).first
        let registration = mapScan.flatMap { SaveRegistration.appliedTransform(scanDirectory: $0.scanDirectory) }
        focusBoxPlacement = region.placement(inRawFrameOf: mapScanId, appliedRegistration: registration)
    }

    /// What the dump records about the frame: the world-map scan (the rescan's source), its
    /// `registration.json` (that scan's raw frame -> the original scan's canonical frame), the
    /// manual nudge bake, the region and the privacy filter. The ICP bake is reported by
    /// ARCoverageView when it applies one, and the region's placement at Start likewise.
    private func stillCaptureFrameContext() -> ARStillCaptureSession.FrameContext {
        var context = ARStillCaptureSession.FrameContext()
        context.manualNudgeBake = bakedGhostTransform
        context.region = scanStore.activeFocusRequest?.region
        context.privacyFilter = isPrivacyFilterOn
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

    /// The capture HUD near the top while a focus scan is set up or running; with Perf Diagnostics
    /// also the developer panel mid-screen and the short-exposure switch on the trailing edge.
    @ViewBuilder var stillCaptureOverlay: some View {
        if let region = scanStore.activeFocusRequest?.region,
           scanStore.activeScanKind == .focus || stillCapture.phase != .idle {
            ZStack {
                VStack {
                    FocusCaptureHUD(region: region, stats: stillCapture.stats, isCapturing: isStillCapturing)
                        .padding(.top, AppConstants.focusHUDTopPadding)
                    Spacer()
                }
                if PerfDiag.enabled {
                    ARStillCaptureOverlay(controller: stillCapture)
                    HStack {
                        Spacer()
                        ARStillShortExposureToggle(controller: stillCapture)
                            .padding(.trailing, 12)
                    }
                }
            }
        }
    }
}
