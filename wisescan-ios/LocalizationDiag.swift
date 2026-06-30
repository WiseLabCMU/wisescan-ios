import Foundation
import ARKit
import simd

/// Phase-0 localization diagnostics (see `docs/fix-localization-plan.md`).
///
/// Everything here is **log-only** and a no-op unless the `perfDiagnostics`
/// Developer-Mode flag is on (it routes through `PerfDiag.log`, same as the VIO
/// instrumentation). The goal is to *prove* the diagnosis and produce the numbers
/// Phase 1/2 act on — it changes no capture behaviour.
///
/// Three probes, tagged in the log so they're greppable:
/// - `[LocDiag ε]`   — relocalization error: map stats at load + camera pose at settle (0.1)
/// - `[LocDiag ICP]` — point-to-plane ICP residual of live LiDAR mesh vs the ghost/canonical mesh (0.2)
/// - `[LocDiag snap]`— single-frame camera-pose discontinuities (the relocalization/loop-closure
///                     snap that baked `world:.zero` overlays don't follow) (0.3)
enum LocalizationDiag {

    // MARK: - 0.1 Relocalization ε

    /// Log the loaded world map's size signals. Compounding shows up here as the
    /// feature-point count + extent **growing every generation** (the map degrading
    /// into a multi-session blob). Called wherever an `ARWorldMap` is deserialized.
    static func logMapStats(_ map: ARWorldMap, context: String) {
        guard PerfDiag.enabled else { return }
        let pts = map.rawFeaturePoints.points
        let fp = pts.count
        let anchors = map.anchors.count
        let e = map.extent
        let c = map.center
        // `extent` is ARKit's axis-aligned bbox, so a few drifted/outlier feature points (a tracking
        // excursion baked into the map) inflate it far beyond the real room. The distance-from-median
        // percentiles disambiguate: if `max` >> `p99` (e.g. max=56m but p99=8m), it's a small WANDERING
        // CLUSTER (drift), not a genuinely large space — and ARKit relocalizes against those outliers.
        var spread = ""
        if fp > 50 {
            let xs = pts.map { $0.x }.sorted()
            let ys = pts.map { $0.y }.sorted()
            let zs = pts.map { $0.z }.sorted()
            let med = SIMD3<Float>(xs[xs.count / 2], ys[ys.count / 2], zs[zs.count / 2])
            var dists = pts.map { simd_distance($0, med) }
            dists.sort()
            func p(_ q: Float) -> Float { dists[min(dists.count - 1, Int(Float(dists.count - 1) * q))] }
            spread = String(format: " | dist-from-median(m) p50=%.1f p95=%.1f p99=%.1f max=%.1f", p(0.50), p(0.95), p(0.99), p(1.0))
        }
        PerfDiag.log(String(
            format: "[LocDiag ε] map load (%@): features=%d anchors=%d extent=(%.2f,%.2f,%.2f) center=(%.2f,%.2f,%.2f)%@",
            context, fp, anchors, e.x, e.y, e.z, c.x, c.y, c.z, spread))
    }

    /// Log the live-camera pose the moment relocalization settles (tracking reaches
    /// `.normal` against a loaded map). After relocalization the live frame adopts the
    /// map frame, so this pose is measured **relative to the map origin** (`0,0,0`).
    /// Re-stand at a marked physical spot across generations and watch this drift — that
    /// drift, accumulating per generation, is the compounding ε.
    static func logSettle(camera: ARCamera, secondsToSettle: TimeInterval) {
        guard PerfDiag.enabled else { return }
        let t = camera.transform.columns.3
        let (yaw, pitch, roll) = eulerDegrees(camera.transform)
        PerfDiag.log(String(
            format: "[LocDiag ε] relocalized settle: cam pos=(%.3f,%.3f,%.3f)m yaw=%.1f° pitch=%.1f° roll=%.1f° (settle %.1fs)",
            t.x, t.y, t.z, yaw, pitch, roll, secondsToSettle))
    }

    // MARK: - 0.3 Layer-divergence snap

    /// Per-frame camera-pose discontinuity detector. ARKit re-pins the floating world
    /// frame on loop closure / post-relocalization; a baked `AnchorEntity(world:.zero)`
    /// overlay does **not** ride that correction, so the jump logged here is exactly the
    /// gap a frozen layer falls behind by. Keep `prev` on the AR delegate queue.
    struct SnapTracker {
        private var prevPos: SIMD3<Float>?
        private var prevRot: simd_quatf?
        private var prevNormal: Bool?

