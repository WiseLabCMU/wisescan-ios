import XCTest
import SwiftData
@testable import wisescan_ios

/// Guards the `.featureCloud` backfill step's DETECTION and GATING.
///
/// The step re-derives `arkit_features.bin` from a scan's persisted `arworldmap.map`, so every
/// scan saved before that artifact existed can recover its feature cloud offline. Two properties
/// have to hold and neither is obvious from the call site:
///
///   1. **Detection is disk-derived and never destructive** — map present + cloud absent is
///      pending; an existing cloud is never re-offered (the save-time one is authoritative); a
///      scan with no map produces no step at all.
///   2. **The step does not gate anything.** `needsPostprocess` is the structural blocker behind
///      rescan / connect / upload. Every legacy scan in an existing library matches the pending
///      condition, so a step that counted as blocking would hard-gate the whole library the
///      instant the app updated. Test 4 is the one that would catch that regression.
///
/// `ARWorldMap` cannot be synthesized in a unit test (no ARSession, and the Simulator never
/// produces a real map), so these tests exercise the file-level predicate and the gate rather
/// than trying to round-trip an archive. The map "archive" here is therefore marker bytes: the
/// detection path only ever asks whether the file EXISTS — it is `backfillFeatureCloud`, covered
/// on device, that parses it.
@MainActor
final class FeatureCloudBackfillTests: XCTestCase {

    /// Scan directories created on the real Documents filesystem, removed in tearDown.
    private var createdDirs: [URL] = []

    override func tearDown() {
        for dir in createdDirs { try? FileManager.default.removeItem(at: dir) }
        createdDirs = []
        super.tearDown()
    }

    /// A location with one scan, its scan directory created on disk and optionally populated with
    /// a world map and/or a feature cloud. One scan per location so `wantsRegistration` is false
    /// (the scan IS its location's original), which keeps `pendingSteps` down to the step under
    /// test.
    private func makeScan(map: Bool, cloud: Bool) throws -> CapturedScan {
        let context = try StitchTestSupport.makeInMemoryContext()
        let (_, scan) = StitchTestSupport.makeLocation(id: UUID(), name: "Backfill",
                                                       scanId: UUID(), in: context)
        let dir = scan.scanDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        createdDirs.append(dir.deletingLastPathComponent())   // .../Scans/<locId>

        if map {
            try Data("WISESCAN_TEST_WORLDMAP".utf8).write(to: scan.worldMapURL)
        }
        if cloud {
            try FeaturePointCloudFile.encode(ids: [], points: []).write(to: scan.featurePointsURL)
        }
        return scan
    }

    // MARK: - Detection

    func testMapWithoutCloud_reportsFeatureCloudStepPending() throws {
        let scan = try makeScan(map: true, cloud: false)
        let steps = ScanPostprocessor.pendingSteps(for: scan, includeColorize: false)
        XCTAssertTrue(steps.contains(.featureCloud),
                      "a scan with a world map and no feature cloud should offer the backfill; got \(steps)")
    }

    func testMapAndCloud_reportsFeatureCloudStepNotPending() throws {
        let scan = try makeScan(map: true, cloud: true)
        XCTAssertFalse(ScanPostprocessor.pendingSteps(for: scan, includeColorize: false)
                        .contains(.featureCloud),
                       "an existing feature cloud must never be re-derived — the save-time one is authoritative")
    }

    func testNeitherMapNorCloud_reportsFeatureCloudStepNotPending() throws {
        let scan = try makeScan(map: false, cloud: false)
        XCTAssertFalse(ScanPostprocessor.pendingSteps(for: scan, includeColorize: false)
                        .contains(.featureCloud),
                       "with no world map there is nothing to derive the cloud from — no step")
    }

    /// A cloud with no map is the Simulator/timeout case (the world-map export produced nothing
    /// but something else wrote the sidecar). Still nothing to do, and nothing to overwrite.
    func testCloudWithoutMap_reportsFeatureCloudStepNotPending() throws {
        let scan = try makeScan(map: false, cloud: true)
        XCTAssertFalse(ScanPostprocessor.pendingSteps(for: scan, includeColorize: false)
                        .contains(.featureCloud),
                       "no map means no step, cloud present or not")
    }

    /// The directory-level predicate the off-main pass re-checks, pinned directly: it has to agree
    /// with the `@Model` path above on all four combinations.
    func testFeatureCloudPending_matchesTheModelPathOnEveryCombination() throws {
        for (map, cloud, expected) in [(true, false, true), (true, true, false),
                                       (false, false, false), (false, true, false)] {
            let scan = try makeScan(map: map, cloud: cloud)
            XCTAssertEqual(ScanPostprocessor.featureCloudPending(scanDirectory: scan.scanDirectory),
                           expected,
                           "featureCloudPending(map: \(map), cloud: \(cloud)) should be \(expected)")
            XCTAssertEqual(ScanPostprocessor.pendingSteps(for: scan, includeColorize: false)
                            .contains(.featureCloud),
                           expected,
                           "pendingSteps(map: \(map), cloud: \(cloud)) should\(expected ? "" : " not") offer .featureCloud")
        }
    }

    // MARK: - The non-blocking property

    /// THE load-bearing assertion. A pending `.featureCloud` must not make `needsPostprocess`
    /// true: that flag is what blocks rescan, connect and upload, and every pre-artifact scan in
    /// an existing library has a map and no cloud. Asserted alongside `pendingSteps` so a failure
    /// distinguishes "the step stopped being detected" from "the step started blocking".
    func testPendingFeatureCloudDoesNotBlockRescanConnectOrUpload() throws {
        let scan = try makeScan(map: true, cloud: false)
        XCTAssertEqual(ScanPostprocessor.pendingSteps(for: scan, includeColorize: false),
                       [.featureCloud],
                       "this fixture should have exactly one pending step, or the gate assertion below proves nothing")
        XCTAssertFalse(ScanPostprocessor.needsPostprocess(scan),
                       "the feature-cloud backfill is a DERIVED artifact, not scan integrity — it must never gate rescan/connect/upload")
    }

    /// The same scan with its cloud already present is equally unblocked: the exclusion above is
    /// what makes the two indistinguishable to the gate, which is the point.
    func testScanWithCloudIsAlsoUnblocked() throws {
        let scan = try makeScan(map: true, cloud: true)
        XCTAssertFalse(ScanPostprocessor.needsPostprocess(scan))
    }
}
