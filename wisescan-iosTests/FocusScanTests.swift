import CoreGraphics
import simd
import XCTest
@testable import wisescan_ios

/// Focus scan filing and export helpers that run without a device.
@MainActor
final class FocusScanTests: XCTestCase {

    /// The person mask comes back from Vision upright (portrait); the blur and the depth zeroing
    /// need it in the still's sensor orientation. `.right` sends the sensor's top-left to the
    /// upright top-right, so a mark there must land back at the sensor's top-left.
    func testSensorOrientationMaskUndoesTheUprightTurn() throws {
        // Upright 2 wide x 3 tall; mark (x 1, y 0), the top-right.
        var bytes = [UInt8](repeating: 0, count: 6)
        bytes[0 * 2 + 1] = 255
        let mask = EquirectPrivacyBlur.FaceMask(bytes: bytes, width: 2, height: 3, hasPerson: true)
        let image = try XCTUnwrap(FocusStillPrivacy.sensorOrientationMask(mask))
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.height, 2)
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let row = image.bytesPerRow
        XCTAssertEqual(data[0 * row + 0], 255, "upright top-right is the sensor's top-left")
        XCTAssertEqual(data.prefix(row * 2).filter { $0 == 255 }.count, 1)
    }

    func testBestStillSkipsBlurredAndPrefersAGoodRegionShare() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("focus_test_\(UUID().uuidString)")
        let photos = dir.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for n in 0..<4 {
            try Data([0xFF]).write(to: photos.appendingPathComponent(String(format: "photo_%05d.jpg", n)))
        }
        // photo 1 is closest to the ideal share but blurred at capture; photo 2 is next closest.
        let csv = """
        index,file,capture_gyro_smear_rad,capture_over_budget,region_frame_coverage
        0,photos/photo_00000.jpg,0.0002,0,0.05
        1,photos/photo_00001.jpg,0.0020,1,0.35
        2,photos/photo_00002.jpg,0.0004,0,0.30
        3,photos/photo_00003.jpg,0.0001,0,0.90
        """
        try csv.write(to: dir.appendingPathComponent("photos.csv"), atomically: true, encoding: .utf8)
        XCTAssertEqual(FocusScanThumbnail.bestStill(in: dir)?.lastPathComponent, "photo_00002.jpg")
    }

    func testBestStillFallsBackToTheFirstStill() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("focus_test_\(UUID().uuidString)")
        let photos = dir.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([0xFF]).write(to: photos.appendingPathComponent("photo_00003.jpg"))
        try Data([0xFF]).write(to: photos.appendingPathComponent("photo_00001.jpg"))
        XCTAssertEqual(FocusScanThumbnail.bestStill(in: dir)?.lastPathComponent, "photo_00001.jpg", "no photos.csv")
    }

    func testRegionPlacementGoesThroughTheMapScansRegistration() {
        let mapScan = UUID()
        var registration = matrix_identity_float4x4
        registration.columns.3 = SIMD4(1, 0, 0, 1)   // raw -> canonical: +1 m in x
        let canonical = FocusRegion(center: SIMD3(2, 0.5, 0), size: SIMD3(1, 1, 1), frameScanId: mapScan, frameIsCanonical: true)
        let placed = canonical.placement(inRawFrameOf: mapScan, appliedRegistration: registration)
        XCTAssertEqual(placed.boxToMap.columns.3.x, 1, accuracy: 1e-6, "canonical x 2 is raw x 1")
        // Drawn on that same scan's raw (unregistered) mesh: already in its frame.
        let raw = FocusRegion(center: SIMD3(2, 0.5, 0), size: SIMD3(1, 1, 1), frameScanId: mapScan, frameIsCanonical: false)
        XCTAssertEqual(raw.placement(inRawFrameOf: mapScan, appliedRegistration: registration).boxToMap.columns.3.x, 2, accuracy: 1e-6)
        XCTAssertEqual(placed.halfExtents, SIMD3(0.5, 0.5, 0.5))
    }
}
