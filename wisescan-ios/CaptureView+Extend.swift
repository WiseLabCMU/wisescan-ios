import SwiftUI
import ARKit
import SwiftData

// MARK: - Mid-Session Extend (Flow A)

extension CaptureView {

    /// Flow A: Mid-session extend.
    /// Auto-saves the current scan, resets ARKit, and starts a fresh session.
    ///
    /// Pin A = camera.transform at the moment the user taps "Pin & Extend".
    /// Pin B = camera.transform after the session resets (same physical point).
    /// The server uses the pair to compute the rigid transform between maps.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func pinAndExtend() {
        guard let frame = currentARSession?.currentFrame else {
            showTransientMessage("No AR frame — try again", duration: 3)
            return
        }

        // Haptic feedback
        hapticGenerator.impactOccurred()

        // Pin A: camera pose in Map A's coordinate system.
        let pinACameraPose = frame.camera.transform
        let compassHeading = locationManager.bestHeading
        
        // Create and record a real anchor so it goes into the source scan's metadata
        let anchor = ARAnchor(name: ARCoverageView.boundaryAnchorName, transform: pinACameraPose)
        currentARSession?.add(anchor: anchor)
        let sourceAnchorId = anchor.identifier
        frameCaptureSession.recordBoundaryAnchor(transform: pinACameraPose, id: sourceAnchorId, compassHeading: compassHeading)

        // Show extend overlay and start save
        scanStore.capturePhase = .extending
        showExtendOverlay = true
        extendPhaseText = "📍 Saving scan..."

        // Stop the recording timer
        recordingTimer?.invalidate()
        recordingTimer = nil

        // Trigger the save pipeline with completion for session restart
        performStopRecording { savedScan in
            guard let savedScan = savedScan else {
                // Save failed — abort extend
                self.showExtendOverlay = false
                self.scanStore.capturePhase = .idle
                self.scanStore.pendingStitchLink = nil
                self.showTransientMessage("Save failed — start a new session", duration: 4)
                return
            }

            // Derive the real source location ID from the saved scan — abort if unavailable.
            guard let actualSourceLocationId = savedScan.location?.id else {
                self.showExtendOverlay = false
                self.scanStore.capturePhase = .idle
                self.showTransientMessage("Cannot link — source location unavailable", duration: 4)
                return
            }

            // Phase 2: Session restart
            self.extendPhaseText = "📍 Stay still — starting new session..."
            self.scanStore.capturePhase = .saving

            // Create new location for the adjacent space
            let sourceName = savedScan.location?.name ?? "Unknown"
            let newLocation = ScanLocation(name: "Adjacent to \(sourceName)", scanCase: .linkAdjacent)
            self.modelContext.insert(newLocation)
            do {
                try self.modelContext.save()
            } catch {
                print("[CaptureView] Failed to save new location: \(error)")
                // Clean up the just-inserted location so a failed save can't leave a phantom
                // "Adjacent to …" location that autosave later persists. The stabilization task's
                // cleanup defer isn't reached on this early return, so do it here. (delete() alone —
                // NOT rollback(), which would also discard mapA's just-saved scan.)
                self.modelContext.delete(newLocation)
                self.showExtendOverlay = false
                self.scanStore.capturePhase = .idle
                self.showTransientMessage("Failed to create location — please try again", duration: 4)
                return
            }

            // Reset AR session to fresh using the shared helper
            // Note: updateUIView will re-enable sceneReconstruction = .mesh when isRecording becomes true
            let config = ARCoverageView.makeFreshConfiguration()
            let preResetTimestamp = self.currentARSession?.currentFrame?.timestamp ?? 0
            self.currentARSession?.run(config, options: [.resetTracking, .removeExistingAnchors])
            self.cachedGhostMeshData = nil

            // Set up for new session
            self.scanStore.activeLocationForScan = newLocation.id
            self.scanStore.activeScanCase = .linkAdjacent
            self.scanStore.activeRelocalizationMap = nil
            self.scanStore.activeScanToExtend = nil
            self.scanStore.boundaryAnchorTransform = nil
            self.scanStore.boundaryAnchorId = nil

            // Pin B is placed AFTER the new session stabilizes (below) so that
            // its transform is expressed in mapB's actual coordinate space,
            // including rotation — not a hardcoded identity.

            // Wait for the new AR session to stabilize, place Pin B, and start recording.
            // Uses the shared stabilization helper (CaptureView+Recording.swift).
            self.sessionStabilizationTask = Task { @MainActor in
                // Clean up orphaned location on any abort path (cancel, timeout, no-frame).
                var didLinkSuccessfully = false
                defer {
                    if !didLinkSuccessfully {
                        self.modelContext.delete(newLocation)
                        try? self.modelContext.save()
                        self.scanStore.resetCaptureState()
                    }
                }

                guard let pinB = await self.awaitStabilizationAndPlacePinB(
                    preResetTimestamp: preResetTimestamp,
                    failureMessage: "Link"
                ) else { return }

                self.scanStore.pendingStitchLink = PendingStitchLink(
                    sourceLocationId: actualSourceLocationId,
                    sourceScanId: savedScan.id,
                    sourceAnchorId: sourceAnchorId,
                    sourceAnchorTransform: pinACameraPose,
                    sourceAnchorCompassHeading: compassHeading,
                    targetLocationId: newLocation.id,
                    targetAnchorId: pinB.anchorId,
                    targetAnchorTransform: pinB.transform,
                    targetAnchorCompassHeading: pinB.compassHeading,
                    linkType: .midSession
                )

                didLinkSuccessfully = true
                self.showExtendOverlay = false
                self.showTransientMessage("📍 Linked! Scanning new space...", duration: 3)
            }
        }
    }
}
