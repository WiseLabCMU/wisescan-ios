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

        // ── Now switch to nominal mode (drops mesh anchors, frees AR memory) ──
        isRecording = false

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

        // Run vertex coloring in background using saved camera frames (.utility QoS
        // so the name-prompt keyboard stays responsive while coloring runs)
        DispatchQueue.global(qos: .utility).async {
            let vertexColors = VertexColorAccumulator.colorizeFromSavedFrames(
                objData: result.data,
                rawDataDir: rawDataPath
            )

            DispatchQueue.main.async {
                self.saveMessage = "Saving World Map..."

                // Export ARWorldMap for Scan4D relocalization
                VertexColorAccumulator.exportWorldMap(from: self.currentARSession) { mapURL in
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
                                scanCase: self.scanStore.activeScanCase
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
                                thumbnailData: thumbnailData
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
            scanCase: scanStore.activeScanCase
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
}
