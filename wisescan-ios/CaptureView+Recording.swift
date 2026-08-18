import SwiftUI
import ARKit
import RealityKit
import SwiftData
import RoomPlan
import os

// MARK: - Recording Controls

extension CaptureView {

    func toggleRecording() {
        if isRecording {
            // Every user-initiated stop confirms via the menu — the old rescan bypass saved
            // immediately on an accidental tap with no way to cancel/discard (2026-07-22 field
            // report). Rescans simply see fewer options (the menu hides Save & Scan Adjacent
            // itself). Programmatic stops (extend flow, VIO-compromised halt) call
            // stopRecording()/performStopRecording directly and are unaffected.
            showStopMenu = true
        } else {
            // Link-adjacent recording ALWAYS starts programmatically after the user aligns to the
            // previous scan: confirmAlignment / pinAndExtend capture Pin A, reset into the new map,
            // place Pin B, then call startRecording() directly (awaitStabilizationAndPlacePinB),
            // bypassing toggleRecording. A MANUAL record tap in a link-adjacent flow is therefore never
            // the intended path — allowing it starts an un-aligned scan whose world frame is wrong
            // (~90° off, or a smaller offset). Block it unconditionally for the whole pre-recording
            // window.
            //
            // Keyed on activeScanCase ALONE — not activeScanToExtend or capturePhase — because both are
            // cleared/late-set inside the flow: confirmAlignment/pinAndExtend nil out activeScanToExtend,
            // and capturePhase enters the alignment set only in ARCoverageView.onAppear (after the first
            // render). Either left a window where the live record button could start an un-aligned scan
            // (the ~90°/offset ghost-jump race). activeScanCase is set synchronously at the trigger
            // (LocationDetailView / pinAndExtend) and reset to .rescanSpace on save/abort, so it is true
            // for exactly the pre-recording window and never blocks normal scans or rescans.
            if scanStore.activeScanCase == .linkAdjacent {
                showTransientMessage("Align with the previous scan first", duration: 3)
                return
            }
            // Gate user-initiated record-start on tracking being out of the cold-init state, so a scan
            // can't begin while VIO is still initializing (those frames have no reliable world frame —
            // the cause of stuck/empty cold first scans). Only blocks .initializing/.notAvailable;
            // .relocalizing is allowed so rescan/link-adjacent relocalization flows still start. The
            // programmatic extend/alignment start path (awaitStabilizationAndPlacePinB) bypasses
            // toggleRecording and already waits for .normal, so chained scans are unaffected.
            guard scanStats.trackingStatus.isReadyToStartRecording else {
                // Self-heal a dead session before bouncing: if no ARFrame has arrived for
                // several seconds the capture graph is wedged (post-idle Fig err storm,
                // 2026-07-24 run 3) and "establishing tracking" would bounce forever —
                // re-running the config rebuilds the graph so the NEXT tap succeeds. No-op
                // while frames are flowing (normal 1–2 s VIO warm-up).
                scanStore.reviveARSession?()
                showTransientMessage("Hold steady — establishing tracking…", duration: 3)
                return
            }
            // Phase 2.1 (perfDiag): if we're relocalized into a rescan but the auto-align correction
            // isn't ready yet (the green chip hasn't appeared), briefly hold so it can land and bake —
            // the ghost mesh being visible is NOT the same as the correction being locked. Times out →
            // record raw (feature-poor spaces that never produce a trusted correction aren't blocked).
            // Removes the "recorded a hair before the refine completed → no bake" miss.
            let shouldAwaitAlignment = PerfDiag.enabled
                && cachedGhostMeshData != nil
                && scanStats.trackingStatus.isNormal
                && scanStore.icpAlignReady == nil
                && !isAwaitingAlignment
            guard shouldAwaitAlignment else {
                startRecordingCheckingShutterPath()
                return
            }
            isAwaitingAlignment = true
            Task { @MainActor in
                defer { isAwaitingAlignment = false }
                let deadline = Date().addingTimeInterval(8)
                while scanStore.icpAlignReady == nil, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 150_000_000) // 150 ms
                }
                startRecordingCheckingShutterPath()
            }
        }
    }

    /// Record-start work for the 360° source: warn if the audio cues will be inaudible,
    /// open the still session, and confirm the camera is really reachable before the
    /// operator walks off (the chip reports the verdict — CaptureView observes
    /// `cameraUnresponsive`). Extracted to keep `startRecording` inside the body-length
    /// limit.
    private func armThetaForRecording() {
        if let cueWarning = CaptureCueAudibility.warningIfInaudible() {
            showTransientMessage(cueWarning, duration: 5)
        }
        ThetaCameraManager.shared.beginScanStillSession(rawDataDir: frameCaptureSession.captureDir)
        Task { await ThetaCameraManager.shared.verifyReadyForCapture() }
    }

    /// Records only after the operator knows which shutter path they are getting.
    ///
    /// The OSC fallback is silent and capture still works, which is the problem: BLE
    /// shuts the camera ~1.3 s faster per still and pushes the file URL instead of
    /// polling, so a dropped link quietly turns a brisk scan into a slow one. Worse, the
    /// sway window is anchored on the shutter ack, and an OSC ack is an HTTP round trip
    /// — on a loaded device that measured up to 3.4 s, which makes the resulting sway
    /// numbers meaningless rather than merely late.
    ///
    /// So it asks, rather than choosing for them: reconnect, continue on Wi-Fi, or
    /// cancel. Nothing is blocked — Wi-Fi capture is legitimate — but it stops being the
    /// default that nobody noticed.
    func startRecordingCheckingShutterPath() {
        // Rig height first: it is the one pre-flight whose failure cannot be recovered
        // afterwards. The solve anchors dy to it within ±5 cm and has been seen riding
        // both walls of that window, so an unset or mistyped height does not merely
        // degrade the result — it produces confidently wrong poses, and the colour lands
        // wrong with a healthy-looking residual. Warning at the FIRST STILL (where this
        // used to live) is too late: the operator has already walked into the room.
        if ThetaCameraManager.shared.isConnected, rigHeightImplausible {
            showRigHeightPrompt = true
            return
        }
        continueAfterRigHeightWarning()
    }

    /// Unset, or outside what any real rig measures.
    var rigHeightImplausible: Bool {
        rigMeasuredDyMeters < AppConstants.rigHeightMinPlausibleMeters
            || rigMeasuredDyMeters > AppConstants.rigHeightMaxPlausibleMeters
    }

    /// Prompt action: past the rig-height question, carry on with the shutter-path one.
    ///
    /// The path has to be PROVEN here, not read off `canShutterOverBLE`, and it has to be
    /// proven before recording rather than alongside it: the probe used to run in a
    /// detached Task from `armThetaForRecording`, racing the first still it was meant to
    /// protect. One control write settles it in well under a second.
    func continueAfterRigHeightWarning() {
        guard ThetaCameraManager.shared.isConnected else {
            startRecording()
            return
        }
        isReconnectingBLE = true
        Task { @MainActor in
            await ThetaCameraManager.shared.prepareShutterPath()
            isReconnectingBLE = false
            if ThetaCameraManager.shared.shutterPathIsBLE {
                startRecording()
            } else {
                showBLEShutterPrompt = true
            }
        }
    }

    /// Prompt action: try to bring the BLE link back, then record either way — a failed
    /// reconnect must not strand the operator standing in the room.
    func reconnectBLEThenRecord() {
        isReconnectingBLE = true
        Task { @MainActor in
            // `ensureLinkReady` early-returns when the link IS ready, which is the exact
            // state a refused control plane leaves behind — so on that failure this used
            // to be a placebo. Tear the link down first: a fresh connection is the only
            // thing that can re-trigger encryption or re-read a moved attribute table.
            _ = await ThetaBLEManager.shared.recoverControlPlane()
            isReconnectingBLE = false
            if !ThetaBLEManager.shared.canShutterOverBLE {
                showTransientMessage(
                    "Bluetooth control is still refused — recording over Wi-Fi. To fix it: "
                    + "Settings → Bluetooth → ⓘ next to the camera → Forget This Device, then "
                    + "pair it again from Add Camera.", duration: 8)
            }
            startRecording()
        }
    }

    func startRecording() {
        // Bake the manual ghost-mesh offsets into the ARKit world origin right before recording
        // starts (restored from main). ARCoverageView consumes bakedGhostTransform via
        // session.setWorldOrigin at record-start so the captured mesh + the world map we export at
        // save time are co-framed in the SAME (nudged) origin — see finishStopRecording's co-framing
        // comment. In the link-adjacent mapB flow the ghost is cleared so offsets are 0 → nil bake.
        if ghostXOffset != 0 || ghostYRotation != 0 || ghostZOffset != 0 {
            let rotation = simd_quatf(angle: ghostYRotation, axis: [0, 1, 0])
            let translation = SIMD3<Float>(ghostXOffset, 0, ghostZOffset)
            bakedGhostTransform = Transform(rotation: rotation, translation: translation).matrix
            // Zero the sliders so the visual offset isn't double-applied after baking.
            ghostYRotation = 0
            ghostXOffset = 0
            ghostZOffset = 0
        } else {
            bakedGhostTransform = nil
        }
        showManualAdjust = false // dismiss the manual-adjust panel once recording begins

        isRecording = true
        // Item 2: clear any prior scan's tracking-unreliable warning so it doesn't bleed into this run
        // (the coordinator's TrackingStabilityMonitor accumulators reset in resetForRecording).
        scanStore.trackingUnreliable = nil
        // Baseline for the "move the camera to start the live mesh" cue. In a relocalized ghost /
        // stitch-boundary flow `totalVertices` already starts high, so the cue is shown until enough
        // NEW vertices appear relative to this baseline (not an absolute count).
        verticesAtRecordStart = scanStats.totalVertices
        if scanStore.capturePhase == .idle {
            scanStore.capturePhase = .recording
        }
        recordingSeconds = 0
        saveMessage = nil
        scanCoach.reset()
        sampleStorageHeadroom()
        // Reset the per-scan 360° still counter so equirect_stills/ numbering starts at 1.
        armThetaForRecording()

        // Rod-stillness rig mode: with the 360° camera riding above the phone, tighten
        // the angular stillness gate by the lever arm (measured rig height when set,
        // mechanical prior otherwise). Phone-only scans keep the base thresholds.
        if ThetaCameraManager.shared.isConnected {
            let measured = Float(UserDefaults.standard.double(forKey: AppConstants.Key.rigMeasuredDyMeters))
            frameCaptureSession.rigLeverArmMeters = measured > 0.1 ? measured : AppConstants.rigRodHeightMeters
        } else {
            frameCaptureSession.rigLeverArmMeters = nil
        }

        // Start frame capture for raw data export
        if let session = currentARSession {
            // Provide LocationManager to frame capture session so it can grab metadata
            frameCaptureSession.start(
                session: session,
                overlapMax: overlapMax,
                rejectBlur: rejectBlur,
                privacyFilter: isPrivacyFilterOn, // Applied during export
                locationManager: locationManager,
                activeLocationId: scanStore.activeLocationForScan,
                hardwareDeviceModel: UIDevice.current.name,
                mockIMU: developerMode && mockIMU,
                mockCameraImages: developerMode && mockCameraImages,
                mockDepthMaps: developerMode && mockDepthMaps
            )
        }

        // Start a timer to track recording duration
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            recordingSeconds += 1
            if recordingSeconds > 4 {
                showExtendPrompt = false // Auto-dismiss after recording starts
            }
        }
    }

    func stopRecording(force: Bool = false) {
        // ── Extract all AR data BEFORE switching to nominal mode ──
        // (Setting isRecording = false triggers ARCoverageView to drop mesh anchors)
        //
        // Force path (onDisappear teardown): NO gates, NO waits — it must never hang or block teardown.
        if force {
            recordingTimer?.invalidate()
            recordingTimer = nil
            performStopRecording()
            return
        }

        // Re-entrancy guard for the async settle below. The record button stays live until
        // performStopRecording claims isProcessingMesh, so without this a second tap during the
        // hold-steady window would launch a second stop.
        guard !isProcessingMesh && !isWaitingToSave && !isStabilizingBeforeSave else { return }
        isStabilizingBeforeSave = true

        // TWO GATES, reconciled. They guard DIFFERENT failures, so we keep both — and order matters:
        //
        //  (1) HOLD STEADY (new, soft): wait (bounded) for tracking == .normal so the mesh snapshot +
        //      world-map export aren't captured mid-drift (handheld motion toward the Stop button).
        //      Runs FIRST — deliberately — because it also DE-FLICKERS gate (2): mappingStatus is read
        //      from the current frame, so a transient .limited at Stop can momentarily knock it off
        //      "mapped" and FALSE-REJECT a genuinely good scan. Settling first makes gate (2) read a
        //      stable state. It's SOFT: on timeout we fall through (the scan's data is already frozen,
        //      the saved mesh re-pins on ARKit corrections, and the world-map export has its own hard
        //      failure reprompt) — we never hard-reject a completed scan for failing to hold still.
        //
        //  (2) FEATURE GATE (existing, hard): require a "mapped" world map — a scan that can't
        //      relocalize later isn't worth saving. Unchanged behavior (keep recording + prompt to map
        //      more on failure), just evaluated AFTER the settle instead of on a possibly-dipped state.
        //
        // force bypasses BOTH (above). The direct performStopRecording() paths (extend / programmatic)
        // are unaffected — they stabilize at their START via awaitStabilizationAndPlacePinB.
        Task { @MainActor in
            defer { isStabilizingBeforeSave = false }

            _ = await awaitTrackingNormalForSave() // (1) soft settle

            guard scanStats.hasEnoughFeaturesForRelocalization else { // (2) hard gate, post-settle
                saveMessage = nil
                showInsufficientTrackingAlert = true
                return
            }

            recordingTimer?.invalidate()
            recordingTimer = nil
            performStopRecording()
        }
    }

    /// Best-effort "hold steady" settle before the save pose is captured. Polls up to
    /// `stabilizationMaxPolls` for tracking `.normal` so the mesh snapshot + world-map export aren't
    /// taken mid-drift. Returns whether it settled; the caller proceeds regardless on timeout (see the
    /// SOFT rationale in stopRecording). Silent in the common case — the message only shows if tracking
    /// isn't already `.normal` on entry.
    @MainActor
    private func awaitTrackingNormalForSave() async -> Bool {
        if currentARSession?.currentFrame?.camera.trackingState == .normal { return true }
        saveMessage = "Hold steady — saving…"
        for _ in 0..<AppConstants.stabilizationMaxPolls {
            try? await Task.sleep(for: .milliseconds(AppConstants.stabilizationPollIntervalMs))
            if currentARSession?.currentFrame?.camera.trackingState == .normal { return true }
        }
        return false
    }

    /// Resolves the current location name from the model context.
    func resolveCurrentLocationName() -> String {
        guard let locId = scanStore.activeLocationForScan else { return "Unknown" }
        let descriptor = FetchDescriptor<ScanLocation>(predicate: #Predicate { $0.id == locId })
        return (try? modelContext.fetch(descriptor).first?.name) ?? "Unknown"
    }

    func performStopRecording(completion: ((CapturedScan?) -> Void)? = nil) {
        // Re-entrancy guard. The pipeline below hops to a background queue (capSession.stop() flushes
        // every per-frame JSON — seconds on a long scan) BEFORE finishStopRecording sets the flags the
        // capture button's .disabled watches. Until this fix, isRecording stayed true and the button
        // stayed enabled/"Tap to stop" across that whole gap, so a second tap launched a SECOND save
        // pipeline → duplicate scan. Claim the in-flight state synchronously on this tap: disables the
        // button immediately and short-circuits any re-entrant call. saveMessage gives instant feedback
        // (the missing feedback is what made users tap again). Reset on every early-exit path below.
        guard !isProcessingMesh && !isWaitingToSave else { return }
        isProcessingMesh = true
        saveMessage = "Finishing scan…"

        // Flush the per-frame capture JSONs OFF the main thread (O(frames)) so ending a long scan
        // doesn't freeze the UI or starve ARKit (perf fix ported from main). The mesh export and
        // world-map co-framing that follow must run on main with the AR session still live, so we
        // hop back before any of that — the ordering (and the map↔OBJ co-framing) is unchanged.
        let capSession = frameCaptureSession
        // Stop the capture timer on the main thread NOW, before stop() runs off-main below.
        // The timer was scheduled on the main run loop and Timer isn't safe to invalidate from
        // another thread; this also guarantees no further frames are captured during shutdown.
        // (FrameCaptureSession.pauseCapture() contract — see its docs.)
        capSession.pauseCapture()
        // Snapshot the save-routing state NOW, on main, while it's still valid. The pipeline below
        // resolves asynchronously, and a teardown/reset between here and finishStopRecording (most
        // notably onDisappear's resetCaptureState) would otherwise clear scanStore — making an
        // in-progress rescan look like a brand-new location and triggering prompts on a dead view.
        let locationId = scanStore.activeLocationForScan
        let scanCase = scanStore.activeScanCase
        // Snapshot detected semantic display classes for metadata (populated by RoomPlan coordinator)
        capSession.semanticClassesDetected = scanStats.detectedClasses
        // Snapshot final photo-coverage stats for metadata (populated by the coverage grid)
        if scanStats.photoCoverageOccupied > 0 {
            capSession.photoCoverageStats = FrameCaptureSession.PhotoCoverageSummary(
                covered: scanStats.photoCoverageCovered,
                occupied: scanStats.photoCoverageOccupied,
                meanStillOverlap: scanStats.meanStillOverlap,
                standpointDiversity: scanStats.standpointDiversity
            )
        }
        DispatchQueue.global(qos: .utility).async {
            let rawDataPath = capSession.stop()
            DispatchQueue.main.async {
                self.finishStopRecording(rawDataPath: rawDataPath, locationId: locationId,
                                         scanCase: scanCase, completion: completion)
            }
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private func finishStopRecording(rawDataPath: URL?, locationId: UUID?, scanCase: ScanCase,
                                     completion: ((CapturedScan?) -> Void)? = nil) {
        // SNAPSHOT the mesh from the still-active AR session: a handful of memcpys (raw vertex/face
        // buffers + segmentation pixels + camera matrices), all by value. This is the only mesh work
        // that must stay on the main/AR thread at Stop, so the copied data is co-framed (same instant,
        // same world frame) with the segmentation — including through the scan-adjacent/extend flow,
        // which routes through this same path. ALL the heavy work — the per-vertex world transform,
        // the privacy person-projection, AND the OBJ string formatting (together the old multi-second
        // main-thread freeze that stalled the name prompt) — is deferred to buildMeshOBJ(from:) in the
        // off-main block below. snapshotMeshBuffers reads currentFrame inside pinned ARFrame memory, so
        // grab it once here and reuse it for the thumbnail below.
        let currentFrame = currentARSession?.currentFrame
        let meshSnapshot = ARCoverageView.snapshotMeshBuffers(from: currentFrame, privacyFilter: isPrivacyFilterOn)

        // DEFERRED ROOMPLAN BUILD: we no longer snapshot a live CapturedRoom here — recording stopped
        // consuming the live incremental room (it cost ~215 MB of contested during-scan memory and
        // competed with VIO). The room is now reconstructed by RoomBuilder from CapturedRoomData in the
        // background save block below, triggered AFTER the world-map export so its CPU can't perturb
        // the pose-sensitive capture. The old semantic↔mesh ~90° drift race is gone with the live
        // consume: RoomBuilder reconstructs in the world frame the scan was captured in, once, at end.

        // [DEFERRED-ROOMPLAN] DECISION 3 (revised 2026-07-16): the deferred box gets its
        // destination only AFTER saveScan completes (see savePendingScan / the extend flow) —
        // that's the trigger gate that keeps the in-process RoomBuilder off the pose-sensitive
        // save path (world-map export below). didEndWith just stashes the CapturedRoomData in the
        // box until then; the save never waits on RoomPlan.

        // Now that the mesh is frozen above, end the recording-mode RoomPlan session immediately
        // rather than waiting for updateUIView's nominal-downgrade branch — which the post-Stop save
        // pipeline stalls for 15–25s, so RoomPlan kept running, re-basing its room and burning
        // battery long after Stop. Stopping here can't affect the saved data (already snapshotted)
        // or the mesh export (already done). Idempotent — updateUIView's later stopRoomPlanSession()
        // guard-returns once roomCaptureSession is nil.
        scanStore.requestStopRoomPlan?()

        // Capture a 2D thumbnail from the current camera frame
        var thumbnailData: Data?
        if let currentFrame = currentFrame {
            let ciImage = CIImage(cvPixelBuffer: currentFrame.capturedImage)
            let context = CIContext()
            if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
                let uiImage = UIImage(cgImage: cgImage)
                let maxW = AppConstants.thumbnailMaxWidth
                let targetSize = CGSize(width: maxW, height: maxW * (uiImage.size.height / uiImage.size.width))
                let renderer = UIGraphicsImageRenderer(size: targetSize)
                let resizedImage = renderer.image { _ in
                    UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
                        .draw(in: CGRect(origin: .zero, size: targetSize))
                }
                thumbnailData = resizedImage.jpegData(compressionQuality: AppConstants.thumbnailJpegQuality)
            }
        }

        var finalSnapshot = meshSnapshot

        // If test modes are active and no mesh was generated (e.g. Simulator), inject a dummy mesh
        if finalSnapshot == nil {
            if developerMode && (mockCameraImages || mockIMU || mockDepthMaps) {
                finalSnapshot = ARCoverageView.dummyMeshSnapshot()
            }
        }

        guard let snapshot = finalSnapshot else {
            // No live mesh to snapshot. Two distinct cases land here:
            //
            // LITE MODE (no LiDAR): a meshless snapshot is the NORM — this device never has
            // ARMeshAnchors — not a tracking loss. Feature-based world maps still work without
            // LiDAR (older Lite builds saved them and their rescans relocalize from them), so
            // export the map and route through the normal pendingScan flow: a new space still
            // gets its name prompt, and the scan saves with an empty mesh (the backend
            // reconstructs geometry from the raw frames). Regression fixed 2026-07-22: this
            // guard's recovery path silently saved every Lite scan as an unnamed
            // "Recovered Scan" with no world map.
            //
            // VIO LOSS (LiDAR device, tracking relocalizing at Stop): ARKit dropped its mesh
            // anchors, and a relocalizing session's map is unreliable — preserve the raw
            // frames as a mesh-less, map-less scan below rather than discarding everything.
            // Extend flows need a co-framed mesh + world map either way, so those discard.
            let rawFrameCount: Int = rawDataPath.map {
                (try? FileManager.default.contentsOfDirectory(atPath: $0.appendingPathComponent("images").path).count) ?? 0
            } ?? 0

            if completion == nil, !ARCoverageView.supportsLiDAR, rawFrameCount > 0 {
                isRecording = false
                saveMessage = "Saving World Map..."
                VertexColorAccumulator.exportWorldMap(from: currentARSession) { mapURL, mapSuspect in
                    DispatchQueue.main.async {
                        // A nil mapURL degrades to a mapless (non-relocalizable) scan rather
                        // than a Retry/Discard alert — the raw frames are the payload on this
                        // device class, and the name prompt below must still happen.
                        self.pendingScan = PendingScanData(
                            locationId: locationId, meshData: Data(), vertexCount: 0, faceCount: 0,
                            rawDataPath: rawDataPath, vertexColors: nil, worldMapURL: mapURL,
                            thumbnailData: thumbnailData, scanCase: scanCase,
                            worldMapSuspect: mapSuspect)
                        self.frameCaptureSession = FrameCaptureSession()
                        MetaWearableManager.shared.activeCaptureSession = self.frameCaptureSession
                        self.isProcessingMesh = false
                        if locationId != nil {
                            self.savePendingScan()
                        } else {
                            self.saveMessage = nil
                            self.newLocationName = ""
                            self.showNamePrompt = true
                        }
                    }
                }
                return
            }

            isRecording = false
            isProcessingMesh = false  // release the re-entrancy claim from performStopRecording

            if completion == nil, rawFrameCount > 0 {
                // Recover the raw capture: empty mesh (geometry comes from the frames downstream),
                // no world map (a relocalizing session's map is unreliable / not extendable).
                let recoveredName = newLocationName.isEmpty ? "Recovered Scan" : newLocationName
                let savedScan = ScanFileManager.shared.saveScan(
                    context: modelContext,
                    locationId: locationId,
                    name: recoveredName,
                    meshData: Data(),
                    vertexCount: 0,
                    faceCount: 0,
                    hardwareDeviceModel: UIDevice.current.name,
                    rawDataPath: rawDataPath,
                    vertexColors: nil,
                    worldMapURL: nil,
                    thumbnailData: thumbnailData,
                    scanCase: scanCase
                )
                frameCaptureSession = FrameCaptureSession()
                MetaWearableManager.shared.activeCaptureSession = frameCaptureSession
                saveMessage = savedScan != nil
                    ? "Saved \(rawFrameCount) frames (mesh lost to tracking interruption)"
                    : "Save failed"
                scanStore.resetCaptureState()
                clearMessage()
                completion?(savedScan)
                return
            }

            // Nothing usable to preserve (no frames), or a stitch/extend flow — discard.
            saveMessage = "No Mesh Data"
            frameCaptureSession = FrameCaptureSession()
            MetaWearableManager.shared.activeCaptureSession = frameCaptureSession

            // Clean up any empty location created for this flow
            if let locId = locationId {
                let descriptor = FetchDescriptor<ScanLocation>(predicate: #Predicate { $0.id == locId })
                if let location = try? modelContext.fetch(descriptor).first, location.scans.isEmpty {
                    modelContext.delete(location)
                    try? modelContext.save()
                }
            }

            if completion == nil {
                scanStore.resetCaptureState()
            } else {
                scanStore.pendingStitchLink = nil
            }

            clearMessage()
            completion?(nil)
            return
        }

        // If this is an extend flow, skip the name prompt and save immediately
        let isExtendFlow = (completion != nil)

        if !isExtendFlow {
            // Normal flow: prompt for name or auto-save
            isProcessingMesh = true
            isWaitingToSave = false

            if locationId == nil {
                // Name prompt is DEFERRED to the pipeline's completion (pendingScan stored):
                // right now the world-map export + mesh/color build are still running on the
                // live session, and presenting a keyboard/alert over the tearing-down ARView
                // is the stop-stall anti-pattern (CONTRIBUTING; triage item 5 measured 7s on
                // the marginal iPad with the alert in the window). Deferring also means the
                // world-map failure alert (exportWorldMapThenContinue) can never stack under
                // the naming alert. The save pipeline itself is untouched — only the alert's
                // timing moves.
                saveMessage = "Processing scan…"
            } else {
                isWaitingToSave = true
                saveMessage = "Coloring mesh..."
            }
        } else {
            isProcessingMesh = true
        }

        let capturedLocationId = locationId
        let capturedScanCase = scanCase

        // DECISION 3: no save-time registration target — registration (like the RoomBuilder room
        // and the ghost proxy it depends on) runs at POST-PROCESS (ScanPostprocessor), which
        // resolves the canonical target itself. The save persists raw artifacts only.

        // ── Capture the ARWorldMap co-framed with the OBJ, BEFORE coloring ──
        // mesh.obj was just baked from the live world frame above. The world map
        // must be grabbed before the seconds-long vertex coloring step: across a
        // long gap ARKit can apply a loop-closure/drift correction that shifts the
        // world origin, and when it does the reloaded map relocalizes dead-on (its
        // anchors moved with the correction) while the ghost mesh — frozen in the
        // pre-correction frame — renders misaligned. That was the alignment bug.
        //
        // Disable scene reconstruction first via a direct run (NOT the isRecording
        // binding, to avoid a second session.run racing getCurrentWorldMap). This
        // drops the mesh anchors so they don't bloat the map, while preserving the
        // world origin (no resetTracking) so the map stays co-framed with the OBJ.
        // The identity-transform origin anchor marks that shared frame's origin.
        //
        // CRITICAL: mutate the *live* configuration rather than re-running a fresh
        // makeConfiguration(). A fresh config has initialWorldMap=nil; re-running it
        // (even without resetTracking) discarded every feature point this session had
        // *inherited* from the loaded map, so getCurrentWorldMap then returned only the
        // handful this session observed itself. A baseline scan (no inherited map) was
        // unaffected — but a relocalized generation saved a near-empty map (~100s of
        // features instead of 1000s), and the *next* generation couldn't relocalize
        // against it at all. Keeping the live config (initialWorldMap intact, no reset)
        // preserves the full merged map while still turning mesh reconstruction off.
        if let liveConfig = currentARSession?.configuration as? ARWorldTrackingConfiguration {
            liveConfig.sceneReconstruction = []
            currentARSession?.run(liveConfig)
        } else {
            currentARSession?.run(ARCoverageView.makeConfiguration())
        }
        saveMessage = "Saving World Map..."
        let originAnchor = ARAnchor(name: "Scan4D_Mesh_Origin", transform: matrix_identity_float4x4)
        currentARSession?.add(anchor: originAnchor)

        // Export the ARWorldMap (co-framed with the OBJ). A scan with no world map can't be
        // relocalized or extended, so on failure exportWorldMapThenContinue offers Retry / Discard —
        // never save-without-map. `proceed` runs on the main thread with a guaranteed-valid mapURL.
        exportWorldMapThenContinue(isExtendFlow: isExtendFlow, completion: completion) { mapURL, mapSuspect in
            // Map captured. Sync the isRecording binding so SwiftUI's updateUIView
            // reflects nominal mode (reconstruction was already disabled above).
            self.isRecording = false

            // Fast placeholder coloring from surface normals (perf). It's far cheaper than the
            // photo-based pass but still re-parses the OBJ + does two O(n) passes, so run it OFF the
            // main thread, then hop back for the SwiftData / @State mutations. The high-quality
            // colorize is now a deliberate post-scan user action — the "Color" button on each scan
            // (ScansListView / LocationDetailView bulk) runs colorizeFromSavedFrames and sets
            // isColored = true. Scans saved here keep isColored = false (saveScan never sets it),
            // so that button is still offered.
            DispatchQueue.global(qos: .utility).async {
                // Build the OBJ off-main from the Stop-instant snapshot: per-vertex world transform,
                // privacy person-projection, and float→string formatting. This is the whole multi-second
                // cost that used to run on main and stall the name prompt; the snapshot taken on main at
                // Stop is what keeps it co-framed with the segmentation. `snapshot` has vertices (the
                // guard above returns nil only when empty), so this is non-nil in practice; bail safely
                // on the impossible nil so the UI never hangs.
                guard let result = ARCoverageView.buildMeshOBJ(from: snapshot) else {
                    DispatchQueue.main.async {
                        self.isRecording = false
                        self.isProcessingMesh = false
                        self.isWaitingToSave = false
                        self.showNamePrompt = false
                        self.frameCaptureSession = FrameCaptureSession()
                        MetaWearableManager.shared.activeCaptureSession = self.frameCaptureSession
                        self.showTransientMessage("Save failed — mesh could not be built", duration: 4)
                        completion?(nil)
                    }
                    return
                }

                // [DEFERRED-ROOMPLAN] DECISION 3: nothing derived is built here anymore. The old
                // save-time chain — RoomBuilder (waited on RoomPlan with a 3 s data-gate that a
                // hot device starved, 2026-07-13) → plane registration → ghost proxy — is gone:
                // the room is built by the deferred POST-SAVE RoomBuilder (DeferredRoomBuild,
                // armed after saveScan), and registration/proxy/colorize run at Post-process from
                // the on-disk artifacts. The scan saves RAW-frame with normals colors.
                let meshData = result.data
                let vertexColors = VertexColorAccumulator.generateNormalsColors(objData: meshData)

                DispatchQueue.main.async {
                    // Package the Mesh OBJ and ARWorldMap into the raw data directory for zipping.
                    // DECISION 3: raw artifacts only — roomplan.json lands post-save via the
                    // deferred RoomBuilder; registration.json / mesh_proxy.obj are written by
                    // ScanPostprocessor later.
                    if let rawDir = rawDataPath {
                        let meshFileURL = rawDir.appendingPathComponent("mesh.obj")
                        try? meshData.write(to: meshFileURL)
                        let destMapURL = rawDir.appendingPathComponent("relocalization.worldmap")
                        try? FileManager.default.copyItem(at: mapURL, to: destMapURL)
                        // Face-aligned per-face classification (the proxy build's subtraction
                        // input). One byte per mesh.obj face; absent when the classifier was off.
                        if let classes = result.faceClasses {
                            try? classes.write(to: rawDir.appendingPathComponent("face_classes.bin"))
                        }
                    }

                    if isExtendFlow {
                        // Extend flow: save immediately and call completion
                        let autoSaveName = capturedLocationId == nil ? "New Space" : "Scan"
                        let savedScan = ScanFileManager.shared.saveScan(
                            context: self.modelContext,
                            locationId: capturedLocationId,
                            name: autoSaveName,
                            meshData: meshData,
                            vertexCount: result.vertexCount,
                            faceCount: result.faceCount,
                            hardwareDeviceModel: UIDevice.current.name,
                            rawDataPath: rawDataPath,
                            vertexColors: vertexColors,
                            worldMapURL: mapURL,
                            thumbnailData: thumbnailData,
                            scanCase: capturedScanCase,
                            worldMapSuspect: mapSuspect
                        )
                        self.frameCaptureSession = FrameCaptureSession()
                        MetaWearableManager.shared.activeCaptureSession = self.frameCaptureSession
                        self.isProcessingMesh = false

                        guard let savedScan else {
                            // Required mesh write failed — nothing was persisted.
                            self.showTransientMessage("Save failed — scan not stored", duration: 4)
                            completion?(nil)
                            return
                        }

                        // Write deferred stitching.json now that we have the real target scan ID
                        self.writeStitchingLinkIfPending(targetScanId: savedScan.id)

                        // [DEFERRED-ROOMPLAN] Save is complete — arm the deferred RoomBuilder
                        // with the scan's final directory + schedule the bad-scan grace check
                        // (see savePendingScan for the full rationale).
                        self.scanStore.setRoomDataPersistDir?(savedScan.scanDirectory)
                        ScanPostprocessor.scheduleBadScanCheck(scanId: savedScan.id,
                                                               modelContext: self.modelContext,
                                                               scanStore: self.scanStore)

                        completion?(savedScan)
                    } else {
                        // Normal flow: store as pending scan
                        self.pendingScan = PendingScanData(
                            locationId: capturedLocationId,
                            meshData: meshData,
                            vertexCount: result.vertexCount,
                            faceCount: result.faceCount,
                            rawDataPath: rawDataPath,
                            vertexColors: vertexColors,
                            worldMapURL: mapURL,
                            thumbnailData: thumbnailData,
                            scanCase: capturedScanCase,
                            worldMapSuspect: mapSuspect
                        )

                        // Release frame capture session memory
                        self.frameCaptureSession = FrameCaptureSession()
                        MetaWearableManager.shared.activeCaptureSession = self.frameCaptureSession
                        self.isProcessingMesh = false

                        // If user already tapped save in the alert, OR if this is a background extension
                        if self.isWaitingToSave {
                            self.savePendingScan()
                        } else if capturedLocationId != nil {
                            self.savePendingScan()
                        } else {
                            // New space: the pipeline is DONE (world map, mesh, colors all
                            // persisted to the raw dir) and the AR view has downgraded to
                            // nominal — now ask for the name on a quiet device (deferred from
                            // finishStopRecording; see the comment there). Keyboard is instant
                            // and nothing pose-sensitive can be disturbed anymore.
                            self.saveMessage = nil
                            self.newLocationName = ""
                            self.showNamePrompt = true
                        }
                    }
                }
            }
        }
    }

    /// Exports the ARWorldMap (co-framed with the OBJ — reconstruction is already disabled and the
    /// Scan4D_Mesh_Origin anchor placed by the caller) and runs `proceed(mapURL)` on the main thread
    /// on success. A scan with no world map is useless (not relocalizable / extendable), so on
    /// failure we do NOT offer save-without-map: the user can Retry the export (after moving to a
    /// more feature-rich spot) or Discard the whole scan. If there's no window to present in, we
    /// discard rather than silently persist a mapless scan or hang.
    private func exportWorldMapThenContinue(isExtendFlow: Bool,
                                            completion: ((CapturedScan?) -> Void)?,
                                            proceed: @escaping (URL, _ mapSuspect: Bool) -> Void) {
        VertexColorAccumulator.exportWorldMap(from: currentARSession) { mapURL, mapSuspect in
            DispatchQueue.main.async {
                if let mapURL = mapURL {
                    proceed(mapURL, mapSuspect)
                    return
                }
                let alert = UIAlertController(
                    title: "World Map Not Captured",
                    message: "Not enough features were tracked to build a world map, so this scan can't be "
                        + "relocalized or extended later. Move to a more detailed area and try again, or "
                        + "discard this scan. Discarding deletes this recording's frames and photos "
                        + "and cannot be undone.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "Try Again", style: .default) { _ in
                    self.saveMessage = "Saving World Map..."
                    // Keep the full-screen extend overlay text honest during the retry (otherwise it
                    // keeps showing the stale "📍 Saving scan..." behind the alert).
                    if isExtendFlow { self.extendPhaseText = "📍 Retrying world map…" }
                    self.exportWorldMapThenContinue(
                        isExtendFlow: isExtendFlow, completion: completion, proceed: proceed
                    )
                })
                alert.addAction(UIAlertAction(title: "Discard Scan", style: .destructive) { _ in
                    self.discardInProgressScan(isExtendFlow: isExtendFlow, completion: completion)
                })
                if !self.presentTopAlert(alert) {
                    self.discardInProgressScan(isExtendFlow: isExtendFlow, completion: completion)
                }
            }
        }
    }

    /// Abandons an in-progress save (world-map export failed and the user chose Discard, or there
    /// was no window to prompt in). Tears down the capture session, deletes any empty location
    /// created for this flow, and resets state. For the extend flow it fires completion(nil) so the
    /// caller (pinAndExtend) can abort its session-restart sequence and clean up its new location.
    func discardInProgressScan(isExtendFlow: Bool, completion: ((CapturedScan?) -> Void)?) {
        ThetaCameraManager.shared.endScanStillSession()   // drop the 360° floor markers with the scan
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        isProcessingMesh = false
        isWaitingToSave = false
        pendingScan = nil

        frameCaptureSession.discardCapture()
        frameCaptureSession = FrameCaptureSession()
        MetaWearableManager.shared.activeCaptureSession = frameCaptureSession

        // Clean up any empty location created for this flow.
        if let locId = scanStore.activeLocationForScan {
            let descriptor = FetchDescriptor<ScanLocation>(predicate: #Predicate { $0.id == locId })
            if let location = try? modelContext.fetch(descriptor).first, location.scans.isEmpty {
                modelContext.delete(location)
                try? modelContext.save()
            }
        }

        if isExtendFlow {
            // Extend abort: drop the pending link and let the completion handler reset the flow.
            scanStore.pendingStitchLink = nil
            saveMessage = nil
            completion?(nil)
        } else {
            saveMessage = "Scan Discarded"
            scanStore.resetCaptureState()
            clearMessage()
        }
    }

    /// Deletes a stopped-and-baked pending scan that was never saved (naming-dialog discard,
    /// after its destructive confirmation): removes the temp artifacts — raw frames dir and
    /// world map, which both live in FileManager.temporaryDirectory and saveScan would
    /// normally move — and clears the save-flow state. Dropping pendingScan alone would
    /// leak the (potentially large) raw-frames dir.
    func discardPendingScan() {
        if let pending = pendingScan {
            if let rawDir = pending.rawDataPath {
                try? FileManager.default.removeItem(at: rawDir)
            }
            if let mapURL = pending.worldMapURL {
                try? FileManager.default.removeItem(at: mapURL)
            }
        }
        pendingScan = nil
        saveMessage = nil
        isProcessingMesh = false
        isWaitingToSave = false
    }

    /// Consumes a pending stitch link and persists it as a `StitchLink` SwiftData row now that the
    /// real target scan ID is known. Resolves both endpoint scans in the model graph.
    func writeStitchingLinkIfPending(targetScanId: UUID) {
        guard let pending = scanStore.pendingStitchLink else { return }

        let srcId = pending.sourceScanId
        let srcDescriptor = FetchDescriptor<CapturedScan>(predicate: #Predicate { $0.id == srcId })
        let tgtDescriptor = FetchDescriptor<CapturedScan>(predicate: #Predicate { $0.id == targetScanId })
        guard let sourceScan = try? modelContext.fetch(srcDescriptor).first,
              let targetScan = try? modelContext.fetch(tgtDescriptor).first else {
            stitchLog.error("could not resolve endpoint scans (source=\(srcId.uuidString.prefix(8), privacy: .public) target=\(targetScanId.uuidString.prefix(8), privacy: .public))")
            self.showTransientMessage("⚠️ Scan saved but spatial link failed to write", duration: 5)
            scanStore.pendingStitchLink = nil
            return
        }

        do {
            _ = try StitchLinkStore.create(
                sourceScan: sourceScan,
                targetScan: targetScan,
                sourceAnchor: pending.sourceAnchorTransform,
                targetAnchor: pending.targetAnchorTransform,
                sourceAnchorId: pending.sourceAnchorId,
                targetAnchorId: pending.targetAnchorId,
                sourceCompassHeading: pending.sourceAnchorCompassHeading,
                targetCompassHeading: pending.targetAnchorCompassHeading,
                linkType: pending.linkType,
                in: modelContext
            )
            stitchLog.info("created link source=\(srcId.uuidString.prefix(8), privacy: .public) target=\(targetScanId.uuidString.prefix(8), privacy: .public)")
        } catch {
            stitchLog.error("failed to save link: \(error.localizedDescription, privacy: .public)")
            self.showTransientMessage("⚠️ Scan saved but spatial link failed to write", duration: 5)
        }
        scanStore.pendingStitchLink = nil
    }

    func clearMessage() {
        messageVersion += 1
        let currentVersion = messageVersion
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if self.messageVersion == currentVersion {
                self.saveMessage = nil
            }
        }
    }

    /// Shows a transient message that auto-clears after `duration` seconds.
    /// Uses a version counter to avoid clearing a newer message.
    func showTransientMessage(_ text: String, duration: TimeInterval) {
        messageVersion += 1
        let currentVersion = messageVersion
        saveMessage = text
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if messageVersion == currentVersion {
                saveMessage = nil
            }
        }
    }

    func savePendingScan() {
        guard let pending = pendingScan else {
            // Nothing to save — clear any processing/waiting flags so the record button can't stay
            // disabled ("Processing previous scan…") forever on a stray call.
            isProcessingMesh = false
            isWaitingToSave = false
            return
        }

        let locationId: UUID?
        var finalName = "New Space"

        if let activeLocationId = pending.locationId {
            locationId = activeLocationId
        } else {
            let trimmedName = newLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
            finalName = trimmedName.isEmpty ? "New Space" : trimmedName
            locationId = nil // ScanFileManager will create a new location with this name
        }

        let savedScan = ScanFileManager.shared.saveScan(
            context: modelContext,
            locationId: locationId,
            name: finalName,
            meshData: pending.meshData,
            vertexCount: pending.vertexCount,
            faceCount: pending.faceCount,
            hardwareDeviceModel: UIDevice.current.name,
            rawDataPath: pending.rawDataPath,
            vertexColors: pending.vertexColors,
            worldMapURL: pending.worldMapURL,
            thumbnailData: pending.thumbnailData,
            scanCase: pending.scanCase,
            worldMapSuspect: pending.worldMapSuspect
        )

        guard let savedScan else {
            // Required mesh write failed — nothing was persisted, and the rollback also
            // removes the location, so the user sees NO trace of the scan anywhere
            // (field 2026-08-06: read as "the scan vanished"). pendingScan is kept, so
            // the capture is still retryable — say so in a modal the user cannot miss,
            // with the actual reason (a caption under the record button was missed).
            saveFailedReason = ScanFileManager.shared.lastSaveFailureReason ?? "unknown error"
            saveMessage = nil
            showSaveFailedAlert = true
            isWaitingToSave = false
            return
        }

        // Write deferred stitching.json now that we have the real target scan ID
        writeStitchingLinkIfPending(targetScanId: savedScan.id)

        // [DEFERRED-ROOMPLAN] Save is complete — arm the deferred RoomBuilder with the scan's
        // final directory. The build starts as soon as didEndWith's CapturedRoomData is also in
        // hand (usually already is) and writes roomplan.json/_raw when it finishes; it was held
        // until now so it can't overlap the world-map export.
        scanStore.setRoomDataPersistDir?(savedScan.scanDirectory)
        // Schedule the DECISION-3 bad-scan check: if no room materializes (and no build is in
        // flight) within the grace window, warn the user to redo the scan while they're still
        // standing in the room.
        ScanPostprocessor.scheduleBadScanCheck(scanId: savedScan.id, modelContext: modelContext,
                                               scanStore: scanStore)

        saveMessage = "Scan Saved!"
        ThetaCameraManager.shared.endScanStillSession()   // the scan's floor markers retire with it
        pendingScan = nil
        // Release the processing/waiting claim now that the save is done — otherwise isWaitingToSave
        // (set in finishStopRecording's rescan branch / the name-prompt Save) leaks true and leaves the
        // record button disabled ("Processing previous scan…") indefinitely on the next scan.
        isProcessingMesh = false
        isWaitingToSave = false

        // Reset the FULL capture state so a scan started before the delayed tab switch below can't
        // inherit stale link/rescan routing (activeScanToExtend, activeScanCase, boundary fields).
        // The pending link was already consumed above; navigationPath is untouched by this reset.
        scanStore.resetCaptureState()

        // Programmatically navigate to the created LocationDetailView
        let savedLoc = savedScan.location

        // Switch to Scans tab after a brief delay. Stored + cancelled in onDisappear so that if the
        // user navigates away from capture during the delay, we don't yank them to the Scans tab and
        // push navigation onto a view they already left.
        saveNavigationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1000))
            guard !Task.isCancelled else { return }
            selectedTab = 2
            if let loc = savedLoc {
                scanStore.navigationPath = NavigationPath()
                scanStore.navigationPath.append(loc)
            }
            saveMessage = nil
        }
    }

    // MARK: - Shared Stabilization Helper

    /// Result of a successful Pin B placement after session stabilization.
    struct PinBResult {
        let transform: simd_float4x4
        let anchorId: UUID
        let compassHeading: Double?
    }

    /// Waits for the AR session to stabilize after a reset, places Pin B (metadata-only — a UUID
    /// plus the camera transform published to ScanStore, no ARAnchor; see `pinB`), starts
    /// recording, and records the boundary anchor.
    ///
    /// Shared by both mid-session extend (Flow A) and cross-session alignment (Flow B)
    /// to avoid duplicating the stabilization → anchor → record sequence.
    ///
    /// - Parameters:
    ///   - preResetTimestamp: Timestamp of the last AR frame before the session reset.
    ///     Used to detect that we're looking at a post-reset frame.
    ///   - failureMessage: User-facing prefix for error messages (e.g., "Link" vs "Alignment").
    /// - Returns: `PinBResult` on success, `nil` on timeout / no-frame / cancellation.
    func awaitStabilizationAndPlacePinB(
        preResetTimestamp: TimeInterval,
        failureMessage: String
    ) async -> PinBResult? {
        // Poll for tracking to reach .normal after the session reset.
        // Track whether we actually observed a valid post-reset frame to avoid
        // passing the post-loop guard on a stale pre-reset `.normal` frame.
        var didStabilize = false
        for _ in 0..<AppConstants.stabilizationMaxPolls {
            try? await Task.sleep(for: .milliseconds(AppConstants.stabilizationPollIntervalMs))
            if Task.isCancelled { return nil }
            if let currentFrame = self.currentARSession?.currentFrame,
               currentFrame.timestamp > preResetTimestamp,
               currentFrame.camera.trackingState == .normal {
                didStabilize = true
                break
            }
        }
        guard !Task.isCancelled else { return nil }

        // Abort if tracking never stabilized — placing an anchor with degraded
        // tracking would produce an unreliable stitch transform.
        guard didStabilize else {
            print("[BoundaryAnchor] Stabilization timeout — no valid post-reset frame observed")
            self.showExtendOverlay = false
            self.scanStore.capturePhase = .idle
            self.showTransientMessage("Tracking unstable — move to a well-lit area and try again", duration: 4)
            return nil
        }

        // Place Pin B in Map B's coordinate space using the camera's current transform.
        let pinBCompassHeading = self.locationManager.bestHeading
        guard let frame = self.currentARSession?.currentFrame else {
            print("[BoundaryAnchor] ERROR: No frame available for pinB")
            self.showExtendOverlay = false
            self.scanStore.capturePhase = .idle
            self.showTransientMessage("\(failureMessage) failed — no AR frame. Start a new scan.", duration: 4)
            return nil
        }

        // Pin B is metadata-only, mirroring Pin A — no ARAnchor. The saved stitch transform is
        // this camera-pose snapshot (recordBoundaryAnchor / PendingStitchLink), not a value read
        // back from a live anchor, so an anchor adds nothing to correctness. It would also be
        // futile: a fresh mapB session carries no world map, so record-start runs with
        // .removeExistingAnchors and would wipe the anchor immediately. Publishing the transform
        // to scanStore lets ARCoverageView draw the boundary marker directly at record-start.
        let pinBTransform = frame.camera.transform
        let pinBId = UUID()
        self.scanStore.boundaryAnchorTransform = pinBTransform
        self.scanStore.boundaryAnchorId = pinBId
        print("[BoundaryAnchor] Placed pinB (metadata-only) in mapB at \(frame.camera.transform.columns.3)")

        // Start recording and then record Pin B (order matters:
        // FrameCaptureSession.start() clears boundary anchor state).
        self.scanStore.capturePhase = .recording
        self.startRecording()

        self.frameCaptureSession.recordBoundaryAnchor(
            transform: pinBTransform,
            id: pinBId,
            compassHeading: pinBCompassHeading
        )

        return PinBResult(
            transform: pinBTransform,
            anchorId: pinBId,
            compassHeading: pinBCompassHeading
        )
    }
}
