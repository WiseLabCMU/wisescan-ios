import Foundation
import simd

/// POST-PROCESS rig calibration (the 2026-07-30 pivot): solves the phone→360°-camera
/// extrinsics from the scan's OWN equirect stills against the scan's COMPLETE mesh,
/// then bakes `cam_transform` + provenance into every still sidecar.
///
/// Why post-process beats the old pre-scan ritual:
/// - The calibration inputs share the capture session with the poses they produce, so
///   the Theta's per-session yaw-reference reset (run14: 103° jump, rig untouched) is
///   irrelevant by construction.
/// - The FULL scan mesh surrounds every still position (the ritual calibrated against
///   the young mid-scan mesh — the dominant failure mode of runs 6-11).
/// - Every scan refines the persisted rig geometry (dy/dLateral/pitch — proven
///   repeatable across sessions; yaw is per-session by hardware behavior).
///
/// Frame discipline: runs in the RAW capture frame — BEFORE registration bakes
/// mesh.obj into the canonical frame — matching the sidecars' raw phone poses. A scan
/// whose registration already applied is stamped with prior poses instead (rare:
/// re-runs of pre-pivot scans; solving against a baked mesh with raw poses would be
/// silently wrong).
///
/// Runs on the postprocess background queue (no main-actor state).
enum EquirectPostCalibration {

    /// Provenance values stamped into `rig_calibration_source`.
    static let sourceSolved = "solved_postprocess"
    static let sourceYawOnly = "solved_postprocess_yaw_only"
    static let sourcePrior = "prior_postprocess"

    /// Bumped when the solver/anchoring changes enough that already-stamped scans should
    /// re-calibrate on their next Process. v2: 360post1 — the rolling-refinement anchor
    /// trusted a poisoned unbounded-era profile (dLat 0.574 m persisted → every baked
    /// pose offset ~0.6 m in x/z); v2 sanity-gates the anchor and re-solves everything.
    /// v3: 360post4 — dy box widened to the telescoping envelope (±0.6 m); scans solved
    /// against the old 1.3 m ceiling re-solve unclipped. v4: tape measure (0.787 m) vs
    /// solve (1.299 m) proved a systematic +dy pull in the chamfer cost — dy now anchors
    /// to the user-measured rig height when provided (±0.15), unmeasured envelope back
    /// to ±0.3.
    static let solverVersion = 4

    struct StillRecord {
        let sequence: Int
        let sidecarURL: URL
        let jpgURL: URL
        let phoneToWorld: simd_float4x4
        let phonePos: SIMD3<Float>
    }

    /// Entry point from the postprocessor. Returns a short human status for the log.
    /// Precondition (enforced by the caller): no pending downloads — every sidecar's
    /// JPG is on disk, so the solve sees the scan's full still set.
    nonisolated static func run(scanDir: URL, rawDataDir: URL,
                                report: (String) -> Void) -> String {
        let t0 = Date()
        func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }
        let stills = loadStills(rawDataDir: rawDataDir)
        guard !stills.isEmpty else { return "no stills" }

        // Already-registered scans: the mesh is canonical but the sidecar poses are raw.
        // Solving across frames would be silently wrong — stamp prior poses and say so.
        if let reg = SaveRegistration.loadSidecar(scanDirectory: scanDir), reg.applied {
            bake(stills: stills, profile: persistedOrPrior(), source: sourcePrior,
                 residual: nil)
            return "registration already baked — prior poses stamped for \(stills.count) still(s)"
        }

        report("Reading scan mesh…")
        let tParse = Date()
        guard let mesh = RigCalibrationSolver.SavedMeshOBJ.load(objURL: meshURL(scanDir: scanDir, rawDataDir: rawDataDir)) else {
            bake(stills: stills, profile: persistedOrPrior(), source: sourcePrior,
                 residual: nil)
            return "mesh.obj unavailable — prior poses stamped for \(stills.count) still(s)"
        }
        let parseMs = ms(tParse)

        // Build solver inputs from the best-spread subset (aliasing shrinks and the
        // solve sharpens with baseline; cost grows linearly with inputs). Mesh edges for
        // ALL positions extract in one face pass; the edge maps decode per still.
        let tPrep = Date()
        let selected = selectBySpread(stills, cap: 5)
        let edgesPerStill = RigCalibrationSolver.extractMeshEdges(
            mesh: mesh, nearAll: selected.map(\.phonePos),
            radius: AppConstants.calibrationMeshRadiusMeters)
        var inputs: [RigCalibrationSolver.CalibrationInput] = []
        for (idx, still) in selected.enumerated() {
            report("Calibrating 360° rig (\(idx + 1)/\(selected.count))…")
            let edges = edgesPerStill[idx]
            guard edges.count >= AppConstants.calibrationMinMeshEdges,
                  let jpegData = try? Data(contentsOf: still.jpgURL),
                  let edgeMap = RigCalibrationSolver.detectEquirectEdges(in: jpegData)
            else { continue }
            inputs.append(RigCalibrationSolver.CalibrationInput(
                phoneToWorld: still.phoneToWorld, edgeMap: edgeMap, meshEdges: edges))
        }
        let prepMs = ms(tPrep)

