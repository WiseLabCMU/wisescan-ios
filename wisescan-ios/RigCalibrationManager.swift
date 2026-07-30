import ARKit
import Foundation
import Observation
import os
import simd

/// Orchestrates the pre-scan rig calibration flow (docs/design/still-source-360.md →
/// "Calibration UX: pre-scan, integrated into Dashboard card").
///
/// State machine: `.idle` → `.capturing` → `.solving` → `.review` → `.idle`.
/// The manager accumulates calibration captures (phone pose + equirect + mesh edges),
/// runs the solver on a background queue, and persists the result to UserDefaults.
///
/// Integrates with:
/// - `ThetaCameraManager` for 360° still capture during calibration
/// - `ARCoverageView.Coordinator` for mesh anchor access
/// - `ThetaCameraCard` (Dashboard) for the calibration UI
@Observable
@MainActor
final class RigCalibrationManager {
    static let shared = RigCalibrationManager()

    enum State: Equatable {
        case idle
        case capturing(stillsCollected: Int)
        case solving
        case review(residualPx: Float, converged: Bool)
        case failed(String)
    }

    private(set) var state: State = .idle

    /// The currently persisted calibration profile (loaded at init, updated after accept).
    private(set) var currentProfile: RigProfile?

    /// The currently active profile. Returns `nil` if a camera is connected but its
    /// serial number mismatches the profile's stored serial number.
    var activeProfile: RigProfile? {
        guard let profile = currentProfile else { return nil }
        let theta = ThetaCameraManager.shared
        if theta.isConnected, let serial = theta.serialNumber, let profileSerial = profile.cameraSerialNumber {
            if serial != profileSerial {
                return nil // Serial mismatch: calibration is physically invalid
            }
        }
        return profile
    }

    /// Last solved result (available during `.review`).
    private(set) var lastResult: RigCalibrationSolver.CalibrationResult?

    /// Mesh vertex count near the current phone position (updated by the AR delegate
    /// for the environment quality gate).
    var nearbyMeshVertexCount: Int = 0

    /// Accumulated calibration inputs.
    private var capturedInputs: [RigCalibrationSolver.CalibrationInput] = []

    /// Temporary directory for calibration equirects (cleaned after solve).
    private var calibrationTempDir: URL?

    /// Re-entrancy guard: prevents double-taps during the async capture pipeline.
    /// Also observed by the calibration overlay for button disable + progress label.
    private(set) var isCapturingCalibrationStill = false

    /// User-visible reason the last calibration capture attempt failed, shown on the
    /// calibration card and cleared when a new capture starts. (Review finding #10:
    /// failures used to logger.error and bail, leaving the card stuck on "capturing"
    /// with no feedback.)
    private(set) var captureErrorMessage: String?

    private let logger = Logger(subsystem: "org.arenaxr.scan4d", category: "rigcal")

    private init() {
        currentProfile = RigProfile.load()
    }

    // MARK: - Public API

    var isCalibrating: Bool {
        switch state {
        case .capturing, .solving: return true
        default: return false
        }
    }

    /// Includes `.failed` and `.review` so the user can see the error and retry or accept the result.
    var showsCalibrationOverlay: Bool {
        switch state {
        case .capturing, .solving, .review, .failed: return true
        default: return false
        }
    }

    var isEnvironmentSufficient: Bool {
        nearbyMeshVertexCount >= AppConstants.calibrationMeshVertexMinimum
    }

    /// Human-readable calibration age for the Dashboard card.
    var calibrationAgeDescription: String? {
        guard let profile = currentProfile, profile.isSolved else { return nil }
        let elapsed = Date().timeIntervalSince(profile.timestamp)
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }

    /// Begin a calibration session. Resets any previous captures.
    func beginCalibration() {
        capturedInputs.removeAll()
        lastResult = nil
        state = .capturing(stillsCollected: 0)
        logger.info("Calibration session started")

        // Create a temporary directory for calibration equirects
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rig_calibration_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        calibrationTempDir = tempDir
    }

    /// Cancel the calibration session.
    func cancelCalibration() {
        capturedInputs.removeAll()
        lastResult = nil
        state = .idle
        cleanupTempDir()
        logger.info("Calibration cancelled")
    }

