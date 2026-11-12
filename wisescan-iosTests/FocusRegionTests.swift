import XCTest
import simd
@testable import wisescan_ios

/// The focus-scan region: its JSON (also the import format a downstream processor writes) and the
/// box math the capture gate and the viewer rely on.
@MainActor
final class FocusRegionTests: XCTestCase {

    func testJSONRoundTripUsesExplicitKeys() throws {
        let region = FocusRegion(center: SIMD3(1, 0.8, -2), yaw: 0.5, size: SIMD3(1.2, 0.6, 0.8),
                                 label: "work table", source: .roomplan, detail: .detail,
                                 locationId: UUID(), frameScanId: UUID(), frameIsCanonical: true,
                                 createdAtMs: 1_761_200_000_000)
        let data = try XCTUnwrap(region.encoded())
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        for key in ["center_m", "yaw_rad", "size_m", "detail_level", "frame_is_canonical", "created_at_ms"] {
            XCTAssertTrue(json.contains("\"\(key)\""), "missing \(key) in \(json)")
        }
        XCTAssertTrue(json.contains("\"roomplan\""))
        XCTAssertEqual(FocusRegion.decode(data), region)
    }

    func testLenientDecodeNeedsOnlyTheBox() throws {
        let minimal = #"{"center_m":[0.5,0.9,-1],"size_m":[0.6,0.4,0.6],"label":"bench"}"#
        let region = try XCTUnwrap(FocusRegion.decode(Data(minimal.utf8)))
        XCTAssertEqual(region.center, SIMD3(0.5, 0.9, -1))
        XCTAssertEqual(region.yaw, 0)
        XCTAssertEqual(region.detail, .check)
        XCTAssertEqual(region.source, .imported)
        XCTAssertTrue(region.frameIsCanonical)
        XCTAssertEqual(region.label, "bench")
        XCTAssertNil(FocusRegion.decode(Data(#"{"center_m":[0,0,0]}"#.utf8)), "a box needs a size")
    }

    func testContainsAndCornersFollowYaw() {
        // 2 m along local x, 0.2 m along local z, turned 90 degrees: it now runs along world z.
        let region = FocusRegion(center: SIMD3(0, 1, 0), yaw: .pi / 2, size: SIMD3(2, 0.5, 0.2))
        XCTAssertTrue(region.contains(SIMD3(0, 1, 0.9)))
        XCTAssertFalse(region.contains(SIMD3(0.9, 1, 0)))
        XCTAssertFalse(region.contains(SIMD3(0, 1.3, 0)), "above the top face")
        let corners = region.corners
        XCTAssertEqual(corners.count, 8)
        let maxZ = corners.map(\.z).max() ?? 0
        XCTAssertEqual(maxZ, 1, accuracy: 1e-5)
        let maxX = corners.map(\.x).max() ?? 0
        XCTAssertEqual(maxX, 0.1, accuracy: 1e-5)
    }

    func testValidity() {
        XCTAssertTrue(FocusRegion(center: .zero, size: SIMD3(1, 1, 1)).isValid)
        XCTAssertFalse(FocusRegion(center: .zero, size: SIMD3(0, 1, 1)).isValid)
        XCTAssertFalse(FocusRegion(center: .zero, size: SIMD3(1, 1, 50)).isValid, "room-sized is not a focus region")
        XCTAssertFalse(FocusRegion(center: SIMD3(.nan, 0, 0), size: SIMD3(1, 1, 1)).isValid)
    }

    func testDeepLinkCarriesARegion() throws {
        let json = #"{"center_m":[1,0.8,-2],"size_m":[1.2,0.6,0.8],"label":"work table","detail_level":"detail","source":"user"}"#
        let base64url = Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let url = try XCTUnwrap(URL(string: "scan4d://focus-region?data=\(base64url)"))
        let region = try FocusRegionInbox.region(from: url).get()
        XCTAssertEqual(region.label, "work table")
        XCTAssertEqual(region.detail, .detail)
        XCTAssertEqual(region.source, .imported, "an import is recorded as one whatever it says")

        var components = URLComponents()
        components.scheme = "scan4d"
        components.host = "focus-region"
        components.queryItems = [URLQueryItem(name: "json", value: json)]
        XCTAssertEqual(try FocusRegionInbox.region(from: try XCTUnwrap(components.url)).get().size, SIMD3(1.2, 0.6, 0.8))
    }

    func testDeepLinkRefusals() throws {
        XCTAssertEqual(FocusRegionInbox.region(from: try XCTUnwrap(URL(string: "wisescandat://callback"))), .failure(.notARegionLink))
        XCTAssertEqual(FocusRegionInbox.region(from: try XCTUnwrap(URL(string: "scan4d://focus-region"))), .failure(.noPayload))
        XCTAssertEqual(FocusRegionInbox.region(from: try XCTUnwrap(URL(string: "scan4d://focus-region?data=@@@"))), .failure(.undecodable))
        let huge = #"{"center_m":[0,0,0],"size_m":[1,1,40]}"#
        XCTAssertEqual(FocusRegionInbox.region(fromJSON: Data(huge.utf8)), .failure(.invalidBox))
    }

    func testDetailLevelsTightenSpacingAndRaiseTargets() {
        let levels = FocusDetailLevel.allCases
        XCTAssertEqual(levels, [.check, .detail, .splat])
        for (a, b) in zip(levels, levels.dropFirst()) {
            XCTAssertGreaterThan(a.spacingDeg, b.spacingDeg)
            XCTAssertLessThan(a.targetStills, b.targetStills)
        }
        XCTAssertTrue(FocusDetailLevel.check.finishesAtTarget)
        XCTAssertFalse(FocusDetailLevel.splat.finishesAtTarget)
    }
}
