import XCTest
import simd
@testable import wisescan_ios

/// `PromotionGate` — the shadow-mode verdict on whether the baseline world map a rescan relocalized
/// into should be replaced because the room changed, and whether this scan could replace it.
///
/// The gate scores the feature-point correspondences `FeaturePointDiff` already extracts (baseline
/// captured at map load, current cloud captured at save) and answers with one of five decisions.
/// **Three** measurements feed it, not two:
///
/// * **the rigid fit** — `RigidFit.ransac` over the id-matched `(baseline, current)` pairs, which
///   reports how much of the old geometry the new session still agrees with (`inlierFraction`), how
///   tightly (`inlierRMSMetres`), and how well-spread the agreeing evidence was (`lambdaRatio`,
///   `horizontalExtentM`).
/// * **coverage** — the fraction of BASELINE CELLS that a fresh point re-occupies. Low coverage
///   means the rescan saw only part of the space.
/// * **staleness (ghosts)** — the fraction of BASELINE POINTS sitting in a cell that was demonstrably
///   revisited (a fresh point landed in its 26-neighbourhood) yet came back empty. Those points are
///   geometry the space no longer has. A baseline cell with no fresh point ANYWHERE near it is not a
///   ghost — that region was simply not walked this time, and absence of evidence is not evidence of
///   absence.
///
/// They are read along **three verdict axes**, and the decision-table fixtures below are built to
/// move one axis at a time and assert exactly which drivers fired:
///
/// * **change pressure** — a low inlier fraction or a high stale fraction means the ROOM CHANGED.
///   Without it the verdict is HOLD, however perfect the fit: an unchanged room never promotes.
/// * **fit qualification** — inlier count, inlier RMS, λ-ratio and horizontal extent, deliberately
///   NOT the inlier fraction. A changed room whose fit fails this REBASELINES; it never promotes.
/// * **coverage** — a changed room must have been revisited broadly to promote; thin, it
///   REBASELINES.
///
/// **The fit is part of the verdict.** An earlier draft of this file assumed it was not, and built
/// every decision fixture out of pairs that map each point to itself along a single line. That input
/// is exactly what `RigidFit.ransac` returns `nil` for (every minimal sample has zero triangle area),
/// so four decision tests silently landed on the `ransacNoConsensus` branch of `evaluate` instead of
/// on the verdict they named. `PromotionGate.swift` flags the disagreement as an unresolved contract
/// conflict; it is resolved **toward the implementation** here — the fixtures now carry pairs with
/// real room-sized spread, and `ransacNoConsensus` gets a test of its own rather than being where
/// everything accidentally ends up.
///
/// Everything here is synthesized: cell-centred point clouds and hand-built `Correspondences`. No
/// ARKit, no files, no device.
///
/// `@MainActor` because the module compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: it
/// costs nothing here and keeps these tests callable whether or not the gate is marked `nonisolated`
/// (it is — it is scored on the `getCurrentWorldMap` callback queue, off main).
@MainActor
final class PromotionGateTests: XCTestCase {

    private typealias Thresholds = PromotionGate.Thresholds

    // MARK: - Cell geometry helpers
    //
    // Every coordinate is derived from `cellSizeM`, so recalibrating the cell size moves the
    // fixtures with it instead of silently invalidating the expected fractions.

    private var s: Float { PromotionGate.cellSizeM }

    /// Dead centre of cell `(i, j, k)`.
    private func centre(_ i: Int, _ j: Int = 0, _ k: Int = 0) -> SIMD3<Float> {
        SIMD3((Float(i) + 0.5) * s, (Float(j) + 0.5) * s, (Float(k) + 0.5) * s)
    }

    /// Centre of cell `(i, j, k)` nudged by `dx` cells along x. `|dx| < 0.5` stays inside the cell.
    private func inside(_ i: Int, _ j: Int = 0, _ k: Int = 0, dx: Float) -> SIMD3<Float> {
        centre(i, j, k) + SIMD3(dx * s, 0, 0)
    }

    /// A point sitting EXACTLY on the lower x boundary of cell `i` — the shared face between cells
    /// `i-1` and `i`. Floor division puts it in `i`.
    private func lowerXFace(_ i: Int, _ j: Int = 0, _ k: Int = 0) -> SIMD3<Float> {
        SIMD3(Float(i) * s, (Float(j) + 0.5) * s, (Float(k) + 0.5) * s)
    }

    func testCellSize_isHalfAMetre() {
        XCTAssertEqual(Double(PromotionGate.cellSizeM), 0.5, accuracy: 1e-9,
                       "Fixture geometry below assumes the 0.5 m bin the gate is specified against.")
    }

    // MARK: - 1. Coverage

    /// Eight baseline cells, three of them re-occupied — 3/8 exactly, and nothing else.
    ///
    /// Cell 0 is deliberately left OUT of the baseline so the boundary point can discriminate: a
    /// fresh point at exactly x = 0.5·cell belongs to cell 1 (floor), and if the implementation put
    /// it in cell 0 instead the fraction would drop to 2/8 rather than landing on the same answer by
    /// accident. Two of the fresh points are at negative x, which the 21-bit band pack has to carry
    /// through a masked shift without aliasing onto a different cell.
    func testCoverage_isTheExactFractionOfBaselineCellsReoccupied() {
        let baselineCells = [-2, -1, 1, 2, 3, 4, 5, 6]        // note: no cell 0
        let baseline = baselineCells.map { centre($0) }

        let fresh: [SIMD3<Float>] = [
            inside(-1, dx: -0.1),        // negative coordinate, negative cell index
            lowerXFace(1),               // exactly on the 1|0 face -> cell 1
            inside(3, dx: 0.3),
            centre(10)                   // no baseline here: must not inflate the numerator
        ]

        XCTAssertEqual(PromotionGate.coverageFraction(baseline: baseline, fresh: fresh),
                       3.0 / 8.0, accuracy: 1e-9)
    }

    /// The other side of the boundary convention: move the boundary point one hair below the face
    /// and it falls into cell 0, which is not a baseline cell, so coverage drops by exactly one cell.
    func testCoverage_boundaryPointBelongsToTheUpperCell() {
        let baseline = [-2, -1, 1, 2, 3, 4, 5, 6].map { centre($0) }
        let justBelowTheFace = SIMD3<Float>(Float(1) * s - (s * 0.02), 0.5 * s, 0.5 * s)

        let fresh: [SIMD3<Float>] = [
            inside(-1, dx: -0.1),
            justBelowTheFace,            // cell 0 — not in the baseline
            inside(3, dx: 0.3)
        ]

        XCTAssertEqual(PromotionGate.coverageFraction(baseline: baseline, fresh: fresh),
                       2.0 / 8.0, accuracy: 1e-9,
                       "A point below the face must bin to the lower cell, not round up into cell 1.")
    }

