import XCTest
import simd
@testable import wisescan_ios

/// `RigidFit` — the closed-form rigid (rotation + translation, **no scale**) fit between two epochs
/// of the same location, its deterministic RANSAC wrapper, and the conditioning it reports about the
/// correspondence set.
///
/// The correspondences come from the world map: ARKit feature identifiers survive a map's
/// save → load → save cycle, so two scans of one room join on `id` rather than being re-matched
/// geometrically (`FeaturePointDiff.correspondences`). That join is what makes a fit possible at all
/// — and it is also why the fit must be robust and must report its own conditioning, because the
/// joined set is not clean data:
///
/// - **Furniture moves.** A chair that slid 0.8 m between epochs contributes a tight cluster of
///   correspondences that are individually consistent and collectively a lie. They must land outside
///   the inlier set, not drag the transform toward a compromise that fits neither the room nor the
///   chair.
/// - **Scale is not a free parameter.** Two scans of one physical room are the same size. An
///   estimator that lets scale absorb residual (Umeyama with `with_scaling`, or an unconstrained
///   affine solve) will report a beautiful RMS on a cloud that is 10% larger, and quietly resize the
///   canonical frame. The rotation block must stay orthonormal with determinant +1.
/// - **Some sets cannot constrain the answer.** Points strung along a corridor rail, or the handful
///   that survive the join when relocalization was poor and they all sit within arm's reach, admit a
///   fit that is numerically fine and geometrically meaningless. `RigidFit.Conditioning` carries the
///   numbers `PromotionGate` uses to refuse promotion; `RigidFit` itself never renders a verdict.
///
/// **The actual API this file is written against** (`wisescan-ios/RigidFit.swift`), which is *not*
/// the `fit(from:to:)`-over-two-arrays shape an earlier draft of this file assumed:
///
/// ```swift
/// RigidFit.fit(_ pairs: [(SIMD3<Float>, SIMD3<Float>)]) -> RigidFit.Transform?
/// RigidFit.ransac(pairs:inlierDistanceM:iterations:seed:) -> RigidFit.Result?
/// ```
///
/// - Pairs are ordered `(baseline, current)` and the recovered transform maps baseline → current:
///   `rotation * baseline + translation ≈ current`.
/// - `Transform.translation` is the **vector**; `Transform.translationMetres` is its scalar
///   magnitude. `Transform.angleDegrees` is the unsigned rotation magnitude.
/// - `Result` reports `pairCount` / `inlierCount` / `inlierFraction` / `inlierRMSMetres` /
///   `conditioning`. There is **no `outlierIndices`** — where a test needs the identity of the
///   rejected pairs it recomputes them from the returned transform, which is a stronger check
///   anyway (it tests the transform, not a bookkeeping array).
/// - `Conditioning.lambdaRatio` is the plain λ_min/λ_max of the inlier baseline covariance —
///   **scale-free, not scale-aware**. `Conditioning.horizontalExtentM` is the **major** horizontal
///   span (larger of the X and Z bounding-box spans), not the minor principal extent. The two are
///   deliberately complementary and each catches a degeneracy the other cannot; the tests below
///   assert exactly that split rather than asking either scalar to do both jobs.
/// - Only `ransac` computes `Conditioning`; the closed-form `fit` returns a bare `Transform`.
/// - `ransac` is seeded (SplitMix64) and therefore bit-reproducible run to run.
///
/// Everything here is synthesized in-process; no fixture on disk.
final class RigidFitTests: XCTestCase {

    // MARK: - Fit parameters used throughout
    //
    // Read from `PromotionGate.Thresholds` where the shipping caller reads them, so a recalibration
    // moves these fixtures with the gate instead of leaving them testing a regime nothing uses.

    private var inlierDistanceM: Float { PromotionGate.Thresholds.inlierDistanceM }
    private var iterations: Int { PromotionGate.Thresholds.ransacIterations }
    private var seed: UInt64 { PromotionGate.Thresholds.ransacSeed }

    private func ransac(_ pairs: [(SIMD3<Float>, SIMD3<Float>)],
                        inlierDistanceM: Float? = nil) -> RigidFit.Result? {
        RigidFit.ransac(pairs: pairs,
                        inlierDistanceM: inlierDistanceM ?? self.inlierDistanceM,
                        iterations: iterations,
                        seed: seed)
    }