        /// Feed each frame's camera transform. Logs (and returns) when a single-frame jump
        /// exceeds the thresholds AND occurs in a *correction context*. A raw per-frame camera
        /// delta can't be distinguished from hand motion during steady `.normal` tracking (a brisk
        /// pan easily clears 2 cm / 0.5° at 60 fps — that's what produced hundreds of false "snaps").
        /// A frame correction is only reliably separable from motion when tracking is **degraded**,
        /// or on the **recovery frame** (previous frame degraded, now normal — the relocalization
        /// snap). So we only log/count those; sustained normal→normal jumps are treated as motion
        /// and ignored. (Limitation: a pure loop-closure snap during continuous normal tracking is
        /// indistinguishable from motion via raw delta, so it isn't counted.)
        @discardableResult
        mutating func observe(_ transform: simd_float4x4,
                              tracking: ARCamera.TrackingState,
                              posThreshold: Float = 0.02,
                              rotThresholdDeg: Float = 0.5) -> (dPos: Float, dRotDeg: Float)? {
            guard PerfDiag.enabled else { return nil }
            let pos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            let rot = simd_quatf(transform)
            let nowNormal = (tracking == .normal)
            defer { prevPos = pos; prevRot = rot; prevNormal = nowNormal }
            guard let pp = prevPos, let pr = prevRot, let wasNormal = prevNormal else { return nil }
            // Only a degraded frame or the recovery-into-normal frame is a trustworthy correction
            // context; steady normal→normal is motion.
            let correctionContext = !nowNormal || !wasNormal
            guard correctionContext else { return nil }
            let dPos = simd_distance(pos, pp)
            let dot = min(1, abs(simd_dot(rot.vector, pr.vector)))
            let dRotDeg = (2 * acos(dot)) * 180 / .pi
            if dPos > posThreshold || dRotDeg > rotThresholdDeg {
                let ctx = nowNormal ? "recovery→normal" : "degraded"
                PerfDiag.log(String(
                    format: "[LocDiag snap] frame correction: Δpos=%.1fcm Δrot=%.2f° (%@) — baked world:.zero layers now lag by this much",
                    dPos * 100, dRotDeg, ctx))
                return (dPos, dRotDeg)
            }
            return nil
        }
    }

    // MARK: - Per-run consolidated summary

    /// One copy-paste line per relocalized recording, computed on-device so values never need
    /// hand-transcription. Populated as the run progresses and emitted at stop-recording.
    ///
    /// **Threading:** touched on the **main thread only**. The probes fire on the AR delegate /
    /// ICP background queues and hop to main to populate this, so there's no cross-queue race.
    struct Summary {
        var mapName: String?
        var features: Int?
        var anchors: Int?
        var settlePos: SIMD3<Float>?
        var settleYaw: Float?
        var settleSecs: Double?
        var sawRelocalizing = false   // did the session pass through .limited(.relocalizing) this run?
        var icp: ICPReport?
        var icpPending = false
        var ghostLoaded = false       // was a ghost/canonical mesh available as the ICP target?
        var snapMaxPos: Float = 0
        var snapMaxRotDeg: Float = 0
        var snapCount = 0
        var didRecord = false
        // Phase 2.1: the gravity-locked correction actually baked into the origin at record-start
        // (nil = not baked: untrusted refine, none ready, or perfDiag off). When set, the `icp` field
        // above carries the POST-bake re-measure (residual should collapse toward ~0 if the bake is right).
        var bakedTransM: Float?
        var bakedYawDeg: Float?

        /// A new relocalization target = a new run; resets everything, then stamps the map.
        mutating func recordMap(_ map: ARWorldMap, name: String?) {
            self = Summary()
            mapName = name
            features = map.rawFeaturePoints.points.count
            anchors = map.anchors.count
        }
        mutating func recordSettle(pos: SIMD3<Float>, yaw: Float, secs: Double) {
            settlePos = pos; settleYaw = yaw; settleSecs = secs
        }
        mutating func recordSnap(dPos: Float, dRotDeg: Float) {
            snapCount += 1
            snapMaxPos = max(snapMaxPos, dPos)
            snapMaxRotDeg = max(snapMaxRotDeg, dRotDeg)
        }
    }

    /// Emit the consolidated one-liner. Caller gates on a map having been loaded for this run
    /// (a no-map baseline scan has nothing to relocalize, so no summary).
    static func logSummary(_ s: Summary) {
        guard PerfDiag.enabled else { return }
        let settle: String
        if let p = s.settlePos {
            settle = String(format: "pos=(%.3f,%.3f,%.3f) yaw=%.1f°", p.x, p.y, p.z, s.settleYaw ?? 0)
        } else if s.features == nil {
            settle = "n/a (no map loaded — baseline / no-reloc scan)"
        } else {
            // Map loaded but never reached .normal this run. sawRelocalizing disambiguates a real
            // relocalization failure (tried but never locked) from never even attempting.
            settle = s.sawRelocalizing
                ? "NEVER — saw relocalizing but never reached .normal (relocalization FAILED)"
                : "NEVER — never entered relocalizing (no recovery attempt observed)"
        }
        let secs = s.settleSecs.map { String(format: "%.1fs", $0) } ?? "—"
        let icp: String
        if let r = s.icp {
            let inlierPct = r.sourcePoints > 0 ? Float(r.correspondences) / Float(r.sourcePoints) * 100 : 0
            icp = String(format: "initRMS=%.1fmm finalRMS=%.1fmm corr(trans=%.1fcm rot=%.2f°) inliers=%d/%d (%.0f%%) iters=%d converged=%@ wall=%.0f%% horizObs=%.2f horizMin=%.2f",
                         r.initialRMS * 1000, r.finalRMS * 1000, r.correctionTransM * 100, r.correctionRotDeg,
                         r.correspondences, r.sourcePoints, inlierPct, r.iterations, r.converged ? "yes" : "NO",
                         r.wallInlierFrac * 100, r.horizObservability, r.horizMinObservability)
        } else if s.icpPending {
            icp = "pending (grab the separate [LocDiag ICP] line)"
        } else if !s.ghostLoaded {
            icp = "n/a (no ghost/canonical mesh loaded as ICP target this run)"
        } else {
            icp = "n/a (live mesh below threshold this run)"
        }
        let bake: String
        if let bt = s.bakedTransM {
            bake = String(format: "trans=%.1fcm yaw=%.2f° (ICP below = POST-bake residual)", bt * 100, s.bakedYawDeg ?? 0)
        } else {
            bake = "none (untrusted/none-ready/off → raw relocalized frame)"
        }
        PerfDiag.log(String(
            format: "[LocDiag SUMMARY] map=%@ features=%@ anchors=%@ | settle: %@ (%@) | bake: %@ | ICP: %@ | corrections: count=%d maxΔpos=%.1fcm maxΔrot=%.2f°",
            s.mapName ?? "none",
            s.features.map(String.init) ?? "—",
            s.anchors.map(String.init) ?? "—",
            settle, secs, bake, icp,
            s.snapCount, s.snapMaxPos * 100, s.snapMaxRotDeg))
    }