        let stored = persistedOrPrior()

        // Too few usable inputs for geometry: hold the persisted dy/dLat/pitch and solve
        // the per-session yaw alone off the best still (1-D global scan — cheap, robust).
        if inputs.count < AppConstants.calibrationMinStillsForSolve {
            guard let first = inputs.first,
                  let (yaw, residual) = RigCalibrationSolver.solveSessionYaw(
                    input: first, profile: stored) else {
                bake(stills: stills, profile: stored, source: sourcePrior, residual: nil)
                return "insufficient solver inputs (\(inputs.count)) — prior poses stamped"
            }
            let profile = stored.replacingYaw(yaw)
            bake(stills: stills, profile: profile, source: sourceYawOnly, residual: residual)
            PerfDiag.log(String(format: "[RigCal] postprocess yaw-only solve: yaw=%.2f° residual=%.2f px (%d input(s))",
                                yaw * 180 / .pi, residual, inputs.count))
            return "yaw-only solve from \(inputs.count) still(s)"
        }

        // Full solve — mechanical bounds, yaw global (see below).
        report("Solving 360° rig calibration…")
        let tSolve = Date()
        // dy anchors to the USER-MEASURED rig height when one is set (Settings → 360° rig):
        // the chamfer cost has a systematic +dy pull (dense image-edge bands attract the
        // sparse projected mesh downward → camera up; 360post4 solved 1.299 m vs a
        // 0.787 m tape measure), so the measurement is treated as ground truth with a
        // small slop window. Unmeasured rigs fall back to the mechanical envelope.
        // dLat/pitch/yaw always solve free — they have no such attractor and match
        // physical truth when dy isn't straining (post2/3).
        let measuredDy = Float(UserDefaults.standard.double(forKey: AppConstants.Key.rigMeasuredDyMeters))
        let bounds: RigCalibrationSolver.SolveBounds = measuredDy > 0.1
            ? RigCalibrationSolver.SolveBounds(
                anchorDy: measuredDy, anchorLat: 0,
                dyHalf: AppConstants.calibrationMeasuredDyHalfM,
                latHalf: AppConstants.calibrationBoundLateralM,
                pitchHalfDeg: AppConstants.calibrationBoundPitchDeg)
            : .mechanical
        let result = RigCalibrationSolver.solve(inputs: inputs, prior: stored, bounds: bounds)
        let solveMs = ms(tSolve)
        let p = result.profile
        PerfDiag.log(String(format: "[RigCal] postprocess solve: dy=%.3fm dLat=%.3fm yaw=%.2f° pitch=%.2f° (residual %.2f px, %@, %d inputs)",
                            p.dy, p.dLateral, p.yaw * 180 / .pi, p.pitchResidual * 180 / .pi,
                            result.residualPx, result.converged ? "converged" : "NOT converged",
                            inputs.count))

        guard result.converged, result.residualPx >= 0, result.residualPx.isFinite else {
            bake(stills: stills, profile: stored, source: sourcePrior, residual: nil)
            return "solver did not converge — prior poses stamped"
        }

        bake(stills: stills, profile: result.profile, source: sourceSolved,
             residual: result.residualPx)
        // Rolling geometry: persist the refined rig constants (yaw stored too, but it is
        // session-local by hardware behavior — the next scan re-solves it).
        result.profile.with(cameraModel: stored.cameraModel,
                            cameraSerialNumber: stored.cameraSerialNumber).save()