    /// Several baseline points in one cell are one cell's worth of coverage — coverage is a cell
    /// measure, unlike staleness below.
    func testCoverage_countsCellsNotPoints() {
        let baseline = [centre(0), inside(0, dx: 0.2), inside(0, dx: -0.2), centre(4)]
        let fresh = [inside(0, dx: 0.4)]

        XCTAssertEqual(PromotionGate.coverageFraction(baseline: baseline, fresh: fresh),
                       1.0 / 2.0, accuracy: 1e-9)
    }

    /// Full overlap and zero overlap are the two ends the fractions above interpolate between.
    func testCoverage_isOneOnFullOverlapAndZeroOnNone() {
        let baseline = (0..<6).map { centre($0 * 2) }

        let everywhere = (0..<6).map { inside($0 * 2, dx: 0.3) }
        XCTAssertEqual(PromotionGate.coverageFraction(baseline: baseline, fresh: everywhere),
                       1.0, accuracy: 1e-9)

        let elsewhere = (0..<6).map { centre($0 * 2, 0, 500) }
        XCTAssertEqual(PromotionGate.coverageFraction(baseline: baseline, fresh: elsewhere),
                       0.0, accuracy: 1e-9)

        // A cloud with nothing in it cannot have a denominator; the gate reports 0 rather than NaN.
        XCTAssertEqual(PromotionGate.coverageFraction(baseline: [], fresh: everywhere),
                       0.0, accuracy: 1e-9)
    }

    // MARK: - 2. Staleness (ghosts)

    /// Three cells, three roles:
    ///
    /// * **ghost** at `(0,0,0)` — three baseline points, no fresh point of its own, but a fresh point
    ///   sits in its `(1,1,1)` corner neighbour. That region WAS revisited and the geometry did not
    ///   come back: ghost.
    /// * **covered** at `(10,0,0)` — one baseline point and a fresh point in the same cell.
    /// * **unvisited** at `(50,0,0)` — five baseline points and no fresh point within its
    ///   26-neighbourhood. Not a ghost, and not evidence of anything.
    ///
    /// The fraction is over baseline POINTS, so the ghost cell's three points and the covered cell's
    /// one give 3/4. Two plausible mis-implementations land elsewhere and are asserted against by
    /// name: counting cells rather than points gives 1/2, and letting the unvisited region into the
    /// denominator gives 3/9. The unvisited cell is excluded from BOTH halves — a region nobody
    /// walked is not evidence that its geometry survived, and it is not evidence that it vanished.
    func testStaleness_countsRevisitedGhostPointsAndIgnoresUnvisitedRegions() {
        let ghost = [inside(0, dx: -0.3), centre(0), inside(0, dx: 0.3)]
        let covered = [centre(10)]
        let unvisited = (0..<5).map { inside(50, dx: Float($0) * 0.1 - 0.2) }
        let baseline = ghost + covered + unvisited

        let fresh: [SIMD3<Float>] = [
            centre(1, 1, 1),             // corner neighbour of the ghost cell: revisited, came back empty
            inside(10, dx: 0.2)          // lands in the covered cell itself
        ]

        let stale = PromotionGate.staleFraction(baseline: baseline, fresh: fresh)

        XCTAssertEqual(stale, 3.0 / 4.0, accuracy: 1e-9,
                       "Ghost points over revisited baseline points: 3 ghosts, 1 survivor.")
        XCTAssertNotEqual(stale, 1.0 / 2.0, accuracy: 1e-9, "Counted cells instead of points.")
        XCTAssertNotEqual(stale, 3.0 / 9.0, accuracy: 1e-9, "Unvisited points diluted the denominator.")
    }

    /// A cell whose only nearby fresh point is two cells away is outside the 26-neighbourhood, so it
    /// is unvisited, not a ghost — nothing in the cloud is stale and the fraction is zero.
    func testStaleness_pointTwoCellsAwayDoesNotMakeACellRevisited() {
        let baseline = [centre(0), centre(0) + SIMD3(0, 0.1 * s, 0)]
        let fresh = [centre(2)]          // two cells along x: outside the 26-neighbourhood

        XCTAssertEqual(PromotionGate.staleFraction(baseline: baseline, fresh: fresh),
                       0.0, accuracy: 1e-9)
    }

    /// A revisited cell that DID come back is not a ghost, so a fully re-observed cloud is 0% stale.
    func testStaleness_isZeroWhenEveryBaselineCellComesBack() {
        let baseline = (0..<6).map { centre($0 * 2) }
        let fresh = (0..<6).map { inside($0 * 2, dx: 0.25) }

        XCTAssertEqual(PromotionGate.staleFraction(baseline: baseline, fresh: fresh),
                       0.0, accuracy: 1e-9)
    }

    /// Everything revisited and nothing re-observed: the fraction saturates at 1, the partial case
    /// above lands strictly between, and a cloud nobody walked through reports 0 either way.
    func testStaleness_saturatesAtOneWhenEveryRevisitedCellCameBackEmpty() {
        // Four baseline cells along x at spacing 3, each with a fresh point one cell diagonally off,
        // so every cell is revisited and every cell is empty.
        var baseline: [SIMD3<Float>] = []
        var fresh: [SIMD3<Float>] = []
        for n in 0..<4 {
            baseline.append(centre(n * 3))
            fresh.append(centre(n * 3 + 1, 1))
        }
        XCTAssertEqual(PromotionGate.staleFraction(baseline: baseline, fresh: fresh),
                       1.0, accuracy: 1e-9)

        XCTAssertEqual(PromotionGate.staleFraction(baseline: baseline, fresh: []),
                       0.0, accuracy: 1e-9,
                       "No fresh points at all means nothing was revisited, not that everything is stale.")
    }

    // MARK: - 3. Decision table
    //
    // Every fixture below carries a real, well-conditioned rigid fit unless the test is specifically
    // about the fit, so the decision under test is the one the name claims. Each one first proves it
    // landed where the decision needs it (the self-verifying asserts), then pins the verdict AND the
    // exact driver list: `drivers` is what the calibration pass groups on, so "some driver mentions
    // coverage" is not enough — which axis fired, in which direction, is the contract.

    // MARK: HOLD — no substantial change