    // MARK: - 0.2 LiDAR ICP residual

    struct ICPReport {
        let initialRMS: Float       // residual at the relocalized (identity) pose, coarsest gate — the gross-failure detector
        let finalRMS: Float         // residual after ICP refine (finest gate) — the achievable floor
        let correctionTransM: Float // recovered translation magnitude (m), how far reloc was off
        let correctionRotDeg: Float // recovered rotation magnitude (deg)
        let correspondences: Int    // inlier count (matched within the finest gate)
        let sourcePoints: Int       // live points tried; corr/sourcePoints = inlier fraction (the 4D overlap/change signal)
        let iterations: Int         // total iterations across all coarse-to-fine levels
        let converged: Bool         // did the finest level converge (tiny step or RMS plateau) vs. run out of iters?
        let transform: simd_float4x4 // recovered rigid correction mapping source(live) → target(ghost); the Phase-2.1 bake input
        let targetPoints: Int       // localized + downsampled ghost surfels actually used (NOT the full mesh face count)
        let wallInlierFrac: Float   // fraction of inliers on vertical surfaces (|n·up|<0.5). Floor/ceiling-heavy → low.
        let horizObservability: Float // (Σnx²+Σnz²)/Σny² over inliers — LUMPED horizontal constraint. Floor-dominated → ~0.
        let horizMinObservability: Float // smaller eigenvalue of the 2×2 horizontal translation block / Σny² — the
                                      // WEAKEST-constrained horizontal DIRECTION. Catches a corridor (walls parallel to
                                      // the long axis → that axis unconstrained) that the lumped sum masks. Low ⇒ one
                                      // horizontal axis is ambiguous ⇒ the along-that-axis trans must NOT be baked.
    }

    /// Coarse-to-fine correspondence-distance schedule (metres). The first gate is wide enough to
    /// capture a ~decimeter relocalization offset (the 0.4 finding); later gates tighten to a few cm
    /// for a precise fit. The single fixed 0.30 m gate of the original probe hit the iteration cap
    /// *unconverged* at a 25 cm offset — this schedule is what lets it converge there (and become the
    /// Phase-2.1 refine engine).
    static let icpCorrSchedule: [Float] = [1.0, 0.5, 0.25, 0.12]
    /// Per-level iteration budget. Coarse levels converge in 1–3 iters; the cap matters for the fine level.
    static let icpItersPerLevel = 12
    private static let icpMinCorrespondences = 50
    private static let icpMaxSource = 2500
    /// Backstop cap on the (already localized) target surfel cloud — bounds per-query NN cost if a
    /// dense room still exceeds budget after cropping + voxel-downsampling. The PRIMARY bound is
    /// `localizedTarget`, not this: on a 747k-face / >100 m multi-room map a global subsample left the
    /// *current room* nearly empty (gen-9: 66% inliers, `converged=NO`, stuck at finalRMS≈38 mm), so we
    /// crop to the live cloud's neighbourhood first and only fall back to a global cap if that's degenerate.
    private static let icpMaxTarget = 6000
    /// Voxel size for downsampling the localized target to a uniform density. 8 cm is ample for a
    /// few-cm point-to-plane fit and keeps the cloud bounded by room surface area, not face count.
    private static let icpTargetVoxel: Float = 0.08
    /// Fixed NN-grid cell. Decoupled from `maxCorrDist` (the per-level `cellSize=maxCorrDist` attempt
    /// blew the coarse search volume to ~27 m³); instead the grid stays fine and `nearest` widens its
    /// cell ring to cover the gate. Combined with the target cap, per-query cost stays bounded.
    private static let icpGridCell: Float = 0.5

