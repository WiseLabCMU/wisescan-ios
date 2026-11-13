import CoreGraphics
import XCTest
@testable import scan4d_ios

/// The geometry of the person check (`PersonCheck`): its tiles cover the photo with overlap, a
/// Vision box (origin bottom-left) lands in the mask (origin top-left), padded and clipped, a box
/// found in a tile lands where the tile is, and segmentation counts only where it touches a box.
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

    /// A box a detector finds in a tile lands where that tile sits in the photo: the tile is in
    /// pixels from the top-left, the boxes are normalized from the bottom-left.
    func testATileBoxLandsWhereTheTileIs() {
        // The photo's top-right quarter of a 200 x 100 photo.
        let tile = CGRect(x: 100, y: 0, width: 100, height: 50)
        let whole = PersonCheck.photoBox(CGRect(x: 0, y: 0, width: 1, height: 1), inTile: tile, width: 200, height: 100)
        XCTAssertEqual(whole.minX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(whole.minY, 0.5, accuracy: 1e-9, "the top half, from the bottom")
        XCTAssertEqual(whole.width, 0.5, accuracy: 1e-9)
        XCTAssertEqual(whole.height, 0.5, accuracy: 1e-9)
        // The tile's bottom-left quarter starts at the photo's centre and reaches up and right.
        let corner = PersonCheck.photoBox(CGRect(x: 0, y: 0, width: 0.5, height: 0.5), inTile: tile, width: 200, height: 100)
        XCTAssertEqual(corner, CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25))
    }

    /// Segmentation is kept where it touches a box, whole, and dropped where it touches none.
    func testSegmentationNeedsABox() {
        // 6 x 3: a region at the left with a box on one of its pixels, and one at the right alone.
        let width = 6, height = 3
        let segmentation: [UInt8] = [
            255, 255, 0, 0, 255, 255,
            255, 0, 0, 0, 0, 255,
            0, 0, 0, 0, 0, 0
        ]
        var boxes = [UInt8](repeating: 0, count: width * height)
        boxes[1 * width + 0] = 255
        let regions = PersonCheck.keepTouching(segmentation, boxes: boxes, width: width, height: height)
        XCTAssertEqual(regions.keptRegions, 1)
        XCTAssertEqual(regions.droppedRegions, 1)
        XCTAssertEqual(regions.droppedPixels, 3)
        XCTAssertEqual(Array(regions.kept[0..<2]), [255, 255], "the whole touching region is kept")
        XCTAssertEqual(regions.kept[1 * width + 0], 255)
        XCTAssertEqual(Array(regions.kept[4..<6]), [0, 0], "the lone region is dropped")
        XCTAssertEqual(regions.kept[1 * width + 5], 0)
    }

    /// Regions that touch only diagonally are separate: a box on one keeps only that one.
    func testDiagonalNeighboursAreSeparateRegions() {
        let segmentation: [UInt8] = [255, 0, 0, 255]
        let boxes: [UInt8] = [255, 0, 0, 0]
        let regions = PersonCheck.keepTouching(segmentation, boxes: boxes, width: 2, height: 2)
        XCTAssertEqual(regions.kept, [255, 0, 0, 0])
        XCTAssertEqual(regions.droppedRegions, 1)
    }
}