    /// The legibility case the whole table is calibrated around: an unchanged room, rescanned in
    /// full, fitting perfectly on ample evidence. Every eligibility check would pass — and the answer
    /// is still HOLD, because nothing changed. Each promotion adds a measured-error hop to the
    /// lineage, so the gate promotes lazily, and only for a reason.
    func testDecision_hold_whenAnUnchangedRoomComesBackWithAPerfectFit() throws {
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: 40, ghost: 0, unvisited: 0, pairs: amplePairs()))

        XCTAssertEqual(report.coverageFraction, 1.0, accuracy: 1e-9)
        XCTAssertEqual(report.staleFraction, 0.0, accuracy: 1e-9)
        XCTAssertEqual(report.inlierFraction, 1.0, accuracy: 1e-9)
        assertFitQualifies(report, "the fit must be one that WOULD qualify, or this tests nothing")
        XCTAssertGreaterThanOrEqual(report.coverageFraction, Thresholds.minCoverage)

        XCTAssertEqual(report.decision, .hold,
                       "An unchanged room must not promote, however clean the rescan.")
        XCTAssertEqual(report.drivers, [Driver.quietFraction, Driver.quietStale])
    }

    /// Thin coverage with nothing contradicted: an unchanged room the operator only partly revisited.
    /// Coverage only matters once change has fired, so it is NOT a driver here — it did not decide
    /// anything.
    func testDecision_hold_whenCoverageIsThinButNothingChanged() throws {
        let total = 200
        let covered = max(1, Int((Thresholds.minCoverage / 2) * Double(total)))
        try XCTSkipIf(Double(covered) / Double(total) >= Thresholds.minCoverage,
                      "minCoverage is too small for a 200-cell fixture to land under it.")
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: covered, ghost: 0, unvisited: total - covered,
                                pairs: amplePairs()))

        XCTAssertLessThan(report.coverageFraction, Thresholds.minCoverage)
        XCTAssertLessThanOrEqual(report.staleFraction, Thresholds.changeStaleFraction)
        XCTAssertGreaterThanOrEqual(report.inlierFraction, Thresholds.changeInlierFraction)
        XCTAssertEqual(report.decision, .hold)
        XCTAssertEqual(report.drivers, [Driver.quietFraction, Driver.quietStale])
        XCTAssertFalse(report.drivers.contains { $0.hasPrefix("coverage:") },
                       "thin coverage of an unchanged room decides nothing and must not be blamed")
    }

    /// A fit that would NOT qualify — every pair inside the inlier radius, so the fraction is perfect,
    /// but the inlier RMS above its cap — in a room that did not change. Fit quality is not a change
    /// signal, so this is HOLD, not REBASELINE: there is nothing to rebaseline over.
    func testDecision_hold_evenWhenTheFitWouldNotQualify() throws {
        let noise = try XCTUnwrap(looseFitNoiseM,
                                  "inlierDistanceM is too tight for a loose-but-all-inlier fixture")
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: 40, ghost: 0, unvisited: 0, pairs: amplePairs(),
                                noiseM: noise))

        XCTAssertEqual(report.inlierFraction, 1.0, accuracy: 1e-9,
                       "the noise must stay inside the inlier radius, or the fraction becomes a change signal")
        XCTAssertGreaterThan(report.inlierRMSMetres, Thresholds.maxInlierRMSM)
        XCTAssertEqual(report.staleFraction, 0.0, accuracy: 1e-9)
        XCTAssertEqual(report.decision, .hold)
        XCTAssertEqual(report.drivers, [Driver.quietFraction, Driver.quietStale],
                       "a fit failure without change pressure must not surface as a driver")
    }

    // MARK: PROMOTE — substantial change, eligible scan

    /// The case promotion exists for: a genuinely REARRANGED room. A couch-sized cluster of retained
    /// features moved rigidly by over a metre, dragging the inlier fraction under the change trigger
    /// — while the static majority (walls, floor, everything that stayed put) still fits tightly,
    /// spread through the whole room, on ample inliers, and the rescan covered the room. Low fraction
    /// is the CHANGE signal here, not a quality failure.
    func testDecision_promote_whenARearrangedRoomsStaticMajorityStillFitsTightly() throws {
        let moved = 0.4
        try XCTSkipIf(1 - moved >= Thresholds.changeInlierFraction,
                      "changeInlierFraction no longer sits above a 60% static majority.")
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: 40, ghost: 0, unvisited: 0,
                                pairs: amplePairs(disagreeingFraction: moved),
                                disagreeingFraction: moved, disagreement: .movedCluster))

        XCTAssertEqual(report.inlierFraction, 1 - moved, accuracy: 0.01,
                       "RANSAC must lock onto the static majority, not the moved cluster")
        XCTAssertLessThan(report.inlierFraction, Thresholds.changeInlierFraction)
        XCTAssertLessThanOrEqual(report.staleFraction, Thresholds.changeStaleFraction,
                                 "staleness must stay quiet so the fraction is provably what fired")
        assertFitQualifies(report)
        XCTAssertEqual(report.coverageFraction, 1.0, accuracy: 1e-9)

        XCTAssertEqual(report.decision, .promote)
        XCTAssertEqual(report.drivers, [Driver.changeFraction] + Driver.allEligible)
    }

    /// The other change signal: the fit is perfect and the fraction is perfect, but a meaningful share
    /// of the revisited baseline came back empty — structure the room no longer has. Coverage is
    /// still above the bar, so this scan can carry the promotion.
    func testDecision_promote_whenStalenessCarriesTheChangeSignal() throws {
        let ghost = try XCTUnwrap(promotableGhostCells(outOf: 40),
                                  "no stale fraction both crosses changeStaleFraction and leaves minCoverage")
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: 40 - ghost, ghost: ghost, unvisited: 0, pairs: amplePairs()))

        XCTAssertGreaterThan(report.staleFraction, Thresholds.changeStaleFraction)
        XCTAssertGreaterThanOrEqual(report.coverageFraction, Thresholds.minCoverage)
        XCTAssertEqual(report.inlierFraction, 1.0, accuracy: 1e-9,
                       "the fraction must stay quiet so staleness is provably what fired")
        assertFitQualifies(report)

        XCTAssertEqual(report.decision, .promote)
        XCTAssertEqual(report.drivers, [Driver.changeStale] + Driver.allEligible)
    }

    /// Fit qualification is independent of the fraction, all the way down: a MINORITY of the pairs
    /// agreeing (60% disagree, scattered in every direction) still qualifies when that minority is
    /// numerous, tight and room-spread. This is the fixture that used to read REBASELINE on fraction
    /// alone; under the design it is the strongest change signal there is, on a fit that is fine.
    func testDecision_promote_evenAtAMinorityInlierFraction_whenTheFitStillQualifies() throws {
        let disagreeing = 0.6
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: 40, ghost: 0, unvisited: 0,
                                pairs: amplePairs(disagreeingFraction: disagreeing),
                                disagreeingFraction: disagreeing))

        XCTAssertEqual(report.inlierFraction, 1 - disagreeing, accuracy: 0.01)
        XCTAssertLessThan(report.inlierFraction, 0.5, "the agreeing set must be a minority")
        assertFitQualifies(report)
        XCTAssertEqual(report.decision, .promote,
                       "A low inlier fraction must never, on its own, condemn the fit.")
        XCTAssertEqual(report.drivers, [Driver.changeFraction] + Driver.allEligible)
    }

    /// Both change triggers crossing are both named, in a fixed order (fraction, then staleness), so a
    /// calibration pass can count how often each one fires independently.
    func testDecision_drivers_nameEveryChangeTriggerThatCrossed() throws {
        let moved = 0.4
        let ghost = try XCTUnwrap(promotableGhostCells(outOf: 40))
        try XCTSkipIf(1 - moved >= Thresholds.changeInlierFraction)
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: 40 - ghost, ghost: ghost, unvisited: 0,
                                pairs: amplePairs(disagreeingFraction: moved),
                                disagreeingFraction: moved, disagreement: .movedCluster))

        XCTAssertEqual(report.decision, .promote)
        XCTAssertEqual(report.drivers, [Driver.changeFraction, Driver.changeStale] + Driver.allEligible)
    }

    // MARK: REBASELINE — substantial change, ineligible scan

    /// The twin of the rearranged-room PROMOTE fixture — same moved couch, same fraction, same
    /// coverage — but with only a few hundred pairs, so the static majority is a thin set of inliers.
    /// RMS and spread are still fine; the inlier COUNT is what refuses, checked directly rather than
    /// left implicit in `pairCount × inlierFraction`.
    func testDecision_rebaseline_whenTheChangedRoomsFitRestsOnTooFewInliers() throws {
        let moved = 0.4
        let pairs = Thresholds.minPairs + 1
        try XCTSkipIf(1 - moved >= Thresholds.changeInlierFraction)
        try XCTSkipIf(Double(pairs) * (1 - moved) >= Double(Thresholds.minInlierCount),
                      "minInlierCount no longer sits above the pair floor's static majority.")
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: 40, ghost: 0, unvisited: 0, pairs: pairs,
                                disagreeingFraction: moved, disagreement: .movedCluster))

        XCTAssertGreaterThanOrEqual(report.pairCount, Thresholds.minPairs,
                                    "clear the pair floor, or this tests insufficientData instead")
        XCTAssertLessThan(report.inlierFraction, Thresholds.changeInlierFraction)
        XCTAssertLessThan(inlierCount(report), Thresholds.minInlierCount)
        XCTAssertLessThanOrEqual(report.inlierRMSMetres, Thresholds.maxInlierRMSM)
        XCTAssertGreaterThanOrEqual(report.lambdaRatio, Thresholds.minLambdaRatio)
        XCTAssertGreaterThanOrEqual(report.horizontalExtentM, Thresholds.minHorizontalExtentM)

        XCTAssertEqual(report.decision, .rebaseline)
        XCTAssertEqual(report.drivers, [Driver.changeFraction, Driver.fitCountLow])
    }

    /// A changed room (staleness) whose fit agrees loosely: every pair is an inlier, but the inlier RMS
    /// is over its cap. Not a seat to build the next baseline on.
    func testDecision_rebaseline_whenTheChangedRoomsFitIsLoose() throws {
        let noise = try XCTUnwrap(looseFitNoiseM)
        let ghost = try XCTUnwrap(promotableGhostCells(outOf: 40))
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: 40 - ghost, ghost: ghost, unvisited: 0, pairs: amplePairs(),
                                noiseM: noise))

        XCTAssertGreaterThan(report.staleFraction, Thresholds.changeStaleFraction)
        XCTAssertGreaterThanOrEqual(report.coverageFraction, Thresholds.minCoverage)
        XCTAssertEqual(report.inlierFraction, 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(report.inlierRMSMetres, Thresholds.maxInlierRMSM)
        XCTAssertGreaterThanOrEqual(inlierCount(report), Thresholds.minInlierCount)

        XCTAssertEqual(report.decision, .rebaseline)
        XCTAssertEqual(report.drivers, [Driver.changeStale, Driver.fitRMSHigh])
    }

    /// A changed room whose agreeing evidence all sits in one corner — tight, plentiful, nicely
    /// three-dimensional, and too small an area to vouch for the whole map.
    func testDecision_rebaseline_whenTheAgreementIsConfinedToOneCorner() throws {
        let ghost = try XCTUnwrap(promotableGhostCells(outOf: 40))
        let halfSpan = Float(Thresholds.minHorizontalExtentM) * 0.3
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: 40 - ghost, ghost: ghost, unvisited: 0, pairs: amplePairs(),
                                halfSpanM: halfSpan))

        XCTAssertLessThan(report.horizontalExtentM, Thresholds.minHorizontalExtentM)
        XCTAssertGreaterThanOrEqual(report.lambdaRatio, Thresholds.minLambdaRatio,
                                    "the spread must stay 3-D so extent is provably the only refusal")
        XCTAssertLessThanOrEqual(report.inlierRMSMetres, Thresholds.maxInlierRMSM)

        XCTAssertEqual(report.decision, .rebaseline)
        XCTAssertEqual(report.drivers, [Driver.changeStale, Driver.fitExtentLow])
    }

    /// A changed room whose agreeing evidence is room-wide but flat — every retained feature on the
    /// floor. The horizontal span is fine; λ-ratio is what refuses.
    func testDecision_rebaseline_whenTheAgreementIsFlat() throws {
        let ghost = try XCTUnwrap(promotableGhostCells(outOf: 40))
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: 40 - ghost, ghost: ghost, unvisited: 0, pairs: amplePairs(),
                                heightM: 0.05))

        XCTAssertLessThan(report.lambdaRatio, Thresholds.minLambdaRatio)
        XCTAssertGreaterThanOrEqual(report.horizontalExtentM, Thresholds.minHorizontalExtentM)
        XCTAssertLessThanOrEqual(report.inlierRMSMetres, Thresholds.maxInlierRMSM)

        XCTAssertEqual(report.decision, .rebaseline)
        XCTAssertEqual(report.drivers, [Driver.changeStale, Driver.fitLambdaLow])
    }

    /// Most of what was revisited is gone, and the revisit itself was thin. The fit is perfect, so
    /// coverage is provably the only refusal: a partial look at a changed room cannot be the next
    /// baseline. (Under the feature proxy ghosts are uncovered cells by definition, which is why this
    /// fixture moves staleness and coverage together.)
    func testDecision_rebaseline_whenTheChangedRoomCameBackThin() throws {
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: 20, ghost: 20, unvisited: 0, pairs: amplePairs()))

        XCTAssertLessThan(report.coverageFraction, Thresholds.minCoverage)
        XCTAssertGreaterThan(report.staleFraction, Thresholds.changeStaleFraction)
        assertFitQualifies(report)

        XCTAssertEqual(report.decision, .rebaseline)
        XCTAssertEqual(report.drivers, [Driver.changeStale, Driver.coverageThin])
    }

    // MARK: No verdict

    func testDecision_insufficientData_whenTooFewPairsToJudge() throws {
        try XCTSkipIf(PromotionGate.Thresholds.minPairs < 1, "No pair floor to fall under.")
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: 40, ghost: 0, unvisited: 0,
                                pairs: PromotionGate.Thresholds.minPairs - 1))

        XCTAssertEqual(report.decision, .insufficientData,
                       "Geometry good enough to promote must still not be judged on too few pairs.")
        assertDrivers(report, mention: ["pair"])
    }

    /// Pairs enough to try, but geometrically degenerate: every retained feature lies on one line, so
    /// `RigidFit.ransac` rejects every minimal sample and reports no consensus. That is the absence
    /// of a measurement, not a bad measurement, so it reads `insufficientData` and says which branch
    /// it came from — distinct from the pair-floor case above, which shares the verdict.
    func testDecision_insufficientData_whenTheCorrespondencesAreGeometricallyDegenerate() throws {
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: 40, ghost: 0, unvisited: 0,
                                pairs: PromotionGate.Thresholds.minPairs + 1,
                                collinearPairs: true))

        XCTAssertGreaterThanOrEqual(report.pairCount, PromotionGate.Thresholds.minPairs,
                                    "this fixture must clear the pair floor or it tests the wrong branch")
        XCTAssertEqual(report.decision, .insufficientData)
        assertDrivers(report, mention: ["consensus", "ransac"])
        XCTAssertEqual(report.inlierFraction, 0.0, accuracy: 1e-9,
                       "no fit was obtained, so every fit-derived field must read zero rather than stale data")
        XCTAssertEqual(report.lambdaRatio, 0.0, accuracy: 1e-9)
        XCTAssertEqual(report.horizontalExtentM, 0.0, accuracy: 1e-9)
    }

    /// A link-adjacent scan deliberately relocalizes into the map of a DIFFERENT physical room in
    /// order to find its way to the boundary. Scored on these thresholds it would report REBASELINE
    /// on essentially every save, so the gate declines to have an opinion — but it still RECORDS the
    /// measurement, which is the half this test is really about.
    func testDecision_notApplicable_forLinkAdjacentProvenance() throws {
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: 40, ghost: 0, unvisited: 0,
                                pairs: PromotionGate.Thresholds.minPairs + 1,
                                scanCase: .linkAdjacent))

        XCTAssertEqual(report.decision, .notApplicable)
        assertDrivers(report, mention: ["adjacent", "provenance", "scan case", "scancase"])
    }

    /// The suppression is of the VERDICT, not of the MEASUREMENT: a `notApplicable` report must carry
    /// exactly the same numbers its `rescanSpace` twin does, or the shadow period collects nothing
    /// about the Connect-Adjacent flow.
    func testNotApplicable_stillCarriesEveryMetric() throws {
        let pairs = PromotionGate.Thresholds.minPairs + 1
        let rescan = PromotionGate.evaluate(
            makeCorrespondences(covered: 30, ghost: 6, unvisited: 4, pairs: pairs))
        let linked = PromotionGate.evaluate(
            makeCorrespondences(covered: 30, ghost: 6, unvisited: 4, pairs: pairs,
                                scanCase: .linkAdjacent))

        XCTAssertEqual(linked.decision, .notApplicable)
        XCTAssertNotEqual(rescan.decision, .notApplicable)

        XCTAssertEqual(linked.pairCount, rescan.pairCount)
        XCTAssertEqual(linked.freshCount, rescan.freshCount)
        XCTAssertEqual(linked.coverageFraction, rescan.coverageFraction, accuracy: 1e-12)
        XCTAssertEqual(linked.staleFraction, rescan.staleFraction, accuracy: 1e-12)
        XCTAssertEqual(linked.inlierFraction, rescan.inlierFraction, accuracy: 1e-12)
        XCTAssertEqual(linked.inlierRMSMetres, rescan.inlierRMSMetres, accuracy: 1e-12)
        XCTAssertEqual(linked.lambdaRatio, rescan.lambdaRatio, accuracy: 1e-12)
        XCTAssertEqual(linked.horizontalExtentM, rescan.horizontalExtentM, accuracy: 1e-12)
        XCTAssertEqual(linked.verticalExtentM, rescan.verticalExtentM, accuracy: 1e-12)
        XCTAssertGreaterThan(linked.inlierFraction, 0,
                             "the fit must still run when the verdict is suppressed")
    }

    // MARK: - 4. The pair floor, read off the constant

    func testPairFloor_justUnderIsInsufficient_justOverIsARealVerdict() throws {
        let minPairs = PromotionGate.Thresholds.minPairs
        try XCTSkipIf(minPairs < 1, "No pair floor to straddle.")

        let under = PromotionGate.evaluate(
            makeCorrespondences(covered: 40, ghost: 0, unvisited: 0, pairs: minPairs - 1))
        XCTAssertEqual(under.decision, .insufficientData)
        XCTAssertEqual(under.pairCount, minPairs - 1)

        let over = PromotionGate.evaluate(
            makeCorrespondences(covered: 40, ghost: 0, unvisited: 0, pairs: minPairs + 1))
        XCTAssertNotEqual(over.decision, .insufficientData,
                          "One pair past the floor the gate must commit to a real verdict.")
        XCTAssertEqual(over.pairCount, minPairs + 1)
    }

    // MARK: - 5. Report serialization

    func testReport_roundTripsFieldByField() throws {
        let original = PromotionGate.evaluate(
            makeCorrespondences(covered: 30, ghost: 3, unvisited: 7,
                                pairs: PromotionGate.Thresholds.minPairs + 5))
        let encoded = try XCTUnwrap(original.encoded(), "the gate must be able to encode its own report")
        let decoded = try XCTUnwrap(PromotionGate.Report.decode(encoded),
                                    "A report this gate just wrote must decode.")

        XCTAssertEqual(decoded.version, original.version)
        XCTAssertEqual(decoded.version, PromotionGate.Report.schemaVersion)
        XCTAssertEqual(decoded.decision, original.decision)
        XCTAssertEqual(decoded.drivers, original.drivers)
        XCTAssertEqual(decoded.pairCount, original.pairCount)
        XCTAssertEqual(decoded.coverageFraction, original.coverageFraction, accuracy: 1e-12)
        XCTAssertEqual(decoded.staleFraction, original.staleFraction, accuracy: 1e-12)
        XCTAssertEqual(decoded.inlierFraction, original.inlierFraction, accuracy: 1e-12)
        XCTAssertEqual(decoded.inlierRMSMetres, original.inlierRMSMetres, accuracy: 1e-12)
        XCTAssertEqual(decoded.fitOffsetMetres, original.fitOffsetMetres, accuracy: 1e-12)
        XCTAssertEqual(decoded.fitRotationDegrees, original.fitRotationDegrees, accuracy: 1e-12)

        // Catches every field the list above does not name — extents included — without this test
        // having to know their spelling or type.
        let reEncoded = try XCTUnwrap(decoded.encoded())
        XCTAssertEqual(try jsonObject(encoded) as? NSDictionary,
                       try jsonObject(reEncoded) as? NSDictionary,
                       "Some field did not survive the round trip.")
    }

    /// Every report today is scored from the feature-point proxy, and must say so: the calibration
    /// dataset gets partitioned on this field once sweep-derived coverage exists.
    func testReport_stampsTheFeatureProxyAsItsCoverageSource() throws {
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: 30, ghost: 3, unvisited: 7,
                                pairs: PromotionGate.Thresholds.minPairs + 5))
        XCTAssertEqual(report.coverageSource, PromotionGate.Report.coverageSourceFeatureProxy)
        XCTAssertTrue(report.logLine().contains("space(featureProxy)"),
                      "the log line must carry the source alongside the numbers it qualifies")
        let decoded = try XCTUnwrap(PromotionGate.Report.decode(try XCTUnwrap(report.encoded())))
        XCTAssertEqual(decoded.coverageSource, report.coverageSource)
    }

    /// `load(from:)` is the path the calibration tooling actually uses; it must agree with `decode`.
    func testReport_roundTripsThroughAFileOnDisk() throws {
        let original = PromotionGate.evaluate(
            makeCorrespondences(covered: 30, ghost: 3, unvisited: 7,
                                pairs: PromotionGate.Thresholds.minPairs + 5))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("PromotionGateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent(PromotionGate.filename)
        try XCTUnwrap(original.encoded()).write(to: url)

        let loaded = try XCTUnwrap(PromotionGate.Report.load(from: url))
        XCTAssertEqual(loaded.decision, original.decision)
        XCTAssertEqual(loaded.drivers, original.drivers)
        XCTAssertEqual(loaded.coverageFraction, original.coverageFraction, accuracy: 1e-12)

        XCTAssertNil(PromotionGate.Report.load(from: dir.appendingPathComponent("absent.json")),
                     "a missing sidecar is nil, not a crash")
    }

    func testReport_withAMismatchedSchemaVersion_isRejected() throws {
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: 30, ghost: 0, unvisited: 0,
                                pairs: PromotionGate.Thresholds.minPairs + 1))
        let encoded = try XCTUnwrap(report.encoded())
        var json = try XCTUnwrap(try jsonObject(encoded) as? [String: Any],
                                 "The report must encode as a JSON object.")

        let versionKey = try XCTUnwrap(["version", "schemaVersion"].first { json[$0] != nil },
                                       "The report must record the schema version it was written at.")
        json[versionKey] = PromotionGate.Report.schemaVersion + 1
        let bumped = try JSONSerialization.data(withJSONObject: json)

        XCTAssertNil(PromotionGate.Report.decode(bumped),
                     "A report from a schema this build does not understand must be refused, not half-read.")
    }

    /// The report is a diagnostic that travels — it must describe SHAPE and PROPORTION, never where
    /// in the world the user was. Extents and fractions survive; centroids, origins and positions do
    /// not.
    func testReport_carriesNoWorldFramePosition() throws {
        let report = PromotionGate.evaluate(
            makeCorrespondences(covered: 30, ghost: 3, unvisited: 7,
                                pairs: PromotionGate.Thresholds.minPairs + 5))
        let keys = allKeys(in: try jsonObject(try XCTUnwrap(report.encoded())))

        let banned = ["centroid", "centre", "center", "origin", "position", "translat", "anchor"]
        for key in keys {
            let lower = key.lowercased()
            for token in banned {
                XCTAssertFalse(lower.contains(token),
                               "Report field '\(key)' looks like a world-frame location.")
            }
            XCTAssertFalse(["x", "y", "z", "min", "max", "bbox"].contains(lower),
                           "Report field '\(key)' looks like a world-frame corner.")
        }

        XCTAssertTrue(keys.contains { k in ["extent", "span", "size"].contains { k.lowercased().contains($0) } },
                      "Extents are what the report is allowed to say about size — it should say it.")
    }

    // MARK: - 6. Temp file placement

    private func mapURL(_ dir: String, _ stem: String) -> URL {
        URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("\(stem).worldmap")
    }

    func testTempURL_isDerivedFromTheMapStem() {
        let map = mapURL("/var/tmp/scan", "worldmap_a1b2c3d4")
        let temp = PromotionGate.tempURL(besideWorldMap: map)

        XCTAssertEqual(temp.deletingPathExtension().lastPathComponent, "worldmap_a1b2c3d4")
        XCTAssertEqual(temp.pathExtension, PromotionGate.tempExtension)
    }

    func testTempURL_sitsInTheMapsOwnDirectory() {
        let map = mapURL("/var/tmp/scan/session-7", "worldmap_a1b2c3d4")
        let temp = PromotionGate.tempURL(besideWorldMap: map)

        XCTAssertEqual(temp.deletingLastPathComponent().path,
                       map.deletingLastPathComponent().path)
    }

    /// The reason the name is derived rather than fixed: two in-flight saves must not be able to hand
    /// each other's quality report to `saveScan`, which promotes the file by name.
    func testTempURL_differentMapsNeverShareAPath() {
        let a = PromotionGate.tempURL(besideWorldMap: mapURL("/var/tmp/scan", "worldmap_a1b2c3d4"))
        let b = PromotionGate.tempURL(besideWorldMap: mapURL("/var/tmp/scan", "worldmap_99887766"))

        XCTAssertNotEqual(a.path, b.path)
    }

    /// Same stem, different directories — still distinct, because the derivation keeps the map's
    /// whole location and not just its name.
    func testTempURL_sameStemInDifferentDirectoriesStaysDistinct() {
        let a = PromotionGate.tempURL(besideWorldMap: mapURL("/var/tmp/scan/one", "worldmap_a1b2c3d4"))
        let b = PromotionGate.tempURL(besideWorldMap: mapURL("/var/tmp/scan/two", "worldmap_a1b2c3d4"))

        XCTAssertNotEqual(a.path, b.path)
    }

    // MARK: - Fixtures

    /// SplitMix64, so a failure reproduces from the test name alone.
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

    /// How the disagreeing share of a `fitPairs` cloud disagrees.
    private enum Disagreement {
        /// Each disagreeing pair displaced 0.3–1.5 m in its own direction: no rival consensus.
        case scattered
        /// Every disagreeing pair is part of one couch-sized cluster moved rigidly by ~1.2 m — what a
        /// rearranged room looks like. It IS a rival consensus, just a smaller one than the room.
        case movedCluster
    }

    /// Room-sized `(baseline, current)` correspondences under a known small rigid transform — the
    /// registration half of a fixture, independent of the occupancy half.
    ///
    /// - `disagreeingFraction` of the pairs disagree with that transform, as `disagreement` says.
    ///   They are interleaved, not appended, so an estimator that assumed outliers were contiguous
    ///   would fail here.
    /// - `noiseM` adds per-axis uniform noise in `±noiseM` to every AGREEING pair's current end: the
    ///   inlier RMS becomes ≈ `noiseM`, and the worst residual ≈ `noiseM·√3`.
    /// - `halfSpanM` / `heightM` size the room the agreeing pairs are drawn from (x, z in
    ///   `±halfSpanM`, y in `0...heightM`).
    /// - `collinear` puts every baseline point on one line, which is what `RigidFit.ransac` refuses
    ///   (zero triangle area in every minimal sample).
    ///
    /// Every option at its default draws exactly the random sequence it always did, so fixtures that
    /// predate an option are unaffected by it.
    private func fitPairs(count: Int,
                          disagreeingFraction: Double,
                          disagreement: Disagreement = .scattered,
                          noiseM: Float = 0,
                          halfSpanM: Float = 2.5,
                          heightM: Float = 3,
                          collinear: Bool,
                          seed: UInt64) -> [(SIMD3<Float>, SIMD3<Float>)] {
        var rng = SeededGenerator(seed: seed)
        let angle: Float = 3 * .pi / 180
        let c: Float = cos(angle)
        let sn: Float = sin(angle)
        let rotation = simd_float3x3(SIMD3<Float>(c, 0, -sn),
                                     SIMD3<Float>(0, 1, 0),
                                     SIMD3<Float>(sn, 0, c))
        let translation = SIMD3<Float>(0.15, 0.02, -0.08)

        // The moved couch: a 1.4 × 0.9 × 0.9 m block in one corner of the default room, slid 1.2 m
        // along −x and 0.3 m along −z. Far beyond the inlier radius, so none of it can join the
        // room's consensus.
        let couchMin = SIMD3<Float>(0.8, 0, 1.4)
        let couchSize = SIMD3<Float>(1.4, 0.9, 0.9)
        let couchShift = SIMD3<Float>(-1.2, 0, -0.3)

        // Disagreeing indices are picked by `(i * 3) % 10`, which permutes the residues of each block
        // of ten, so the set is scattered through the array rather than being a contiguous run. An
        // estimator that assumed outliers were contiguous, or that classified by array position,
        // would fail on this.
        let disagreeingPerTen = Int((disagreeingFraction * 10).rounded())

        var pairs: [(SIMD3<Float>, SIMD3<Float>)] = []
        pairs.reserveCapacity(count)
        for i in 0..<count {
            let disagrees = (i * 3) % 10 < disagreeingPerTen

            if disagrees && disagreement == .movedCluster {
                let baseline = couchMin + SIMD3<Float>(Float.random(in: 0...1, using: &rng),
                                                       Float.random(in: 0...1, using: &rng),
                                                       Float.random(in: 0...1, using: &rng)) * couchSize
                pairs.append((baseline, rotation * baseline + translation + couchShift))
                continue
            }

            let baseline: SIMD3<Float>
            if collinear {
                baseline = SIMD3<Float>(-2.5 + Float(i) * 0.02, 1.0, 0.5)
            } else {
                let x = Float.random(in: -halfSpanM...halfSpanM, using: &rng)
                let y = Float.random(in: 0...heightM, using: &rng)
                let z = Float.random(in: -halfSpanM...halfSpanM, using: &rng)
                baseline = SIMD3<Float>(x, y, z)
            }
            var current: SIMD3<Float> = rotation * baseline + translation
            if disagrees {
                let dx = Float.random(in: -1...1, using: &rng)
                let dy = Float.random(in: -1...1, using: &rng)
                let dz = Float.random(in: -1...1, using: &rng)
                var direction = SIMD3<Float>(dx, dy, dz)
                if simd_length_squared(direction) < 1e-6 { direction = SIMD3<Float>(1, 0, 0) }
                let magnitude = Float.random(in: 0.3...1.5, using: &rng)
                current += simd_normalize(direction) * magnitude
            } else if noiseM > 0 {
                current += SIMD3<Float>(Float.random(in: -noiseM...noiseM, using: &rng),
                                        Float.random(in: -noiseM...noiseM, using: &rng),
                                        Float.random(in: -noiseM...noiseM, using: &rng))
            }
            pairs.append((baseline, current))
        }
        return pairs
    }

    /// Builds correspondences whose coverage, staleness and fit are each exactly what the call asks
    /// for.
    ///
    /// **Occupancy half** — three bands, kept far enough apart in z that no band's fresh points can
    /// reach into another's 26-neighbourhoods:
    ///
    /// * `covered` — one baseline point and one fresh point per cell.
    /// * `ghost` — one baseline point per cell, with the fresh point one cell diagonally away so the
    ///   cell reads as revisited-and-empty.
    /// * `unvisited` — one baseline point per cell and no fresh point anywhere near.
    ///
    /// So `coverage = covered / (covered + ghost + unvisited)` and `stale = ghost / (ghost + covered)`.
    ///
    /// **Registration half** — a separate room-sized cloud from `fitPairs`, deliberately NOT folded
    /// into `baselinePositions` or `freshPoints`. `evaluate` reads the pair list and the two occupancy
    /// clouds through completely disjoint code paths, and mixing them would make the coverage and
    /// staleness fractions above impossible to state by hand: every pair position would add cells to
    /// the occupancy denominator. Keeping them apart is what lets each test move one variable.
    private func makeCorrespondences(covered: Int,
                                     ghost: Int,
                                     unvisited: Int,
                                     pairs: Int,
                                     disagreeingFraction: Double = 0,
                                     disagreement: Disagreement = .scattered,
                                     noiseM: Float = 0,
                                     halfSpanM: Float = 2.5,
                                     heightM: Float = 3,
                                     collinearPairs: Bool = false,
                                     scanCase: ScanCase = .rescanSpace) -> FeaturePointDiff.Correspondences {
        var baseline: [SIMD3<Float>] = []
        var fresh: [SIMD3<Float>] = []

        let coveredPoints = (0..<covered).map { centre($0 * 2, 0, 0) }
        baseline += coveredPoints
        fresh += coveredPoints.map { $0 + SIMD3(0.2 * s, 0, 0) }

        for n in 0..<ghost {
            baseline.append(centre(n * 3, 0, 100))
            fresh.append(centre(n * 3 + 1, 1, 100))      // corner neighbour: revisited, empty
        }

        for n in 0..<unvisited {
            baseline.append(centre(n * 2, 0, 200))
        }

        let pairList = pairs > 0
            ? fitPairs(count: pairs, disagreeingFraction: disagreeingFraction,
                       disagreement: disagreement, noiseM: noiseM,
                       halfSpanM: halfSpanM, heightM: heightM,
                       collinear: collinearPairs, seed: 0x9A7E_0001)
            : []

        return FeaturePointDiff.Correspondences(
            baselineName: "synthetic",
            baselineMapPath: "/var/tmp/scan/worldmap_a1b2c3d4.worldmap",
            scanCase: scanCase.rawValue,
            baselinePointCount: baseline.count,
            currentCount: pairList.count + fresh.count,
            pairs: pairList,
            freshPoints: fresh,
            baselinePositions: baseline)
    }

    // MARK: - Fixture sizing, read off the thresholds

    /// A pair count whose AGREEING share clears `minInlierCount` with a quarter to spare (and clears
    /// the pair floor), so a fixture that wants a qualifying fit is not one recalibration away from
    /// testing the count instead.
    private func amplePairs(disagreeingFraction: Double = 0) -> Int {
        let needed = Double(Thresholds.minInlierCount) * 1.25 / (1 - disagreeingFraction)
        return max(Thresholds.minPairs + 1, Int(needed.rounded(.up)))
    }

    /// Per-axis noise half-width that keeps every agreeing pair inside the inlier radius (worst case
    /// `noise·√3`, the corner of the noise cube) while pushing the inlier RMS (≈ `noise`) over its
    /// cap — the midpoint of that window, or nil if recalibration has closed it.
    private var looseFitNoiseM: Float? {
        let rmsCap = Float(Thresholds.maxInlierRMSM)
        let ceiling = Thresholds.inlierDistanceM / Float(3).squareRoot()
        guard rmsCap < ceiling else { return nil }
        return (rmsCap + ceiling) / 2
    }

    /// Ghost cells, out of `total` covered-or-ghost cells, putting staleness over the change trigger
    /// while leaving coverage at or over `minCoverage`. Under the fixture's occupancy model those two
    /// move together (`stale = ghost/total`, `coverage = 1 − stale`), so the window is
    /// `(changeStaleFraction, 1 − minCoverage]`; this aims at its middle, or returns nil if
    /// recalibration has closed it.
    private func promotableGhostCells(outOf total: Int) -> Int? {
        let target = (Thresholds.changeStaleFraction + (1 - Thresholds.minCoverage)) / 2
        let ghost = Int((target * Double(total)).rounded())
        let stale = Double(ghost) / Double(total)
        guard stale > Thresholds.changeStaleFraction, 1 - stale >= Thresholds.minCoverage else { return nil }
        return ghost
    }

    /// The fit's inlier count, recovered from the two report fields that determine it. The report
    /// carries no count field of its own; the GATE reads `RigidFit.Result.inlierCount` directly.
    private func inlierCount(_ report: PromotionGate.Report) -> Int {
        Int((Double(report.pairCount) * report.inlierFraction).rounded())
    }

    // MARK: - Driver vocabulary
    //
    // Spelled out literally, not rebuilt from the gate's own helper: these strings are what a
    // calibration pass will group sidecars on, so changing one is a change to a contract and should
    // have to change here too.

    private enum Driver {
        static let quietFraction = "change:inlierFraction>=changeInlierFraction"
        static let quietStale = "change:staleFraction<=changeStaleFraction"
        static let changeFraction = "change:inlierFraction<changeInlierFraction"
        static let changeStale = "change:staleFraction>changeStaleFraction"

        static let fitCountOK = "fit:inlierCount>=minInlierCount"
        static let fitCountLow = "fit:inlierCount<minInlierCount"
        static let fitRMSOK = "fit:inlierRMSMetres<=maxInlierRMSM"
        static let fitRMSHigh = "fit:inlierRMSMetres>maxInlierRMSM"
        static let fitLambdaOK = "fit:lambdaRatio>=minLambdaRatio"
        static let fitLambdaLow = "fit:lambdaRatio<minLambdaRatio"
        static let fitExtentOK = "fit:horizontalExtentM>=minHorizontalExtentM"
        static let fitExtentLow = "fit:horizontalExtentM<minHorizontalExtentM"

        static let coverageOK = "coverage:coverageFraction>=minCoverage"
        static let coverageThin = "coverage:coverageFraction<minCoverage"

        /// Every eligibility check, held, in the order a PROMOTE lists them.
        static let allEligible = [fitCountOK, fitRMSOK, fitLambdaOK, fitExtentOK, coverageOK]
    }

    // MARK: - Assertion helpers

    /// The report has to say WHICH threshold produced the decision — a bare verdict is not actionable
    /// and cannot be tuned. Any one of `tokens` appearing in any driver satisfies it.
    private func assertDrivers(_ report: PromotionGate.Report,
                               mention tokens: [String],
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertFalse(report.drivers.isEmpty, "\(report.decision) named no driver.", file: file, line: line)
        let joined = report.drivers.joined(separator: " | ").lowercased()
        XCTAssertTrue(tokens.contains { joined.contains($0.lowercased()) },
                      "drivers \(report.drivers) name none of \(tokens) for decision \(report.decision).",
                      file: file, line: line)
    }

    /// Every fit-qualification check holds — the fixture's fit is one the gate would trust.
    private func assertFitQualifies(_ report: PromotionGate.Report,
                                    _ message: String = "the fit must qualify for this fixture to test what it names",
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(inlierCount(report), Thresholds.minInlierCount, message, file: file, line: line)
        XCTAssertLessThanOrEqual(report.inlierRMSMetres, Thresholds.maxInlierRMSM, message, file: file, line: line)
        XCTAssertGreaterThanOrEqual(report.lambdaRatio, Thresholds.minLambdaRatio, message, file: file, line: line)
        XCTAssertGreaterThanOrEqual(report.horizontalExtentM, Thresholds.minHorizontalExtentM, message,
                                    file: file, line: line)
    }

    private func jsonObject(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Every key anywhere in the encoded report, nested containers included.
    private func allKeys(in object: Any) -> [String] {
        switch object {
        case let dict as [String: Any]:
            return Array(dict.keys) + dict.values.flatMap { allKeys(in: $0) }
        case let array as [Any]:
            return array.flatMap { allKeys(in: $0) }
        default:
            return []
        }
    }
}
