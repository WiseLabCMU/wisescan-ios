import Foundation
import simd

// ============================================================================================
//  ⚠️  SHADOW MODE — THIS FILE DECIDES NOTHING  ⚠️
//
//  `PromotionGate.Decision` exists to be LOGGED and PERSISTED. Nothing in the app may read it
//  to change behaviour: not the save path, not the relocalization-target selection, not the
//  export gate, not the UI. There is no `if decision == .promote` anywhere outside this file,
//  and there must not be one until the thresholds below stop being guesses.
//
//  The reason is in `Thresholds`: every number in it was picked by argument, not measured. The
//  whole point of the shadow period is to accumulate `reloc_quality.json` sidecars from real
//  scans in real rooms and *then* set the numbers from that distribution. A gate wired live on
//  provisional thresholds would silently start rebaselining (or refusing to) in rooms nobody
//  has looked at, and the resulting dataset would be a record of the gate's own behaviour
//  rather than of the rooms — which is exactly the measurement we are trying to take.
//
//  If you are here to wire this into a behaviour change: the prerequisite is a calibration
//  pass over collected sidecars, not a code review of this file.
// ============================================================================================

/// Shadow-mode quality assessment of a relocalization against the map it relocalized into.
///
/// One `Report` is produced per save that loaded a world map, written beside the map as
/// `reloc_quality.json`, and summarised into one `[PromoGate]` line. It answers a single question
/// in numbers: *is the baseline map still a good frame to keep relocalizing into, or has the room
/// changed / the map decayed enough that a fresh baseline would serve better?*
///
/// Input is `FeaturePointDiff.Correspondences` — the baseline/current feature correspondences
/// `LocalizationDiag` already extracts at save. Scoring splits in two:
///
/// * **the rigid fit** — `RigidFit.ransac` over the id-matched pairs, which reports how much of the
///   old geometry the new session still agrees with, how tightly, and how well-spread the agreeing
///   evidence was. `RigidFit` deliberately reports raw scalars and no verdicts; every accept/reject
///   number for it lives in `Thresholds` here.
/// * **occupancy** — `coverageFraction` and `staleFraction`, which ask the complementary question
///   the pairs cannot: not "does the retained geometry still line up" but "did this session go back
///   and look, and did what it saw still contain what the map claims is there".
///
/// Deliberately free of ARKit and RealityKit imports (Foundation + simd only) so it is testable in
/// the Simulator, and free of `PerfDiag` calls so it has no logging side effects — `logLine()`
/// RETURNS the string and the caller decides whether to log it.
///
/// Explicitly `nonisolated` (the project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`): without
/// it every entry point would be main-actor-isolated and unreachable from the `getCurrentWorldMap`
/// callback queue, where this is scored. Same reason `RigidFit` and `WorldMapCache` are spelled
/// `nonisolated`.
nonisolated enum PromotionGate {

    // MARK: - Sidecar naming

    /// Filename inside a scan directory / exported bundle.
    static let filename = "reloc_quality.json"

    /// Extension for the pre-promotion temp file written next to the world map.
    static let tempExtension = "relocq"

    /// Temp URL for the quality report belonging to the scan whose world map is `mapURL`:
    /// `worldmap_<8hex>.relocq` beside `worldmap_<8hex>.worldmap`.
    ///
    /// The name is derived, never fixed. `saveScan` promotes this file *by name*, so a fixed name
    /// in the temp root would let two in-flight saves (or a retried export) silently attach scan
    /// A's quality report to scan B's bundle.
    static func tempURL(besideWorldMap mapURL: URL) -> URL {
        mapURL.deletingPathExtension().appendingPathExtension(tempExtension)
    }

    /// Edge length of the occupancy cells, in metres. The single definition is
    /// `Thresholds.voxelM`; this is the spelling the rest of the app and the tests read it by, so
    /// that recalibrating the bin size is still a one-line edit in `Thresholds`.
    static var cellSizeM: Float { Thresholds.voxelM }

    // MARK: - Thresholds

    /// **The one place every number in this gate lives.** Nothing below appears as a literal
    /// anywhere else in this file, and nothing outside this file may hard-code an equivalent.
    /// `RigidFit` holds none of its own — it reports raw scalars precisely so that all policy sits
    /// here and a tuning change cannot silently rewrite what "a fit" means.
    ///
    /// **Every constant here is PROVISIONAL and UNCALIBRATED.** Unlike `LocalizationDiag.BakeGate`
    /// — whose values were moved by specific device sessions, and whose comments name them — not
    /// one number below has been confronted with a real scan. They were chosen so the gate is
    /// *legible* during the shadow period (roughly: a clean rescan of an unchanged room should read
    /// PROMOTE, a rearranged room should read REBASELINE), not because any of them sits at a
    /// measured accept/reject boundary.
    ///
    /// Each constant is annotated with **what field data would revise it**. The shape of that data
    /// is the same in every case: a population of `reloc_quality.json` sidecars, each labelled by
    /// hand with what the room actually was (unchanged / lightly rearranged / substantially changed
    /// / different room), so the threshold can be placed in the gap between labels rather than in
    /// the middle of one. Follow `BakeGate.minHorizMinObs`'s precedent (0.2 → 0.5 from one
    /// elongated-desk-room session): a threshold moves when a *named* session shows it in the wrong
    /// place, and the comment records which session.
    ///
    /// **Do not freeze any of these from one space or one device class.** The plan's own caveat for
    /// the ICP threshold applies verbatim: capture across 2–3 spaces and both shipping device
    /// classes (iPad + iPhone Pro) first, or the numbers over-fit the room they were collected in.
    /// Feature density differs enough between the two LiDAR classes that a pair-count or coverage
    /// threshold tuned on one can be structurally unreachable on the other.
    enum Thresholds {

        // MARK: Fit (RANSAC) parameters

        /// Residual (m) under which a correspondence counts as a RANSAC inlier. 0.05 provisional,
        /// borrowed from `FeaturePointDiff`'s 5 cm spatial-fallback radius and from the observed
        /// per-approach seating ε of ~5–7 cm — i.e. deliberately just wide enough to swallow the
        /// honest seat error, so the inlier/outlier split reflects *scene change* rather than ε.
        ///
        /// Revised by: the distribution of per-pair residuals on scans hand-labelled "unchanged
        /// room". If that distribution's p95 sits well under 5 cm, tighten until `inlierFraction`
        /// starts separating unchanged from rearranged rooms; if it straddles 5 cm, retained
        /// feature drift is itself the noise floor and this must widen instead.
        static let inlierDistanceM: Float = 0.05

        /// RANSAC iteration budget. 256 provisional — enough for a high inlier ratio at a 3-point
        /// minimal sample, and small enough to stay off the critical path of a save.
        ///
        /// Revised by: measured wall-clock of `evaluate` on the largest real maps (the gen-8 lesson
        /// — an "inert" probe that pegs a core is not inert), together with whether runs on the
        /// same input at different seeds agree on `inlierFraction`. Seed disagreement means the
        /// budget is too small for the real inlier ratio; a budget costing more than a few tens of
        /// ms at save means it is too large.
        static let ransacIterations = 256

        /// Fixed RANSAC seed. **Deliberately a literal, not `Date()`/`random()`**: during the
        /// shadow period the same inputs must produce the same report, or a sidecar cannot be
        /// re-derived from a re-run and the calibration dataset stops being reproducible.
        /// `RigidFit` seeds a private SplitMix64 from it for the same reason.
        ///
        /// Revised by: nothing about the rooms. This changes only if the calibration pass needs a
        /// seed *sweep* to measure run-to-run variance, and even then it stays a fixed list of
        /// literals rather than becoming nondeterministic.
        static let ransacSeed: UInt64 = 0x5F3B_1A27_C4D9_0E61

        /// Minimum id-matched correspondences before a verdict is meaningful at all. 200
        /// provisional — an order of magnitude below `BakeGate.minCorrespondences` (400), because
        /// that gate protects a transform that gets *baked into geometry* while this one only
        /// labels a run.
        ///
        /// Revised by: the pair-count distribution across successful relocalizations on both device
        /// classes. Place this below the low tail of runs a human calls "relocalized fine" — its
        /// job is to catch the run that never localized, not to be a quality bar. If real
        /// iPhone-class runs routinely land under 200, this is too high and the `insufficientData`
        /// bucket will eat the dataset.
        static let minPairs = 200

        // MARK: Spatial binning

        /// Edge length (m) of the occupancy cells behind `coverageFraction` and `staleFraction`.
        /// 0.5 provisional, matching `LocalizationDiag.icpGridCell` — coarse enough that a
        /// half-metre of relocalization error does not read as a missing cell, fine enough that a
        /// piece of furniture occupies more than one cell.
        ///
        /// Revised by: sensitivity of coverage/staleness to this value on the same recorded scans
        /// (re-run the sidecar offline at 0.25 / 0.5 / 1.0 m). Pick the size at which the
        /// unchanged-room and changed-room populations separate most; if none does, the occupancy
        /// framing is wrong and the metric needs replacing, not retuning.
        static let voxelM: Float = 0.5

        // MARK: Promote side — ALL must hold

        /// Fraction of correspondences the rigid fit must explain. 0.70 provisional.
        ///
        /// This is deliberately *not* `BakeGate`'s philosophy, and the difference is the point.
        /// `BakeGate` refuses to trust inlier fraction, because there a low fraction means low
        /// overlap and the 4D contract says a low-overlap scan must still register on the surviving
        /// scaffold. Here fraction IS the signal — it is the change metric the plan reserves it
        /// for: a pair whose two endpoints disagree after the best rigid fit is a feature the room
        /// *moved*.
        ///
        /// Revised by: `inlierFraction` on hand-labelled unchanged rooms (should cluster high)
        /// against rearranged rooms. Set this in the gap. If there is no gap, the id-matched pair
        /// set is dominated by structure that never moves (floor, walls) and the metric needs
        /// restricting to non-structural features before it can carry a threshold.
        static let minInlierFraction: Double = 0.70

        /// RMS residual (m) over the inliers. 0.02 provisional — tighter than
        /// `BakeGate.maxFinalRMS` (0.06) and `PlaneRegistration.Gate.maxFinalRMS` (0.05), because
        /// those measure mesh/plane fits against lumpy surfaces while this measures *the same ARKit
        /// feature point* seen twice, which should agree far more tightly than a surface.
        ///
        /// Revised by: the inlier-RMS distribution on unchanged rooms. `[FeatDiff]`'s existing 1 cm
        /// drift bucket (`>1cm=N` over retained points) is the direct precursor measurement — if
        /// median retained drift is itself ~2 cm, this threshold sits under the noise floor and
        /// nothing will ever promote.
        static let maxInlierRMSM: Double = 0.02

        /// λ_min/λ_max of the covariance of the inlier baseline positions — how
        /// *three-dimensionally* the agreeing evidence is spread. 0.05 provisional, far looser than
        /// `PlaneRegistration.Gate.minWeakAxisFrac` (0.1) because that gate conditions a solve while
        /// this one only asks that the agreement is not confined to a single line or plane (one
        /// corridor wall, one desk row, one hover in place).
        ///
        /// Read it together with `minHorizontalExtentM`, never alone: `RigidFit.Conditioning`
        /// documents why a scale-free ratio cannot separate "hovered over half a square metre" from
        /// "walked a genuinely long thin corridor", and the absolute extent is what separates them.
        ///
        /// Revised by: λratio on corridor/elongated spaces against ordinary rooms — the
        /// elongated-room session that moved `minHorizMinObs` is exactly the kind of data that sets
        /// this. Expect to raise it if corridor scans promote on evidence from one wall.
        static let minLambdaRatio: Double = 0.05

        /// Horizontal span (m) of the inlier baseline positions — the larger of their X and Z
        /// bounding-box spans, as `RigidFit.Conditioning` defines it. 3.0 provisional: about the
        /// short dimension of a small room, so agreement confined to one corner does not promote
        /// the whole map.
        ///
        /// Revised by: room sizes in the collected set. This is the constant most likely to be
        /// structurally wrong for small spaces (a 2.5 m bathroom can never satisfy it), so the
        /// first labelled small-room sidecar that reads HOLD purely on this should either lower it
        /// or replace it with a fraction of the baseline map's own extent.
        static let minHorizontalExtentM: Double = 3.0

        /// Fraction of baseline-occupied cells containing at least one FRESH point this session.
        /// 0.60 provisional — a rescan that re-observed most of the mapped volume.
        ///
        /// Revised by: coverage on scans the operator describes as "walked the whole room again"
        /// against "just re-did one side". Those two intents are the population this separates, and
        /// they are cheap to label at capture time. Note it is a *behaviour* metric as much as a
        /// room metric: it reads low on a short deliberate partial rescan of an unchanged room,
        /// which is why it is paired with staleness rather than used alone.
        static let minCoverage: Double = 0.60

        /// Ghost-candidate fraction (see `staleFraction`) above which the map is carrying too much
        /// unconfirmed structure to promote. 0.25 provisional.
        ///
        /// Revised by: staleness on unchanged rooms, which sets the floor this metric can reach at
        /// all. ARKit's own feature churn puts a non-zero floor under it; until that floor is
        /// measured, 0.25 is a guess at "a quarter of the map is suspect", not a calibrated line.
        static let maxStale: Double = 0.25

        // MARK: Degradation side — either condition rebaselines

        /// Inlier fraction below which the baseline is treated as no longer describing this room,
        /// rather than merely describing it imperfectly. 0.50 provisional — below
        /// `minInlierFraction` so there is a deliberate HOLD band (0.50–0.70) where the run is
        /// neither good enough to promote nor bad enough to abandon the baseline over.
        ///
        /// Revised by: whether the HOLD band is ever occupied in practice. If real scans pile up at
        /// the edges and the band is empty, the two constants should collapse into one; if
        /// everything lands in the band, the band is too wide.
        static let degradedInlierFraction: Double = 0.50

        /// Staleness above which — *combined with* coverage below `minCoverage` — the baseline is
        /// rebaselined. 0.40 provisional. The conjunction is the point: high staleness alone can
        /// mean "the operator only rescanned half the room", but high staleness *while* the
        /// revisited volume came back thin means the map is describing structure that is no longer
        /// there where the operator did look.
        ///
        /// Revised by: the joint (coverage, staleness) scatter over labelled scans — this is a 2-D
        /// decision boundary being approximated by an axis-aligned corner, and the scatter will
        /// show whether the corner is in the right place or whether the two metrics are correlated
        /// enough that only one is needed.
        static let degradedStale: Double = 0.40
    }

    // MARK: - Decision

    /// Shadow-mode verdict. **Read this to log it or store it; never to branch on it.** See the
    /// file header.
    enum Decision: String, Codable {
        /// Every promote-side threshold held: the baseline map still describes this room well.
        case promote
        /// Neither clean enough to promote nor degraded enough to abandon — the deliberate middle.
        case hold
        /// The baseline no longer describes what the device is seeing; a fresh baseline would serve
        /// better than continuing to relocalize into this one.
        case rebaseline
        /// The run never produced enough evidence to judge. Distinct from `hold`: `hold` is a
        /// measurement, this is the absence of one.
        case insufficientData
        /// The question does not apply to this capture flow. See the `linkAdjacent` branch in
        /// `evaluate`.
        case notApplicable
    }

    // MARK: - Report

    /// The persisted `reloc_quality.json` payload, and the source of the `[PromoGate]` log line.
    ///
    /// **PRIVACY — aggregate only.** Nothing here is a position. The repo treats a real feature
    /// cloud as a spatial record of someone's room (`scripts/check-privacy.sh`, and the
    /// `FeaturePointCloudFileTests` header spelling out why no captured cloud is committed), and
    /// this sidecar travels further than the cloud does — it is small, it is JSON, and it is
    /// exactly the kind of file that ends up pasted into an issue. So it carries **spans,
    /// fractions and counts, never a world-frame centroid, bounding-box corner, or raw point**.
    /// Extents are differences of coordinates: they say how big the overlap was without saying
    /// where on Earth it is.
    ///
    /// The same rule shapes two field names. `fitOffsetMetres` is a scalar magnitude, so it is
    /// safe — but it is not spelled `fitTranslation…`, because a reader scanning field names for
    /// anything location-shaped should not have to stop and reason about whether a "translation"
    /// is a vector. Any field added here has to pass the same test: could a reader locate the room
    /// from it, and does its *name* invite someone to put a position there later?
    struct Report: Codable {

        /// Schema version. Increment when the structure changes. `decode` REJECTS any version other
        /// than the current one rather than trying to read what it does not understand — the
        /// sidecar is cheap to regenerate offline from a recorded scan, and a half-understood
        /// report silently polluting the calibration dataset is the specific failure this exists to
        /// prevent. Mirrors `DerivedSurfacesData.schemaVersion`.
        static let schemaVersion = 1

        /// Plain-language statement of what "baseline" means in this file, carried IN the JSON so a
        /// consumer reading a sidecar months from now cannot mistake it.
        ///
        /// It says what it says because the tempting reading is the wrong one:
        /// `LocationDetailView.startRescan` sets `activeRelocalizationMap = latestScan.worldMapURL`
        /// — the PREVIOUS generation's saved map. Items 1.1/1.2 of
        /// `docs/design/fix-localization-plan.md` (add `canonicalScanId`; relocalize against the
        /// canonical scan's map instead of the latest) are **still unchecked**, so there is no fixed
        /// gen-0 reference in the app today. Consequently the word "canonical" appears in no JSON
        /// field name here and must not be introduced into one: a field called `canonicalMapName`
        /// would assert a property of the data that the save path does not provide, and every
        /// downstream analysis built on that assertion would be wrong about what it compared.
        static let baselineNote = """
            'baseline' here is the PREVIOUS generation's saved world map (the most recent scan of \
            this location), which is what the rescan flow loads to relocalize into. It is NOT a \
            fixed gen-0 or canonical reference map — the app has no canonical-scan selection yet. \
            Reports from successive generations of one location therefore compare against \
            DIFFERENT baselines, each one the generation before it; they are not measurements \
            against a common frame and must not be pooled as if they were.
            """

        let version: Int
        /// Copy of `baselineNote` at write time, so the file explains itself offline.
        let baselineNote: String

        // Provenance
        let baselineMapName: String
        let baselineMapPointCount: Int
        let currentMapPointCount: Int
        /// `ScanCase` raw value (`"RescanSpace"` / `"LinkAdjacent"`), carried as a string so a
        /// future case cannot make an old sidecar undecodable.
        let scanCase: String
        /// ISO-8601, UTC.
        let capturedAt: String

        // Correspondences
        let pairCount: Int
        /// `pairCount / baselineMapPointCount` — how much of the baseline map ARKit kept BY ID.
        let retainedFraction: Double
        /// Points in the current map with no baseline identifier.
        let freshCount: Int

        // Rigid fit over the correspondences (all zero when no fit was obtained — see `decision`)
        let inlierFraction: Double
        let inlierRMSMetres: Double
        /// Magnitude of the fit's offset, in metres. A scalar, never a vector — see the PRIVACY note.
        let fitOffsetMetres: Double
        let fitRotationDegrees: Double

        // Spread of the inlier evidence (spans only — see the PRIVACY note)
        let lambdaRatio: Double
        let horizontalExtentM: Double
        let verticalExtentM: Double

        // Occupancy
        let coverageFraction: Double
        let staleFraction: Double

        // Verdict
        let decision: Decision
        /// Names of the `Thresholds` constants (or the non-threshold cause) responsible for
        /// `decision` — on `promote` the ones that were satisfied, otherwise the ones that were
        /// not. Never empty: a bare verdict cannot be tuned, and the whole purpose of the shadow
        /// period is to learn which constant is doing the work.
        let drivers: [String]

        /// Encodes for writing to `filename` / `tempURL(besideWorldMap:)`.
        func encoded() -> Data? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try? encoder.encode(self)
        }

        /// Decodes a report, REJECTING any schema version other than the current one.
        static func decode(_ data: Data) -> Report? {
            guard let decoded = try? JSONDecoder().decode(Report.self, from: data),
                  decoded.version == schemaVersion else { return nil }
            return decoded
        }

        /// Reads a sidecar from disk. Same version rejection as `decode`.
        static func load(from url: URL) -> Report? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return decode(data)
        }
    }

    // MARK: - Entry point

    /// Scores one relocalization and labels it.
    ///
    /// `capturedAt` defaults to now because `Correspondences` carries no timestamp: it is built at
    /// save, which is within seconds of capture. Pass it explicitly when re-deriving a report
    /// offline from a recorded scan, so the sidecar keeps the scan's date rather than the
    /// re-derivation's.
    ///
    /// Decision precedence, in order:
    /// 1. `.notApplicable` when the scan case is `LinkAdjacent`;
    /// 2. `.insufficientData` when there are fewer than `Thresholds.minPairs` correspondences, or
    ///    `RigidFit.ransac` finds no consensus;
    /// 3. `.promote` when ALL promote-side thresholds hold;
    /// 4. `.rebaseline` when the fit is degraded, or the revisited volume came back thin AND stale;
    /// 5. `.hold` otherwise.
    ///
    /// Metrics are computed in every case, `.notApplicable` included — the suppression is of the
    /// verdict, not of the measurement.
    static func evaluate(_ correspondences: FeaturePointDiff.Correspondences,
                         capturedAt: Date = Date()) -> Report {

        // --- Occupancy: computed for every run, whatever the verdict turns out to be -----------
        let occupancy = occupancy(baseline: correspondences.baselinePositions, fresh: correspondences.freshPoints)

        let retainedFraction = correspondences.baselinePointCount > 0
            ? Double(correspondences.pairs.count) / Double(correspondences.baselinePointCount)
            : 0

        // --- Rigid fit, when there is enough to fit -------------------------------------------
        var fit: RigidFit.Result?
        let tooFewPairs = correspondences.pairs.count < Thresholds.minPairs
        if !tooFewPairs {
            fit = RigidFit.ransac(pairs: correspondences.pairs,
                                  inlierDistanceM: Thresholds.inlierDistanceM,
                                  iterations: Thresholds.ransacIterations,
                                  seed: Thresholds.ransacSeed)
        }

        let decision: Decision
        let drivers: [String]

        if correspondences.scanCase == ScanCase.linkAdjacent.rawValue {
            // Connect Adjacent relocalizes into the map of a DIFFERENT physical room in order to
            // find its way to the boundary (`LocationDetailView.startConnectAdjacent`). The new
            // scan is *supposed* to be mostly elsewhere: retained pairs are sparse by design,
            // coverage of the old room is meant to be low, and the unvisited remainder of the old
            // room reads as stale. Scored on these thresholds the flow would report REBASELINE on
            // essentially every Connect-Adjacent save — a systematic false positive that would
            // dominate the calibration dataset and drag every threshold the wrong way. So the
            // metrics are still recorded (they are informative about the link itself) and only the
            // verdict is suppressed.
            decision = .notApplicable
            drivers = ["scanCase=\(correspondences.scanCase)"]

        } else if tooFewPairs {
            decision = .insufficientData
            drivers = ["minPairs"]

        } else if let fit {
            // Promote requires every one of these. They are listed once and reused for both the
            // satisfied set (promote) and the blocking set (everything else), so the two can never
            // drift apart.
            let checks: [(name: String, held: Bool)] = [
                ("minInlierFraction", fit.inlierFraction >= Thresholds.minInlierFraction),
                ("maxInlierRMSM", fit.inlierRMSMetres <= Thresholds.maxInlierRMSM),
                ("minLambdaRatio", fit.conditioning.lambdaRatio >= Thresholds.minLambdaRatio),
                ("minHorizontalExtentM", fit.conditioning.horizontalExtentM >= Thresholds.minHorizontalExtentM),
                ("minCoverage", occupancy.coverage >= Thresholds.minCoverage),
                ("maxStale", occupancy.stale <= Thresholds.maxStale)
            ]
            let blockers = checks.filter { !$0.held }.map(\.name)

            if blockers.isEmpty {
                decision = .promote
                drivers = checks.map(\.name)
            } else {
                var degraders: [String] = []
                if fit.inlierFraction < Thresholds.degradedInlierFraction {
                    degraders.append("degradedInlierFraction")
                }
                if occupancy.coverage < Thresholds.minCoverage,
                   occupancy.stale > Thresholds.degradedStale {
                    // Distinct from the promote-side "minCoverage" check name even though both read
                    // the same threshold: `drivers` is the field a calibration pass tunes from, and
                    // reusing one name across a blocker and a degrader would make a `hold` blocked
                    // on coverage indistinguishable from a `rebaseline` driven by it.
                    degraders.append("degradedCoverage")
                    degraders.append("degradedStale")
                }
                decision = degraders.isEmpty ? .hold : .rebaseline
                drivers = degraders.isEmpty ? blockers : degraders
            }

        } else {
            // Pairs enough to try, but RANSAC found no consensus. Two very different causes land
            // here and the sidecar cannot yet tell them apart, which is itself worth knowing during
            // the shadow period: either the two clouds genuinely do not agree on any rigid
            // transform (a false lock, or a room changed beyond recognition), or the correspondence
            // set is geometrically degenerate — `RigidFit` rejects every minimal sample whose three
            // baseline points are near-collinear (`minSampleAreaM2`), so a scan whose retained
            // features all lie along one wall returns nil no matter how many pairs it has.
            // Either way there is no fit to judge, so no fit-based verdict is emitted: the rigid
            // fit is part of the verdict, and a degenerate or non-agreeing correspondence set
            // cannot promote. That is what makes `Thresholds` owning all fit policy meaningful —
            // it only means something if the fit can actually block.
            decision = .insufficientData
            drivers = ["ransacNoConsensus"]
        }

        return Report(version: Report.schemaVersion,
                      baselineNote: Report.baselineNote,
                      baselineMapName: correspondences.baselineName,
                      baselineMapPointCount: correspondences.baselinePointCount,
                      currentMapPointCount: correspondences.currentCount,
                      scanCase: correspondences.scanCase,
                      capturedAt: iso8601(capturedAt),
                      pairCount: correspondences.pairs.count,
                      retainedFraction: retainedFraction,
                      freshCount: correspondences.freshPoints.count,
                      inlierFraction: fit?.inlierFraction ?? 0,
                      inlierRMSMetres: fit?.inlierRMSMetres ?? 0,
                      fitOffsetMetres: fit?.transform.translationMetres ?? 0,
                      fitRotationDegrees: fit?.transform.angleDegrees ?? 0,
                      lambdaRatio: fit?.conditioning.lambdaRatio ?? 0,
                      horizontalExtentM: fit?.conditioning.horizontalExtentM ?? 0,
                      verticalExtentM: fit?.conditioning.verticalExtentM ?? 0,
                      coverageFraction: occupancy.coverage,
                      staleFraction: occupancy.stale,
                      decision: decision,
                      drivers: drivers)
    }

    /// ISO-8601 in UTC. Built per call rather than cached in a static: `ISO8601DateFormatter` is a
    /// mutable, non-`Sendable` class, and `evaluate` is `nonisolated` and runs off the main actor at
    /// save. One allocation per save is not worth a shared-mutable-state hazard.
    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    // MARK: - Occupancy

    /// Fraction of baseline-occupied CELLS that a fresh point re-occupies: how much of the mapped
    /// volume this session actually went back and looked at.
    ///
    /// A cell measure, not a point measure — a densely-mapped cell and a sparse one are equally
    /// "one place that was or was not revisited". `staleFraction` is the opposite by design.
    static func coverageFraction(baseline: [SIMD3<Float>], fresh: [SIMD3<Float>]) -> Double {
        occupancy(baseline: baseline, fresh: fresh).coverage
    }

    /// Ghost candidates: the fraction of baseline POINTS whose own cell holds no fresh point, but
    /// at least one of whose 26 neighbouring cells does.
    ///
    /// The neighbour condition is the whole idea. It restricts the count to baseline structure in a
    /// region the operator demonstrably revisited this session and *still* did not re-observe —
    /// geometry the space plausibly no longer has. Structure in a part of the building nobody
    /// walked through this time has no fresh neighbour, is correctly not counted, and is also kept
    /// out of the denominator: absence of evidence there is not evidence of absence, in either
    /// direction.
    ///
    /// A point measure, not a cell measure: a densely-mapped region that went stale is a bigger
    /// loss than a sparse one, and the fraction should say so.
    ///
    /// **Why FRESH points and not retained ones.** Retention is not re-observation. ARKit carries
    /// feature points forward from a loaded map for the life of the session whether or not the
    /// camera ever re-confirmed them, so a retained point is evidence about the map file, not about
    /// what the device saw — `[FeatDiff]`'s retained-drift statistics are subject to exactly this
    /// (a point that never moved may never have been looked at). A FRESH point could only have been
    /// minted by this session observing that spot, which makes freshness the one signal in this
    /// data that means "the device saw something here, now". That is what both metrics need, and it
    /// is why a cell full of retained points and no fresh ones counts as unconfirmed.
    static func staleFraction(baseline: [SIMD3<Float>], fresh: [SIMD3<Float>]) -> Double {
        occupancy(baseline: baseline, fresh: fresh).stale
    }

    /// Both occupancy metrics in one pass over the grid, so `evaluate` bins the clouds once.
    private static func occupancy(baseline: [SIMD3<Float>], fresh: [SIMD3<Float>])
        -> (coverage: Double, stale: Double) {
        guard !baseline.isEmpty else { return (0, 0) }
        let cell = cellSizeM

        // Point counts per baseline cell: coverage needs the key set, staleness needs the weights.
        var baselineCells = [Int64: Int](minimumCapacity: baseline.count)
        for point in baseline { baselineCells[cellKey(point, cell), default: 0] += 1 }

        var freshCells = Set<Int64>(minimumCapacity: fresh.count)
        for point in fresh { freshCells.insert(cellKey(point, cell)) }

        var reoccupiedCells = 0
        var ghostPoints = 0
        var revisitedPoints = 0
        for (key, count) in baselineCells {
            if freshCells.contains(key) {
                reoccupiedCells += 1
                revisitedPoints += count
                continue
            }
            // The cell itself came back empty — a ghost only if the region around it WAS revisited.
            var neighbourSeen = false
            neighbourSearch: for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        if dx == 0 && dy == 0 && dz == 0 { continue }
                        if freshCells.contains(neighbourKey(key, Int64(dx), Int64(dy), Int64(dz))) {
                            neighbourSeen = true
                            break neighbourSearch
                        }
                    }
                }
            }
            if neighbourSeen {
                ghostPoints += count
                revisitedPoints += count
            }
        }

        let coverage = Double(reoccupiedCells) / Double(baselineCells.count)
        let stale = revisitedPoints > 0 ? Double(ghostPoints) / Double(revisitedPoints) : 0
        return (coverage, stale)
    }

    /// The same 21-bit-band cell pack used by the three existing copies in `LocalizationDiag.swift`
    /// — `VoxelGrid.key`, the `decimate` loop, and `FeaturePointDiff.cellKey` — restated privately
    /// here rather than shared, to keep this file free of ARKit (`LocalizationDiag` imports it, so
    /// reaching into it would cost this file its Simulator testability). Note this is unrelated to
    /// `VoxelGrid.swift`, which is the GPU capture grid (8 m extent, 2 cm cells) and bins for a
    /// completely different purpose.
    ///
    /// Collisions across the bands are harmless in those three copies because an exact distance
    /// test follows. **Here there is no such test**, so a collision would merge two distant cells
    /// into one occupancy bucket. The band covers ±2^20 cells; at the 0.5 m `voxelM` that is ±524
    /// km per axis, so a collision needs coordinates no ARKit session can reach.
    ///
    /// `.rounded(.down)` is floor, not truncation, so cells are uniform across the origin: a point
    /// at x = −0.1 belongs to cell −1, and the shared face at x = 0 belongs to cell 0.
    private static func cellKey(_ point: SIMD3<Float>, _ cell: Float) -> Int64 {
        let x = Int64((point.x / cell).rounded(.down))
        let y = Int64((point.y / cell).rounded(.down))
        let z = Int64((point.z / cell).rounded(.down))
        return (x & 0x1FFFFF) | ((y & 0x1FFFFF) << 21) | ((z & 0x1FFFFF) << 42)
    }

    /// Key of the cell offset from `key` by `(dx, dy, dz)` cells.
    ///
    /// Operating on the packed fields is exact: each band is masked independently, and
    /// `(raw &+ d) & mask == ((raw & mask) &+ d) & mask`, so stepping a masked field wraps exactly
    /// as the unmasked coordinate would have. No unpack-to-signed round trip is needed, and
    /// negative cell indices step correctly.
    private static func neighbourKey(_ key: Int64, _ dx: Int64, _ dy: Int64, _ dz: Int64) -> Int64 {
        let x = (key & 0x1FFFFF) &+ dx
        let y = ((key >> 21) & 0x1FFFFF) &+ dy
        let z = ((key >> 42) & 0x1FFFFF) &+ dz
        return (x & 0x1FFFFF) | ((y & 0x1FFFFF) << 21) | ((z & 0x1FFFFF) << 42)
    }
}

