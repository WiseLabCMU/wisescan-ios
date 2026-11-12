import XCTest
import SwiftData
import simd
@testable import wisescan_ios

/// Test 3: one-time migration of legacy `stitching.json` files into SwiftData.
///
/// Covers idempotency (the UserDefaults guard) and the code-side de-dup by link id
/// (the `.unique` backstop): running the import twice — or against an already-imported
/// id after the flag is cleared — must never create duplicate `StitchLink` rows.
@MainActor
final class StitchLinkMigrationTests: XCTestCase {

    private let flagKey = "stitchLinkMigrationV1Done"
    private var fixtureLocationIds: [UUID] = []

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: flagKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: flagKey)
        // Remove any legacy fixture dirs written into the test host's Documents.
        for id in fixtureLocationIds {
            if let dir = StitchingMetadataManager.locationDirectory(for: id) {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        fixtureLocationIds.removeAll()
        super.tearDown()
    }

    /// Writes a legacy stitching.json fixture into `locationId`'s on-disk directory.
    private func writeLegacyManifest(_ manifest: StitchingManifest, for locationId: UUID) throws {
        fixtureLocationIds.append(locationId)
        let dir = try XCTUnwrap(StitchingMetadataManager.locationDirectory(for: locationId))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: StitchingMetadataManager.url(forLocationDir: dir), options: .atomic)
    }

    private func makeLegacyLink(sourceLoc: UUID, sourceScan: UUID,
                                targetLoc: UUID, targetScan: UUID,
                                id: UUID) -> StitchingLink {
        StitchingLink(
            id: id,
            sourceLocationId: sourceLoc,
            sourceScanId: sourceScan,
            sourceAnchorId: UUID(),
            sourceAnchorTransform: CodableMatrix4x4(matrix_identity_float4x4),
            sourceAnchorCompassHeading: nil,
            targetLocationId: targetLoc,
            targetScanId: targetScan,
            targetAnchorId: UUID(),
            targetAnchorTransform: CodableMatrix4x4(matrix_identity_float4x4),
            targetAnchorCompassHeading: nil,
            linkedAt: Date(timeIntervalSince1970: 1_700_000_000),
            linkType: .midSession
        )
    }

    func testMigration_importsLegacyLink_andIsIdempotent() async throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let aLoc = UUID(), aScan = UUID()
        let bLoc = UUID(), bScan = UUID()
        StitchTestSupport.makeLocation(id: aLoc, name: "A", scanId: aScan, in: context)
        StitchTestSupport.makeLocation(id: bLoc, name: "B", scanId: bScan, in: context)
        try context.save()

        let linkId = UUID()
        let manifest = StitchingManifest(links: [
            makeLegacyLink(sourceLoc: aLoc, sourceScan: aScan, targetLoc: bLoc, targetScan: bScan, id: linkId)
        ])
        try writeLegacyManifest(manifest, for: aLoc)

        // First run imports exactly one link and resolves both endpoints.
        await StitchLinkStore.migrateFromFilesIfNeeded(context: context)
        var links = try context.fetch(FetchDescriptor<StitchLink>())
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.id, linkId)
        XCTAssertEqual(links.first?.endpointAScan?.id, aScan)
        XCTAssertEqual(links.first?.endpointBScan?.id, bScan)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: flagKey), "Migration should set its done flag")

        // Second run is a guarded no-op (flag set).
        await StitchLinkStore.migrateFromFilesIfNeeded(context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StitchLink>()), 1)

        // Even with the flag cleared, the code-side de-dup by id must prevent a duplicate row.
        UserDefaults.standard.removeObject(forKey: flagKey)
        await StitchLinkStore.migrateFromFilesIfNeeded(context: context)
        links = try context.fetch(FetchDescriptor<StitchLink>())
        XCTAssertEqual(links.count, 1, "Re-running with the same link id must not duplicate the row")
    }

    func testMigration_skipsLinkWithUnresolvableEndpoints() async throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let aLoc = UUID(), aScan = UUID()
        StitchTestSupport.makeLocation(id: aLoc, name: "A", scanId: aScan, in: context)
        try context.save()

        // Target scan id doesn't exist in the store → the link must be skipped, not crash.
        let manifest = StitchingManifest(links: [
            makeLegacyLink(sourceLoc: aLoc, sourceScan: aScan, targetLoc: UUID(), targetScan: UUID(), id: UUID())
        ])
        try writeLegacyManifest(manifest, for: aLoc)

        await StitchLinkStore.migrateFromFilesIfNeeded(context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<StitchLink>()), 0)
    }
}