    /// Parse the ghost OBJ + build its surfel cloud **once** (call at ghost-load and cache the result).
    /// The parse + face→centroid/normal build over a large mesh (100k–700k faces) is the expensive part;
    /// doing it per refine — every ~2 s through the whole alignment sweep — is a real sustained-compute
    /// load that heats the device and can thermally throttle VIO into the very tracking breakdown it's
    /// trying to measure (cf. the gen-8 "log-only probe not behaviorally inert" finding). So build once,
    /// reuse the arrays. Returns nil (with a log) on parse failure / too few faces.
    static func buildGhostSurfels(from ghostOBJ: Data) -> (pts: [SIMD3<Float>], nrm: [SIMD3<Float>])? {
        guard let obj = MeshParser.parseOBJ(from: ghostOBJ) else {
            PerfDiag.log("[LocDiag ICP] ghost surfels: OBJ parse failed")
            return nil
        }
        guard let surfels = ghostSurfels(from: obj), surfels.pts.count >= 200 else {
            PerfDiag.log("[LocDiag ICP] ghost surfels: too few faces (<200)")
            return nil
        }
        return surfels
    }

    /// Run the ICP of the live mesh against the **pre-built** ghost (prior/canonical) surfel cloud and
    /// **log** the residual (the 0.2 probe). Thin wrapper over `refine` — the expensive parse/build is
    /// NOT done here (use the cache from `buildGhostSurfels`), only the source subsample + refine. Pure/
    /// array-based so it holds no ARFrame reference; call on a background queue.
    ///
    /// - liveWorldVertices: live LiDAR vertices already transformed to world space.
    /// - targetPts/targetNrm: the cached ghost surfel cloud (baked in the same map frame).
    @discardableResult
    static func runICPResidualLog(liveWorldVertices: [SIMD3<Float>],
                                  targetPts: [SIMD3<Float>], targetNrm: [SIMD3<Float>]) -> ICPReport? {
        guard PerfDiag.enabled else { return nil }
        guard liveWorldVertices.count >= 200 else {
            PerfDiag.log("[LocDiag ICP] skipped: only \(liveWorldVertices.count) live verts (<200)")
            return nil
        }
        guard targetPts.count >= 200 else {
            PerfDiag.log("[LocDiag ICP] skipped: only \(targetPts.count) ghost surfels (<200)")
            return nil
        }

        let source = subsample(liveWorldVertices, to: icpMaxSource)
        guard let report = refine(source: source, targetPts: targetPts, targetNrm: targetNrm) else {
            PerfDiag.log(String(
                format: "[LocDiag ICP] aborted: <%d correspondences even at the coarsest %.1fm gate (clouds barely overlap?)",
                icpMinCorrespondences, icpCorrSchedule.first ?? 0))
            return nil
        }

        let inlierPct = report.sourcePoints > 0 ? Float(report.correspondences) / Float(report.sourcePoints) * 100 : 0
        PerfDiag.log(String(
            format: "[LocDiag ICP] initRMS=%.1fmm finalRMS=%.1fmm correction: trans=%.1fcm rot=%.2f° corr=%d/%d (%.0f%%) iters=%d converged=%@ wall=%.0f%% horizObs=%.2f horizMin=%.2f tgtUsed=%d/%d",
            report.initialRMS * 1000, report.finalRMS * 1000, report.correctionTransM * 100, report.correctionRotDeg,
            report.correspondences, report.sourcePoints, inlierPct, report.iterations,
            report.converged ? "yes" : "NO(iter cap)", report.wallInlierFrac * 100, report.horizObservability,
            report.horizMinObservability, report.targetPoints, targetPts.count))
        return report
    }

    /// Build the ghost target as face centroids + normals (a point cloud with normals, for
    /// point-to-plane). Returns nil only on an empty OBJ.
    static func ghostSurfels(from obj: MeshParser.OBJData) -> (pts: [SIMD3<Float>], nrm: [SIMD3<Float>])? {
        var targetPts: [SIMD3<Float>] = []
        var targetNrm: [SIMD3<Float>] = []
        targetPts.reserveCapacity(obj.faces.count)
        targetNrm.reserveCapacity(obj.faces.count)
        for f in obj.faces {
            let i0 = Int(f.0), i1 = Int(f.1), i2 = Int(f.2)
            guard i0 < obj.vertices.count, i1 < obj.vertices.count, i2 < obj.vertices.count else { continue }
            let v0 = obj.vertices[i0], v1 = obj.vertices[i1], v2 = obj.vertices[i2]
            let n = simd_cross(v1 - v0, v2 - v0)
            let len = simd_length(n)
            guard len > 1e-7 else { continue }
            targetPts.append((v0 + v1 + v2) / 3)
            targetNrm.append(n / len)
        }
        return targetPts.isEmpty ? nil : (targetPts, targetNrm)
    }

