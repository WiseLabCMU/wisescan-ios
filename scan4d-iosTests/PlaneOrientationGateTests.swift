import XCTest
import simd
@testable import wisescan_ios

/// `PlaneRegistration.orientationMatches` — the gate that keeps a live plane anchor from entering the
/// fit as the wrong KIND of surface.
///
/// RoomPlan surfaces are gravity-aligned by construction, so this only bites on live `ARPlaneAnchor`s,
/// where the classification is a guess about a real surface: a sloped ceiling or a leaning board can
/// arrive classified `.wall`, and a ramp can arrive classified `.floor`. Both are worse than useless,
/// because the solve reads full 3D normals — a tilted wall injects a vertical component into a
/// translation meant to be horizontal, and a tilted floor corrupts the only constraint `ty` has. And
/// neither is visible in the residual, which fits the bad plane perfectly well.
final class PlaneOrientationGateTests: XCTestCase {

    private func normal(pitchDeg: Float) -> SIMD3<Float> {
        let r = pitchDeg * .pi / 180
        return SIMD3(0, cos(r), -sin(r))   // pitchDeg = 0 → straight up, 90 → horizontal
    }

    func testTrueVerticalWall_isAccepted() {
        XCTAssertTrue(PlaneRegistration.orientationMatches(category: .wall, normal: normal(pitchDeg: 90)))
    }

    func testTrueLevelFloor_isAccepted() {
        XCTAssertTrue(PlaneRegistration.orientationMatches(category: .floor, normal: normal(pitchDeg: 0)))
    }

    /// Tracking noise on a genuine wall must not cost it its place — the gate exists to exclude the
    /// wrong kind of surface, not to police a few degrees of jitter.
    func testSlightlyOffWall_isStillAccepted() {
        XCTAssertTrue(PlaneRegistration.orientationMatches(category: .wall, normal: normal(pitchDeg: 80)))
    }

    func testSlightlyOffFloor_isStillAccepted() {
        XCTAssertTrue(PlaneRegistration.orientationMatches(category: .floor, normal: normal(pitchDeg: 10)))
    }

    /// A sloped ceiling or leaning surface classified as a wall.
    func testTiltedSurfaceClaimingToBeAWall_isRejected() {
        XCTAssertFalse(PlaneRegistration.orientationMatches(category: .wall, normal: normal(pitchDeg: 60)))
    }

    /// A ramp classified as a floor — the case that would quietly drag the vertical solution.
    func testRampClaimingToBeAFloor_isRejected() {
        XCTAssertFalse(PlaneRegistration.orientationMatches(category: .floor, normal: normal(pitchDeg: 30)))
    }

    /// Normal sign is not trusted anywhere in this file, so a floor pointing down reads the same as one
    /// pointing up.
    func testInvertedFloorNormal_isAccepted() {
        XCTAssertTrue(PlaneRegistration.orientationMatches(category: .floor, normal: SIMD3(0, -1, 0)))
    }

    /// A 45° surface belongs to neither category — the two tests are not complements, and something
    /// diagonal has to fail both rather than fall through to one of them.
    func testDiagonalSurface_belongsToNeitherCategory() {
        let diagonal = normal(pitchDeg: 45)
        XCTAssertFalse(PlaneRegistration.orientationMatches(category: .wall, normal: diagonal))
        XCTAssertFalse(PlaneRegistration.orientationMatches(category: .floor, normal: diagonal))
    }
}
