import SwiftUI
import ARKit
import SwiftData

// MARK: - Cross-Session Alignment (Flow B)

extension CaptureView {

    /// Flow B: User confirmed alignment — capture camera pose in Map A, reset session, drop Pin B in Map B.
    ///
    /// The user has relocalized into Map A's coordinate system using the old world map.
    /// Pin A = camera.transform in Map A's coords right now (the user IS at the boundary).
    /// Pin B = camera.transform in Map B's coords after session reset (same physical point).
    /// The server uses the pair to compute the A↔B rigid transform.
    ///
    /// No pre-existing boundary anchor is required — the world map provides
    /// relocalization, and the user chooses the boundary point by walking there.
    func confirmAlignment() {
        guard !isConfirmingAlignment else { return }
        guard let frame = currentARSession?.currentFrame else { return }

        isConfirmingAlignment = true

        // Cancel any in-flight stabilization task from a prior attempt
        sessionStabilizationTask?.cancel()

        guard let sourceLocId = scanStore.activeLocationForScan,
              let sourceScanId = scanStore.activeScanToExtend else {
            isConfirmingAlignment = false
            showTransientMessage("Cannot link — no source scan selected", duration: 4)
            return
        }

        // Pin A: camera pose in Map A's coordinate system at this moment.
        // The user is physically at the boundary; the relocalized session
        // expresses this position in Map A's world coordinates.
        let pinACameraPose = frame.camera.transform
        let pinACompassHeading = locationManager.bestHeading
        let pinAId = UUID()  // Metadata ID only — no ARAnchor needed for the stitch link

        // Create new location for the adjacent space
        let sourceName = resolveCurrentLocationName()
        let newLocation = ScanLocation(name: "Adjacent to \(sourceName)", scanCase: .linkAdjacent)
        modelContext.insert(newLocation)
        do {
            try modelContext.save()
        } catch {
            print("[CaptureView] Failed to save new location: \(error)")
            isConfirmingAlignment = false
            showTransientMessage("Failed to create location — please try again", duration: 4)
            return
        }

        // Tear down old world map, start fresh session (mapB)
        let config = ARCoverageView.makeFreshConfiguration()
        currentARSession?.run(config, options: [.resetTracking, .removeExistingAnchors])

        // Set up for new recording
        scanStore.activeLocationForScan = newLocation.id
        scanStore.activeScanCase = .linkAdjacent
        scanStore.activeRelocalizationMap = nil
        scanStore.activeScanToExtend = nil
        scanStore.boundaryAnchorTransform = nil
        scanStore.boundaryAnchorId = nil
        scanStore.distanceToBoundaryAnchor = nil
        cachedGhostMeshData = nil

        hapticGenerator.impactOccurred()
        showTransientMessage("📍 Aligning — hold still...", duration: 3)

        // Wait for the new session (mapB) to stabilize, then place pinB as a real anchor
        // in mapB's coordinate space and start recording.
        sessionStabilizationTask = Task { @MainActor in
            defer { self.isConfirmingAlignment = false }
            // Clean up orphaned location on any abort path (cancel, timeout, no-frame).
            var didLinkSuccessfully = false
            defer {
                if !didLinkSuccessfully {
                    self.modelContext.delete(newLocation)
                    try? self.modelContext.save()
                    self.scanStore.resetCaptureState()
                }
            }
            for _ in 0..<25 { // 5s timeout (25 × 200ms)
                try? await Task.sleep(for: .milliseconds(200))
                if Task.isCancelled { return }
                if self.currentARSession?.currentFrame?.camera.trackingState == .normal {
                    break
                }
            }
            guard !Task.isCancelled else { return }

            guard self.currentARSession?.currentFrame?.camera.trackingState == .normal else {
                print("[BoundaryAnchor] Stabilization timeout — tracking not normal, aborting alignment")
                self.scanStore.capturePhase = .idle
                self.showTransientMessage("Tracking unstable — move to a well-lit area and try again", duration: 4)
                return
            }

            // Pin B: camera pose in Map B's coordinate space.
            // User hasn't moved — same physical point as Pin A.
            let pinBTransform: simd_float4x4
            let pinBId: UUID
            let pinBCompassHeading = self.locationManager.bestHeading

            if let frame = self.currentARSession?.currentFrame {
                let anchor = ARAnchor(
                    name: ARCoverageView.boundaryAnchorName,
                    transform: frame.camera.transform
                )
                self.currentARSession?.add(anchor: anchor)
                pinBTransform = frame.camera.transform
                pinBId = anchor.identifier
                print("[BoundaryAnchor] Placed pinB in mapB at \(frame.camera.transform.columns.3)")
            } else {
                print("[BoundaryAnchor] ERROR: No frame available for pinB — aborting alignment")
                self.scanStore.capturePhase = .idle
                self.showTransientMessage("Alignment failed — no AR frame. Try again.", duration: 4)
                return
            }

            // Build PendingStitchLink with camera poses from both coordinate spaces.
            self.scanStore.pendingStitchLink = PendingStitchLink(
                sourceLocationId: sourceLocId,
                sourceScanId: sourceScanId,
                sourceAnchorId: pinAId,
                sourceAnchorTransform: pinACameraPose,
                sourceAnchorCompassHeading: pinACompassHeading,
                targetLocationId: newLocation.id,
                targetAnchorId: pinBId,
                targetAnchorTransform: pinBTransform,
                targetAnchorCompassHeading: pinBCompassHeading,
                linkType: .crossSession
            )

            didLinkSuccessfully = true
            self.scanStore.capturePhase = .recording
            self.startRecording()

            // Record Pin B AFTER startRecording() — FrameCaptureSession.start()
            // clears boundary anchor state, so recording must begin first.
            self.frameCaptureSession.recordBoundaryAnchor(
                transform: pinBTransform,
                id: pinBId,
                compassHeading: pinBCompassHeading
            )

            self.showTransientMessage("📍 Aligned & linked! Scanning new space...", duration: 3)
        }
    }

    /// Flow B: User cancelled alignment — return to idle.
    func cancelAlignment() {
        sessionStabilizationTask?.cancel()
        sessionStabilizationTask = nil
        isConfirmingAlignment = false
        scanStore.resetCaptureState()
        cachedGhostMeshData = nil
        showTransientMessage("Alignment cancelled — start a new scan without linking", duration: 4)
    }
}
