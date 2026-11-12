import XCTest
@testable import wisescan_ios

/// The mesh preview's photo-position markers: one on/off toggle for everyone (every photo,
/// stills and 360° stills), and the full cycle with motion frames in Developer Mode.
final class KeyframeMarkerModeTests: XCTestCase {
    func testEverydayToggleIsOnOff() {
        XCTAssertEqual(KeyframeMarkerMode.none.photoPositionsToggled, .photos)
        XCTAssertEqual(KeyframeMarkerMode.photos.photoPositionsToggled, .none)
        // Left on another tier by Developer Mode: the toggle switches it off.
        XCTAssertEqual(KeyframeMarkerMode.motion.photoPositionsToggled, .none)
    }

    func testPhotosShowsEveryPhotoButNotMotion() {
        let photos = KeyframeMarkerMode.photos
        XCTAssertTrue(photos.showStills)
        XCTAssertTrue(photos.showEquirectFaces)
        XCTAssertFalse(photos.showMotion)
    }

    func testDeveloperCycleStillReachesEveryTier() {
        var seen: Set<KeyframeMarkerMode> = []
        var mode = KeyframeMarkerMode.none
        for _ in 0..<6 {
            seen.insert(mode)
            mode = mode.next(hasEquirects: true)
        }
        XCTAssertEqual(seen, [.none, .stills, .equirectFaces, .motion, .all])
        XCTAssertEqual(KeyframeMarkerMode.photos.next(hasEquirects: true), .motion)
    }
}