        if PerfDiag.enabled {
            writeDiagnostics(inputs: inputs, solved: result.profile)
        }
        return String(format: "solved (%.2f px, %d inputs; parse %ds + prep %ds + solve %ds, %d iters; total %ds)",
                      result.residualPx, inputs.count, parseMs / 1000, prepMs / 1000,
                      solveMs / 1000, result.iterations, ms(t0) / 1000)
    }

    // MARK: - Stills

    /// Every sidecar with a decodable phone pose AND its JPG on disk.
    private nonisolated static func loadStills(rawDataDir: URL) -> [StillRecord] {
        let dir = rawDataDir.appendingPathComponent("equirect_stills")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [StillRecord] = []
        for file in files where file.hasPrefix("still_") && file.hasSuffix(".json") {
            let sidecarURL = dir.appendingPathComponent(file)
            let jpgURL = dir.appendingPathComponent(String(file.dropLast(5)) + ".JPG")
            guard FileManager.default.fileExists(atPath: jpgURL.path),
                  let data = try? Data(contentsOf: sidecarURL),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let seq = obj["sequence"] as? Int,
                  let flat = obj["phone_transform"] as? [Double], flat.count == 16 else { continue }
            let cols = (0..<4).map { c in
                SIMD4<Float>(Float(flat[c * 4]), Float(flat[c * 4 + 1]),
                             Float(flat[c * 4 + 2]), Float(flat[c * 4 + 3]))
            }
            let m = simd_float4x4(columns: (cols[0], cols[1], cols[2], cols[3]))
            out.append(StillRecord(
                sequence: seq, sidecarURL: sidecarURL, jpgURL: jpgURL, phoneToWorld: m,
                phonePos: SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)))
        }
        return out.sorted { $0.sequence < $1.sequence }
    }

    /// Greedy farthest-point selection: keep up to `cap` stills maximizing baseline spread.
    private nonisolated static func selectBySpread(_ stills: [StillRecord], cap: Int) -> [StillRecord] {
        guard stills.count > cap else { return stills }
        var picked = [stills[0]]
        var remaining = Array(stills.dropFirst())
        while picked.count < cap, !remaining.isEmpty {
            let next = remaining.max { a, b in
                let da = picked.map { simd_distance($0.phonePos, a.phonePos) }.min() ?? 0
                let db = picked.map { simd_distance($0.phonePos, b.phonePos) }.min() ?? 0
                return da < db
            }!
            picked.append(next)
            remaining.removeAll { $0.sequence == next.sequence }
        }
        return picked.sorted { $0.sequence < $1.sequence }
    }

    // MARK: - Baking

    /// Write cam_transform + provenance (+ residual when solved) into every sidecar.
    private nonisolated static func bake(stills: [StillRecord], profile: RigProfile,
                                         source: String, residual: Float?) {
        for still in stills {
            guard let data = try? Data(contentsOf: still.sidecarURL),
                  var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            let cam = RigCalibrationSolver.composeRigTransform(
                phoneToWorld: still.phoneToWorld,
                dy: profile.dy, dLateral: profile.dLateral,
                yaw: profile.yaw, pitchResidual: profile.pitchResidual)
            let cols = [cam.columns.0, cam.columns.1, cam.columns.2, cam.columns.3]
            obj["cam_transform"] = cols.flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
            obj["rig_calibration_source"] = source
            obj["rig_calibration_solver_version"] = solverVersion
            if let residual { obj["rig_calibration_residual_px_rms"] = Double(residual) }
            if let out = try? JSONSerialization.data(withJSONObject: obj,
                                                     options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: still.sidecarURL, options: .atomic)
            }
        }
    }

    // MARK: - Helpers

    /// The persisted profile, accepted ONLY if its geometry lies inside the mechanical
    /// bounds — profiles saved by unbounded-era solves (or any future corruption) must
    /// not seed the refinement anchor or the yaw-only geometry (360post1: a stored
    /// dLat of 0.574 m dragged every baked pose ~0.6 m off in x/z, and ±0.15 m
    /// refinement bounds could never walk back to the true ~0.1 m).
    private nonisolated static func persistedOrPrior() -> RigProfile {
        guard let stored = RigProfile.load(), stored.isSolved else { return .mechanicalPrior }
        let mech = RigProfile.mechanicalPrior
        let pitchMax = AppConstants.calibrationBoundPitchDeg * Float.pi / 180
        let sane = abs(stored.dy - mech.dy) <= AppConstants.calibrationBoundDyM
            && abs(stored.dLateral) <= AppConstants.calibrationBoundLateralM
            && abs(stored.pitchResidual) <= pitchMax
        if !sane {
            PerfDiag.log(String(format: "[RigCal] persisted profile REJECTED (outside mechanical bounds: dy=%.3f dLat=%.3f pitch=%.1f°) — using mechanical prior",
                                stored.dy, stored.dLateral, stored.pitchResidual * 180 / .pi))
            return .mechanicalPrior
        }
        return stored
    }

    private nonisolated static func meshURL(scanDir: URL, rawDataDir: URL) -> URL {
        let top = scanDir.appendingPathComponent("mesh.obj")
        return FileManager.default.fileExists(atPath: top.path)
            ? top : rawDataDir.appendingPathComponent("mesh.obj")
    }

    private nonisolated static func writeDiagnostics(
        inputs: [RigCalibrationSolver.CalibrationInput], solved: RigProfile
    ) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rigcal_diag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let renderStart = Date()
        for (idx, input) in inputs.enumerated() {
            // Subsample edges for the overlay like the solve does — splatting the full
            // uncapped set (~50k edges/still) cost ~30 s of the 360post3 total.
            let maxEdges = AppConstants.calibrationMaxEdgesPerInput
            let edges: [RigCalibrationSolver.MeshEdge]
            if input.meshEdges.count <= maxEdges {
                edges = input.meshEdges
            } else {
                let step = max(1, input.meshEdges.count / maxEdges)
                edges = Swift.stride(from: 0, to: input.meshEdges.count, by: step)
                    .prefix(maxEdges).map { input.meshEdges[$0] }
            }
            let slim = RigCalibrationSolver.CalibrationInput(
                phoneToWorld: input.phoneToWorld, edgeMap: input.edgeMap, meshEdges: edges)
            guard let png = RigCalibrationSolver.renderDiagnostic(
                input: slim, solved: solved, prior: .mechanicalPrior) else { continue }
            try? png.write(to: dir.appendingPathComponent("post_\(stamp)_still\(idx + 1).png"))
        }
        PerfDiag.log("[RigCal] postprocess diagnostics (\(Int(Date().timeIntervalSince(renderStart) * 1000)) ms) → Documents/rigcal_diag/post_*.png")
    }
}
