import Foundation
import simd
#if canImport(RoomPlan)
import RoomPlan
#endif
#if canImport(ARKit)
import ARKit
#endif

/// Plane-to-plane rigid registration — the PRIMARY rescan-registration engine
/// (see "★ PRIMARY registration approach" in `docs/fix-localization-plan.md`).
///
/// Registers a source room's planar surfaces (a rescan's `RoomBuilder` output, built at save)
/// against a target room's (the ghost's persisted `roomplan.json`) and recovers the rigid,
/// **gravity-locked** transform mapping source → target — the scan's transform-into-canonical
/// (DECISION 1: applied at export, not baked live).
///
/// Sibling of `LocalizationDiag.refine` (dense mesh-ICP, demoted to background reference):
/// same weighted point-to-plane Gauss-Newton and the same observability geometry, but over
/// ~5–20 RoomPlan rectangles instead of NN over 10⁵–10⁶ surfels — the hot loop disappears,
/// and planes average out the lumpy-LiDAR noise the mesh fit was brittle to.
///
/// Core math (per the plan):
/// - **Gravity-locked by construction** — the parameter vector is [yaw, tx, ty, tz]; pitch/roll
///   are never solved (ARKit is gravity-aligned; the ICP path recovered them only as noise and
///   projected them away after the fact).
/// - **Observability gate on the eigenvalue, never a wall count** — horizontal translation + yaw
///   are observable iff ≥2 walls have linearly-independent normals; 3 near-parallel walls read
///   "enough" by count but aren't. Gate on λ_min/λ_max of the area-weighted 2×2 horizontal
///   normal block (the `horizMinObservability` idea, carried over exactly).
/// - **Inter-axis whitening, capped** — up-weight normals along the weak eigen-direction so
///   abundant long side-walls don't out-vote sparse cross-walls (the cubicle-row conditioning
///   fix). Capped: leaning too hard on a few divider planes trades long-axis slop for variance.
///   Whitening expands the recoverable regime; the eigen gate still backstops true degeneracy.
///
/// Pure math, no logging, no `PerfDiag` gate — intended for the production save path. The core
/// deliberately depends only on Foundation + simd so it compiles standalone (off-device synthetic
/// validation); RoomPlan conveniences are `#if canImport(RoomPlan)`.
enum PlaneRegistration {

    // MARK: - Input planes

    enum Category {
        case wall   // vertical plane / horizontal normal — constrains yaw + tx/tz
        case floor  // horizontal plane / vertical normal — constrains ty only
    }

    /// A bounded planar patch (a RoomPlan surface): rectangle spanning `xAxis`×`width` by
    /// `yAxis`×`height`, centered at `center`, with `normal` completing the frame. Normal SIGN
    /// is not trusted (RoomPlan orientation varies) — matching and the solve are undirected.
    struct Plane {
        let center: SIMD3<Float>
        let normal: SIMD3<Float>
        let xAxis: SIMD3<Float>
        let yAxis: SIMD3<Float>
        let width: Float
        let height: Float
        let category: Category
        var area: Float { max(width * height, 1e-4) }
    }

    /// Build a `Plane` from the persisted `roomplan.json` schema values: `category` string
    /// ("wall"/"floor" accepted; doors/windows/openings are skipped — they're coplanar with their
    /// wall, so including them would only double-count that plane's area) and the column-major
    /// 16-float transform (`RoomPlanExporter.flattenMatrix` convention: col0=xAxis, col1=yAxis,
    /// col2=normal, col3=center).
    static func plane(category: String, width: Float, height: Float, transform t: [Float]) -> Plane? {
        guard t.count == 16 else { return nil }
        let cat: Category
        switch category {
        case "wall": cat = .wall
        case "floor": cat = .floor
        default: return nil
        }
        return Plane(center: SIMD3(t[12], t[13], t[14]),
                     normal: simd_normalize(SIMD3(t[8], t[9], t[10])),
                     xAxis: simd_normalize(SIMD3(t[0], t[1], t[2])),
                     yAxis: simd_normalize(SIMD3(t[4], t[5], t[6])),
                     width: width, height: height, category: cat)
    }