    /// Pure coarse-to-fine point-to-plane ICP — no logging, no `PerfDiag` gate. The reusable engine
    /// for both the 0.2 probe (above) and the Phase-2.1 pre-record refine. Returns the recovered rigid
    /// transform mapping `source` (live world verts) onto the ghost surfels, plus the residual report.
    /// nil if it never accumulated `icpMinCorrespondences` even at the coarsest gate (clouds disjoint).
    ///
    /// The NN grid is built ONCE at a fixed cell; `nearest` widens its cell ring to cover each level's
    /// gate (the `bestD=maxDist²` filter keeps the match exact). The target is first cropped to the live
    /// cloud's neighbourhood + voxel-downsampled so the *current room* stays dense on a huge multi-room map.
    static func refine(source: [SIMD3<Float>],
                       targetPts: [SIMD3<Float>],
                       targetNrm: [SIMD3<Float>],
                       schedule: [Float] = icpCorrSchedule,
                       itersPerLevel: Int = icpItersPerLevel) -> ICPReport? {
        // Localize the target to the live cloud's neighbourhood (margin ≥ the coarsest gate's reach)
        // and voxel-downsample to uniform density — keeps the current room dense on a multi-room map.
        let margin = (schedule.max() ?? 1.0) + 1.0
        var (tPts, tNrm) = localizedTarget(source: source, targetPts: targetPts, targetNrm: targetNrm,
                                           margin: margin, voxel: icpTargetVoxel)
        // Degenerate crop (tiny overlap / bad source AABB) → fall back to a bounded global subsample so
        // we still attempt a fit rather than aborting. And backstop the localized cloud's size.
        if tPts.count < 200 {
            (tPts, tNrm) = subsamplePaired(targetPts, targetNrm, to: icpMaxTarget)
        } else if tPts.count > icpMaxTarget {
            (tPts, tNrm) = subsamplePaired(tPts, tNrm, to: icpMaxTarget)
        }
        // Build the NN grid ONCE at a fixed fine cell; `nearest` widens its ring to cover each level's gate.
        let grid = VoxelGrid(points: tPts, cellSize: icpGridCell)

        var transform = matrix_identity_float4x4
        var initialRMS: Float = 0
        var finalRMS: Float = 0
        var lastCorr = 0
        var totalIters = 0
        var converged = false
        var measuredInitial = false
        var lastWallFrac: Float = 0       // inlier normal stats from the final completed iteration (the
        var lastHorizObs: Float = 0       // converged state) — how well the fit constrains X/Z+yaw.
        var lastHorizMinObs: Float = 0    // weakest-constrained horizontal direction (corridor detector).

        levelLoop: for maxCorrDist in schedule {
            var levelConverged = false
            var prevRMS = Float.greatestFiniteMagnitude
            var it = 0
            while it < itersPerLevel {
                it += 1; totalIters += 1
                // Accumulate the 6x6 point-to-plane normal equations.
                var ata = [Double](repeating: 0, count: 36)
                var atb = [Double](repeating: 0, count: 6)
                var sumSq: Double = 0
                var corr = 0
                // Inlier normal stats (ARKit world Y is up): wall = vertical surface (|n.y|<0.5); the
                // translation-block diagonal Σnx²/Σny²/Σnz² is the per-axis translation observability,
                // and Σnx·nz is the horizontal cross term (for the 2×2 eigen / corridor detector).
                var sumNx2: Double = 0, sumNy2: Double = 0, sumNz2: Double = 0, sumNxNz: Double = 0
                var wallCorr = 0
                for sp in source {
                    let s = apply(transform, sp)
                    guard let ti = grid.nearest(to: s, maxDist: maxCorrDist, points: tPts) else { continue }
                    let d = tPts[ti], n = tNrm[ti]
                    let r = simd_dot(s - d, n) // signed point-to-plane distance
                    let c = simd_cross(s, n)
                    let a = [Double(c.x), Double(c.y), Double(c.z), Double(n.x), Double(n.y), Double(n.z)]
                    let b = Double(-r)
                    for row in 0..<6 {
                        atb[row] += a[row] * b
                        for col in 0..<6 { ata[row * 6 + col] += a[row] * a[col] }
                    }
                    sumSq += Double(r * r)
                    sumNx2 += Double(n.x * n.x); sumNy2 += Double(n.y * n.y); sumNz2 += Double(n.z * n.z)
                    sumNxNz += Double(n.x * n.z)
                    if abs(n.y) < 0.5 { wallCorr += 1 }
                    corr += 1
                }
                guard corr >= icpMinCorrespondences else {
                    // Too few matches at this gate. If a coarser level already refined, stop — a finer
                    // gate can only match fewer. If this is the coarsest level (lastCorr==0), the clouds
                    // barely overlap → fall through with lastCorr==0 so the caller treats nil as abort.
                    if lastCorr > 0 { break levelLoop }
                    break
                }
                let rms = Float((sumSq / Double(corr)).squareRoot())
                if !measuredInitial { initialRMS = rms; measuredInitial = true } // residual at identity, coarsest gate
                finalRMS = rms
                lastCorr = corr
                lastWallFrac = Float(wallCorr) / Float(corr)
                let invNy = 1 / max(sumNy2, 1e-6)
                lastHorizObs = Float((sumNx2 + sumNz2) * invNy)
                // Smaller eigenvalue of the symmetric 2×2 horizontal block [[Σnx²,Σnxnz],[Σnxnz,Σnz²]]:
                // (a+c)/2 − sqrt(((a−c)/2)² + b²). It's the constraint along the weakest horizontal
                // DIRECTION (axis-agnostic), so a corridor (one axis ≈0) reads low even when the lumped
                // sum looks healthy from abundant cross-corridor wall.
                let a = sumNx2, c = sumNz2, b = sumNxNz
                let halfSum = (a + c) / 2
                let disc = (((a - c) / 2) * ((a - c) / 2) + b * b).squareRoot()
                lastHorizMinObs = Float(max(0, halfSum - disc) * invNy)

                // RMS-plateau convergence: point-to-plane bottoms out at a surface-noise floor; the
                // step test alone can miss this and burn the whole budget oscillating around it.
                if it >= 2, prevRMS - rms < prevRMS * 1e-3 { levelConverged = true; break }
                prevRMS = rms

                guard let x = solve6x6(ata, atb) else { break }
                transform = increment(x) * transform
                // Converged once the incremental step is tiny.
                let step = sqrt(x[0]*x[0] + x[1]*x[1] + x[2]*x[2] + x[3]*x[3] + x[4]*x[4] + x[5]*x[5])
                if step < 1e-5 { levelConverged = true; break }
            }
            converged = levelConverged // reflects the finest level actually run
        }

        // No valid iteration ran (too few correspondences even at the coarsest gate).
        guard lastCorr > 0 else { return nil }

        let tCol = transform.columns.3
        let transMag = simd_length(SIMD3<Float>(tCol.x, tCol.y, tCol.z))
        let rotQuat = simd_quatf(transform)
        let rotDeg = (2 * acos(min(1, abs(rotQuat.real)))) * 180 / .pi

        return ICPReport(initialRMS: initialRMS, finalRMS: finalRMS,
                         correctionTransM: transMag, correctionRotDeg: rotDeg,
                         correspondences: lastCorr, sourcePoints: source.count,
                         iterations: totalIters, converged: converged, transform: transform,
                         targetPoints: tPts.count, wallInlierFrac: lastWallFrac, horizObservability: lastHorizObs,
                         horizMinObservability: lastHorizMinObs)
    }