    /// Capture one calibration still. Called when the user taps during stillness in
    /// calibration mode. The caller provides the phone pose and mesh anchors;
    /// this method triggers the Theta capture + download, extracts mesh edges, and
    /// detects equirect edges.
    ///
    /// Returns immediately; the capture runs asynchronously.
    func captureCalibrationStill(
        phoneTransform: simd_float4x4,
        timestamp: TimeInterval,
        meshAnchors: [ARMeshAnchor]
    ) {
        guard case .capturing(let count) = state,
              count < AppConstants.calibrationStillCount,
              !isCapturingCalibrationStill else { return }
        isCapturingCalibrationStill = true
        captureErrorMessage = nil

        let thetaManager = ThetaCameraManager.shared
        guard thetaManager.isConnected, !thetaManager.isCapturing else {
            isCapturingCalibrationStill = false
            return
        }

        let phonePos = SIMD3<Float>(phoneTransform.columns.3.x,
                                   phoneTransform.columns.3.y,
                                   phoneTransform.columns.3.z)

        logger.info("Calibration still \(count + 1): triggering capture")

        // Trigger the Theta capture FIRST — the ~2s in-camera exposure/stitch overlaps the
        // mesh-edge extraction below instead of waiting behind it.
        thetaManager.takePicture()

        // Wait for the capture + download, then process
        Task {
            defer {
                Task { @MainActor in
                    self.isCapturingCalibrationStill = false
                }
            }

            // Extract mesh edges near the phone position — OFF main (transforms every vertex
            // of every nearby anchor; on main this froze the UI and stalled the AR session).
            let (meshEdges, vertexCount) = await Self.computeOffMain {
                RigCalibrationSolver.extractMeshEdges(
                    from: meshAnchors,
                    near: phonePos,
                    radius: AppConstants.calibrationMeshRadiusMeters
                )
            }
            self.nearbyMeshVertexCount = vertexCount
            if vertexCount < AppConstants.calibrationMeshVertexMinimum {
                self.logger.warning("Low mesh density at calibration position: \(vertexCount) vertices")
                // Don't block — the user sees the warning on the card
            }
            self.logger.info("Calibration still: \(meshEdges.count) edges, \(vertexCount) vertices near position")

            // Poll for the capture to complete (the manager sets isCapturing = false)
            var attempts = 0
            while thetaManager.isCapturing && attempts < 100 {
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                attempts += 1
            }

            guard let capture = thetaManager.lastCapture,
                  let url = URL(string: capture.fileURL) else {
                self.failCapture("The camera didn't report a finished still — check the Theta and tap Capture again.")
                return
            }

            // Single download of the ~11 MB equirect (review finding #8: this used to run
            // twice — once via downloadLastCapture for transfer stats/preview, then again
            // for the raw bytes).
            let jpegData: Data
            do {
                jpegData = try await thetaManager.downloadData(from: url)
            } catch {
                self.failCapture("Downloading the still failed (\(error.localizedDescription)) — check the Theta Wi-Fi link and tap Capture again.")
                return
            }

            // Detect edges in the equirect — off main (Sobel + chamfer over the working image)
            let detected = await Self.computeOffMain {
                RigCalibrationSolver.detectEquirectEdges(in: jpegData)
            }
            guard let edgeMap = detected else {
                self.failCapture("Couldn't detect edges in the still — try a brighter position with more visible structure.")
                return
            }

            let input = RigCalibrationSolver.CalibrationInput(
                phoneToWorld: phoneTransform,
                edgeMap: edgeMap,
                meshEdges: meshEdges
            )

            await MainActor.run {
                self.capturedInputs.append(input)
                let newCount = self.capturedInputs.count
                self.logger.info("Calibration still \(newCount)/\(AppConstants.calibrationStillCount) captured")

                if newCount >= AppConstants.calibrationStillCount {
                    self.runSolver()
                } else {
                    self.state = .capturing(stillsCollected: newCount)
                }
            }
        }
    }

    /// Route a calibration capture failure to the card UI + log (finding #10 — was a
    /// silent log-and-return; the user saw a button that just popped back to idle).
    private func failCapture(_ message: String) {
        captureErrorMessage = message
        logger.error("Calibration capture failed: \(message)")
    }