    #if canImport(RoomPlan)
    /// Planes straight from a `CapturedRoom` (the save-time source side: this rescan's final
    /// RoomBuilder output). Surface local frame: rectangle in XY, normal along Z.
    static func planes(from room: CapturedRoom) -> [Plane] {
        var out: [Plane] = []
        for s in room.walls { out.append(plane(from: s, category: .wall)) }
        for s in room.floors { out.append(plane(from: s, category: .floor)) }
        return out
    }

    private static func plane(from s: CapturedRoom.Surface, category: Category) -> Plane {
        let m = s.transform
        return Plane(center: SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z),
                     normal: simd_normalize(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)),
                     xAxis: simd_normalize(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)),
                     yAxis: simd_normalize(SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)),
                     width: s.dimensions.x, height: s.dimensions.y, category: category)
    }

    /// Planes from the ghost's persisted clean schema (the target side: decoded `roomplan.json`).
    static func planes(fromExportSurfaces surfaces: [RoomPlanExportData.ExportSurface]) -> [Plane] {
        surfaces.compactMap {
            plane(category: $0.category, width: $0.dimensions.width,
                  height: $0.dimensions.height, transform: $0.transform)
        }
    }
    #endif

    #if canImport(ARKit)
    /// Planes from live `ARPlaneAnchor`s (the ghost auto-align's live side). Classification-gated:
    /// only `.wall`/`.floor` anchors enter the fit (tables/seats/doors are content, not scaffold;
    /// on non-classifying devices this returns [] and auto-align simply never engages). Small
    /// anchors are dropped — early plane detections are unstable and area-weighting would already
    /// mute them, but excluding them keeps the correspondence matching clean.
    ///
    /// ARPlaneAnchor frame: the plane lies in the anchor's local XZ (normal = local +Y);
    /// `planeExtent` spans local X/Z after `rotationOnYAxis` about local Y.
    static func planes(fromPlaneAnchors anchors: [ARPlaneAnchor], minArea: Float = 1.0) -> [Plane] {
        anchors.compactMap { a in
            let cat: Category
            switch a.classification {
            case .wall: cat = .wall
            case .floor: cat = .floor
            default: return nil
            }
            let ext = a.planeExtent
            guard ext.width * ext.height >= minArea else { return nil }
            let m = a.transform
            let rot = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                    SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                    SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
            let spin = simd_quatf(angle: ext.rotationOnYAxis, axis: SIMD3(0, 1, 0))
            let c = m * SIMD4<Float>(a.center.x, a.center.y, a.center.z, 1)
            return Plane(center: SIMD3(c.x, c.y, c.z),
                         normal: simd_normalize(rot * SIMD3(0, 1, 0)),
                         xAxis: simd_normalize(rot * spin.act(SIMD3(1, 0, 0))),
                         yAxis: simd_normalize(rot * spin.act(SIMD3(0, 0, 1))),
                         width: ext.width, height: ext.height, category: cat)
        }
    }
    #endif

    /// Rigidly transform a plane — rotate its frame vectors, move its center (e.g. between the
    /// raw capture frame and the canonical frame).
    static func applying(_ m: simd_float4x4, to p: Plane) -> Plane {
        let r = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                              SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                              SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let c = m * SIMD4<Float>(p.center.x, p.center.y, p.center.z, 1)
        return Plane(center: SIMD3(c.x, c.y, c.z), normal: simd_normalize(r * p.normal),
                     xAxis: simd_normalize(r * p.xAxis), yAxis: simd_normalize(r * p.yAxis),
                     width: p.width, height: p.height, category: p.category)
    }

    // MARK: - Report

    struct Report {
        let initialRMS: Float     // weighted point-to-plane RMS (m) at the initial transform
        let finalRMS: Float       // weighted RMS after refinement — raw area weights, NOT whitened,
                                  // so the gate metric isn't flattered by the conditioning fix
        let transform: simd_float4x4 // recovered rigid source→target; gravity-locked by construction
        let yawDeg: Float         // recovered yaw magnitude (deg)
        let transM: Float         // recovered translation magnitude (m)
        let matchedWalls: Int     // wall pairs in the final correspondence set
        let matchedFloors: Int    // floor pairs (0 ⇒ ty unobserved and held at ~0)
        let sourceWalls: Int
        let targetWalls: Int
        let horizEigMin: Float    // eigenvalues of the area-weighted 2×2 horizontal normal block
        let horizEigMax: Float    //   over matched walls (units: m² of wall area), RAW weights
        let iterations: Int
        let converged: Bool
        /// Per-correspondence post-fit detail — the refusal diagnostic (one bistable wall shows a
        /// large signed offset while the rest sit at noise). Indices are into the caller's ORIGINAL
        /// source/target arrays (stable under `excludingSource`), so trim logging stays coherent.
        let pairs: [PairStat]
        /// λ_min/λ_max ∈ [0,1] — the observability conditioning. Square room → ~1; bare corridor
        /// (parallel walls only) → ~0. THE gate quantity (a wall count misfires; this can't).
        var weakAxisFrac: Float { horizEigMax > 1e-6 ? horizEigMin / horizEigMax : 0 }
        var floorMatched: Bool { matchedFloors > 0 }
    }

    /// One matched plane pair, measured at the final transform.
    struct PairStat {
        let sourceIndex: Int
        let targetIndex: Int
        let category: Category
        /// Signed perpendicular offset of the transformed source center to the target plane (m) —
        /// the per-wall disagreement a rigid fit couldn't absorb.
        let centerOffsetM: Float
        /// Point-to-plane RMS over the pair's 5 samples (m) — adds corner/yaw misfit the center
        /// offset alone can't see.
        let rmsM: Float
    }

    // MARK: - Trust gate

    /// Accept thresholds for applying a registration at export (the `BakeGate` sibling; same
    /// trust philosophy — convergence + tightness + horizontal conditioning, never inlier
    /// fraction). PROVISIONAL values pending real-scan tuning (BakeGate's were device-tuned).
    enum Gate {
        /// Hard floor — the solve is mechanically unconstrained below 2 matched walls. The real
        /// gate is `minWeakAxisFrac`; this only guards the degenerate arithmetic.
        static let minMatchedWalls = 2
        /// λ_min/λ_max of the horizontal normal block. 0.1 provisional: passes a cubicle row
        /// (small-but-real cross-wall area), refuses a bare/near-bare corridor. Tune from device
        /// data the way `minHorizMinObs` was (0.2→0.5 from the elongated-desk-room session).
        static let minWeakAxisFrac: Float = 0.1
        /// RoomPlan planes are clean (no lumpy-mesh noise floor), so the fit should seat tighter
        /// than the mesh-ICP 0.06 m; 0.05 provisional.
        static let maxFinalRMS: Float = 0.05
        static let maxTransM: Float = 0.5   // beyond ~½ m it's likely a false-lock, not ε
        static let maxYawDeg: Float = 15    // observed ε is sub-2°; large recovered yaw = bad fit
        /// Below this the rescan is already within noise of canonical — skip the correction at
        /// the call site (logs "already aligned", distinct from "untrusted").
        static let minTransM: Float = 0.03
    }

    /// The transform to apply to the exported mesh + world map for a trusted registration, else
    /// nil (persist raw/uncorrected — today's behaviour). Unlike the live-bake convention
    /// (`inverse(live→ghost)` fed to `setWorldOrigin`), save-time applies source→target DIRECTLY
    /// to the exported geometry — no inverse, no origin shift.
    static func exportTransform(from r: Report) -> simd_float4x4? {
        guard r.converged,
              r.matchedWalls >= Gate.minMatchedWalls,
              r.weakAxisFrac >= Gate.minWeakAxisFrac,
              r.finalRMS <= Gate.maxFinalRMS,
              r.transM <= Gate.maxTransM,
              r.yawDeg <= Gate.maxYawDeg else { return nil }
        return r.transform
    }

    // MARK: - Tunables

    /// Correspondence gates. One fixed level (no coarse-to-fine schedule needed: ~10 planes a
    /// side, re-matched every iteration for the cost of a few hundred dot products).
    static let matchAngleDeg: Float = 25      // undirected normal agreement (ε yaw is sub-2°; generous)
    static let matchOffsetM: Float = 0.6      // perpendicular plane-to-plane gap (covers maxTransM + noise)
    static let lateralSlackM: Float = 1.0     // extra allowance on in-plane center separation
    /// Whitening up-weight ceiling (the plan's capped up-weight — the bias/variance knee).
    static let whitenCap: Float = 4.0
    static let maxIterations = 10

    // MARK: - The fit

    /// Register `source` planes onto `target` planes. Returns nil only if a valid correspondence
    /// set (≥2 matched walls) never forms — rooms disjoint or normals irreconcilable. A returned
    /// Report is NOT yet trusted; that's `exportTransform(from:)`.
    ///
    /// Each plane contributes 5 point-to-plane samples (center + 4 corners, weight `area/5`) —
    /// the corners are what constrain yaw within a single wall pair. RoomPlan's wall *extension*
    /// (it lengthens walls / closes spaces) is benign here: the extension is coplanar, so an
    /// overhanging corner still has ~0 residual against the matched plane; and a *fabricated*
    /// wall with no live counterpart simply fails to match and falls out of the fit.
    ///
    /// `excludingSource`: source indices withheld from matching (the trim rescue's leave-one-out).
    /// Report indices stay in the ORIGINAL source array's space.
    static func register(source: [Plane], target: [Plane],
                         initial: simd_float4x4 = matrix_identity_float4x4,
                         excludingSource: Set<Int> = []) -> Report? {
        let sourceWalls = source.enumerated()
            .filter { !excludingSource.contains($0.offset) && $0.element.category == .wall }.count
        let targetWalls = target.filter { $0.category == .wall }.count
        guard sourceWalls >= 2, targetWalls >= 2 else { return nil }

        var transform = initial
        var initialRMS: Float = 0
        var finalRMS: Float = 0
        var iterations = 0
        var converged = false
        var lastMatches: [MatchPair] = []

        for it in 1...maxIterations {
            let matches = match(source: source, target: target, transform: transform,
                                excluding: excludingSource)
            let wallMatches = matches.filter { source[$0.s].category == .wall }.count
            guard wallMatches >= 2 else {
                // Never matched → abort; degraded mid-refit → keep the last good state.
                if lastMatches.isEmpty { return nil }
                break
            }
            lastMatches = matches
            iterations = it

            // Raw area-weighted 2×2 horizontal normal block over matched walls — both the
            // observability measure and the whitening input.
            let block = horizontalBlock(source: source, target: target,
                                        matches: matches, transform: transform)
            let whiten = whitenWeights(block: block)

            // Accumulate the 4-DOF [yaw, tx, ty, tz] point-to-plane normal equations.
            var ata = [Double](repeating: 0, count: 16)
            var atb = [Double](repeating: 0, count: 4)
            var sumWSq = 0.0, sumW = 0.0
            for m in matches {
                let sp = source[m.s], tp = target[m.t]
                let n = tp.normal
                let wRaw = Double(sp.area) / 5.0
                let wSolve = wRaw * Double(sp.category == .wall ? whiten(n) : 1)
                for pt in samples(of: sp) {
                    let p = apply(transform, pt)
                    let r = Double(simd_dot(p - tp.center, n))
                    // ∂r/∂yaw = (up × p)·n with up×p = (p.z, 0, −p.x) (right-handed about +Y,
                    // matching `increment`'s quatf convention); ∂r/∂t = n.
                    let a = [Double(simd_dot(SIMD3<Float>(p.z, 0, -p.x), n)),
                             Double(n.x), Double(n.y), Double(n.z)]
                    for row in 0..<4 {
                        atb[row] -= wSolve * a[row] * r
                        for col in 0..<4 { ata[row * 4 + col] += wSolve * a[row] * a[col] }
                    }
                    sumWSq += wRaw * r * r
                    sumW += wRaw
                }
            }
            let rms = Float((sumWSq / max(sumW, 1e-12)).squareRoot())
            if it == 1 { initialRMS = rms }
            finalRMS = rms

            // Tiny Tikhonov prior keeps the solve well-posed when a DOF is unobserved (no floor
            // matched ⇒ the ty row is ~0): that DOF then resolves to ~0 correction instead of
            // blowing up the elimination. Negligible (1e-6 relative) on observed DOFs.
            let lambda = 1e-6 * max(ata[0], max(ata[5], max(ata[10], ata[15]))) + 1e-12
            for d in 0..<4 { ata[d * 4 + d] += lambda }
            guard let x = solve4x4(ata, atb) else { break }
            transform = increment(x) * transform

            let step = sqrt(x[0] * x[0] + x[1] * x[1] + x[2] * x[2] + x[3] * x[3])
            if step < 1e-6 { converged = true; break }
        }
        guard !lastMatches.isEmpty else { return nil }

        // Final residual + observability at the converged transform (honest post-step numbers).
        let matches = match(source: source, target: target, transform: transform,
                            excluding: excludingSource)
        let finalSet = matches.filter { source[$0.s].category == .wall }.count >= 2 ? matches : lastMatches
        var sumWSq = 0.0, sumW = 0.0
        var pairs: [PairStat] = []
        for m in finalSet {
            let sp = source[m.s], tp = target[m.t]
            let wRaw = Double(sp.area) / 5.0
            var pairSq: Float = 0
            for pt in samples(of: sp) {
                let r = Double(simd_dot(apply(transform, pt) - tp.center, tp.normal))
                sumWSq += wRaw * r * r
                sumW += wRaw
                pairSq += Float(r * r)
            }
            pairs.append(PairStat(
                sourceIndex: m.s, targetIndex: m.t, category: sp.category,
                centerOffsetM: simd_dot(apply(transform, sp.center) - tp.center, tp.normal),
                rmsM: sqrt(pairSq / 5)))
        }
        finalRMS = Float((sumWSq / max(sumW, 1e-12)).squareRoot())
        let block = horizontalBlock(source: source, target: target,
                                    matches: finalSet, transform: transform)
        let (eigMin, eigMax, _) = eig2x2(block)

        let t = transform.columns.3
        return Report(initialRMS: initialRMS, finalRMS: finalRMS, transform: transform,
                      yawDeg: abs(atan2(transform.columns.2.x, transform.columns.2.z)) * 180 / .pi,
                      transM: simd_length(SIMD3(t.x, t.y, t.z)),
                      matchedWalls: finalSet.filter { source[$0.s].category == .wall }.count,
                      matchedFloors: finalSet.filter { source[$0.s].category == .floor }.count,
                      sourceWalls: sourceWalls, targetWalls: targetWalls,
                      horizEigMin: eigMin, horizEigMax: eigMax,
                      iterations: iterations, converged: converged, pairs: pairs)
    }

    // MARK: - Trim rescue

    /// The ONE-BISTABLE-SURFACE recovery (save/postprocess path only — live auto-align keeps the
    /// plain fit, since trimming a half-grown live plane set could rescue the wrong hypothesis).
    ///
    /// Failure signature it repairs: converged + observable + small trans/yaw, but RMS over gate —
    /// a room whose walls agree EXCEPT one that RoomPlan seats differently between sessions.
    /// Field case (2026-07-20): a floor-to-ceiling window wall, seated at the glass line one
    /// session and at the concrete wall beyond it the next → the room reads ~20 cm longer, and a
    /// rigid fit smears the conflict across all walls (RMS 69 mm, trans dragged to 14 cm).
    ///
    /// Leave-one-out over the matched wall pairs. Both sides of a bistable conflict can produce a
    /// self-consistent trimmed fit (drop the liar OR drop its honest opposite — either refits
    /// tight), so gate-passing alone can't pick a side: choose the SMALLEST-TRANSLATION candidate.
    /// Physics: per-visit seating ε is cm-scale (5.6–7.3 cm measured live) while surface
    /// bistability is dm-scale, so the small-trans hypothesis is the wall consensus compatible
    /// with a plausible seat — whichever wall actually lied. Near-ties (≤1 mm) break on RMS.
    static func trimRescue(source: [Plane], target: [Plane],
                           full: Report) -> (report: Report, droppedSource: Int)? {
        guard full.converged,
              full.matchedWalls > Gate.minMatchedWalls,   // a drop must leave ≥2 matched walls
              full.weakAxisFrac >= Gate.minWeakAxisFrac,
              full.finalRMS > Gate.maxFinalRMS,           // the one failure trimming explains…
              full.transM <= Gate.maxTransM,              // …and none of the ones it doesn't
              full.yawDeg <= Gate.maxYawDeg else { return nil }
        var best: (report: Report, droppedSource: Int)?
        for pair in full.pairs where pair.category == .wall {
            guard let r = register(source: source, target: target,
                                   excludingSource: [pair.sourceIndex]),
                  exportTransform(from: r) != nil else { continue }
            if let b = best {
                if r.transM < b.report.transM - 0.001
                    || (abs(r.transM - b.report.transM) <= 0.001 && r.finalRMS < b.report.finalRMS) {
                    best = (r, pair.sourceIndex)
                }
            } else {
                best = (r, pair.sourceIndex)
            }
        }
        return best
    }

    // MARK: - Correspondence

    private struct MatchPair { let s: Int; let t: Int }

    /// Nearest compatible plane, per source plane: same category, undirected normal agreement
    /// within `matchAngleDeg`, perpendicular gap within `matchOffsetM`, in-plane center
    /// separation within the rectangles' reach + slack (keeps a wall from matching a distant
    /// collinear segment across the room). Many-to-one is allowed — two source segments of one
    /// physical wall legitimately share a target.
    private static func match(source: [Plane], target: [Plane],
                              transform: simd_float4x4,
                              excluding: Set<Int> = []) -> [MatchPair] {
        let cosGate = cos(matchAngleDeg * .pi / 180)
        var out: [MatchPair] = []
        let rot = rotation(transform)
        for (si, sp) in source.enumerated() where !excluding.contains(si) {
            let c = apply(transform, sp.center)
            let n = rot * sp.normal
            let sReach = 0.5 * sqrt(sp.width * sp.width + sp.height * sp.height)
            var best = -1
            var bestScore = Float.greatestFiniteMagnitude
            for (ti, tp) in target.enumerated() where tp.category == sp.category {
                guard abs(simd_dot(n, tp.normal)) >= cosGate else { continue }
                let d = c - tp.center
                let perp = abs(simd_dot(d, tp.normal))
                guard perp <= matchOffsetM else { continue }
                let lateral = simd_length(d - simd_dot(d, tp.normal) * tp.normal)
                let tReach = 0.5 * sqrt(tp.width * tp.width + tp.height * tp.height)
                guard lateral <= sReach + tReach + lateralSlackM else { continue }
                let score = perp + 0.3 * lateral
                if score < bestScore { bestScore = score; best = ti }
            }
            if best >= 0 { out.append(MatchPair(s: si, t: best)) }
        }
        return out
    }

    // MARK: - Observability + whitening

    /// Area-weighted 2×2 scatter of matched walls' horizontal normal components
    /// [[Σw·nx², Σw·nx·nz], [·, Σw·nz²]] — sign-invariant (outer product), so undirected
    /// normals are fine. Target normals: they're the fixed frame the fit seats into.
    private static func horizontalBlock(source: [Plane], target: [Plane],
                                        matches: [MatchPair],
                                        transform: simd_float4x4) -> (a: Double, b: Double, c: Double) {
        var a = 0.0, b = 0.0, c = 0.0
        for m in matches where source[m.s].category == .wall {
            let n = target[m.t].normal
            let w = Double(source[m.s].area)
            a += w * Double(n.x * n.x)
            b += w * Double(n.x * n.z)
            c += w * Double(n.z * n.z)
        }
        return (a, b, c)
    }

    /// Per-normal whitening multiplier: up-weight (capped at `whitenCap`) in proportion to the
    /// normal's alignment with the WEAK eigen-direction, driving the horizontal block toward
    /// isotropic so sparse cross-walls aren't out-voted by high-area side-walls.
    private static func whitenWeights(block: (a: Double, b: Double, c: Double)) -> (SIMD3<Float>) -> Float {
        let (eigMin, eigMax, weakDir) = eig2x2(block)
        guard eigMax > 1e-6, eigMin > 1e-9 else { return { _ in 1 } } // degenerate → gate's job
        let boost = min(whitenCap, sqrt(eigMax / eigMin))
        return { n in
            let h = SIMD2<Float>(n.x, n.z)
            let len = simd_length(h)
            guard len > 1e-4 else { return 1 }
            let align = simd_dot(h / len, weakDir)
            return 1 + (boost - 1) * align * align
        }
    }

    /// Eigen-decomposition of the symmetric 2×2 [[a,b],[b,c]]: (λ_min, λ_max, unit eigenvector
    /// of λ_min — the weakest-constrained horizontal direction).
    private static func eig2x2(_ m: (a: Double, b: Double, c: Double)) -> (Float, Float, SIMD2<Float>) {
        let half = (m.a + m.c) / 2
        let disc = (((m.a - m.c) / 2) * ((m.a - m.c) / 2) + m.b * m.b).squareRoot()
        let eigMin = max(0, half - disc), eigMax = half + disc
        // (a−λ)x + b·y = 0 ⇒ v = (b, λ−a); fall back to axis picks when b≈0.
        var v = SIMD2<Float>(Float(m.b), Float(eigMin - m.a))
        if simd_length(v) < 1e-9 { v = m.a <= m.c ? SIMD2(1, 0) : SIMD2(0, 1) }
        return (Float(eigMin), Float(eigMax), simd_normalize(v))
    }

    // MARK: - Math helpers

    private static func samples(of p: Plane) -> [SIMD3<Float>] {
        let hx = p.xAxis * (p.width / 2)
        let hy = p.yAxis * (p.height / 2)
        return [p.center, p.center + hx + hy, p.center + hx - hy,
                p.center - hx + hy, p.center - hx - hy]
    }

    private static func apply(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = m * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD3(v.x, v.y, v.z)
    }

    private static func rotation(_ m: simd_float4x4) -> simd_float3x3 {
        simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                      SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                      SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
    }

    /// Incremental transform from the solution [yaw, tx, ty, tz] — yaw about world Y only, so
    /// every increment (and hence the composed result) is gravity-locked by construction.
    private static func increment(_ x: [Double]) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: Float(x[0]), axis: SIMD3(0, 1, 0)))
        m.columns.3 = SIMD4(Float(x[1]), Float(x[2]), Float(x[3]), 1)
        return m
    }

    /// Gaussian elimination with partial pivoting over the 4×4 normal equations — same
    /// algorithm as `LocalizationDiag.solve6x6`, sized to the gravity-locked parameterization.
    private static func solve4x4(_ A: [Double], _ b: [Double]) -> [Double]? {
        var m = A
        var v = b
        let n = 4
        for col in 0..<n {
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
}