    /// Crop the target surfels to the live cloud's AABB + `margin` and voxel-downsample (one surfel
    /// per `voxel` cell) to a uniform density. On a large multi-room map (e.g. 747k faces / >100 m
    /// extent) a global subsample leaves the *current room* almost empty — ICP then can't converge
    /// (gen-9: stuck at finalRMS≈38 mm, 66% inliers). Cropping keeps local density high at bounded cost.
    static func localizedTarget(source: [SIMD3<Float>],
                                targetPts: [SIMD3<Float>], targetNrm: [SIMD3<Float>],
                                margin: Float, voxel: Float) -> (pts: [SIMD3<Float>], nrm: [SIMD3<Float>]) {
        guard !source.isEmpty, !targetPts.isEmpty else { return (targetPts, targetNrm) }
        var lo = source[0], hi = source[0]
        for p in source { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        lo -= SIMD3<Float>(repeating: margin)
        hi += SIMD3<Float>(repeating: margin)
        let inv = 1 / voxel
        var seen = Set<Int64>()
        var op = [SIMD3<Float>](); var on = [SIMD3<Float>]()
        for i in 0..<targetPts.count {
            let p = targetPts[i]
            if p.x < lo.x || p.x > hi.x || p.y < lo.y || p.y > hi.y || p.z < lo.z || p.z > hi.z { continue }
            let kx = Int64((p.x * inv).rounded(.down))
            let ky = Int64((p.y * inv).rounded(.down))
            let kz = Int64((p.z * inv).rounded(.down))
            let key = (kx & 0x1FFFFF) | ((ky & 0x1FFFFF) << 21) | ((kz & 0x1FFFFF) << 42)
            if seen.insert(key).inserted { op.append(p); on.append(targetNrm[i]) }
        }
        return (op, on)
    }

    // MARK: - Phase 2.1 bake

    /// Gate thresholds for trusting a refine enough to bake it into the world origin. A refine that
    /// fails any of these is left un-baked (record in the raw relocalized frame — today's behaviour).
    /// The reject-and-reprompt UX is Phase 2.2, not here.
    ///
    /// Trust is keyed on **absolute correspondence count + a tight finalRMS + horizontal conditioning
    /// + convergence**, NOT inlier *fraction*. A low fraction means low overlap / scene change (the
    /// unmatched live points just have no ghost counterpart — they don't bias the fit), which the 4D
    /// contract says must still register on the surviving scaffold; a *bad lock* instead fails to
    /// converge or sits at a high finalRMS. (Observed: a farther-standpoint scan with 34% inliers but
    /// 842 well-distributed corr, horizObs=2.85, converged, finalRMS=30.6mm — a good 17.7cm fit the
    /// old 60% fraction floor wrongly rejected.) Fraction is the 4D *change metric* (2.2/2.3), not bake trust.
    enum BakeGate {
        static let minCorrespondences = 400   // enough well-distributed matches to constrain a rigid fit
        static let minInlierFrac: Float = 0.15 // sanity floor only — near-total non-overlap = likely bad lock
        static let minHorizObs: Float = 0.5   // LUMPED horizontal constraint; floor-dominated fits read ~0
        static let minHorizMinObs: Float = 0.5 // weakest horizontal DIRECTION; catches an elongated/corridor room
                                               // the lumped sum masks. Tuned 0.2→0.5 from an elongated repeating-desk
                                               // room (2026-06-22): a horizMin=0.31 fit (lumped horizObs=1.98, looked
                                               // fine) baked but WARNed (didn't null); clean OKs all sat ≥0.61, with a
                                               // gap at 0.41–0.61 — so 0.5 cuts the unreliable along-axis fits cleanly.
        static let maxFinalRMS: Float = 0.06  // the fit must actually be tight (m); a forced bad alignment won't be
        static let maxTransM: Float = 0.5     // beyond ~½ m a "correction" is likely a false-lock, not ε
        static let maxRotDeg: Float = 15      // our ε is sub-2°; a large recovered rotation = bad fit
        /// Below this the relocalization is already within the post-bake noise floor — applying a
        /// correction would be within measurement error of doing nothing, so we skip the bake (the
        /// common small/cramped-space case: ε is inherently tiny). Applied at the call site, not in
        /// `bakeTransform` (the trust gate), so "already aligned" logs distinctly from "untrusted".
        static let minTransM: Float = 0.03
    }

    /// Quality score for picking the **best** trusted refine out of a short rolling buffer (Phase 2.1
    /// polish). In feature-desert rooms refine quality swings wildly within seconds (47%→99% inliers,
    /// `horizMin` 0.04→1.38), so baking whichever trusted fit is *latest* at record-tap can grab a
    /// marginal one while a far better fit was moments away. Higher is better; it rewards the three
    /// things that make a fit trustworthy and well-conditioned:
    /// - **inlier fraction** — overlap / how much of the live cloud found a ghost counterpart,
    /// - **`horizMinObservability`** — the weakest-constrained horizontal direction (the axis the bake
    ///   could get wrong); a fit that constrains both horizontal axes scores far above a corridor-like one,
    /// - **tightness (`1/finalRMS`)** — how closely the fit actually seats.
    /// All three already gate the bake (`BakeGate`); this just *ranks* the survivors.
    static func refineQuality(_ r: ICPReport) -> Float {
        let inlierFrac = r.sourcePoints > 0 ? Float(r.correspondences) / Float(r.sourcePoints) : 0
        let tightness = 1 / max(r.finalRMS, 1e-3)
        return inlierFrac * max(r.horizMinObservability, 1e-3) * tightness
    }

    /// The gravity-locked correction to bake into `setWorldOrigin` for a trusted refine, else nil.
    ///
    /// `refine.transform` maps live→ghost, so the world origin must shift by its **inverse** for
    /// recorded geometry to land in the ghost/canonical frame (this matches the proven manual
    /// ghost-nudge convention: the transform that moves the ghost onto reality is `inverse(live→ghost)`).
    /// We then **gravity-lock** it (yaw + full translation, drop pitch/roll) — ARKit is gravity-aligned
    /// so any pitch/roll ICP recovered is noise, and we never want to tilt the world.
    static func bakeTransform(from r: ICPReport) -> simd_float4x4? {
        let inlierFrac = r.sourcePoints > 0 ? Float(r.correspondences) / Float(r.sourcePoints) : 0
        guard r.converged,
              r.correspondences >= BakeGate.minCorrespondences,
              inlierFrac >= BakeGate.minInlierFrac,
              r.horizObservability >= BakeGate.minHorizObs,
              r.horizMinObservability >= BakeGate.minHorizMinObs, // corridor / single-axis-ambiguous → refuse to bake
              r.finalRMS <= BakeGate.maxFinalRMS,
              r.correctionTransM <= BakeGate.maxTransM,
              r.correctionRotDeg <= BakeGate.maxRotDeg else { return nil }
        return gravityLocked(r.transform.inverse)
    }

    /// Project a rigid transform to gravity-locked yaw + full translation (drops pitch/roll).
    static func gravityLocked(_ m: simd_float4x4) -> simd_float4x4 {
        let yaw = atan2(m.columns.2.x, m.columns.2.z) // world Y up; same convention as the settle-yaw log
        let rot = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        var out = simd_float4x4(rot)
        out.columns.3 = m.columns.3 // keep full translation, including the vertical (floor-constrained) offset
        return out
    }

    // MARK: - Math helpers

    private static func apply(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = m * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD3<Float>(v.x, v.y, v.z)
    }

    /// Build an incremental rigid transform from a small-angle solution [ωx,ωy,ωz,tx,ty,tz].
    private static func increment(_ x: [Double]) -> simd_float4x4 {
        let wx = Float(x[0]), wy = Float(x[1]), wz = Float(x[2])
        let t = SIMD3<Float>(Float(x[3]), Float(x[4]), Float(x[5]))
        // Rotation from the small-angle axis-angle vector (exact, not just I+[ω]×).
        let angle = sqrt(wx*wx + wy*wy + wz*wz)
        let rot: simd_quatf = angle < 1e-9
            ? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            : simd_quatf(angle: angle, axis: SIMD3<Float>(wx, wy, wz) / angle)
        var m = simd_float4x4(rot)
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    /// Solve a 6x6 symmetric positive-(semi)definite system via Gaussian elimination
    /// with partial pivoting. Returns nil if singular.
    private static func solve6x6(_ A: [Double], _ b: [Double]) -> [Double]? {
        var m = A            // row-major 6x6
        var v = b
        let n = 6
        for col in 0..<n {
            // Pivot.
            var pivot = col
            var best = abs(m[col * n + col])
            for r in (col + 1)..<n where abs(m[r * n + col]) > best {
                best = abs(m[r * n + col]); pivot = r
            }
            guard best > 1e-12 else { return nil }
            if pivot != col {
                for c in 0..<n { m.swapAt(col * n + c, pivot * n + c) }
                v.swapAt(col, pivot)
            }
            let diag = m[col * n + col]
            for r in (col + 1)..<n {
                let factor = m[r * n + col] / diag
                guard factor != 0 else { continue }
                for c in col..<n { m[r * n + c] -= factor * m[col * n + c] }
                v[r] -= factor * v[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = v[row]
            for c in (row + 1)..<n { sum -= m[row * n + c] * x[c] }
            x[row] = sum / m[row * n + row]
        }
        return x
    }

    /// Stride-subsample two parallel arrays in lockstep (keeps each target point with its normal).
    private static func subsamplePaired(_ pts: [SIMD3<Float>], _ nrm: [SIMD3<Float>],
                                        to cap: Int) -> ([SIMD3<Float>], [SIMD3<Float>]) {
        guard pts.count > cap else { return (pts, nrm) }
        let step = Double(pts.count) / Double(cap)
        var op = [SIMD3<Float>](); op.reserveCapacity(cap)
        var on = [SIMD3<Float>](); on.reserveCapacity(cap)
        var i = 0
        while i < cap {
            let idx = Int(Double(i) * step)
            op.append(pts[idx]); on.append(nrm[idx])
            i += 1
        }
        return (op, on)
    }

    private static func subsample(_ pts: [SIMD3<Float>], to cap: Int) -> [SIMD3<Float>] {
        guard pts.count > cap else { return pts }
        // Fractional step so the cap holds even when count is between 1× and 2× cap
        // (integer `count/cap` rounds to 1 there and copies everything).
        let step = Double(pts.count) / Double(cap)
        var out = [SIMD3<Float>]()
        out.reserveCapacity(cap)
        var i = 0
        while i < cap {
            out.append(pts[Int(Double(i) * step)])
            i += 1
        }
        return out
    }

    /// Yaw/pitch/roll in degrees from a transform's rotation (for human-readable logs).
    private static func eulerDegrees(_ m: simd_float4x4) -> (Float, Float, Float) {
        let r = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                              SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                              SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let pitch = asin(-max(-1, min(1, r[2][1])))
        let yaw = atan2(r[2][0], r[2][2])
        let roll = atan2(r[0][1], r[1][1])
        let k: Float = 180 / .pi
        return (yaw * k, pitch * k, roll * k)
    }

    /// Uniform-grid nearest-neighbour over a fixed target cloud. Cheap to build, O(1)
    /// expected query over the 27-cell neighbourhood — adequate for a per-scan one-shot.
    private struct VoxelGrid {
        private var cells: [Int64: [Int]] = [:]
        private let cell: Float

        init(points: [SIMD3<Float>], cellSize: Float) {
            cell = cellSize
            for (idx, p) in points.enumerated() {
                cells[Self.key(p, cell), default: []].append(idx)
            }
        }

        private static func key(_ p: SIMD3<Float>, _ cell: Float) -> Int64 {
            let x = Int64((p.x / cell).rounded(.down))
            let y = Int64((p.y / cell).rounded(.down))
            let z = Int64((p.z / cell).rounded(.down))
            // Cantor-ish pack; collisions across the 21-bit bands are fine (just extra candidates).
            return (x & 0x1FFFFF) | ((y & 0x1FFFFF) << 21) | ((z & 0x1FFFFF) << 42)
        }

        func nearest(to q: SIMD3<Float>, maxDist: Float, points: [SIMD3<Float>]) -> Int? {
            // Scan enough cells each side to cover `maxDist` (cell is fixed, gate varies per ICP level).
            // The `bestD = maxDist²` filter still enforces the exact gate; the ring only bounds lookups.
            let r = Int64((maxDist / cell).rounded(.up))
            let bx = Int64((q.x / cell).rounded(.down))
            let by = Int64((q.y / cell).rounded(.down))
            let bz = Int64((q.z / cell).rounded(.down))
            var best = -1
            var bestD = maxDist * maxDist
            for dx in -r...r { for dy in -r...r { for dz in -r...r {
                let k = ((bx + dx) & 0x1FFFFF)
                    | (((by + dy) & 0x1FFFFF) << 21)
                    | (((bz + dz) & 0x1FFFFF) << 42)
                guard let bucket = cells[k] else { continue }
                for idx in bucket {
                    let d = simd_distance_squared(q, points[idx])
                    if d < bestD { bestD = d; best = idx }
                }
            }}}
            return best >= 0 ? best : nil
        }
    }
}
