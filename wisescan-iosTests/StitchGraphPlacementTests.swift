import XCTest
import SwiftData
import simd
@testable import wisescan_ios

/// Test 1 (highest value): `StitchGraphBuilder.placeScans` transform propagation.
///
/// A regression here silently MISPLACES combined renders with no crash, and the
/// directed→bidirectional refactor touched exactly this BFS. We exercise both the
/// forward branch (root is the link's source) and the inverse branch (root is the
/// link's target) by controlling the location UUIDs so the deterministic root
/// (smallest UUID) is known.
///
/// Geometry under test: a point in the TARGET frame maps to the SOURCE frame by
/// `R = sourceAnchorMatrix · inverse(targetAnchorMatrix)`. The root location is
/// placed at identity; the neighbor gets `R` (forward) or `inverse(R)` (reverse).
@MainActor
final class StitchGraphPlacementTests: XCTestCase {

    // Deterministic ids: locA sorts before locB, so locA is always the BFS root.
    private let locAId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private let locBId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let scanAId = UUID(uuidString: "0000000A-0000-0000-0000-000000000000")!
    private let scanBId = UUID(uuidString: "0000000B-0000-0000-0000-000000000000")!

    /// Forward branch: root (locA) is the link SOURCE. With source anchor = identity and
    /// target anchor = translation(t), R = translation(-t), so the target location places
    /// at translation(-t).
    func testPlaceScans_forwardEdge_placesTargetByInverseTranslation() async throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let a = StitchTestSupport.makeLocation(id: locAId, name: "A", scanId: scanAId, in: context)
        let b = StitchTestSupport.makeLocation(id: locBId, name: "B", scanId: scanBId, in: context)

        let t = SIMD3<Float>(1, 2, 3)
        // source = A (anchor identity), target = B (anchor translation(t)).
        _ = try StitchLinkStore.create(
            sourceScan: a.scan, targetScan: b.scan,
            sourceAnchor: matrix_identity_float4x4,
            targetAnchor: StitchTestSupport.translation(t),
            sourceAnchorId: UUID(), targetAnchorId: UUID(),
            sourceCompassHeading: nil, targetCompassHeading: nil,
            linkType: .midSession, in: context
        )

        let graph = await StitchGraphBuilder.build(from: [a.location, b.location])
        let component = try XCTUnwrap(graph.components.first)
        let placed = StitchGraphBuilder.placeScans(in: component, edges: graph.edges(in: component))

        let placedA = try XCTUnwrap(placed.first { $0.locationId == locAId })
        let placedB = try XCTUnwrap(placed.first { $0.locationId == locBId })

        // Root placed at identity, with its representative scan resolved.
        XCTAssertTrue(StitchTestSupport.matricesEqual(placedA.transform, matrix_identity_float4x4))
        XCTAssertEqual(placedA.scanId, scanAId)
        // Target placed by inverse translation; representative scan is the target scan.
        XCTAssertTrue(StitchTestSupport.matricesEqual(placedB.transform, StitchTestSupport.translation(-t)))
        XCTAssertEqual(placedB.scanId, scanBId)
    }

    /// Reverse branch: root (locA) is the link TARGET (source = B, the larger UUID). With
    /// source anchor = translation(t) and target anchor = identity, R = translation(t) and
    /// the BFS follows the edge in reverse, so the source location places at inverse(R) =
    /// translation(-t). Same expected placement, but exercises the `else` path.
    func testPlaceScans_reverseEdge_placesSourceByInverseTranslation() async throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let a = StitchTestSupport.makeLocation(id: locAId, name: "A", scanId: scanAId, in: context)
        let b = StitchTestSupport.makeLocation(id: locBId, name: "B", scanId: scanBId, in: context)

        let t = SIMD3<Float>(1, 2, 3)
        // source = B (anchor translation(t)), target = A (anchor identity). Root is still A.
        _ = try StitchLinkStore.create(
            sourceScan: b.scan, targetScan: a.scan,
            sourceAnchor: StitchTestSupport.translation(t),
            targetAnchor: matrix_identity_float4x4,
            sourceAnchorId: UUID(), targetAnchorId: UUID(),
            sourceCompassHeading: nil, targetCompassHeading: nil,
            linkType: .midSession, in: context
        )

        let graph = await StitchGraphBuilder.build(from: [a.location, b.location])
        let component = try XCTUnwrap(graph.components.first)
        let placed = StitchGraphBuilder.placeScans(in: component, edges: graph.edges(in: component))

        let placedA = try XCTUnwrap(placed.first { $0.locationId == locAId })
        let placedB = try XCTUnwrap(placed.first { $0.locationId == locBId })

        XCTAssertTrue(StitchTestSupport.matricesEqual(placedA.transform, matrix_identity_float4x4))
        XCTAssertTrue(StitchTestSupport.matricesEqual(placedB.transform, StitchTestSupport.translation(-t)))
        XCTAssertEqual(placedB.scanId, scanBId)
    }

    /// Provenance accessors (underpins everything above): `sourceIsA` chooses which stored
    /// endpoint is "source" vs "target", and `localAnchor(for:)` returns the pose in the
    /// given scan's own frame. Cheap contract lock.
    func testProvenanceAccessors_resolveCorrectEndpoint() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let a = StitchTestSupport.makeLocation(id: locAId, name: "A", scanId: scanAId, in: context)
        let b = StitchTestSupport.makeLocation(id: locBId, name: "B", scanId: scanBId, in: context)

        let srcAnchor = StitchTestSupport.translation(SIMD3<Float>(5, 0, 0))
        let tgtAnchor = StitchTestSupport.translation(SIMD3<Float>(0, 7, 0))
        let link = try StitchLinkStore.create(
            sourceScan: a.scan, targetScan: b.scan,
            sourceAnchor: srcAnchor, targetAnchor: tgtAnchor,
            sourceAnchorId: UUID(), targetAnchorId: UUID(),
            sourceCompassHeading: nil, targetCompassHeading: nil,
            linkType: .midSession, in: context
        )

        // sourceIsA == true → endpoint A is source.
        XCTAssertEqual(link.sourceScan?.id, scanAId)
        XCTAssertEqual(link.targetScan?.id, scanBId)
        XCTAssertTrue(StitchTestSupport.matricesEqual(link.sourceAnchorMatrix, srcAnchor))
        XCTAssertTrue(StitchTestSupport.matricesEqual(link.targetAnchorMatrix, tgtAnchor))

        // localAnchor returns the pose in the queried scan's own frame + the other endpoint.
        let localForA = try XCTUnwrap(link.localAnchor(for: a.scan))
        XCTAssertTrue(StitchTestSupport.matricesEqual(localForA.transform, srcAnchor))
        XCTAssertEqual(localForA.otherScan?.id, scanBId)

        let localForB = try XCTUnwrap(link.localAnchor(for: b.scan))
        XCTAssertTrue(StitchTestSupport.matricesEqual(localForB.transform, tgtAnchor))
        XCTAssertEqual(localForB.otherScan?.id, scanAId)
    }

    /// `flatten`/`unflatten` round-trip — guards the column-major layout that both the wire
    /// format and `placeScans` depend on.
    func testMatrixFlattenRoundTrip() {
        let m = simd_float4x4(columns: (
            SIMD4<Float>(1, 2, 3, 4),
            SIMD4<Float>(5, 6, 7, 8),
            SIMD4<Float>(9, 10, 11, 12),
            SIMD4<Float>(13, 14, 15, 16)
        ))
        let restored = StitchLink.unflatten(StitchLink.flatten(m))
        XCTAssertTrue(StitchTestSupport.matricesEqual(restored, m))
    }
}
