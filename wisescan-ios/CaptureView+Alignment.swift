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
            // Drop the just-inserted location so a failed save can't leak a phantom "Adjacent to …"
            // into live @Query results (delete() only — NOT rollback(), which would also discard
            // other pending context changes). Mirrors the Flow A extend path.
            modelContext.delete(newLocation)
            isConfirmingAlignment = false
            showTransientMessage("Failed to create location — please try again", duration: 4)
            return
        }

        // Tear down old world map, start fresh session (mapB)
        let config = ARCoverageView.makeFreshConfiguration()
        let preResetTimestamp = currentARSession?.currentFrame?.timestamp ?? 0
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

        // Take the phase OUT of the alignment-overlay set ({loadingWorldMap, aligning, alignedReady})
        // for the whole mapB stabilization window. Otherwise AlignmentOverlayView — with its live
        // Confirm/Cancel buttons — stays mounted over the freshly-reset, mid-relocalizing session
        // (mirrors Flow A, which uses .saving + showExtendOverlay). awaitStabilizationAndPlacePinB
        // flips this to .recording on success and back to .idle (clearing the overlay) on failure.
        scanStore.capturePhase = .saving
        showExtendOverlay = true
        extendPhaseText = "📍 Aligning — hold still..."

        hapticGenerator.impactOccurred()

        // Wait for the new session (mapB) to stabilize, place pinB, and start recording.
        // Uses the shared stabilization helper (CaptureView+Recording.swift).
        sessionStabilizationTask = Task { @MainActor in
            defer { self.isConfirmingAlignment = false }
            // Clean up orphaned location on any abort path (cancel, timeout, no-frame).
            var didLinkSuccessfully = false
            defer {
                if !didLinkSuccessfully {
                    self.modelContext.delete(newLocation)
                    try? self.modelContext.save()
                    self.scanStore.resetCaptureState()
                    self.showExtendOverlay = false // clear the "hold still" overlay on the cancel path
                }
            }

            guard let pinB = await self.awaitStabilizationAndPlacePinB(
                preResetTimestamp: preResetTimestamp,
                failureMessage: "Alignment"
            ) else { return }

            // Build PendingStitchLink with camera poses from both coordinate spaces.
            self.scanStore.pendingStitchLink = PendingStitchLink(
                sourceLocationId: sourceLocId,
                sourceScanId: sourceScanId,
                sourceAnchorId: pinAId,
                sourceAnchorTransform: pinACameraPose,
                sourceAnchorCompassHeading: pinACompassHeading,
                targetLocationId: newLocation.id,
                targetAnchorId: pinB.anchorId,
                targetAnchorTransform: pinB.transform,
                targetAnchorCompassHeading: pinB.compassHeading,
                linkType: .crossSession
            )

            didLinkSuccessfully = true
            self.showExtendOverlay = false
            self.showTransientMessage("📍 Aligned & linked! Scanning new space...", duration: 3)
        }
    }

    /// Flow B: User cancelled alignment — return to idle.
    /// Resets both app state AND the AR session so the next scan starts
    /// in a fresh coordinate frame (not the source world map's).
    func cancelAlignment() {
        // If a confirm is already in flight, the stabilization task's own defer performs the single
        // resetCaptureState + orphaned-location delete and confirmAlignment already issued the
        // fresh-session reset. Just cancel the task and bail — do NOT resetCaptureState or fire a
        // SECOND resetTracking here (that churned the AR session mid-relocalization).
        if isConfirmingAlignment {
            sessionStabilizationTask?.cancel()
            sessionStabilizationTask = nil
            showExtendOverlay = false
            showTransientMessage("Alignment cancelled — start a new scan without linking", duration: 4)
            return
        }

        sessionStabilizationTask?.cancel()
        sessionStabilizationTask = nil
        scanStore.resetCaptureState()
        cachedGhostMeshData = nil
        showExtendOverlay = false

        // Reset AR session to a clean coordinate space — without this,
        // the session continues running with the source world map loaded,
        // and a subsequent standalone scan would inherit the old frame.
        let freshConfig = ARCoverageView.makeFreshConfiguration()
        currentARSession?.run(freshConfig, options: [.resetTracking, .removeExistingAnchors])

        showTransientMessage("Alignment cancelled — start a new scan without linking", duration: 4)
    }
}
