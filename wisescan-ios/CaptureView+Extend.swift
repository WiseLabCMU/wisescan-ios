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
                self.showExtendOverlay = false
                self.scanStore.capturePhase = .idle
                self.showTransientMessage("Failed to create location — please try again", duration: 4)
                return
            }

            // Reset AR session to fresh using the shared helper
            // Note: updateUIView will re-enable sceneReconstruction = .mesh when isRecording becomes true
            let config = ARCoverageView.makeFreshConfiguration()
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

            // Wait for the new AR session to stabilize before auto-starting recording.
            // Uses structured concurrency so it can be cancelled if the user navigates away.
            self.sessionStabilizationTask = Task { @MainActor in
                // Clean up orphaned location on any abort path (cancel, timeout, no-frame).
                var didLinkSuccessfully = false
                defer {
                    if !didLinkSuccessfully {
                        self.modelContext.delete(newLocation)
                        try? self.modelContext.save()
                        // Clear stale activeLocationForScan (was set to newLocation.id)
                        // and other capture state so the next scan starts fresh.
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

                // Abort if tracking never stabilized — placing an anchor with degraded
                // tracking would produce an unreliable stitch transform.
                guard self.currentARSession?.currentFrame?.camera.trackingState == .normal else {
                    print("[BoundaryAnchor] Stabilization timeout — tracking not normal, aborting link")
                    self.showExtendOverlay = false
                    self.scanStore.capturePhase = .idle
                    self.showTransientMessage("Tracking unstable — move to a well-lit area and try again", duration: 4)
                    return
                }

                // Place pinB in mapB's coordinate space using the camera's current transform.
                // This captures both position (near origin after reset) and rotation
                // (device orientation in the new coordinate frame).
                let pinBTransform: simd_float4x4
                let pinBId: UUID
                // Capture fresh compass heading at Pin B time (may differ from Pin A)
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
                    // Hard failure: no frame means we can't place a real anchor.
                    // Abort the link (but the new session is still usable for standalone recording).
                    print("[BoundaryAnchor] ERROR: No frame available for pinB — aborting link")
                    self.showExtendOverlay = false
                    self.scanStore.capturePhase = .idle
                    self.showTransientMessage("Link failed — no AR frame. Start a new scan.", duration: 4)
                    return
                }

                self.scanStore.pendingStitchLink = PendingStitchLink(
                    sourceLocationId: actualSourceLocationId,
                    sourceScanId: savedScan.id,
                    sourceAnchorId: UUID(),
                    sourceAnchorTransform: pinACameraPose,
                    sourceAnchorCompassHeading: compassHeading,
                    targetLocationId: newLocation.id,
                    targetAnchorId: pinBId,
                    targetAnchorTransform: pinBTransform,
                    targetAnchorCompassHeading: pinBCompassHeading,
                    linkType: .midSession
                )

                didLinkSuccessfully = true
                self.showExtendOverlay = false
                self.scanStore.capturePhase = .recording
                self.startRecording()

                // Record Pin B AFTER startRecording() — FrameCaptureSession.start()
                // clears boundary anchor state, so recording must begin first.
                self.frameCaptureSession.recordBoundaryAnchor(
                    transform: pinBTransform,
                    id: pinBId,
                    compassHeading: pinBCompassHeading
                )

                self.showTransientMessage("📍 Linked! Scanning new space...", duration: 3)
            }
        }
    }
}