// MARK: - Log line

extension PromotionGate.Report {

    /// One consolidated line, in the shape of `[LocDiag SUMMARY]` and `[FeatDiff]`.
    ///
    /// **Returns the string; does not log it.** No `PerfDiag.log` call is made anywhere in this
    /// file, so the gate has no side effects at all and the caller controls whether, when, and
    /// under which diagnostic flag it appears. The gen-8 lesson cuts both ways: a probe that
    /// decides for itself when to run is a probe that can perturb the thing it measures.
    func logLine() -> String {
        String(
            format: "[PromoGate] base=%@(%d) current=%d case=%@ at=%@ | pairs=%d retained=%.0f%% fresh=%d | fit: inliers=%.0f%% rms=%.1fmm offset=%.1fcm rot=%.2f° | spread: λratio=%.3f horiz=%.2fm vert=%.2fm | space: coverage=%.0f%% stale=%.0f%% | decision=%@ drivers=%@ [SHADOW — not acted on]",
            baselineMapName, baselineMapPointCount, currentMapPointCount, scanCase, capturedAt,
            pairCount, retainedFraction * 100, freshCount,
            inlierFraction * 100, inlierRMSMetres * 1000, fitOffsetMetres * 100, fitRotationDegrees,
            lambdaRatio, horizontalExtentM, verticalExtentM,
            coverageFraction * 100, staleFraction * 100,
            decision.rawValue.uppercased(), drivers.isEmpty ? "none" : drivers.joined(separator: ","))
    }
}
