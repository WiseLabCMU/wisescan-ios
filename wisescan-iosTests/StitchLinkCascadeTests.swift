import XCTest
import SwiftData
import simd
@testable import wisescan_ios

/// Test 2: cascade delete integrity — the headline feature of this refactor.
///
/// The cascade rules live on `CapturedScan.linksAsA/linksAsB`, so deleting either
/// endpoint scan — or a whole location, which cascades to its scans — must remove the
/// `StitchLink` automatically. This is the referential integrity the old file-based
/// model lacked.
@MainActor
final class StitchLinkCascadeTests: XCTestCase {

    private func linkCount(in context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<StitchLink>())
    }

    private func makeLinkedPair(in context: ModelContext)
        throws -> (a: (location: ScanLocation, scan: CapturedScan),
                   b: (location: ScanLocation, scan: CapturedScan)) {
        let a = StitchTestSupport.makeLocation(id: UUID(), name: "A", scanId: UUID(), in: context)
        let b = StitchTestSupport.makeLocation(id: UUID(), name: "B", scanId: UUID(), in: context)
        _ = try StitchLinkStore.create(
            sourceScan: a.scan, targetScan: b.scan,
            sourceAnchor: matrix_identity_float4x4, targetAnchor: matrix_identity_float4x4,
            sourceAnchorId: UUID(), targetAnchorId: UUID(),
            sourceCompassHeading: nil, targetCompassHeading: nil,
            linkType: .midSession, in: context
        )
        return (a, b)
    }

    func testDeletingEndpointScan_removesLink() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let pair = try makeLinkedPair(in: context)
        XCTAssertEqual(try linkCount(in: context), 1)

        context.delete(pair.a.scan)
        try context.save()

        XCTAssertEqual(try linkCount(in: context), 0, "Deleting an endpoint scan must cascade-delete its link")
    }

    func testDeletingLocation_cascadesToScansAndRemovesLink() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let pair = try makeLinkedPair(in: context)
        XCTAssertEqual(try linkCount(in: context), 1)

        // Deleting a location cascades to its scans (existing rule), which in turn cascades
        // to the links those scans participate in.
        context.delete(pair.b.location)
        try context.save()

        XCTAssertEqual(try linkCount(in: context), 0, "Deleting a location must cascade through its scans to links")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<CapturedScan>()), 1, "Only the surviving location's scan should remain")
    }

    func testDeletingUnrelatedScan_leavesLinkIntact() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let pair = try makeLinkedPair(in: context)
        // A third, unlinked location/scan.
        let c = StitchTestSupport.makeLocation(id: UUID(), name: "C", scanId: UUID(), in: context)
        try context.save()
        XCTAssertEqual(try linkCount(in: context), 1)

        context.delete(c.scan)
        try context.save()

        XCTAssertEqual(try linkCount(in: context), 1, "Deleting an unrelated scan must not touch existing links")
        _ = pair
    }
}