    // MARK: - Deterministic synthesis

    /// SplitMix64. A fixed seed means a failure reproduces from the test name alone — the whole
    /// point of synthesizing rather than committing a fixture.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// `count` points filling a 5 × 3 × 5 m box — a room-sized spread, the regime the fit is for.
    private func roomCloud(count: Int, seed: UInt64) -> [SIMD3<Float>] {
        var rng = SeededGenerator(seed: seed)
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(count)
        for _ in 0..<count {
            let x = Float.random(in: -2.5...2.5, using: &rng)
            let y = Float.random(in: 0...3, using: &rng)
            let z = Float.random(in: -2.5...2.5, using: &rng)
            points.append(SIMD3<Float>(x, y, z))
        }
        return points
    }

    /// Box–Muller. Isotropic per-axis Gaussian of standard deviation `sigma`.
    private func noise(count: Int, sigma: Float, seed: UInt64) -> [SIMD3<Float>] {
        var rng = SeededGenerator(seed: seed)
        func gaussian() -> Float {
            let u1 = Float.random(in: Float.leastNormalMagnitude...1, using: &rng)
            let u2 = Float.random(in: 0...1, using: &rng)
            return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        }
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            out.append(SIMD3<Float>(gaussian(), gaussian(), gaussian()) * sigma)
        }
        return out
    }

    /// Rotation about the gravity axis. ARKit's +Y is up, so yaw is the rotation a rescan of the
    /// same room actually accumulates.
    private func yaw(_ degrees: Float) -> simd_float3x3 {
        let r: Float = degrees * .pi / 180
        let c: Float = cos(r)
        let s: Float = sin(r)
        return simd_float3x3(SIMD3<Float>(c, 0, -s),
                             SIMD3<Float>(0, 1, 0),
                             SIMD3<Float>(s, 0, c))
    }

    private func centroid(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        var sum = SIMD3<Float>.zero
        for p in points { sum += p }
        return sum / Float(points.count)
    }

    /// Positionally pairs two clouds into the `(baseline, current)` shape the real API takes.
    private func paired(_ baseline: [SIMD3<Float>],
                        _ current: [SIMD3<Float>]) -> [(SIMD3<Float>, SIMD3<Float>)] {
        precondition(baseline.count == current.count)
        var out: [(SIMD3<Float>, SIMD3<Float>)] = []
        out.reserveCapacity(baseline.count)
        for i in 0..<baseline.count { out.append((baseline[i], current[i])) }
        return out
    }

    /// `pairs` with `transform` applied to every baseline point.
    private func mapped(_ baseline: [SIMD3<Float>],
                        by rotation: simd_float3x3,
                        _ translation: SIMD3<Float>) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(baseline.count)
        for p in baseline { out.append(rotation * p + translation) }
        return out
    }

    // MARK: - Shared assertions

    /// Every fit in this file, degenerate ones included, must produce a proper rotation. Horn's
    /// quaternion form cannot emit a reflection by construction — this assertion is the tripwire for
    /// anyone rewriting it on top of an SVD without the `det(V·Uᵀ) < 0` column flip, which fits
    /// mirrored data suspiciously well and turns a room inside out downstream.
    private func assertProperRotation(_ transform: RigidFit.Transform,
                                      _ message: String = "",
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        let det: Float = simd_determinant(transform.rotation)
        XCTAssertGreaterThan(det, 0.99, "reflection produced instead of a rotation. \(message)",
                             file: file, line: line)
        XCTAssertLessThan(det, 1.01, "rotation block carries scale (det \(det)). \(message)",
                          file: file, line: line)
    }

    /// Component-wise, because `translation` is a vector and a magnitude comparison would pass a
    /// transform that pointed the wrong way.
    private func assertTranslation(_ transform: RigidFit.Transform,
                                   matches expected: SIMD3<Float>,
                                   accuracy: Float,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        let recovered: SIMD3<Float> = transform.translation
        XCTAssertEqual(recovered.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(recovered.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(recovered.z, expected.z, accuracy: accuracy, file: file, line: line)
    }

    /// Residual RMS over *every* pair under the recovered transform, inliers and outliers alike.
    /// `inlierRMSMetres` is the estimator's own view of its fit; this is the independent one, and the
    /// only honest way to ask whether a transform explains a cloud it was allowed to disown most of.
    ///
    /// Written as an explicit loop with typed intermediates: the equivalent `zip(...).reduce(...)`
    /// one-liner is what blew the Swift expression type-checker in the previous draft of this file.
    private func rmsOverAllPairs(_ transform: RigidFit.Transform,
                                 _ pairs: [(SIMD3<Float>, SIMD3<Float>)]) -> Double {
        guard !pairs.isEmpty else { return 0 }
        var sumSquares = 0.0
        for pair in pairs {
            let predicted: SIMD3<Float> = transform.apply(pair.0)
            let residual: SIMD3<Float> = predicted - pair.1
            sumSquares += Double(simd_length_squared(residual))
        }
        return (sumSquares / Double(pairs.count)).squareRoot()
    }

    /// Indices whose residual under `transform` exceeds `inlierDistanceM` — the outlier set the real
    /// `Result` does not carry. Recomputing it from the returned transform tests the thing that
    /// matters (does the transform disown the moved furniture) rather than an index array.
    private func outlierIndices(_ transform: RigidFit.Transform,
                                _ pairs: [(SIMD3<Float>, SIMD3<Float>)],
                                threshold: Float) -> Set<Int> {
        var out: Set<Int> = []
        for i in 0..<pairs.count {
            let predicted: SIMD3<Float> = transform.apply(pairs[i].0)
            let residual: SIMD3<Float> = predicted - pairs[i].1
            let distance: Float = simd_length(residual)
            if distance > threshold { out.insert(i) }
        }
        return out
    }

    // MARK: - 1. Pure translation

    /// The simplest thing that can be right: the room did not turn, it shifted. Nothing may be
    /// rejected, and there is no residual to report.
    func testPureTranslation_recoversOffsetWithIdentityRotation() throws {
        let baseline = roomCloud(count: 500, seed: 0x5EED_0001)
        let offset = SIMD3<Float>(0.37, -0.12, 1.84)
        let current = baseline.map { $0 + offset }
        let pairs = paired(baseline, current)

        let closedForm = try XCTUnwrap(RigidFit.fit(pairs))
        XCTAssertLessThan(closedForm.angleDegrees, 0.01,
                          "a pure translation must not manufacture rotation")
        assertTranslation(closedForm, matches: offset, accuracy: 1e-3)
        assertProperRotation(closedForm)

        let robust = try XCTUnwrap(ransac(pairs))
        XCTAssertEqual(robust.pairCount, 500)
        XCTAssertEqual(robust.inlierCount, 500, "clean data must not be trimmed by the robust pass")
        XCTAssertEqual(robust.inlierFraction, 1, accuracy: 1e-9)
        XCTAssertLessThan(robust.inlierRMSMetres, 1e-4)
        assertTranslation(robust.transform, matches: offset, accuracy: 1e-3)
        assertProperRotation(robust.transform)
    }

    // MARK: - 2. Pure rotation

    /// Rotated about its own centroid, so the truth translation is exactly the centroid's
    /// compensation term `c - R·c` — a value the estimator has to recover rather than read off as
    /// zero.
    func testPureRotationAboutCentroid_recoversAngleAndCompensatingTranslation() throws {
        let baseline = roomCloud(count: 500, seed: 0x5EED_0002)
        let c: SIMD3<Float> = centroid(baseline)
        let R: simd_float3x3 = yaw(17)
        var current: [SIMD3<Float>] = []
        current.reserveCapacity(baseline.count)
        for p in baseline { current.append(R * (p - c) + c) }
        let expectedTranslation: SIMD3<Float> = c - R * c
        let pairs = paired(baseline, current)

        let closedForm = try XCTUnwrap(RigidFit.fit(pairs))
        XCTAssertEqual(closedForm.angleDegrees, 17, accuracy: 0.05)
        assertTranslation(closedForm, matches: expectedTranslation, accuracy: 2e-3)
        assertProperRotation(closedForm)

        let robust = try XCTUnwrap(ransac(pairs))
        XCTAssertEqual(robust.inlierFraction, 1, accuracy: 1e-9)
        XCTAssertLessThan(robust.inlierRMSMetres, 5e-4)
        XCTAssertEqual(robust.transform.angleDegrees, 17, accuracy: 0.05)
        assertProperRotation(robust.transform)
    }

    // MARK: - 3. Rotation + translation, the known combined transform

    /// Isotropic σ = 3 mm, the order of ARKit feature jitter between epochs. With 500 points the
    /// transform itself should land far tighter than the noise on any single point — averaging is
    /// the whole reason to fit rather than to difference.
    func testRotationTranslationWithNoise_recoversTransformAndTracksTheNoiseFloor() throws {
        let baseline = roomCloud(count: 500, seed: 0x5EED_0003)
        let R: simd_float3x3 = yaw(23)
        let t = SIMD3<Float>(1.2, -0.3, -0.75)
        let sigma: Float = 0.003
        let jitter = noise(count: baseline.count, sigma: sigma, seed: 0x5EED_1003)
        var current: [SIMD3<Float>] = []
        current.reserveCapacity(baseline.count)
        for i in 0..<baseline.count { current.append(R * baseline[i] + t + jitter[i]) }
        let pairs = paired(baseline, current)

        let robust = try XCTUnwrap(ransac(pairs))

        // A 3-DOF isotropic residual has expected magnitude σ·√3 ≈ 5.2 mm.
        XCTAssertGreaterThan(robust.inlierRMSMetres, 0.002,
                             "an RMS below the noise floor means the noise was absorbed by a free parameter")
        XCTAssertLessThan(robust.inlierRMSMetres, 0.012)
        XCTAssertEqual(robust.transform.angleDegrees, 23, accuracy: 0.1)
        assertTranslation(robust.transform, matches: t, accuracy: 0.005)
        XCTAssertGreaterThan(robust.inlierFraction, 0.9,
                             "Gaussian tails are not moved objects; trimming them wholesale is overfitting")
        assertProperRotation(robust.transform)
    }

    /// The estimator must be rigid, not similarity. A cloud uniformly 10% larger is *not* the same
    /// room, and the fit must say so with a residual it cannot talk its way out of.
    ///
    /// Asserted two ways, because either alone is escapable: the rotation block must stay determinant
    /// +1 (scale folded into the matrix), and the residual over *all* pairs must stay large (scale
    /// absorbed by discarding the points that disagree). A similarity fit collapses both to ~0.
    func testUniformlyScaledCloud_isNotFittedByAbsorbingScale() throws {
        let baseline = roomCloud(count: 500, seed: 0x5EED_0004)
        let R: simd_float3x3 = yaw(23)
        let t = SIMD3<Float>(1.2, -0.3, -0.75)
        var current: [SIMD3<Float>] = []
        current.reserveCapacity(baseline.count)
        for p in baseline {
            let rotated: SIMD3<Float> = R * p
            current.append(rotated * 1.1 + t)
        }
        let pairs = paired(baseline, current)

        let closedForm = try XCTUnwrap(RigidFit.fit(pairs))

        // Best rigid fit leaves 0.1·|p − c| per point ≈ 0.2 m RMS over a 5 × 3 × 5 m box.
        XCTAssertGreaterThan(rmsOverAllPairs(closedForm, pairs), 0.05,
                             "a 10% scale change was fitted away — the estimator is a similarity, not a rigid, fit")
        assertProperRotation(closedForm, "scale must not be folded into the rotation block")

        // The robust path must not launder the same scale change into a high-confidence fit either:
        // it may only explain the shell of points where 10% of the lever arm is under 5 cm. A nil
        // result (no consensus at all) is an equally correct answer, hence the `?? 0`.
        let robust = ransac(pairs)
        XCTAssertLessThan(robust?.inlierFraction ?? 0, 0.5,
                          "a scaled cloud must not come back as a mostly-explained rigid fit")
    }

    // MARK: - 4. Planted moved object

    /// A tight cluster of pairs — one piece of furniture — displaced 0.8 m from where the rest of the
    /// room says it should be. Individually each cluster pair is as consistent as any other; only
    /// their disagreement with the majority marks them. The cluster indices are interleaved rather
    /// than appended so an implementation that assumes outliers are contiguous, or that classifies by
    /// position in the array, fails here.
    private struct MovedObjectScene {
        let pairs: [(SIMD3<Float>, SIMD3<Float>)]
        let movedIndices: Set<Int>
        let rotation: simd_float3x3
        let translation: SIMD3<Float>
        let angleDegrees: Double
    }

    private func movedObjectScene(seed: UInt64) -> MovedObjectScene {
        let count = 500
        var rng = SeededGenerator(seed: seed)
        let R: simd_float3x3 = yaw(11)
        let t = SIMD3<Float>(0.5, 0.05, -0.3)

        let clusterCentre = SIMD3<Float>(1.6, 0.5, -1.2)
        let clusterRadius: Float = 0.3
        // Exactly 0.8 m: (0.6, 0, 0.8) is a unit vector.
        let displacement = SIMD3<Float>(0.6, 0, 0.8) * 0.8

        var pairs: [(SIMD3<Float>, SIMD3<Float>)] = []
        var moved: Set<Int> = []
        pairs.reserveCapacity(count)

        for i in 0..<count {
            let isMoved = (i % 5 == 0)   // 100 of 500 = 20%
            let p: SIMD3<Float>
            if isMoved {
                let dx = Float.random(in: -clusterRadius...clusterRadius, using: &rng)
                let dy = Float.random(in: -clusterRadius...clusterRadius, using: &rng)
                let dz = Float.random(in: -clusterRadius...clusterRadius, using: &rng)
                p = clusterCentre + SIMD3<Float>(dx, dy, dz)
                moved.insert(i)
            } else {
                let x = Float.random(in: -2.5...2.5, using: &rng)
                let y = Float.random(in: 0...3, using: &rng)
                let z = Float.random(in: -2.5...2.5, using: &rng)
                p = SIMD3<Float>(x, y, z)
            }
            let base: SIMD3<Float> = R * p + t
            pairs.append((p, isMoved ? base + displacement : base))
        }

        return MovedObjectScene(pairs: pairs, movedIndices: moved,
                                rotation: R, translation: t, angleDegrees: 11)
    }

    func testMovedObjectCluster_isRejectedAndDoesNotDragTheTransform() throws {
        let scene = movedObjectScene(seed: 0x5EED_0005)

        let robust = try XCTUnwrap(ransac(scene.pairs))

        XCTAssertEqual(robust.pairCount, 500)
        XCTAssertEqual(robust.inlierCount, 400,
                       "the static majority and nothing else must survive the inlier test")
        XCTAssertEqual(robust.inlierFraction, 0.8, accuracy: 0.005)

        // `Result` carries no outlier index list, so the identity of the rejected pairs is recovered
        // from the transform itself — a stronger statement than an index array would be.
        let rejected = outlierIndices(robust.transform, scene.pairs, threshold: inlierDistanceM)
        XCTAssertEqual(rejected, scene.movedIndices,
                       "the moved cluster and nothing else must fall outside the inlier radius")

        XCTAssertEqual(robust.transform.angleDegrees, scene.angleDegrees, accuracy: 0.05,
                       "the moved object pulled the rotation")
        assertTranslation(robust.transform, matches: scene.translation, accuracy: 0.001)
        XCTAssertLessThan(robust.inlierRMSMetres, 0.001,
                          "with the cluster excluded the remaining pairs are exact")
        assertProperRotation(robust.transform)
    }

    /// Same seed, same scene, twice — every reported number must be bit-identical. `RigidFit` seeds a
    /// private SplitMix64 precisely so this holds; an estimator that sampled from a system RNG, or
    /// whose trimming walked an unordered `Set`, would pass the test above and still give two
    /// different canonical frames for one scan pair.
    func testMovedObjectCluster_isDeterministicAcrossRuns() throws {
        let sceneA = movedObjectScene(seed: 0x5EED_0005)
        let sceneB = movedObjectScene(seed: 0x5EED_0005)
        XCTAssertEqual(sceneA.pairs.map(\.0), sceneB.pairs.map(\.0),
                       "the seeded generator itself must be deterministic")
        XCTAssertEqual(sceneA.pairs.map(\.1), sceneB.pairs.map(\.1))

        let first = try XCTUnwrap(ransac(sceneA.pairs))
        let second = try XCTUnwrap(ransac(sceneB.pairs))

        XCTAssertEqual(first.inlierCount, second.inlierCount)
        XCTAssertEqual(first.inlierFraction, second.inlierFraction)
        XCTAssertEqual(first.inlierRMSMetres, second.inlierRMSMetres)
        XCTAssertEqual(first.transform.translation, second.transform.translation)
        XCTAssertEqual(first.transform.rotation, second.transform.rotation)
        XCTAssertEqual(first.conditioning.lambdaRatio, second.conditioning.lambdaRatio)
        XCTAssertEqual(first.conditioning.horizontalExtentM, second.conditioning.horizontalExtentM)
        XCTAssertEqual(first.conditioning.verticalExtentM, second.conditioning.verticalExtentM)
    }

    // MARK: - 5. Degenerate sets are reported, not silently fitted

    /// Features strung along a single horizontal rail — a corridor handrail, a counter edge, a run of
    /// ceiling track — with a centimetre of scatter, which is all it takes for the fit to be
    /// numerically clean while yaw about that line is effectively unconstrained.
    ///
    /// **This is the λratio case, not the extent case.** `horizontalExtentM` is the *major*
    /// horizontal span by design, so a 5 m rail sails past `minHorizontalExtentM` — asserted here so
    /// nobody reads that threshold as a corridor filter. `lambdaRatio` is what collapses, and the two
    /// scalars have to be read together exactly as `RigidFit.Conditioning` documents.
    func testNearCollinearRail_reportsACollapsedLambdaRatio() throws {
        var rng = SeededGenerator(seed: 0x5EED_0006)
        var baseline: [SIMD3<Float>] = []
        baseline.reserveCapacity(200)
        for _ in 0..<200 {
            let x = Float.random(in: -2.5...2.5, using: &rng)
            let y: Float = 1.0 + Float.random(in: -0.01...0.01, using: &rng)
            let z: Float = 0.5 + Float.random(in: -0.01...0.01, using: &rng)
            baseline.append(SIMD3<Float>(x, y, z))
        }
        let R: simd_float3x3 = yaw(9)
        let t = SIMD3<Float>(0.4, 0, -0.2)
        let pairs = paired(baseline, mapped(baseline, by: R, t))

        let robust = try XCTUnwrap(ransac(pairs),
                                   "a near-degenerate set must be REPORTED, not refused — the gate decides, not the fit")

        XCTAssertLessThan(robust.conditioning.lambdaRatio, 0.01,
                          "a line has no second principal direction")
        XCTAssertLessThan(robust.conditioning.lambdaRatio, PromotionGate.Thresholds.minLambdaRatio,
                          "the gate's λratio floor is what refuses a rail")
        XCTAssertGreaterThan(robust.conditioning.horizontalExtentM,
                             PromotionGate.Thresholds.minHorizontalExtentM,
                             "horizontalExtentM is the MAJOR horizontal span: a long rail passes it, by design")
        assertProperRotation(robust.transform, "collinear input is where a missing determinant flip surfaces")
    }

    /// Perfectly collinear — no scatter at all. Every minimal sample has zero triangle area, so
    /// `ransac` rejects them all and returns `nil` rather than a confident-looking fit whose rotation
    /// about the line was picked by round-off. The closed-form `fit` still answers (it is the raw
    /// solver, and Horn's quaternion form cannot emit a reflection even here), which is the
    /// difference between the two entry points.
    func testPerfectlyCollinearPoints_ransacRefusesRatherThanGuessing() throws {
        var baseline: [SIMD3<Float>] = []
        baseline.reserveCapacity(200)
        for i in 0..<200 {
            baseline.append(SIMD3<Float>(-2.5 + Float(i) * 0.025, 1.0, 0.5))
        }
        let R: simd_float3x3 = yaw(9)
        let t = SIMD3<Float>(0.4, 0, -0.2)
        let pairs = paired(baseline, mapped(baseline, by: R, t))

        XCTAssertNil(ransac(pairs),
                     "a zero-area correspondence set has no well-determined fit and must not report one")

        let closedForm = try XCTUnwrap(RigidFit.fit(pairs),
                                       "the raw solver still answers; it is the RANSAC wrapper that refuses")
        assertProperRotation(closedForm, "Horn's quaternion form cannot emit a reflection, collinear or not")
    }

    /// Everything that survived the join sits inside a 0.2 m ball — the signature of a poor
    /// relocalization where only features near where the user stood matched. A millimetre of noise on
    /// a 0.1 m lever arm is degrees of rotation error extrapolated across a whole room.
    ///
    /// **This is the extent case, not the λratio case.** The ball is isotropic, so `lambdaRatio` —
    /// which is the plain, scale-*free* λ_min/λ_max — reports it as well conditioned, and that is
    /// asserted here rather than wished away: a scale-free ratio structurally cannot see the
    /// difference between a small ball and a big one. `horizontalExtentM` is the scalar that carries
    /// the absolute size, and it is what refuses this set.
    func testTightlyClusteredPoints_reportATinyExtentDespiteAHealthyLambdaRatio() throws {
        var rng = SeededGenerator(seed: 0x5EED_0007)
        let centre = SIMD3<Float>(0.8, 1.2, -0.4)
        let radius: Float = 0.1
        var baseline: [SIMD3<Float>] = []
        while baseline.count < 200 {   // rejection sampling: a true ball, isotropic in every direction
            let vx = Float.random(in: -1...1, using: &rng)
            let vy = Float.random(in: -1...1, using: &rng)
            let vz = Float.random(in: -1...1, using: &rng)
            let v = SIMD3<Float>(vx, vy, vz)
            guard simd_length_squared(v) <= 1 else { continue }
            baseline.append(centre + v * radius)
        }
        let R: simd_float3x3 = yaw(9)
        let t = SIMD3<Float>(0.4, 0, -0.2)
        let pairs = paired(baseline, mapped(baseline, by: R, t))

        let robust = try XCTUnwrap(ransac(pairs, inlierDistanceM: 0.01),
                                   "a degenerate set must be REPORTED, not refused — the gate decides, not the fit")

        XCTAssertLessThan(robust.conditioning.horizontalExtentM,
                          PromotionGate.Thresholds.minHorizontalExtentM,
                          "the gate's absolute-extent floor is the only thing that can refuse a hover")
        XCTAssertLessThan(robust.conditioning.horizontalExtentM, 0.25)
        XCTAssertLessThan(robust.conditioning.verticalExtentM, 0.25)
        XCTAssertGreaterThan(robust.conditioning.lambdaRatio, 0.5,
                             "lambdaRatio is scale-free by design: an isotropic ball reads well conditioned however small it is")
        assertProperRotation(robust.transform)
    }

    /// The counterpart the two cases above are only meaningful against: a room-sized spread clears
    /// both thresholds, so the gate is refusing degeneracy rather than refusing everything.
    func testRoomSizedSpread_clearsBothPromotionThresholds() throws {
        let baseline = roomCloud(count: 500, seed: 0x5EED_0008)
        let R: simd_float3x3 = yaw(9)
        let t = SIMD3<Float>(0.4, 0, -0.2)
        let pairs = paired(baseline, mapped(baseline, by: R, t))

        let robust = try XCTUnwrap(ransac(pairs))

        XCTAssertGreaterThan(robust.conditioning.lambdaRatio, PromotionGate.Thresholds.minLambdaRatio)
        XCTAssertGreaterThan(robust.conditioning.horizontalExtentM,
                             PromotionGate.Thresholds.minHorizontalExtentM)
        assertProperRotation(robust.transform)
    }

    // MARK: - 6. Guards

    func testEmptyInput_returnsNil() {
        XCTAssertNil(RigidFit.fit([]))
        XCTAssertNil(ransac([]))
    }

    /// Three pairs is the minimum that can constrain a rotation. Below it there is nothing to report
    /// — not a degenerate result, no result.
    func testFewerThanThreePairs_returnsNil() {
        let baseline = roomCloud(count: 3, seed: 0x5EED_0009)
        let current = baseline.map { $0 + SIMD3<Float>(0.1, 0.2, 0.3) }
        let pairs = paired(baseline, current)

        XCTAssertNil(RigidFit.fit(Array(pairs.prefix(1))))
        XCTAssertNil(RigidFit.fit(Array(pairs.prefix(2))))
        XCTAssertNotNil(RigidFit.fit(pairs),
                        "three pairs is the threshold, not the first rejected count")

        XCTAssertNil(ransac(Array(pairs.prefix(2))))
    }

    /// A zero iteration budget is a caller bug, not a degenerate input; it must come back empty
    /// rather than silently falling through to an unscored model.
    func testZeroIterationBudget_returnsNil() {
        let baseline = roomCloud(count: 100, seed: 0x5EED_000A)
        let pairs = paired(baseline, baseline.map { $0 + SIMD3<Float>(0.1, 0, 0) })

        XCTAssertNil(RigidFit.ransac(pairs: pairs,
                                     inlierDistanceM: inlierDistanceM,
                                     iterations: 0,
                                     seed: seed))
    }
}
