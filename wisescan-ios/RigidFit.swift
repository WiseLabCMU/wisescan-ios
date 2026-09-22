import Foundation
import simd

/// Closed-form rigid (rotation + translation, **no scale**) fitting of 3D point correspondences,
/// with a deterministic RANSAC wrapper and the conditioning scalars a caller needs to decide
/// whether the recovered transform is trustworthy.
///
/// The consumer is the rescan promotion path: ARKit hands back a world map on the
/// `getCurrentWorldMap` completion queue, feature identifiers are matched between the baseline
/// map and the current one, and the resulting ordered pairs `(baseline, current)` are fit here to
/// recover how far the live session has drifted from the baseline frame. The fit maps
/// **baseline → current**.
///
/// Deliberately free of ARKit / RealityKit / UIKit imports so the whole engine is exercisable in
/// the Simulator test target (same rule as `FeaturePointCloudFile`), and — like
/// `PlaneRegistration` — free of logging and of any diagnostics gate: it is production save-path
/// math, not a probe, and a probe that costs CPU inside a live scan has already corrupted one
/// scan in this codebase. Callers log the numbers; this file does not.
///
/// Explicitly `nonisolated` (the project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`):
/// without it every entry point would be main-actor-isolated and unreachable from the world-map
/// callback queue, the same reason `WorldMapCache` is spelled `nonisolated`.
///
/// **Thresholding is not done here.** `RigidFit` reports raw scalars only — angle, translation,
/// inlier fraction, RMS, conditioning — and every accept/reject threshold lives in the
/// `PromotionGate` thresholds enum, so the numbers can be logged and compared across devices
/// without a policy change silently rewriting what "a fit" means.
nonisolated enum RigidFit {

    // MARK: - Public types

    /// A rigid transform `p ↦ rotation * p + translation`, mapping the baseline frame into the
    /// current frame. `rotation` is always a proper rotation (det = +1); the solver cannot emit a
    /// reflection — see `fit`.
    nonisolated struct Transform: Sendable {
        let rotation: simd_float3x3
        let translation: SIMD3<Float>

        /// Rotation magnitude in degrees: the geodesic angle `acos((trace − 1) / 2)`, with the
        /// cosine clamped to [−1, 1] because float round-off routinely pushes the trace of a
        /// near-identity rotation a few ulps past 3 and `acos` would return NaN.
        var angleDegrees: Double {
            let trace = Double(rotation[0][0]) + Double(rotation[1][1]) + Double(rotation[2][2])
            let cosTheta = Swift.min(1.0, Swift.max(-1.0, (trace - 1.0) / 2.0))
            return acos(cosTheta) * 180.0 / .pi
        }

        /// Translation magnitude in metres.
        var translationMetres: Double { Double(simd_length(translation)) }

        /// Maps a baseline-frame point into the current frame.
        func apply(_ point: SIMD3<Float>) -> SIMD3<Float> { rotation * point + translation }

        static let identity = Transform(rotation: matrix_identity_float3x3, translation: .zero)
    }

    /// How well-spread the evidence behind a fit actually was, measured over the **inlier
    /// baseline positions** (the points the transform was ultimately fit to — not the raw pair
    /// set, which can be dominated by outliers the fit never used).
    ///
    /// **Why two scalars and not just the eigenvalue ratio.** `lambdaRatio` is scale-free, so it
    /// cannot tell "the user stood in one corner and waved the phone over half a square metre"
    /// apart from "a genuinely long, thin corridor scanned end to end": both give a small
    /// λ_min/λ_max, but the first is a fit that must be rejected and the second is a fit that is
    /// fine along its long axis and merely weak across it. Carrying the absolute
    /// `horizontalExtentM` alongside separates them — a ratio of 0.02 over 12 m of extent is a
    /// corridor, the same ratio over 0.4 m is a hover. This is exactly the lesson already
    /// recorded for `horizObservability` vs `horizMinObservability` in `LocalizationDiag`: a
    /// lumped or normalized scalar hides the degenerate direction, so the raw companion number
    /// has to ride along with it.
    ///
    /// Vertical extent is reported separately rather than folded into one bounding-box number
    /// because handheld scans are almost always thin in Y (one person's reach), and letting that
    /// expected thinness drag down a horizontal conditioning score would reject every good scan.
    nonisolated struct Conditioning: Sendable {
        /// λ_min / λ_max of the 3×3 covariance of the inlier baseline positions. 1 = isotropic
        /// spread, → 0 = the points are effectively planar or collinear. Zero when there are too
        /// few inliers to form a covariance.
        let lambdaRatio: Double
        /// Larger of the X and Z bounding-box spans of the inlier baseline positions, in metres.
        let horizontalExtentM: Double
        /// Y bounding-box span of the inlier baseline positions, in metres.
        let verticalExtentM: Double

        static let zero = Conditioning(lambdaRatio: 0, horizontalExtentM: 0, verticalExtentM: 0)
    }

    /// The outcome of a RANSAC fit. Everything here is a raw measurement; nothing is a verdict.
    nonisolated struct Result: Sendable {
        /// Refit over the full inlier set, mapping baseline → current.
        let transform: Transform
        /// Correspondences supplied to `ransac`.
        let pairCount: Int
        /// Correspondences within `inlierDistanceM` of `transform` after the final refit.
        let inlierCount: Int
        /// `inlierCount / pairCount`. The overlap/change signal: a low fraction with a tight RMS
        /// means the two maps agree about a small shared region and disagree everywhere else.
        var inlierFraction: Double {
            pairCount > 0 ? Double(inlierCount) / Double(pairCount) : 0
        }
        /// Post-fit RMS residual over the **inliers only**, in metres. Including outliers would
        /// make this a function of the outlier magnitude rather than of the fit quality.
        let inlierRMSMetres: Double
        /// Spread of the inlier baseline positions. See `Conditioning`.
        let conditioning: Conditioning
    }

    // MARK: - Closed-form fit

    /// Least-squares rigid fit of `pairs`, ordered `(baseline, current)`, mapping baseline →
    /// current. Returns `nil` for fewer than 3 pairs or for input with no spread at all.
    ///
    /// **Horn's quaternion form**, not Kabsch. Both sets are centroid-subtracted, the 3×3
    /// correlation matrix `S = Σ b′ c′ᵀ` is accumulated in `Double`, Horn's symmetric 4×4 matrix
    /// `N` is built from `S`, and the eigenvector of its largest eigenvalue *is* the optimal
    /// unit quaternion — which converts to a proper rotation by construction, because no unit
    /// quaternion maps to a reflection. That matters here: plain Kabsch (SVD, `R = V Uᵀ`)
    /// returns a **reflection** on planar or collinear input, which is precisely the degenerate
    /// geometry a hover-in-one-spot rescan produces and which the tests plant deliberately. If
    /// this is ever rewritten on top of an SVD, the `det(R) < 0` sign flip on the smallest
    /// singular direction is mandatory and must be commented as such.
    ///
    /// Scale is never estimated: ARKit metres are metric on both sides, and a free scale would
    /// happily "explain" drift by shrinking the room.
    static func fit(_ pairs: [(SIMD3<Float>, SIMD3<Float>)]) -> Transform? {
        guard pairs.count >= 3 else { return nil }
        var baseline = [SIMD3<Float>](repeating: .zero, count: pairs.count)
        var current = [SIMD3<Float>](repeating: .zero, count: pairs.count)
        for i in 0..<pairs.count {
            baseline[i] = pairs[i].0
            current[i] = pairs[i].1
        }
        let indices = Array(0..<pairs.count)
        return baseline.withUnsafeBufferPointer { b in
            current.withUnsafeBufferPointer { c in
                indices.withUnsafeBufferPointer { idx in
                    horn(baseline: b, current: c, indices: idx, count: idx.count)
                }
            }
        }
    }

    // MARK: - RANSAC

    /// Deterministic RANSAC over `pairs`, ordered `(baseline, current)`.
    ///
    /// Minimal samples are 3 pairs; a sample whose baseline triangle is degenerate (any side
    /// under `minSampleSeparationM`, or area under `minSampleAreaM2`) is rejected before it is
    /// ever fit, because a fit through three near-coincident points is numerically arbitrary and
    /// would score as well as anything else. Redraws are capped so a fully clustered input
    /// terminates instead of spinning.
    ///
    /// Iteration stops early once the inlier fraction passes `earlyExitFraction`. The winning
    /// minimal model is then refit over its whole inlier set and the pairs are re-classified once
    /// against that refit — the standard "refit then re-score" pass, so the reported inlier count
    /// and RMS describe the transform actually returned and not the 3-point model that found it.
    ///
    /// Returns `nil` when `pairs.count < 3` or when no sample ever produced a usable fit.
    ///
    /// - Parameters:
    ///   - inlierDistanceM: residual distance, in metres, inside which a pair counts as an inlier.
    ///   - iterations: fixed cap on minimal-sample trials.
    ///   - seed: seeds a private SplitMix64. Deterministic on purpose — the planted-outlier test
    ///     and cross-run device comparisons both need the same input to give bit-identical
    ///     output, which `SystemRandomNumberGenerator` cannot provide. Never substitute it.
    ///
    /// Cost is O(`iterations` × n) with no allocation inside the scoring loop: positions are
    /// unpacked into two contiguous buffers once, and scoring only reads them by index.
    static func ransac(pairs: [(SIMD3<Float>, SIMD3<Float>)],
                       inlierDistanceM: Float,
                       iterations: Int,
                       seed: UInt64) -> Result? {
        let n = pairs.count
        guard n >= 3, iterations > 0 else { return nil }

        var baseline = [SIMD3<Float>](repeating: .zero, count: n)
        var current = [SIMD3<Float>](repeating: .zero, count: n)
        for i in 0..<n {
            baseline[i] = pairs[i].0
            current[i] = pairs[i].1
        }

        let threshold = Swift.max(inlierDistanceM, 0)
        let thresholdSquared = threshold * threshold
        var rng = SplitMix64(seed: seed)

        // Allocated once, reused every iteration — nothing below allocates inside the loops.
        var sample = [Int](repeating: 0, count: 3)
        var inlierIndices = [Int](repeating: 0, count: n)
        var inlierCount = 0

        var best: Transform?
        var bestInliers = 0

        return baseline.withUnsafeBufferPointer { b -> Result? in
            current.withUnsafeBufferPointer { c -> Result? in

                // MARK: minimal-sample search
                iterationLoop: for _ in 0..<iterations {
                    var drawn = false
                    for _ in 0..<maxSampleRedraws where !drawn {
                        if drawThreeDistinct(into: &sample, count: n, using: &rng),
                           isWellSeparated(b, sample) {
                            drawn = true
                        }
                    }
                    // A failed redraw streak says this iteration was unlucky, NOT that the input is
                    // degenerate: on a cloud where well-separated triples are merely uncommon —
                    // a dense cluster plus a thin room-spread tail — the streak is a probabilistic
                    // event that recurs with fixed odds. Abandoning the remaining budget here
                    // returns nil on data that fits exactly (~3% of seeds, measured), and since the
                    // seed is a fixed literal, a room that trips it would do so on every save.
                    guard drawn else { continue }

                    let candidate = sample.withUnsafeBufferPointer {
                        horn(baseline: b, current: c, indices: $0, count: 3)
                    }
                    guard let candidate else { continue }

                    var hits = 0
                    for i in 0..<n {
                        let residual = candidate.rotation * b[i] + candidate.translation - c[i]
                        if simd_length_squared(residual) <= thresholdSquared { hits += 1 }
                    }
                    if hits > bestInliers {
                        bestInliers = hits
                        best = candidate
                        if Double(hits) / Double(n) > earlyExitFraction { break iterationLoop }
                    }
                }

                guard let seedModel = best, bestInliers >= 3 else { return nil }

                // MARK: refit over the winning model's inliers
                inlierCount = classify(seedModel, b, c, n, thresholdSquared, &inlierIndices)
                var refined = seedModel
                if inlierCount >= 3 {
                    let refit = inlierIndices.withUnsafeBufferPointer {
                        horn(baseline: b, current: c, indices: $0, count: inlierCount)
                    }
                    // A refit can still come back nil if the inliers are perfectly coincident;
                    // the minimal-sample model is then the best available answer.
                    if let refit { refined = refit }
                }

                // MARK: one re-classification pass against the refit
                inlierCount = classify(refined, b, c, n, thresholdSquared, &inlierIndices)
                guard inlierCount > 0 else { return nil }

                var squaredSum = 0.0
                for k in 0..<inlierCount {
                    let i = inlierIndices[k]
                    let residual = refined.rotation * b[i] + refined.translation - c[i]
                    squaredSum += Double(simd_length_squared(residual))
                }
                let rms = (squaredSum / Double(inlierCount)).squareRoot()

                let spread = inlierIndices.withUnsafeBufferPointer {
                    conditioning(baseline: b, indices: $0, count: inlierCount)
                }

                return Result(transform: refined,
                              pairCount: n,
                              inlierCount: inlierCount,
                              inlierRMSMetres: rms,
                              conditioning: spread)
            }
        }
    }

    // MARK: - RANSAC tuning constants

    /// Minimum pairwise baseline separation inside a minimal sample (metres).
    private static let minSampleSeparationM: Float = 0.05
    /// Minimum baseline triangle area inside a minimal sample (m²).
    private static let minSampleAreaM2: Float = 1e-4
    /// Redraws allowed per iteration before the input is declared too clustered to sample.
    private static let maxSampleRedraws = 16
    /// Inlier fraction above which further iterations cannot plausibly help.
    private static let earlyExitFraction = 0.9

    // MARK: - Scoring helpers

    /// Fills `out` with the indices of pairs within `thresholdSquared` of `transform` and returns
    /// how many there are. `out` is pre-sized to the pair count and reused; nothing allocates.
    private static func classify(_ transform: Transform,
                                 _ b: UnsafeBufferPointer<SIMD3<Float>>,
                                 _ c: UnsafeBufferPointer<SIMD3<Float>>,
                                 _ n: Int,
                                 _ thresholdSquared: Float,
                                 _ out: inout [Int]) -> Int {
        var count = 0
        for i in 0..<n {
            let residual = transform.rotation * b[i] + transform.translation - c[i]
            if simd_length_squared(residual) <= thresholdSquared {
                out[count] = i
                count += 1
            }
        }
        return count
    }

    /// Draws 3 distinct indices into `sample`. Returns false if `count < 3`.
    private static func drawThreeDistinct(into sample: inout [Int],
                                          count: Int,
                                          using rng: inout SplitMix64) -> Bool {
        guard count >= 3 else { return false }
        sample[0] = Int.random(in: 0..<count, using: &rng)
        var i = Int.random(in: 0..<count, using: &rng)
        var guard1 = 0
        while i == sample[0] && guard1 < 8 { i = Int.random(in: 0..<count, using: &rng); guard1 += 1 }
        guard i != sample[0] else { return false }
        sample[1] = i
        var j = Int.random(in: 0..<count, using: &rng)
        var guard2 = 0
        while (j == sample[0] || j == sample[1]) && guard2 < 8 {
            j = Int.random(in: 0..<count, using: &rng)
            guard2 += 1
        }
        guard j != sample[0], j != sample[1] else { return false }
        sample[2] = j
        return true
    }

    /// True when the three baseline points are far enough apart, and non-collinear enough, that a
    /// rigid fit through them is meaningfully determined.
    private static func isWellSeparated(_ b: UnsafeBufferPointer<SIMD3<Float>>,
                                        _ sample: [Int]) -> Bool {
        let p0 = b[sample[0]], p1 = b[sample[1]], p2 = b[sample[2]]
        let minSeparationSquared = minSampleSeparationM * minSampleSeparationM
        guard simd_length_squared(p1 - p0) >= minSeparationSquared,
              simd_length_squared(p2 - p0) >= minSeparationSquared,
              simd_length_squared(p2 - p1) >= minSeparationSquared else { return false }
        let area = 0.5 * simd_length(simd_cross(p1 - p0, p2 - p0))
        return area >= minSampleAreaM2
    }

    // MARK: - Horn's absolute orientation

    /// Horn's closed-form fit over the pairs named by `indices[0..<count]`.
    ///
    /// All correlation sums are accumulated in `Double`: the real input is 8–15k `Float` metre
    /// positions, and a naive `Float` accumulation of Σ x·y over that many terms loses precision
    /// exactly where the answer matters (the off-diagonal terms are differences of large,
    /// nearly-equal sums once the points sit metres from the origin).
    private static func horn(baseline b: UnsafeBufferPointer<SIMD3<Float>>,
                             current c: UnsafeBufferPointer<SIMD3<Float>>,
                             indices: UnsafeBufferPointer<Int>,
                             count: Int) -> Transform? {
        guard count >= 3 else { return nil }
        let inverseCount = 1.0 / Double(count)

        var bx = 0.0, by = 0.0, bz = 0.0
        var cx = 0.0, cy = 0.0, cz = 0.0
        for k in 0..<count {
            let i = indices[k]
            bx += Double(b[i].x); by += Double(b[i].y); bz += Double(b[i].z)
            cx += Double(c[i].x); cy += Double(c[i].y); cz += Double(c[i].z)
        }
        bx *= inverseCount; by *= inverseCount; bz *= inverseCount
        cx *= inverseCount; cy *= inverseCount; cz *= inverseCount

        // S[p][q] = Σ b′_p · c′_q  (Horn's S_pq, baseline on the left because the rotation takes
        // baseline → current).
        var sxx = 0.0, sxy = 0.0, sxz = 0.0
        var syx = 0.0, syy = 0.0, syz = 0.0
        var szx = 0.0, szy = 0.0, szz = 0.0
        var baselineSpread = 0.0
        for k in 0..<count {
            let i = indices[k]
            let px = Double(b[i].x) - bx, py = Double(b[i].y) - by, pz = Double(b[i].z) - bz
            let qx = Double(c[i].x) - cx, qy = Double(c[i].y) - cy, qz = Double(c[i].z) - cz
            sxx += px * qx; sxy += px * qy; sxz += px * qz
            syx += py * qx; syy += py * qy; syz += py * qz
            szx += pz * qx; szy += pz * qy; szz += pz * qz
            baselineSpread += px * px + py * py + pz * pz
        }
        // All baseline points coincident: rotation is entirely unconstrained, so there is no fit
        // to report (a translation-only answer would be a lie about what was measured).
        guard baselineSpread > 1e-20 else { return nil }

        // Horn's symmetric N, ordered (w, x, y, z).
        var n = [Double](repeating: 0, count: 16)
        n[0]  = sxx + syy + szz; n[1]  = syz - szy;        n[2]  = szx - sxz;        n[3]  = sxy - syx
        n[4]  = syz - szy;       n[5]  = sxx - syy - szz;  n[6]  = sxy + syx;        n[7]  = szx + sxz
        n[8]  = szx - sxz;       n[9]  = sxy + syx;        n[10] = -sxx + syy - szz; n[11] = syz + szy
        n[12] = sxy - syx;       n[13] = szx + sxz;        n[14] = syz + szy;        n[15] = -sxx - syy + szz

        let (values, vectors) = symmetricEigen(n, 4)
        var top = 0
        for i in 1..<4 where values[i] > values[top] { top = i }

        // Column `top` of `vectors` is the optimal unit quaternion. Being a unit quaternion is
        // what guarantees a proper rotation — there is no det < 0 case to repair.
        var qw = vectors[0 * 4 + top]
        var qx = vectors[1 * 4 + top]
        var qy = vectors[2 * 4 + top]
        var qz = vectors[3 * 4 + top]
        let norm = (qw * qw + qx * qx + qy * qy + qz * qz).squareRoot()
        guard norm > 1e-12 else { return nil }
        qw /= norm; qx /= norm; qy /= norm; qz /= norm

        let r00 = 1 - 2 * (qy * qy + qz * qz)
        let r01 = 2 * (qx * qy - qw * qz)
        let r02 = 2 * (qx * qz + qw * qy)
        let r10 = 2 * (qx * qy + qw * qz)
        let r11 = 1 - 2 * (qx * qx + qz * qz)
        let r12 = 2 * (qy * qz - qw * qx)
        let r20 = 2 * (qx * qz - qw * qy)
        let r21 = 2 * (qy * qz + qw * qx)
        let r22 = 1 - 2 * (qx * qx + qy * qy)

        // simd matrices are column-major: columns(_:) takes columns, not rows.
        let rotation = simd_float3x3(columns: (SIMD3<Float>(Float(r00), Float(r10), Float(r20)),
                                               SIMD3<Float>(Float(r01), Float(r11), Float(r21)),
                                               SIMD3<Float>(Float(r02), Float(r12), Float(r22))))

        let tx = cx - (r00 * bx + r01 * by + r02 * bz)
        let ty = cy - (r10 * bx + r11 * by + r12 * bz)
        let tz = cz - (r20 * bx + r21 * by + r22 * bz)

        return Transform(rotation: rotation,
                         translation: SIMD3<Float>(Float(tx), Float(ty), Float(tz)))
    }

    // MARK: - Conditioning

    /// Covariance-based spread of the baseline positions named by `indices[0..<count]`.
    private static func conditioning(baseline b: UnsafeBufferPointer<SIMD3<Float>>,
                                     indices: UnsafeBufferPointer<Int>,
                                     count: Int) -> Conditioning {
        guard count >= 2 else { return .zero }

        var minX = Double.greatestFiniteMagnitude, maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        var minZ = Double.greatestFiniteMagnitude, maxZ = -Double.greatestFiniteMagnitude
        var mx = 0.0, my = 0.0, mz = 0.0
        for k in 0..<count {
            let i = indices[k]
            let x = Double(b[i].x), y = Double(b[i].y), z = Double(b[i].z)
            mx += x; my += y; mz += z
            minX = Swift.min(minX, x); maxX = Swift.max(maxX, x)
            minY = Swift.min(minY, y); maxY = Swift.max(maxY, y)
            minZ = Swift.min(minZ, z); maxZ = Swift.max(maxZ, z)
        }
        let inverseCount = 1.0 / Double(count)
        mx *= inverseCount; my *= inverseCount; mz *= inverseCount

        var cxx = 0.0, cxy = 0.0, cxz = 0.0, cyy = 0.0, cyz = 0.0, czz = 0.0
        for k in 0..<count {
            let i = indices[k]
            let x = Double(b[i].x) - mx, y = Double(b[i].y) - my, z = Double(b[i].z) - mz
            cxx += x * x; cxy += x * y; cxz += x * z
            cyy += y * y; cyz += y * z; czz += z * z
        }
        cxx *= inverseCount; cxy *= inverseCount; cxz *= inverseCount
        cyy *= inverseCount; cyz *= inverseCount; czz *= inverseCount

        let covariance = [cxx, cxy, cxz,
                          cxy, cyy, cyz,
                          cxz, cyz, czz]
        let (values, _) = symmetricEigen(covariance, 3)
        var lambdaMin = values[0], lambdaMax = values[0]
        for i in 1..<3 {
            lambdaMin = Swift.min(lambdaMin, values[i])
            lambdaMax = Swift.max(lambdaMax, values[i])
        }
        // Jacobi can return a tiny negative eigenvalue for a numerically rank-deficient
        // covariance; clamp so the ratio stays in [0, 1].
        let ratio = lambdaMax > 1e-18 ? Swift.min(1.0, Swift.max(0.0, lambdaMin / lambdaMax)) : 0.0

        return Conditioning(lambdaRatio: ratio,
                            horizontalExtentM: Swift.max(maxX - minX, maxZ - minZ),
                            verticalExtentM: maxY - minY)
    }

    // MARK: - Symmetric eigensolver

    /// Cyclic Jacobi eigendecomposition of a symmetric `n × n` matrix stored row-major in a flat
    /// `[Double]` of length `n·n`. Returns the eigenvalues and a flat `n × n` matrix whose
    /// **columns** are the corresponding unit eigenvectors (`vectors[row * n + column]`).
    /// Eigenvalues are not sorted; callers scan for the extreme they want.
    ///
    /// One solver serves both callers — the 4×4 Horn eigenproblem and the 3×3 conditioning
    /// covariance — because Swift's `simd` has no 3×3 SVD or eigensolver and this repo has none
    /// either: only 2×2 closed forms (`PlaneRegistration`, `LocalizationDiag`) and a power
    /// iteration (`EquirectPostCalibration`) that recovers just the dominant eigenvector and so
    /// cannot answer the λ_min question. Kept private and file-local rather than promoted to a
    /// shared utility until a second file actually needs it.
    ///
    /// Jacobi rather than anything fancier: n ≤ 4, it is unconditionally stable on symmetric
    /// input, and it converges quadratically — the sweep cap is a backstop, not the exit path.
    private static func symmetricEigen(_ matrix: [Double], _ n: Int) -> (values: [Double], vectors: [Double]) {
        var a = matrix
        var v = [Double](repeating: 0, count: n * n)
        for i in 0..<n { v[i * n + i] = 1 }

        // Scale the convergence test by the matrix magnitude so it is relative, not absolute:
        // Horn's N carries entries on the order of Σ|p||q| over thousands of points, while a
        // covariance carries entries on the order of m².
        var scale = 0.0
        for i in 0..<(n * n) { scale += a[i] * a[i] }
        let tolerance = Swift.max(scale * 1e-26, Double.leastNormalMagnitude)

        for _ in 0..<maxJacobiSweeps {
            var offDiagonal = 0.0
            for p in 0..<(n - 1) {
                for q in (p + 1)..<n { offDiagonal += a[p * n + q] * a[p * n + q] }
            }
            if offDiagonal <= tolerance { break }

            for p in 0..<(n - 1) {
                for q in (p + 1)..<n {
                    let apq = a[p * n + q]
                    if abs(apq) < 1e-300 { continue }
                    // Standard Jacobi angle: theta = (a_qq − a_pp) / 2a_pq, and the smaller root
                    // t of t² + 2·theta·t − 1 = 0 is taken for numerical stability.
                    let theta = (a[q * n + q] - a[p * n + p]) / (2 * apq)
                    let sign: Double = theta >= 0 ? 1 : -1
                    let t = sign / (abs(theta) + (theta * theta + 1).squareRoot())
                    let cos = 1 / (t * t + 1).squareRoot()
                    let sin = t * cos

                    // A ← Jᵀ A J, applied as columns first then rows (order matters).
                    for k in 0..<n {
                        let akp = a[k * n + p], akq = a[k * n + q]
                        a[k * n + p] = cos * akp - sin * akq
                        a[k * n + q] = sin * akp + cos * akq
                    }
                    for k in 0..<n {
                        let apk = a[p * n + k], aqk = a[q * n + k]
                        a[p * n + k] = cos * apk - sin * aqk
                        a[q * n + k] = sin * apk + cos * aqk
                    }
                    // V ← V J, accumulating the eigenvectors as columns.
                    for k in 0..<n {
                        let vkp = v[k * n + p], vkq = v[k * n + q]
                        v[k * n + p] = cos * vkp - sin * vkq
                        v[k * n + q] = sin * vkp + cos * vkq
                    }
                }
            }
        }

        var values = [Double](repeating: 0, count: n)
        for i in 0..<n { values[i] = a[i * n + i] }
        return (values, v)
    }

    /// Cyclic sweeps allowed before giving up. Jacobi on a 3×3 or 4×4 converges in 4–6; the cap
    /// only exists so pathological input cannot spin.
    private static let maxJacobiSweeps = 12
}

// MARK: - Deterministic generator

/// SplitMix64. Seeded and reproducible on purpose: RANSAC here must give bit-identical output for
/// bit-identical input, both so the planted-outlier unit test is not flaky and so two device runs
/// over the same recorded pairs can be diffed. `SystemRandomNumberGenerator` is never acceptable
/// in this file.
///
/// `nonisolated` because the project defaults types to `MainActor` and `RandomNumberGenerator`'s
/// `next()` is a nonisolated requirement — an isolated `next()` would not satisfy it.
private nonisolated struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
