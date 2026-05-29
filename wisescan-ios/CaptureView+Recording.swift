import SwiftUI
import ARKit
import SwiftData

// MARK: - Recording Controls

extension CaptureView {

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        isRecording = true
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

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func performStopRecording(completion: ((CapturedScan?) -> Void)? = nil) {
        // Stop frame capture and get raw data path
        let rawDataPath = frameCaptureSession.stop()

        // Export mesh from the still-active AR session
        let meshResult = ARCoverageView.exportMeshOBJ(from: currentARSession, privacyFilter: isPrivacyFilterOn)

        // Capture a 2D thumbnail from the current camera frame
        var thumbnailData: Data? = nil
        if let currentFrame = currentARSession?.currentFrame {
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
                    finalMeshResult = (dummyObjData, 3, 1)
                }
            }
        }

        guard let result = finalMeshResult, !result.data.isEmpty else {
            // Switch to nominal mode (drops mesh anchors, frees AR memory)
            isRecording = false
            saveMessage = "No Mesh Data"
            frameCaptureSession = FrameCaptureSession()
            MetaWearableManager.shared.activeCaptureSession = frameCaptureSession

            // Clean up any empty location created for this flow
            if let locId = scanStore.activeLocationForScan {
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

            if scanStore.activeLocationForScan == nil {
                newLocationName = ""
                showNamePrompt = true
            } else {
                isWaitingToSave = true
                saveMessage = "Coloring mesh..."
            }
        } else {
            isProcessingMesh = true
        }

        let capturedLocationId = scanStore.activeLocationForScan
        let capturedScanCase = scanStore.activeScanCase

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
        currentARSession?.run(ARCoverageView.makeConfiguration())
        saveMessage = "Saving World Map..."
        let originAnchor = ARAnchor(name: "Scan4D_Mesh_Origin", transform: matrix_identity_float4x4)
        currentARSession?.add(anchor: originAnchor)

        VertexColorAccumulator.exportWorldMap(from: currentARSession) { mapURL in
            DispatchQueue.main.async {
                // Map captured. Sync the isRecording binding so SwiftUI's updateUIView
                // reflects nominal mode (reconstruction was already disabled above).
                self.isRecording = false

                // Run vertex coloring in background using saved camera frames (.utility QoS
                // so the name-prompt keyboard stays responsive while coloring runs)
                DispatchQueue.global(qos: .utility).async {
                    let vertexColors = VertexColorAccumulator.colorizeFromSavedFrames(
                        objData: result.data,
                        rawDataDir: rawDataPath
                    )

                    DispatchQueue.main.async {
                        // Package the Mesh OBJ and ARWorldMap into the raw data directory for zipping
                        if let rawDir = rawDataPath {
                            let meshFileURL = rawDir.appendingPathComponent("mesh.obj")
                            try? result.data.write(to: meshFileURL)

                            if let mapURL = mapURL {
                                let destMapURL = rawDir.appendingPathComponent("relocalization.worldmap")
                                try? FileManager.default.copyItem(at: mapURL, to: destMapURL)
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
                            } else if self.scanStore.activeLocationForScan != nil {
                                self.savePendingScan()
                            }
                        }
                    }
                }
            }
        }
    }

    /// Consumes a pending stitch link and writes the stitching.json with the real target scan ID.
    func writeStitchingLinkIfPending(targetScanId: UUID) {
        guard let pending = scanStore.pendingStitchLink else { return }

        let link = StitchingLink(
            sourceLocationId: pending.sourceLocationId,
            sourceScanId: pending.sourceScanId,
            sourceAnchorId: pending.sourceAnchorId,
            sourceAnchorTransform: CodableMatrix4x4(pending.sourceAnchorTransform),
            sourceAnchorCompassHeading: pending.sourceAnchorCompassHeading,
            targetLocationId: pending.targetLocationId,
            targetScanId: targetScanId,
            targetAnchorId: pending.targetAnchorId,
            targetAnchorTransform: CodableMatrix4x4(pending.targetAnchorTransform),
            targetAnchorCompassHeading: pending.targetAnchorCompassHeading,
            linkedAt: Date(),
            linkType: pending.linkType
        )
        StitchingMetadataManager.addLink(link, locationId: pending.targetLocationId) { success in
            if success {
                print("[StitchingMetadata] Wrote stitching.json with targetScanId=\(targetScanId.uuidString)")
            } else {
                print("[StitchingMetadata] WARNING: Failed to write stitching.json for targetScanId=\(targetScanId.uuidString)")
                self.showTransientMessage("⚠️ Scan saved but spatial link failed to write", duration: 5)
            }
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

        // Reset the active state so subsequent scans don't default to this location
        scanStore.activeLocationForScan = nil
        scanStore.activeRelocalizationMap = nil
        scanStore.capturePhase = .idle

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

    /// Waits for the AR session to stabilize after a reset, places Pin B as a real
    /// ARAnchor, starts recording, and records the boundary anchor.
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

        let anchor = ARAnchor(
            name: ARCoverageView.boundaryAnchorName,
            transform: frame.camera.transform
        )
        self.currentARSession?.add(anchor: anchor)
        let pinBTransform = frame.camera.transform
        let pinBId = anchor.identifier
        print("[BoundaryAnchor] Placed pinB in mapB at \(frame.camera.transform.columns.3)")

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
