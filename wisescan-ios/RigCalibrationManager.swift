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

    /// One collected calibration position: everything needed to build a solver input
    /// EXCEPT the equirect bytes, which stay on the camera until the batch download at
    /// solve time. (The per-still download + edge detect used to gate the Capture button
    /// ~2-4 s per position; deferred, the user walks as soon as the camera is ready.)
    private struct PendingStill {
        let phoneToWorld: simd_float4x4
        let meshEdges: [RigCalibrationSolver.MeshEdge]
        let fileURL: URL
    }

    /// Collected calibration positions awaiting the solve-time batch download.
    private var pendingStills: [PendingStill] = []

    /// User-visible progress through the download → edge-detect → solve pipeline,
    /// shown on the calibration card during `.solving`.
    private(set) var solvingStatusMessage: String?

    /// Invalidates in-flight capture/solve pipelines when the session is cancelled or
    /// restarted — an awaited download must not resurrect a cancelled session's state.
    private var sessionGeneration = 0

    /// Still format in force before calibration downshifted it (restored at session end).
    private var preCalibrationFormat: ThetaCameraManager.StillFormat?

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
        sessionGeneration += 1
        pendingStills.removeAll()
        lastResult = nil
        captureErrorMessage = nil
        solvingStatusMessage = nil
        state = .capturing(stillsCollected: 0)
        downshiftStillFormatForCalibration()
        logger.info("Calibration session started")

        // Create a temporary directory for calibration equirects
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rig_calibration_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        calibrationTempDir = tempDir
    }

    /// Cancel the calibration session.
    func cancelCalibration() {
        sessionGeneration += 1
        pendingStills.removeAll()
        lastResult = nil
        captureErrorMessage = nil
        solvingStatusMessage = nil
        state = .idle
        restoreStillFormat()
        cleanupTempDir()
        logger.info("Calibration cancelled")
    }

    /// Capture one calibration still. Called when the user taps during stillness in
    /// calibration mode. The caller provides the phone pose and mesh anchors; this
    /// method triggers the Theta capture and extracts mesh edges (overlapped with the
    /// in-camera stitch), then stashes the position — the ~11 MB download and edge
    /// detection are DEFERRED to a batch when the last still is collected, so the
    /// button frees as soon as the camera can take the next shot.
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
        let generation = sessionGeneration

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
            let extractStart = Date()
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
            PerfDiag.log("[RigCal] mesh edges: \(meshEdges.count) edges from \(vertexCount) verts in \(Int(Date().timeIntervalSince(extractStart) * 1000))ms (overlapped with camera stitch)")

            // HARD gate, not just the card warning: a position with (near-)zero mesh edges
            // contributes nothing but noise, and three of them waste the whole session on a
            // guaranteed-failed solve (run6). The camera shot is a harmless orphan.
            if meshEdges.count < AppConstants.calibrationMinMeshEdges {
                self.failCapture("Not enough LiDAR mesh here (\(meshEdges.count) edges) — sweep the iPad around this position to build mesh, then tap Capture again.")
                return
            }

            // Angular-coverage gate: run9 diagnostics showed tens of thousands of edges
            // ALL in one ~60° wedge (the only direction the iPad had meshed) — count alone
            // passes while the solve stays hopelessly ambiguous. Require the edges to span
            // a real arc around the position.
            let coverage = Self.yawCoverageDegrees(of: meshEdges, around: phonePos)
            PerfDiag.log("[RigCal] mesh coverage: \(Int(coverage))° yaw span (\(meshEdges.count) edges)")
            if coverage < AppConstants.calibrationMinCoverageDeg {
                self.failCapture("Mesh covers only ~\(Int(coverage))° around you — sweep the iPad in a full circle at this spot, then tap Capture again.")
                return
            }

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

            // Defer the ~11 MB download + edge detection to the solve-time batch: the shot
            // persists on the camera, so only the pose + mesh edges + file URL are stashed
            // here and the button frees for the next position.
            await MainActor.run {
                guard self.sessionGeneration == generation else { return }   // cancelled mid-flight
                self.pendingStills.append(PendingStill(
                    phoneToWorld: phoneTransform,
                    meshEdges: meshEdges,
                    fileURL: url
                ))
                let newCount = self.pendingStills.count
                self.logger.info("Calibration still \(newCount)/\(AppConstants.calibrationStillCount) collected (download deferred)")

                if newCount >= AppConstants.calibrationStillCount {
                    self.runSolverPipeline()
                } else {
                    self.state = .capturing(stillsCollected: newCount)
                }
            }
        }
    }

    /// Yaw span (degrees) of mesh-edge midpoints around a position: 16 azimuth bins,
    /// a bin counts when it holds a meaningful number of edges, result = filled × 22.5°.
    /// Cheap ambiguity guard — one dense wedge can hold 50K+ edges and still leave the
    /// 4-DOF solve unconstrained.
    private nonisolated static func yawCoverageDegrees(
        of edges: [RigCalibrationSolver.MeshEdge], around position: SIMD3<Float>
    ) -> Float {
        guard !edges.isEmpty else { return 0 }
        var bins = [Int](repeating: 0, count: 16)
        for edge in edges {
            let mid = (edge.a + edge.b) * 0.5
            let dx = mid.x - position.x, dz = mid.z - position.z
            guard dx * dx + dz * dz > 0.01 else { continue }   // ignore directly under/over
            let yaw = atan2(dx, -dz)   // ARKit convention, matches the solver
            let bin = Int((yaw + .pi) / (2 * .pi) * 16) % 16
            bins[bin < 0 ? bin + 16 : bin] += 1
        }
        let perBinFloor = max(10, edges.count / 200)   // a bin must hold >0.5% of edges
        return Float(bins.filter { $0 >= perBinFloor }.count) * 22.5
    }

    /// Route a calibration capture failure to the card UI + log (finding #10 — was a
    /// silent log-and-return; the user saw a button that just popped back to idle).
    private func failCapture(_ message: String) {
        captureErrorMessage = message
        logger.error("Calibration capture failed: \(message)")
    }

    /// Write one calibration input bundle under Documents/rigcal_diag/inputs/:
    /// still<i>.jpg (raw equirect), still<i>_pose.json (phone_to_world, column-major),
    /// still<i>_edges.bin (Float32 LE, 6 per edge: ax ay az bx by bz). Dev diagnostics
    /// for offline solver work — never exported.
    private nonisolated static func persistCalibrationInput(
        still: PendingStill, jpegData: Data, index: Int
    ) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rigcal_diag/inputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = "still\(index + 1)"
        try? jpegData.write(to: dir.appendingPathComponent("\(base).jpg"))

        let m = still.phoneToWorld
        let flat = [m.columns.0, m.columns.1, m.columns.2, m.columns.3]
            .flatMap { [$0.x, $0.y, $0.z, $0.w] }
        if let pose = try? JSONSerialization.data(
            withJSONObject: ["phone_to_world": flat], options: [.prettyPrinted]) {
            try? pose.write(to: dir.appendingPathComponent("\(base)_pose.json"))
        }

        var floats = [Float]()
        floats.reserveCapacity(still.meshEdges.count * 6)
        for e in still.meshEdges {
            floats.append(contentsOf: [e.a.x, e.a.y, e.a.z, e.b.x, e.b.y, e.b.z])
        }
        floats.withUnsafeBufferPointer {
            try? Data(buffer: $0).write(to: dir.appendingPathComponent("\(base)_edges.bin"))
        }
    }

    /// Batch phase after the last still is collected: download every deferred equirect
    /// (with retries — the shots persist on the camera, so a Wi-Fi hiccup never costs a
    /// walked position), detect edges, then solve. The card shows per-step progress via
    /// `solvingStatusMessage`; every stage emits a [RigCal] PerfDiag timing so the
    /// GPU-acceleration question can be decided from device numbers.
    private func runSolverPipeline() {
        state = .solving
        // All triggers are done — the downloads below fetch files already on the camera,
        // so the scan-time format can come back right away.
        restoreStillFormat()
        let pending = pendingStills
        let prior = currentProfile ?? .mechanicalPrior
        let total = pending.count
        let generation = sessionGeneration
        let thetaManager = ThetaCameraManager.shared

        Task {
            var inputs: [RigCalibrationSolver.CalibrationInput] = []
            for (index, still) in pending.enumerated() {
                self.solvingStatusMessage = "Downloading still \(index + 1)/\(total)…"
                var jpegData: Data?
                for attempt in 1...3 {
                    do {
                        let t0 = Date()
                        let data = try await thetaManager.downloadData(from: still.fileURL)
                        PerfDiag.log("[RigCal] download \(index + 1)/\(total): \(data.count / 1024) KB in \(Int(Date().timeIntervalSince(t0) * 1000))ms (attempt \(attempt))")
                        jpegData = data
                        break
                    } catch {
                        self.logger.warning("Calibration download \(index + 1) attempt \(attempt) failed: \(error.localizedDescription)")
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
                guard self.sessionGeneration == generation else { return }   // cancelled
                guard let jpegData else {
                    self.solvingStatusMessage = nil
                    self.state = .failed("Downloading still \(index + 1) failed — the shots are still on the camera; check the Theta Wi-Fi link and re-run calibration.")
                    return
                }

                self.solvingStatusMessage = "Finding edges in still \(index + 1)/\(total)…"
                let t1 = Date()
                let detected = await Self.computeOffMain {
                    RigCalibrationSolver.detectEquirectEdges(in: jpegData)
                }
                PerfDiag.log("[RigCal] edge detect \(index + 1)/\(total): \(Int(Date().timeIntervalSince(t1) * 1000))ms")
                guard self.sessionGeneration == generation else { return }   // cancelled
                guard let edgeMap = detected else {
                    self.solvingStatusMessage = nil
                    self.state = .failed("Couldn't detect edges in still \(index + 1) — re-run calibration from brighter positions with more visible structure.")
                    return
                }
                inputs.append(RigCalibrationSolver.CalibrationInput(
                    phoneToWorld: still.phoneToWorld,
                    edgeMap: edgeMap,
                    meshEdges: still.meshEdges
                ))

                // Perf-diag builds persist the full solver input (equirect JPEG + pose +
                // mesh edges) so the cost function can be iterated OFFLINE against real
                // captures instead of burning rig time. Local Documents only — these are
                // raw, unblurred captures; they must never leave the device via export.
                if PerfDiag.enabled {
                    Self.persistCalibrationInput(still: still, jpegData: jpegData, index: index)
                    PerfDiag.log("[RigCal] input bundle persisted: still\(index + 1) (\(jpegData.count / 1024) KB jpg + \(still.meshEdges.count) edges) → Documents/rigcal_diag/inputs/")
                }
            }

            self.solvingStatusMessage = "Solving rig parameters…"
            self.logger.info("Running calibration solver with \(inputs.count) inputs...")
            let solveInputs = inputs
            let t2 = Date()
            // Off main: the Nelder-Mead loop is compute-bound (edges × inputs × 100+
            // iterations) and must not stall the AR session's frame delivery.
            let result = await Self.computeOffMain {
                RigCalibrationSolver.solve(inputs: solveInputs, prior: prior)
            }
            PerfDiag.log("[RigCal] solve: \(Int(Date().timeIntervalSince(t2) * 1000))ms, \(result.iterations) iterations")
            guard self.sessionGeneration == generation else { return }   // cancelled

            self.solvingStatusMessage = nil
            self.lastResult = result
            self.logger.info("Solver complete: residual \(result.residualPx) px RMS, converged: \(result.converged), iterations: \(result.iterations)")
            // Repeatability is the real quality metric: on the same physical rig,
            // back-to-back runs should land within ~mm / tenths of a degree of each
            // other even when the residual floor (scene + operator noise) varies.
            let p = result.profile
            PerfDiag.log(String(format: "[RigCal] solved params: dy=%.3fm dLat=%.3fm yaw=%.2f° pitch=%.2f° (residual %.2f px, %@)",
                                p.dy, p.dLateral, p.yaw * 180 / .pi, p.pitchResidual * 180 / .pi,
                                result.residualPx, result.converged ? "converged" : "NOT converged"))

            // Alignment diagnostics: white = image edges, cyan = mechanical prior, red =
            // solved. One PNG per still under Documents/rigcal_diag — if red doesn't hug
            // white better than cyan, the solve added nothing (flat cost surface).
            if result.converged {
                let solvedProfile = result.profile
                let diagInputs = solveInputs
                await Self.computeOffMain {
                    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("rigcal_diag", isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let stamp = Int64(Date().timeIntervalSince1970 * 1000)   // epoch ms (CONTRIBUTING → Units & time)
                    for (idx, input) in diagInputs.enumerated() {
                        guard let png = RigCalibrationSolver.renderDiagnostic(
                            input: input, solved: solvedProfile, prior: .mechanicalPrior) else { continue }
                        try? png.write(to: dir.appendingPathComponent("cal_\(stamp)_still\(idx + 1).png"))
                    }
                    return ()
                }
                PerfDiag.log("[RigCal] alignment diagnostics written to Documents/rigcal_diag/cal_*.png")
            }

            if !result.converged || result.residualPx < 0
                || result.residualPx.isNaN || result.residualPx.isInfinite {
                self.state = .failed("Solver did not converge — try calibrating in a more feature-rich area with visible mesh")
            } else {
                self.state = .review(residualPx: result.residualPx, converged: result.converged)
            }
        }
    }

    /// Calibration solves on a 512-px-wide edge map, so full-resolution stills are ~10×
    /// oversampled: capture at the camera's SMALLEST JPEG size instead. On a THETA X
    /// (11K/60 MP → 5.5K/15 MP) that shrinks the in-camera stitch — the per-position
    /// "hold steady" gate — and cuts the batch download ~4×. Restored at pipeline entry
    /// (before downloads; the files are already on the camera) and on cancel; scan
    /// stills are never captured mid-calibration. Single-format cameras (Z1/V) no-op.
    private func downshiftStillFormatForCalibration() {
        let theta = ThetaCameraManager.shared
        guard theta.isConnected else { return }
        // Full-equirect (2:1) formats ONLY: the X also reports square 1:1 stills, and
        // run6 (2026-07-30) downshifted into 2752×2752 — a 512×512 working image whose
        // vertical pixel scale is 2× the 512×256 the solver and thresholds assume,
        // inflating every residual.
        guard let smallest = theta.stillFormatMenu
                  .filter({ $0.width == $0.height * 2 })
                  .min(by: { $0.width * $0.height < $1.width * $1.height }),
              let current = theta.currentStillFormat, smallest != current else { return }
        preCalibrationFormat = current
        Task {
            do {
                try await theta.applyStillResolution(smallest)
                PerfDiag.log("[RigCal] still format downshifted \(current.width)×\(current.height) → \(smallest.width)×\(smallest.height) for calibration")
                // If a restore already ran while this was in flight (instant cancel),
                // undo immediately so the camera never sticks at the small size.
                if self.preCalibrationFormat == nil {
                    try await theta.applyStillResolution(current)
                    PerfDiag.log("[RigCal] downshift landed after session end — re-restored \(current.width)×\(current.height)")
                }
            } catch {
                self.preCalibrationFormat = nil
                self.logger.warning("Calibration format downshift failed (continuing at full size): \(error.localizedDescription)")
            }
        }
    }

    /// Restore the pre-calibration still format. Idempotent — called from every
    /// session-end path (pipeline entry, cancel).
    private func restoreStillFormat() {
        guard let format = preCalibrationFormat else { return }
        preCalibrationFormat = nil
        Task {
            do {
                try await ThetaCameraManager.shared.applyStillResolution(format)
                PerfDiag.log("[RigCal] still format restored to \(format.width)×\(format.height)")
            } catch {
                self.logger.error("Failed to restore still format \(format.width)×\(format.height) — re-select it on the camera card before scanning: \(error.localizedDescription)")
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

    // (First-still spot-check + session-yaw bridging removed 2026-07-30: the
    // post-process pivot solves calibration from each scan's own stills in the Process
    // step, so there is no pre-known calibration to drift from and no yaw to bridge.)

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
