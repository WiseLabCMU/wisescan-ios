import XCTest
import SwiftData
import simd
@testable import wisescan_ios

/// Diagnoses the "outgoing connectors don't render" bug: when rescanning the SOURCE map (endpoint A),
/// do we resolve the link, its local anchor (in A's frame), and the OTHER map's name? And symmetric
/// for the target map (endpoint B, the working "backwards" direction).
///
/// `StitchLink` has TWO relationships to the same `CapturedScan` type (endpointAScan/endpointBScan).
/// SwiftData's relationship resolution for that case is the prime suspect. These assertions isolate
/// exactly which accessor (inverse arrays, forward relationships, incidentLinks, localAnchor, name)
/// breaks for the source side.
///
/// NOTE: these run against a fresh in-memory store, where the inverse arrays DO populate (see
/// `testInverseArraysPopulateBothSides`). The original failure surfaces on a PERSISTED store after
/// relaunch, which this suite does not reproduce — so these tests guard the fetch-based fix's
/// contract (both directions resolve) but would NOT catch a regression back to trusting the inverse
/// arrays. Reproducing the on-disk failure would need a persisted store reloaded across contexts.
@MainActor
final class StitchConnectorResolutionTests: XCTestCase {

    private func makeLinkedPair(in context: ModelContext)
        throws -> (a: (location: ScanLocation, scan: CapturedScan),
                   b: (location: ScanLocation, scan: CapturedScan),
                   link: StitchLink) {
        let a = StitchTestSupport.makeLocation(id: UUID(), name: "Living Room", scanId: UUID(), in: context)
        let b = StitchTestSupport.makeLocation(id: UUID(), name: "Kitchen", scanId: UUID(), in: context)
        let link = try StitchLinkStore.create(
            sourceScan: a.scan, targetScan: b.scan,
            sourceAnchor: StitchTestSupport.translation(SIMD3<Float>(1, 0, 0)),   // pin A in A's frame
            targetAnchor: StitchTestSupport.translation(SIMD3<Float>(0, 0, 2)),   // pin B in B's frame
            sourceAnchorId: UUID(), targetAnchorId: UUID(),
            sourceCompassHeading: nil, targetCompassHeading: nil,
            linkType: .midSession, in: context
        )
        try context.save()
        return (a, b, link)
    }

    // MARK: Forward relationships (the side create() sets directly)

    func testForwardRelationshipsResolve() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let pair = try makeLinkedPair(in: context)
        XCTAssertEqual(pair.link.endpointAScan?.id, pair.a.scan.id, "endpointAScan should be the source scan")
        XCTAssertEqual(pair.link.endpointBScan?.id, pair.b.scan.id, "endpointBScan should be the target scan")
        XCTAssertEqual(pair.link.sourceScan?.id, pair.a.scan.id)
        XCTAssertEqual(pair.link.targetScan?.id, pair.b.scan.id)
    }

    // MARK: Inverse arrays (what incidentLinks used to trust)

    func testInverseArraysPopulateBothSides() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let pair = try makeLinkedPair(in: context)
        XCTAssertEqual(pair.a.scan.linksAsA.count, 1, "source scan's linksAsA should contain the link")
        XCTAssertEqual(pair.b.scan.linksAsB.count, 1, "target scan's linksAsB should contain the link")
    }

    // MARK: incidentLinks — must find the link from EITHER endpoint

    func testIncidentLinksFromBothEndpoints() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let pair = try makeLinkedPair(in: context)
        XCTAssertEqual(StitchLinkStore.incidentLinks(for: pair.a.scan).count, 1, "OUTGOING: source scan must see its link")
        XCTAssertEqual(StitchLinkStore.incidentLinks(for: pair.b.scan).count, 1, "INCOMING: target scan must see its link")
    }

    // MARK: connectorAnchors — anchor pose + OTHER map name, from EITHER endpoint

    func testConnectorAnchorFromSource() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let pair = try makeLinkedPair(in: context)
        let anchors = StitchLinkStore.connectorAnchors(for: pair.a.scan)
        XCTAssertEqual(anchors.count, 1, "OUTGOING: rescanning the source map must yield one connector")
        let anchor = try XCTUnwrap(anchors.first)
        // In A's frame the connector sits at pin A (translation 1,0,0).
        XCTAssertTrue(StitchTestSupport.matricesEqual(anchor.transform, StitchTestSupport.translation(SIMD3<Float>(1, 0, 0))))
        XCTAssertEqual(anchor.otherLocationName, "Kitchen", "label should name the OTHER connected map")
    }

    func testConnectorAnchorFromTarget() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let pair = try makeLinkedPair(in: context)
        let anchors = StitchLinkStore.connectorAnchors(for: pair.b.scan)
        XCTAssertEqual(anchors.count, 1, "INCOMING: rescanning the target map must yield one connector")
        let anchor = try XCTUnwrap(anchors.first)
        XCTAssertTrue(StitchTestSupport.matricesEqual(anchor.transform, StitchTestSupport.translation(SIMD3<Float>(0, 0, 2))))
        XCTAssertEqual(anchor.otherLocationName, "Living Room", "label should name the OTHER connected map")
    }

    // MARK: Hub case — one source map with multiple outgoing links

    func testHubWithMultipleOutgoingLinks() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let hub = StitchTestSupport.makeLocation(id: UUID(), name: "Hub", scanId: UUID(), in: context)
        let names = ["North", "East", "South"]
        for (i, name) in names.enumerated() {
            let spoke = StitchTestSupport.makeLocation(id: UUID(), name: name, scanId: UUID(), in: context)
            _ = try StitchLinkStore.create(
                sourceScan: hub.scan, targetScan: spoke.scan,
                sourceAnchor: StitchTestSupport.translation(SIMD3<Float>(Float(i), 0, 0)),
                targetAnchor: matrix_identity_float4x4,
                sourceAnchorId: UUID(), targetAnchorId: UUID(),
                sourceCompassHeading: nil, targetCompassHeading: nil,
                linkType: .midSession, in: context
            )
        }
        try context.save()

        let anchors = StitchLinkStore.connectorAnchors(for: hub.scan)
        XCTAssertEqual(anchors.count, 3, "rescanning the hub must yield ALL 3 outgoing connectors")
        XCTAssertEqual(Set(anchors.map(\.otherLocationName)), Set(names))
    }
}
