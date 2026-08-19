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
/// - Every scan refines the persisted rig geometry (offsetPhone/pitch — proven
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
    /// to ±0.3. v5: measured window tightened to ±0.05 — the pull saturates any window
    /// (post5: solved at the +0.15 wall), so it should be no wider than tape/clamp slop.
    /// v6: the pull's ROOT CAUSE isolated offline — a uniform elevation-registration
    /// offset (image rows vs latitude mapping; +5.6° stand rig, ~+10° sagging handheld
    /// clamp) that pitch cannot represent; now solved per scan as a 1-D nuisance and
    /// stamped as elevation_offset_deg. v7: the equirect longitude mapping was MIRRORED
    /// (chirality-flipped) vs the real image — every prior solve matched flipped
    /// geometry; fixed to the face-export convention (atan2(x, −z)), all scans re-solve.
    /// 8: keyframe-anchored yaw basin selection. The bump is load-bearing — scans
    /// solved by v7 re-solve on their next Process and self-heal their colouring.
    /// 14: the along-rod window tightened ±5 → ±3 cm, and the tape anchor stamped into the
    /// sidecar. A field re-measure (0.724 → 0.686 m) handed the solver ground truth: three
    /// healthy solves across both cameras all sat +8 to +10 cm ABOVE the true rod, climbing
    /// the box regardless of where it was centred. The tape owns that axis now; a rail on it
    /// means "re-measure the rod", which would have caught the stale tape on the first scan.
    /// 13: the keyframe anchor's basin is BINDING, not advisory. The coarse yaw scan was
    /// confined to ±yawAnchorWindowDeg of the anchor, but Nelder-Mead then got
    /// ±calibrationBoundYawDeg around each start on top of it, so the reachable set was ±80°
    /// and the refinement could leave the basin the anchor chose. A glass-walled room on
    /// 2026-08-19 did exactly that — solved 50.1° from a healthy anchor, because the "edges"
    /// in a room of glass are reflections and reflections move with the camera.
    /// 12: the gravity read generalized to the Z1, whose MakerNote encodes the same vector at
    /// a different offset with a 2^20 denominator instead of 1e8. A Z1 scan therefore stopped
    /// falling back to the assumed rod direction. Its own fit is 1.64° mean (vs 1.57° on the
    /// X) and it puts the rig's rod within 1.5° of where the X put it — two models, two
    /// firmwares, two encodings, one physical rig.
    /// 11: the rod's DIRECTION is measured rather than assumed. The 360° camera writes its
    /// own accelerometer reading into every still, and the one constant phone→camera rotation
    /// that explains all of them puts the rod 7.6° off the assumed −x̂ on the field rig — 10 cm
    /// of lateral offset at 0.77 m, which is exactly what the solve had been forcing into its
    /// across-rod axes. The solve box became a CYLINDER around that measured axis, so its two
    /// half-ranges finally mean what they say (tape slop along, clamp geometry across) rather
    /// than being x/y/z ranges that only lined up while the direction was assumed.
    /// 10: the rig offset moved into the PHONE's frame (RigProfile.offsetPhone). The old
    /// world-frame pair (dy along gravity + dLateral across phone-horizontal) spanned a
    /// 2-plane and could not express the forward swing a tilted phone gives the lens —
    /// 6-17 cm on the field archive's 5-13° tilts — so the solve pushed the error into
    /// whatever else would move. Confirmed on the 2026-08-18 19:19 scan, which stamped
    /// "solved, converged, 2.92 px" with dy 2 mm off its wall and elevation pinned at the
    /// exact end of its sweep on all five stills. The operator's tape now constrains
    /// ‖offsetPhone‖ with no conversion, and pitchResidual / elevation_offset_deg have
    /// nothing systematic left to absorb — whether they collapse toward zero is the
    /// falsifiable test of this model.
    /// 9: v8's anchor never actually worked — it read depth with the byte order
    /// inverted, zeroed the translation column of every keyframe pose (parking them all
    /// at the world origin), and scored at the 1.0 m mechanical prior rather than the
    /// operator's measured rig. Alongside that: the rig height is now converted from the
    /// along-rod distance the operator measures to the world-vertical offset the model
    /// uses, the solve's frozen inclusion mask / coarse yaw ranking / elevation sweep all
    /// evaluate at the centre of the solve box instead of the generic prior, and the
    /// operator/rig segmentation mask is subtracted from the edge cost (the −45° band
    /// never reached the operator's upper body on ANY scan in the archive). Every one of
    /// those changes what a v8 solve would have returned, so v8 scans re-solve.
    static let solverVersion = 14

    struct StillRecord {
        let sequence: Int
        let sidecarURL: URL
        let jpgURL: URL
        let phoneToWorld: simd_float4x4
        let phonePos: SIMD3<Float>
        /// Exposure-window sway from the capture-time motion probe (fallback: whole
        /// trigger window for pre-guard sidecars). nil = no probe ran.
        let swayM: Float?
        let swayDeg: Float?

        /// Lens displacement over the exposure window, in metres.
        var swayCombinedM: Float {
            AppConstants.swayCombinedMeters(translationM: swayM ?? 0, degrees: swayDeg ?? 0)
        }

        /// The SOLVE-side gate, which is much looser than the operator warning: dropping
        /// a still costs the solve a viewpoint, and viewpoint spread is what breaks the
        /// room's rotational symmetry.
        var swayed: Bool { swayCombinedM > AppConstants.thetaSwayRejectCombinedMeters }
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

        let solveSet = swayFiltered(stills, report: report)

        // Build solver inputs from the best-spread subset (aliasing shrinks and the
        // solve sharpens with baseline; cost grows linearly with inputs). Mesh edges for
        // ALL positions extract in one face pass; the edge maps decode per still.
        let tPrep = Date()
        let selected = selectForSolve(solveSet, cap: 5, report: report)
        let edgesPerStill = RigCalibrationSolver.extractMeshEdges(
            mesh: mesh, nearAll: selected.map(\.phonePos),
            radius: AppConstants.calibrationMeshRadiusMeters)
        var inputs: [RigCalibrationSolver.CalibrationInput] = []
        for (idx, still) in selected.enumerated() {
            report("Calibrating 360° rig (\(idx + 1)/\(selected.count))…")
            let edges = edgesPerStill[idx]
            // The operator/rig mask for this still, written moments earlier in the same
            // Process run. Absent (older scan, or generation failed) just falls back to
            // the elevation band.
            let maskURL = rawDataDir.appendingPathComponent("equirect_masks")
                .appendingPathComponent(still.jpgURL.deletingPathExtension()
                    .appendingPathExtension("png").lastPathComponent)
            guard edges.count >= AppConstants.calibrationMinMeshEdges,
                  let jpegData = try? Data(contentsOf: still.jpgURL),
                  let edgeMap = RigCalibrationSolver.detectEquirectEdges(
                      in: jpegData, operatorMask: OperatorRigMask.load(pngAt: maskURL))
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
        // 0.787 m tape measure). The measurement is a BOOTSTRAP anchor, not an override —
        // the solve still refines dy inside the slop window (its repeatability there is
        // the health check). Unmeasured rigs fall back to the mechanical envelope.
        // dLat/pitch/yaw always solve free — they have no such attractor and match
        // physical truth when dy isn't straining (post2/3).
        // The operator measures ALONG THE ROD, and with the offset now living in the phone's
        // own frame that is exactly what the model wants — no cosine, no per-scan tilt
        // correction, no reinterpretation. It pins ‖offsetPhone‖ directly.
        let measuredRod = Float(UserDefaults.standard.double(forKey: AppConstants.Key.rigMeasuredDyMeters))
        // The camera's own accelerometer measures which way the rod points, which was the
        // last purely assumed input in the whole geometry. On staging_B42F9231 it came out
        // 7.6° off the assumed −x̂ — 10 cm of lateral offset on a 0.77 m rod, which is exactly
        // the magnitude the solve had been forcing into its across-rod axes (and railing at
        // 0.125 m the run before). It agreed with the edge cost's own independent answer to
        // 4.4°, so this is corroboration rather than a substitution.
        let rod = measuredRodDirection(stills: stills)
        let bounds: RigCalibrationSolver.SolveBounds = measuredRod > 0.1
            ? .measured(rodLengthM: measuredRod, direction: rod)
            : .mechanical
        if measuredRod > 0.1 {
            PerfDiag.log(String(format: "[RigCal] rig offset anchored at %.3f m along %@ (±%.0fcm along, ±%.0fcm across)",
                                measuredRod,
                                rod == nil ? "the assumed −x̂ (no camera gravity)"
                                           : String(format: "the MEASURED rod (%.1f° off −x̂)",
                                                    acos(min(1, max(-1, -(rod!.x)))) * 180 / .pi),
                                bounds.alongHalf * 100, bounds.acrossHalf * 100))
        }
        // v8: let the phone's keyframes choose the yaw basin before the edge cost
        // refines inside it. Uses the first selected still — any of them anchors the
        // same rig, and one is enough to break the room's rotational symmetry.
        // The offset it scores at must be the BEST one available, not the stored profile's:
        // persistedOrPrior() substitutes the mechanical prior whenever no sane profile
        // exists, so a first solve on a 0.70 m rig placed the trial camera well off the real
        // lens position, and the yaw score — which is nothing but "does the still's content
        // land where the keyframes say" — ranked the wrong basin.
        // The camera's own accelerometer, per still — an INDEPENDENT measurement of two of
        // the three rotational DOF, owing nothing to ARKit, the mesh, or the cost function.
        let anchorYaw = anchorYawIfPossible(selected: selected, rawDataDir: rawDataDir,
                                            offsetPhone: bounds.anchorOffset, report: report)
        let result = RigCalibrationSolver.solve(inputs: inputs, prior: stored, bounds: bounds,
                                                yawAnchor: anchorYaw)
        let solveMs = ms(tSolve)
        let p = result.profile
        // Run-to-run accuracy record — internal only, never surfaced to the operator.
        // Carries the CONTEXT the residual needs to be comparable: RMS rises with the
        // number of constraints, so a 5-input solve cannot be read against a 3-input one
        // (across this project's field runs, every 3-4 input solve landed under 2.75 px
        // and every 6-still scan over 4, with spread and heading flat throughout). Spread
        // and input steadiness are logged for the same reason — they are the other two
        // things that differ between runs.
        let spreadM = selected.count > 1
            ? selected.flatMap { first in selected.map { simd_distance(first.phonePos, $0.phonePos) } }.max() ?? 0
            : 0
        let meanSwayMm = selected.isEmpty ? 0
            : selected.map { $0.swayCombinedM * 1000 }.reduce(0, +) / Float(selected.count)
        PerfDiag.log(String(format: "[RigCal] postprocess solve: offset=(%.3f,%.3f,%.3f)m |%.3fm| yaw=%.2f° pitch=%.2f° elev=%.1f° "
                            + "(residual %.2f px, %@, %d inputs, spread %.2fm, mean sway %.0fmm)",
                            p.offsetPhone.x, p.offsetPhone.y, p.offsetPhone.z, p.rodLengthM,
                            p.yaw * 180 / .pi, p.pitchResidual * 180 / .pi,
                            result.elevOffsetDeg,
                            result.residualPx, result.converged ? "converged" : "NOT converged",
                            inputs.count, spreadM, meanSwayMm))

        // A parameter sitting on its bound is not a measurement, it is the optimizer telling
        // you the model cannot reach the data — and it stamps as "solved, converged, 2.9 px"
        // exactly like a real fit, which is how a boundary has been shipping as a pose.
        // Name every railed parameter in the log AND in the sidecar so downstream can tell.
        let rails = railedParameters(profile: p, bounds: bounds, result: result, anchorYaw: anchorYaw)
        if !rails.isEmpty {
            // The upward rod rail ALONE is not a failed fit — it is the tape doing its job of
            // capping the solver's documented upward pull, and the pose error is bounded by
            // the box. Saying "treat as approximate" for that case sent the operator off to
            // re-measure a rod that had not moved. Anything else railed keeps the loud form.
            let onlyCappedPull = rails.count == 1 && rails[0].contains("known upward pull")
            PerfDiag.log(onlyCappedPull
                ? "[RigCal] \(rails[0]) — poses good to ~\(Int(bounds.alongHalf * 100))cm along the rod"
                : "[RigCal] ⚠️ AT THE LIMIT: \(rails.joined(separator: ", ")) — the residual is a "
                    + "boundary, not a fit; treat these poses as approximate")
        }

        guard result.converged, result.residualPx >= 0, result.residualPx.isFinite else {
            bake(stills: stills, profile: stored, source: sourcePrior, residual: nil)
            return "solver did not converge — prior poses stamped"
        }

        bake(stills: stills, profile: result.profile, source: sourceSolved,
             residual: result.residualPx, elevOffsetDeg: result.elevOffsetDeg, railed: rails,
             rodAnchor: (simd_length(bounds.anchorOffset), measuredRod > 0.1))
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
            let swayM = (obj["exposure_motion_m"] as? Double) ?? (obj["trigger_motion_m"] as? Double)
            let swayDeg = (obj["exposure_motion_deg"] as? Double) ?? (obj["trigger_motion_deg"] as? Double)
            out.append(StillRecord(
                sequence: seq, sidecarURL: sidecarURL, jpgURL: jpgURL, phoneToWorld: m,
                phonePos: SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z),
                swayM: swayM.map(Float.init), swayDeg: swayDeg.map(Float.init)))
        }
        return out.sorted { $0.sequence < $1.sequence }
    }

    /// SWAY GUARD: a still whose phone moved during the exposure window carries a
    /// pose that doesn't match its pano — feeding it to the solve poisons yaw/dy for
    /// the whole scan. Prefer clean stills; fall back to the least-swayed only when
    /// there aren't enough clean ones to reach the solve floor.
    private nonisolated static func swayFiltered(_ stills: [StillRecord],
                                                 report: (String) -> Void) -> [StillRecord] {
        let clean = stills.filter { !$0.swayed }
        if clean.count >= AppConstants.calibrationMinStillsForSolve {
            if clean.count < stills.count {
                report("Excluding \(stills.count - clean.count) swayed still(s) from the solve")
            }
            return clean
        }
        // Rank on the same combined lens displacement the gates use — translation
        // alone put stills in the wrong order, since rotation dominates the metric.
        let bySway = stills.sorted { $0.swayCombinedM < $1.swayCombinedM }
        if stills.contains(where: \.swayed) {
            report("Too few clean stills — least-swayed retained for the solve")
        }
        return Array(bySway.prefix(max(AppConstants.calibrationMinStillsForSolve, clean.count)))
            .sorted { $0.sequence < $1.sequence }
    }

    /// Picks the stills the solve runs on. Spread alone used to decide it, which threw
    /// away the one thing extra stills are actually good for: CHOICE. A scan with six
    /// stills does not need all six — it needs the steadiest few with enough baseline
    /// between them, and a still whose phone drifted before the shutter carries a pose
    /// that is simply wrong, so including it for its position is a bad trade.
    ///
    /// Steadiness first, then spread among the survivors: trim the shakiest down to a
    /// shortlist a little larger than the cap, so the geometry still has room to choose,
    /// then take the widest baseline from that shortlist. Below the cap nothing is
    /// dropped — there is no choice to make.
    ///
    /// Note this is ranking, not thresholding. `swayFiltered` already removed anything
    /// over the gate; this picks the best of what is left, which works even while the
    /// gate itself is loose.
    private nonisolated static func selectForSolve(_ stills: [StillRecord], cap: Int,
                                                   report: (String) -> Void) -> [StillRecord] {
        guard stills.count > cap else { return selectBySpread(stills, cap: cap) }
        let shortlistSize = min(stills.count, cap + 2)
        let steadiest = stills
            .sorted { $0.swayCombinedM < $1.swayCombinedM }
            .prefix(shortlistSize)
            .sorted { $0.sequence < $1.sequence }
        let chosen = selectBySpread(Array(steadiest), cap: cap)
        report("Solving from \(chosen.count) of \(stills.count) stills (steadiest, best spread)")
        PerfDiag.log("[RigCal] selected stills "
            + chosen.map { "#\($0.sequence)(\(Int($0.swayCombinedM * 1000))mm)" }.joined(separator: " ")
            + " from " + stills.map { "#\($0.sequence)(\(Int($0.swayCombinedM * 1000))mm)" }.joined(separator: " "))
        return chosen
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
                                         source: String, residual: Float?,
                                         elevOffsetDeg: Float? = nil,
                                         railed: [String] = [],
                                         rodAnchor: (meters: Float, fromTape: Bool)? = nil) {
        for still in stills {
            guard let data = try? Data(contentsOf: still.sidecarURL),
                  var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            let cam = RigCalibrationSolver.composeRigTransform(
                phoneToWorld: still.phoneToWorld,
                offsetPhone: profile.offsetPhone,
                yaw: profile.yaw, pitchResidual: profile.pitchResidual)
            let cols = [cam.columns.0, cam.columns.1, cam.columns.2, cam.columns.3]
            obj["cam_transform"] = cols.flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
            obj["rig_calibration_source"] = source
            obj["rig_calibration_solver_version"] = solverVersion
            if let residual { obj["rig_calibration_residual_px_rms"] = Double(residual) }
            // Image-vertical registration nuisance — consumers sampling the equirect with
            // the standard mapping (e.g. face export) can compensate by this much.
            if let elevOffsetDeg { obj["elevation_offset_deg"] = Double(elevOffsetDeg) }
            // Written on EVERY bake, empty array included: an absent key would be
            // indistinguishable from "written by a build that did not check".
            obj["rig_calibration_railed"] = railed
            // The rod-length ANCHOR this solve was centred on, and where it came from. The
            // 2026-08-19 stale-tape incident (solved with 0.724 on a rod that had been 0.686
            // for a day and a half) was invisible downstream because only the SOLVED length
            // was stamped — with the input recorded, a wrong tape is auditable per scan.
            if let rodAnchor {
                obj["rig_rod_anchor_m"] = Double(rodAnchor.meters)
                obj["rig_rod_anchor_source"] = rodAnchor.fromTape ? "tape" : "mechanical_default"
            }
            // The geometry that produced cam_transform, so a consumer can audit a pose
            // without re-deriving it: the offset in the PHONE's frame (metres) and its
            // length, which is the number the operator taped.
            obj["rig_offset_phone_m"] = [Double(profile.offsetPhone.x),
                                         Double(profile.offsetPhone.y),
                                         Double(profile.offsetPhone.z)]
            obj["rig_rod_length_m"] = Double(profile.rodLengthM)
            obj["rig_yaw_deg"] = Double(profile.yaw * 180 / .pi)
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
        // Centre on what the rig actually is when the operator has measured it. Judging a
        // 0.70 m rig against the 1.0 m mechanical prior spends most of the ±0.3 m window on
        // heights this rig cannot have, and rejects a perfectly good solved profile at 0.66 m
        // only after it has already drifted.
        let measured = Float(UserDefaults.standard.double(forKey: AppConstants.Key.rigMeasuredDyMeters))
        let centre = measured > 0.1 ? measured : mech.rodLengthM
        // Judge the rod LENGTH against the measurement and the across-rod offsets against
        // zero — the two have completely different physical uncertainties, and lumping them
        // into one box let a wild lateral offset pass while a fine rod length failed.
        let across = simd_length(SIMD3<Float>(0, stored.offsetPhone.y, stored.offsetPhone.z))
        let sane = abs(stored.rodLengthM - centre) <= AppConstants.calibrationBoundRodM
            && across <= AppConstants.calibrationBoundAcrossRodM * 1.5
            && abs(stored.pitchResidual) <= pitchMax
        if !sane {
            PerfDiag.log(String(format: "[RigCal] persisted profile REJECTED (rod=%.3fm across=%.3fm pitch=%.1f° vs anchor %.3fm) — using mechanical prior",
                                stored.rodLengthM, across, stored.pitchResidual * 180 / .pi, centre))
            return .mechanicalPrior
        }
        return stored
    }

    /// Which solved parameters came back on (or within a hair of) a bound. "Within a hair"
    /// matters: Nelder-Mead approaches a wall asymptotically, so an exact equality test
    /// misses the case entirely — 2 mm inside a ±50 mm box is a rail, not a fit.
    private nonisolated static func railedParameters(
        profile: RigProfile, bounds: RigCalibrationSolver.SolveBounds,
        result: RigCalibrationSolver.CalibrationResult, anchorYaw: Float?) -> [String] {
        var rails: [String] = []
        // Along and across the rod, matching the cylinder the solve is actually bounded by.
        // The along-rod rail is direction-aware because its two walls mean different things:
        // the UPPER wall is the documented upward pull being capped by the tape (expected on
        // a healthy scan — 2026-08-19: +2.0 cm then +3.0 cm railed, back to back, same rig,
        // fresh tape), while the LOWER wall means the solve wants a shorter rod than the
        // tape says, i.e. the tape entry is long or belongs to a different rig era.
        let excursion = bounds.excursion(profile.offsetPhone)
        let alongSigned = simd_dot(profile.offsetPhone - bounds.anchorOffset, bounds.rodDirection)
        if abs(excursion.along - bounds.alongHalf) < 0.005 {
            rails.append(alongSigned > 0
                ? String(format: "rod length %.3fm at the tape's +%.0fcm wall (known upward pull, capped — re-measure only if the rig changed)",
                         simd_length(profile.offsetPhone), bounds.alongHalf * 100)
                : String(format: "rod length %.3fm at the tape's −%.0fcm wall (solve wants a SHORTER rod than the tape — the tape entry is likely long or from another rig era)",
                         simd_length(profile.offsetPhone), bounds.alongHalf * 100))
        }
        if abs(excursion.across - bounds.acrossHalf) < 0.005 {
            rails.append(String(format: "across-rod offset %.3fm on its ±%.0fcm bound",
                                excursion.across, bounds.acrossHalf * 100))
        }
        let pitchDeg = profile.pitchResidual * 180 / .pi
        if bounds.pitchHalfDeg - abs(pitchDeg) < 0.5 {
            rails.append(String(format: "pitch %.1f° on its ±%.0f° bound", pitchDeg, bounds.pitchHalfDeg))
        }
        // The elevation sweep's own limit, derived the same way the solver derives the value.
        if abs(result.elevOffsetDeg) >= AppConstants.calibrationElevationSweepLimitDeg - 0.05 {
            rails.append(String(format: "elevation %.1f° at the end of its sweep", result.elevOffsetDeg))
        }
        // Not a bound, but the same class of problem: the edge cost walked a long way from
        // the basin the keyframes picked, and the keyframes are the absolute reference.
        if let anchorYaw {
            let delta = abs(atan2(sin(profile.yaw - anchorYaw), cos(profile.yaw - anchorYaw))) * 180 / .pi
            if delta > AppConstants.yawAnchorDisagreementWarnDeg {
                rails.append(String(format: "yaw %.1f° from the keyframe anchor", delta))
            }
        }
        return rails
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
        let stamp = Int64(Date().timeIntervalSince1970 * 1000)   // epoch ms (CONTRIBUTING → Units & time)
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

extension EquirectPostCalibration {
    /// v8 basin selection — see EquirectYawAnchor. Uses the first selected still: any of
    /// them anchors the same rig, and one is enough to break the room's symmetry.
    /// Fit the ONE constant phone→camera rotation that best explains every still's gravity
    /// reading, and report how well it holds. The rig is rigid, so a good fit means the
    /// clamp held and the camera's zenith reference agrees with ARKit's; a per-still
    /// outlier means that still moved, and a bad fit across the board means the rig shifted
    /// mid-scan — none of which anything else in this pipeline can currently detect.
    ///
    /// Field baseline (THETA X 2.92.0, 10 stills, 2026-08-19): mean 1.57°, max 4.88°.
    /// The rod's direction in the phone's frame, from the camera's own accelerometer, or nil
    /// when it cannot be trusted. Returns a unit vector pointing from the phone camera toward
    /// the 360° lens.
    private nonisolated static func measuredRodDirection(stills: [StillRecord]) -> SIMD3<Float>? {
        var cameraG: [SIMD3<Float>] = []
        var phoneG: [SIMD3<Float>] = []
        for still in stills {
            autoreleasepool {
                guard let data = try? Data(contentsOf: still.jpgURL, options: .mappedIfSafe),
                      let found = ThetaGravity.parseDetailed(jpeg: data) else { return }
                let gravity = found.gravity
                if cameraG.isEmpty {
                    // Once per scan: where the vector was found, so a model this has never
                    // seen can be verified from a field bundle rather than a teardown.
                    PerfDiag.log("[RigCal] camera gravity found at MakerNote offset \(found.offset), "
                        + "scale 1/\(found.scale)")
                }
                // Gravity in the PHONE's frame is minus its world-up column, expressed locally.
                let pose = still.phoneToWorld
                let local = SIMD3<Float>(-pose.columns.0.y, -pose.columns.1.y, -pose.columns.2.y)
                guard simd_length(local) > 0.5 else { return }
                cameraG.append(simd_normalize(gravity))
                phoneG.append(simd_normalize(local))
            }
        }
        // Four, not three: three unit vectors determine a rotation exactly, so the residual
        // that gates everything below would be identically zero and prove nothing.
        guard cameraG.count >= 4, let rotation = bestFitRotation(from: phoneG, to: cameraG) else {
            PerfDiag.log(cameraG.isEmpty
                ? "[RigCal] camera gravity: not present in these stills (unrecognized MakerNote — different model or firmware); rod direction assumed"
                : "[RigCal] camera gravity: only \(cameraG.count) still(s) carried it — need 4 to fit; rod direction assumed")
            return nil
        }
        let errors = zip(phoneG, cameraG).map { phone, camera -> Float in
            acos(min(1, max(-1, simd_dot(rotation * phone, camera)))) * 180 / .pi
        }
        let mean = errors.reduce(0, +) / Float(errors.count)

        // The rod runs along whichever camera body axis gravity loads — the Theta sits on top
        // of the pole, so that axis IS the pole. Pick it from the data rather than naming it,
        // since axis conventions differ by model.
        let meanCameraG = simd_normalize(cameraG.reduce(SIMD3<Float>.zero, +))
        var axis = SIMD3<Float>(0, 0, 1)
        if abs(meanCameraG.x) > abs(meanCameraG.y), abs(meanCameraG.x) > abs(meanCameraG.z) {
            axis = SIMD3<Float>(meanCameraG.x > 0 ? 1 : -1, 0, 0)
        } else if abs(meanCameraG.y) > abs(meanCameraG.z) {
            axis = SIMD3<Float>(0, meanCameraG.y > 0 ? 1 : -1, 0)
        } else {
            axis = SIMD3<Float>(0, 0, meanCameraG.z > 0 ? 1 : -1)
        }
        // Gravity points DOWN the rod, so the lens is the other way. rotation maps
        // phone→camera; its transpose brings the body axis back into the phone's frame.
        let direction = simd_normalize(-(rotation.transpose * axis))

        let offAssumed = acos(min(1, max(-1, simd_dot(direction, SIMD3<Float>(-1, 0, 0))))) * 180 / .pi
        PerfDiag.log(String(format:
            "[RigCal] camera gravity vs ARKit over %d stills: mean %.2f° max %.2f° — rod points "
            + "(%+.3f,%+.3f,%+.3f) in the phone frame, %.1f° off the assumed −x̂",
            errors.count, mean, errors.max() ?? 0, direction.x, direction.y, direction.z, offAssumed))

        // Gates. A poor fit means the rig moved mid-scan or the vector was misread; a wild
        // direction means the fit found a different geometry than a rod-mounted rig, and in
        // either case the ASSUMPTION is safer than a bad measurement.
        guard mean <= AppConstants.calibrationGravityFitMaxDeg else {
            PerfDiag.log(String(format: "[RigCal] gravity fit too loose (%.2f° > %.1f°) — rod direction assumed; the rig may have shifted mid-scan",
                                mean, AppConstants.calibrationGravityFitMaxDeg))
            return nil
        }
        guard offAssumed <= AppConstants.calibrationRodDirectionMaxOffDeg else {
            PerfDiag.log(String(format: "[RigCal] measured rod direction %.1f° off −x̂, beyond the %.0f° sanity limit — assumed instead",
                                offAssumed, AppConstants.calibrationRodDirectionMaxOffDeg))
            return nil
        }
        return direction
    }

    /// Horn's quaternion solution for the rotation minimizing ‖R·a − b‖, via power iteration
    /// on the 4×4 profile matrix — a handful of unit vectors, so no linear-algebra dependency.
    private nonisolated static func bestFitRotation(from source: [SIMD3<Float>],
                                                    to target: [SIMD3<Float>]) -> simd_float3x3? {
        guard source.count == target.count, source.count >= 3 else { return nil }
        var covariance = simd_float3x3(0)
        for (a, b) in zip(source, target) {
            covariance += simd_float3x3(columns: (a.x * b, a.y * b, a.z * b))
        }
        let m = covariance
        let trace = m[0][0] + m[1][1] + m[2][2]
        var profile = simd_float4x4(0)
        profile[0] = SIMD4<Float>(trace, m[1][2] - m[2][1], m[2][0] - m[0][2], m[0][1] - m[1][0])
        profile[1] = SIMD4<Float>(m[1][2] - m[2][1], m[0][0] - m[1][1] - m[2][2], m[0][1] + m[1][0], m[2][0] + m[0][2])
        profile[2] = SIMD4<Float>(m[2][0] - m[0][2], m[0][1] + m[1][0], -m[0][0] + m[1][1] - m[2][2], m[1][2] + m[2][1])
        profile[3] = SIMD4<Float>(m[0][1] - m[1][0], m[2][0] + m[0][2], m[1][2] + m[2][1], -m[0][0] - m[1][1] + m[2][2])
        // Shifted power iteration: the shift keeps the dominant eigenvalue positive so the
        // iteration converges on the LARGEST one, which is the optimal quaternion.
        var q = SIMD4<Float>(1, 0, 0, 0)
        let shift = abs(trace) + 3
        for _ in 0..<200 {
            let next = profile * q + shift * q
            let length = simd_length(next)
            guard length > 1e-9 else { return nil }
            q = next / length
        }
        return simd_float3x3(simd_quatf(ix: q.y, iy: q.z, iz: q.w, r: q.x))
    }

    fileprivate static func anchorYawIfPossible(selected: [StillRecord], rawDataDir: URL,
                                                offsetPhone: SIMD3<Float>,
                                                report: (String) -> Void) -> Float? {
        guard let still = selected.first else { return nil }
        return EquirectYawAnchor.solve(rawDataDir: rawDataDir, stillJPG: still.jpgURL,
                                       phoneToWorld: still.phoneToWorld,
                                       offsetPhone: offsetPhone, report: report)
    }
}