    /// Run the solver on a background queue after all stills are captured.
    private func runSolver() {
        state = .solving
        let inputs = capturedInputs
        let prior = currentProfile ?? .mechanicalPrior

        logger.info("Running calibration solver with \(inputs.count) inputs...")

        // Explicitly dispatch to GCD global queue. The solver's Nelder-Mead loop is
        // compute-bound (2000 edges × 3 inputs × 100+ iterations); even with subsampling
        // this must not block the main thread or the AR session's frame delivery.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = RigCalibrationSolver.solve(inputs: inputs, prior: prior)

            DispatchQueue.main.async {
                guard let self else { return }
                self.lastResult = result
                self.logger.info("Solver complete: residual \(result.residualPx) px RMS, converged: \(result.converged), iterations: \(result.iterations)")

                if !result.converged || result.residualPx < 0
                    || result.residualPx.isNaN || result.residualPx.isInfinite {
                    self.state = .failed("Solver did not converge — try calibrating in a more feature-rich area with visible mesh")
                } else {
                    self.state = .review(residualPx: result.residualPx, converged: result.converged)
                }
            }
        }
    }

    func acceptCalibration() {
        guard let result = lastResult else { return }
        
        let theta = ThetaCameraManager.shared
        var model: String?
        if case .connected(let m, _) = theta.state { model = m }
        
        let boundProfile = result.profile.with(
            cameraModel: model,
            cameraSerialNumber: theta.serialNumber
        )
        
        boundProfile.save()
        currentProfile = boundProfile
        state = .idle
        cleanupTempDir()
        logger.info("Calibration accepted and saved (residual: \(result.residualPx) px RMS)")
    }

    /// Reject the result and restart.
    func redoCalibration() {
        beginCalibration()
    }

    /// Clear the persisted calibration (explicit user action from settings).
    func resetCalibration() {
        RigProfile.clear()
        currentProfile = nil
        state = .idle
        logger.info("Calibration profile cleared")
    }

    // MARK: - First-still drift spot-check

    /// Warning message from the most recent drift spot-check (nil = OK or not checked).
    /// The capture view observes this to show a transient warning toast.
    private(set) var driftWarning: String?

    /// Whether the first-still spot-check has already run for the current scan.
    private var hasSpotChecked = false

    /// Reset the spot-check flag at the start of each recording session.
    func resetSpotCheck() {
        hasSpotChecked = false
        driftWarning = nil
    }

    /// Run the first-still calibration spot-check. Called after the first 360° still
    /// of a scan downloads. Evaluates the cost function at the stored parameters against
    /// the live capture — no optimization, O(1), milliseconds.
    ///
    /// - Returns: `true` if the check passed (or was skipped), `false` if drift detected.
    @discardableResult
    func spotCheckFirstStill(
        phoneTransform: simd_float4x4,
        jpegData: Data,
        meshAnchors: [ARMeshAnchor]
    ) async -> Bool {
        guard !hasSpotChecked else { return driftWarning == nil }
        hasSpotChecked = true

        guard let profile = currentProfile, profile.isSolved else {
            logger.info("Spot-check: no calibration — skipped")
            return true
        }

        let phonePos = SIMD3<Float>(phoneTransform.columns.3.x,
                                   phoneTransform.columns.3.y,
                                   phoneTransform.columns.3.z)
        // ALL compute off main: this runs MID-RECORDING (first 360° still of the scan) —
        // extraction alone can touch 100k+ live mesh vertices, and a main stall here is the
        // VIO-starvation class the capture pipeline is engineered to avoid.
        let liveResidualOrNil: Float? = await Self.computeOffMain {
            let (meshEdges, _) = RigCalibrationSolver.extractMeshEdges(
                from: meshAnchors, near: phonePos,
                radius: AppConstants.calibrationMeshRadiusMeters
            )
            guard let edgeMap = RigCalibrationSolver.detectEquirectEdges(
                in: jpegData, maxWidth: AppConstants.calibrationEdgeDetectionWidth
            ) else { return nil }
            let input = RigCalibrationSolver.CalibrationInput(
                phoneToWorld: phoneTransform,
                edgeMap: edgeMap,
                meshEdges: meshEdges
            )
            return RigCalibrationSolver.validateCalibration(input: input, profile: profile)
        }
        guard let liveResidual = liveResidualOrNil else {
            logger.warning("Spot-check: edge detection failed — skipped")
            return true
        }
        let storedResidual = profile.residualPx
        let driftRatio = storedResidual > 0 ? liveResidual / storedResidual : Float.greatestFiniteMagnitude

        logger.info("Spot-check: live residual \(String(format: "%.1f", liveResidual)) px RMS vs stored \(String(format: "%.1f", storedResidual)) px RMS (ratio \(String(format: "%.1f", driftRatio))×)")

        if liveResidual > AppConstants.calibrationDriftWarnFloorPx
            && driftRatio > AppConstants.calibrationDriftWarnMultiplier {
            let msg = String(format: "⚠️ Rig may have shifted — residual drifted from %.1f → %.1f px", storedResidual, liveResidual)
            driftWarning = msg
            logger.warning("\(msg)")
            return false
        }

        driftWarning = nil
        return true
    }

    // MARK: - Private

    /// Run the CPU-heavy calibration compute (mesh-edge extraction, and optionally equirect
    /// edge detection + a cost evaluation) OFF the main actor. Everything here is read-only
    /// over the snapshot inputs; results hop back to the caller's actor. Never run these
    /// inline on main — extraction transforms every vertex of every nearby anchor, and the
    /// spot-check variant runs MID-RECORDING where a main stall starves VIO (the ARFrame-
    /// retention failure class this repo fights hardest).
    private nonisolated static func computeOffMain<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    private func cleanupTempDir() {
        if let dir = calibrationTempDir {
            try? FileManager.default.removeItem(at: dir)
            calibrationTempDir = nil
        }
    }
}
