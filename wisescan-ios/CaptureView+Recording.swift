import SwiftUI
import ARKit
import RealityKit
import SwiftData
import os

// MARK: - Recording Controls

extension CaptureView {

    func toggleRecording() {
        if isRecording {
            if scanStore.activeScanCase == .rescanSpace && scanStore.activeLocationForScan != nil {
                stopRecording()
            } else {
                showStopMenu = true
            }
        } else {
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
        // Baseline for the "move the camera to start the live mesh" cue. In a relocalized ghost /
        // stitch-boundary flow `totalVertices` already starts high, so the cue is shown until enough
        // NEW vertices appear relative to this baseline (not an absolute count).
        verticesAtRecordStart = scanStats.totalVertices
        if scanStore.capturePhase == .idle {
            scanStore.capturePhase = .recording
        }
        recordingSeconds = 0
        saveMessage = nil

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
        // Validate mapping status before allowing save (skip when force-stopping, e.g. onDisappear)
        if !force && !scanStats.hasEnoughFeaturesForRelocalization {
            showInsufficientTrackingAlert = true
            return
        }

        recordingTimer?.invalidate()
        recordingTimer = nil

        performStopRecording()
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
        // Export mesh from the still-active AR session. exportMeshOBJ now takes the ARFrame directly
        // (main's change — reading currentFrame inside pinned ARFrame memory), so grab it once here
        // and reuse it for the thumbnail below.
        let currentFrame = currentARSession?.currentFrame
        let meshResult = ARCoverageView.exportMeshOBJ(from: currentFrame, privacyFilter: isPrivacyFilterOn)

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

        var finalMeshResult = meshResult

        // If test modes are active and no mesh was generated (e.g. Simulator), inject a dummy mesh
        if finalMeshResult == nil || finalMeshResult!.data.isEmpty {
            if developerMode && (mockCameraImages || mockIMU || mockDepthMaps) {
                let dummyObj = "v -0.5 -0.5 -0.5\nv 0.5 -0.5 -0.5\nv 0.5 0.5 -0.5\nf 1 2 3\n"
                if let dummyObjData = dummyObj.data(using: .utf8) {
                    finalMeshResult = ARCoverageView.MeshExportResult(
                        data: dummyObjData, vertexCount: 3, faceCount: 1
                    )
                }
            }
        }

        guard let result = finalMeshResult, !result.data.isEmpty else {
            // Switch to nominal mode (drops mesh anchors, frees AR memory)
            isRecording = false
            isProcessingMesh = false  // release the re-entrancy claim from performStopRecording
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
                newLocationName = ""
                showNamePrompt = true
            } else {
                isWaitingToSave = true
                saveMessage = "Coloring mesh..."
            }
        } else {
            isProcessingMesh = true
        }

        let capturedLocationId = locationId
        let capturedScanCase = scanCase

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
        exportWorldMapThenContinue(isExtendFlow: isExtendFlow, completion: completion) { mapURL in
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
                let vertexColors = VertexColorAccumulator.generateNormalsColors(objData: result.data)

                DispatchQueue.main.async {
                    // Package the Mesh OBJ and ARWorldMap into the raw data directory for zipping.
                    if let rawDir = rawDataPath {
                        let meshFileURL = rawDir.appendingPathComponent("mesh.obj")
                        try? result.data.write(to: meshFileURL)
                        let destMapURL = rawDir.appendingPathComponent("relocalization.worldmap")
                        try? FileManager.default.copyItem(at: mapURL, to: destMapURL)
                        // Write roomplan.json + roomplan_raw.json if RoomPlan captured room data
                        if let room = self.finalCapturedRoom {
                            RoomPlanExporter.writeRoomPlan(room, to: rawDir)
                        }
                    }

                    if isExtendFlow {
                        // Extend flow: save immediately and call completion
                        let autoSaveName = capturedLocationId == nil ? "New Space" : "Scan"
                        let savedScan = ScanFileManager.shared.saveScan(
                            context: self.modelContext,
                            locationId: capturedLocationId,
                            name: autoSaveName,
                            meshData: result.data,
                            vertexCount: result.vertexCount,
                            faceCount: result.faceCount,
                            hardwareDeviceModel: UIDevice.current.name,
                            rawDataPath: rawDataPath,
                            vertexColors: vertexColors,
                            worldMapURL: mapURL,
                            thumbnailData: thumbnailData,
                            scanCase: capturedScanCase
                        )
                        self.frameCaptureSession = FrameCaptureSession()
                        MetaWearableManager.shared.activeCaptureSession = self.frameCaptureSession
                        self.isProcessingMesh = false

                        // Write deferred stitching.json now that we have the real target scan ID
                        self.writeStitchingLinkIfPending(targetScanId: savedScan.id)

                        completion?(savedScan)
                    } else {
                        // Normal flow: store as pending scan
                        self.pendingScan = PendingScanData(
                            locationId: capturedLocationId,
                            meshData: result.data,
                            vertexCount: result.vertexCount,
                            faceCount: result.faceCount,
                            rawDataPath: rawDataPath,
                            vertexColors: vertexColors,
                            worldMapURL: mapURL,
                            thumbnailData: thumbnailData,
                            scanCase: capturedScanCase
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
                                            proceed: @escaping (URL) -> Void) {
        VertexColorAccumulator.exportWorldMap(from: currentARSession) { mapURL in
            DispatchQueue.main.async {
                if let mapURL = mapURL {
                    proceed(mapURL)
                    return
                }
                let alert = UIAlertController(
                    title: "World Map Not Captured",
                    message: "Not enough features were tracked to build a world map, so this scan can't be "
                        + "relocalized or extended later. Move to a more detailed area and try again, or "
                        + "discard this scan.",
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
        guard let pending = pendingScan else { return }

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
            scanCase: pending.scanCase
        )

        // Write deferred stitching.json now that we have the real target scan ID
        writeStitchingLinkIfPending(targetScanId: savedScan.id)

        saveMessage = "Scan Saved!"
        pendingScan = nil
        isWaitingToSave = false

        // Reset the FULL capture state so a scan started before the delayed tab switch below can't
        // inherit stale link/rescan routing (activeScanToExtend, activeScanCase, boundary fields).
        // The pending link was already consumed above; navigationPath is untouched by this reset.
        scanStore.resetCaptureState()

        // Programmatically navigate to the created LocationDetailView
        let savedLoc = savedScan.location

        // Switch to Scans tab after a brief delay (cancellable via structured concurrency)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1000))
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
