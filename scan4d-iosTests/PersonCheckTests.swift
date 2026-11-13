import CoreGraphics
import XCTest
@testable import scan4d_ios

/// The geometry of the person check (`PersonCheck`): its tiles cover the photo with overlap, and
/// a Vision box (origin bottom-left) lands in the mask (origin top-left), padded and clipped.
/// What Vision finds is checked against real photos, not here.
final class PersonCheckTests: XCTestCase {

    func testTilesCoverThePhotoAndOverlap() {
        let width = 1536, height = 2048
        let tiles = PersonCheck.tiles(width: width, height: height, columns: 2, rows: 3, overlap: 0.25)
        XCTAssertEqual(tiles.count, 6)
        for tile in tiles {
            XCTAssertGreaterThanOrEqual(tile.minX, 0)
            XCTAssertGreaterThanOrEqual(tile.minY, 0)
            XCTAssertLessThanOrEqual(tile.maxX, CGFloat(width))
            XCTAssertLessThanOrEqual(tile.maxY, CGFloat(height))
        }
        // Every pixel (sampled) falls in some tile.
        for y in stride(from: 0, to: height, by: 16) {
            for x in stride(from: 0, to: width, by: 16) {
                XCTAssertTrue(tiles.contains { $0.contains(CGPoint(x: x, y: y)) }, "(\(x), \(y)) uncovered")
            }
        }
        // Neighbours share about a quarter of a tile.
        let first = tiles[0], second = tiles[1]
        let shared = first.maxX - second.minX
        XCTAssertEqual(Double(shared / first.width), 0.25, accuracy: 0.02)
    }

    func testOneTileIsTheWholePhoto() {
        XCTAssertEqual(PersonCheck.tiles(width: 100, height: 80, columns: 1, rows: 1, overlap: 0.25),
                       [CGRect(x: 0, y: 0, width: 100, height: 80)])
    }

    /// A box at Vision's bottom-left lands at the mask's bottom-left rows, grown by the padding.
    func testABoxLandsUprightAndPadded() {
        let width = 10, height = 10
        var bytes = [UInt8](repeating: 0, count: width * height)
        PersonCheck.fill(normalizedBox: CGRect(x: 0.2, y: 0.0, width: 0.2, height: 0.2), padding: 0.5,
                         into: &bytes, maskWidth: width, maskHeight: height)
        func set(_ x: Int, _ y: Int) -> Bool { bytes[y * width + x] == 255 }
        // Box x 0.2...0.4 padded by 0.1 each side: columns 1...4; y 0...0.2 from the bottom,
        // padded: rows 7...9 from the top (clipped at the bottom edge).
        XCTAssertTrue(set(1, 9))
        XCTAssertTrue(set(4, 7))
        XCTAssertFalse(set(5, 9))
        XCTAssertFalse(set(0, 9))
        XCTAssertFalse(set(2, 6))
        XCTAssertFalse(set(2, 0), "nothing at the top")
    }
}
