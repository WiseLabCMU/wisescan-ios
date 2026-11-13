import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import scan4d_ios

/// Applying the Privacy Filter to a scan captured with it off (`PrivacyFilterReapply`): the
/// metadata it writes, which frames then wait for a mask, the masks it generates, and that a frame
/// the person check can't read fails closed.
@MainActor
final class PrivacyFilterReapplyTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("reapply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("raw_data/images"),
                                                withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var raw: URL { root.appendingPathComponent("raw_data") }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func readJSON(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// A small solid-color JPEG standing in for a captured frame.
    private func writeFrame(_ stem: String) throws {
        let width = 64, height = 48
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: raw.appendingPathComponent("images/\(stem).jpg"))
    }

    /// The decoded mask: 8-bit gray (colorize reads one byte per pixel), and its pixel values.
    private func maskPixels(_ png: Data) throws -> (bitsPerPixel: Int, values: Set<UInt8>) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let bytes = try XCTUnwrap(image.dataProvider?.data as Data?)
        return (image.bitsPerPixel, Set(bytes))
    }

    // MARK: Marking

    func testRoomMetadataGetsTheFlagAndKeepsEverythingElse() throws {
        try writeJSON(["privacy_filter": false, "device": "iPad"], to: raw.appendingPathComponent("scan4d_metadata.json"))
        try writeJSON(["privacy_filter": false, "frames": 3], to: root.appendingPathComponent("scan4d_metadata.json"))
        XCTAssertTrue(PrivacyFilterReapply.isUnfiltered(record: .room(rawData: raw)))

        XCTAssertTrue(PrivacyFilterReapply.markRoomMetadata(rawData: raw, scanDirectory: root, at: Date()))

        let rawMeta = try readJSON(raw.appendingPathComponent("scan4d_metadata.json"))
        XCTAssertEqual(rawMeta["privacy_filter"] as? Bool, true)
        XCTAssertNotNil(rawMeta[PrivacyFilterReapply.appliedAfterCaptureKey])
        XCTAssertEqual(rawMeta["device"] as? String, "iPad")
        let topMeta = try readJSON(root.appendingPathComponent("scan4d_metadata.json"))
        XCTAssertEqual(topMeta["privacy_filter"] as? Bool, true)
        XCTAssertEqual(topMeta["frames"] as? Int, 3)
        XCTAssertFalse(PrivacyFilterReapply.isUnfiltered(record: .room(rawData: raw)), "no longer offered")
    }

    func testRoomWithoutMetadataIsNotMarkedOrOffered() {
        XCTAssertFalse(PrivacyFilterReapply.markRoomMetadata(rawData: raw, scanDirectory: root, at: Date()))
        XCTAssertFalse(PrivacyFilterReapply.isUnfiltered(record: .room(rawData: raw)),
                       "an unreadable state is not offered")
    }

    func testFocusManifestGetsTheFlagAndKeepsEverythingElse() throws {
        let folder = root.appendingPathComponent("focus_capture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try writeJSON(["setup": ["privacyFilter": false, "detail": "splat"], "stills": 5],
                      to: folder.appendingPathComponent("manifest.json"))
        XCTAssertTrue(PrivacyFilterReapply.isUnfiltered(record: .focus(captureFolder: folder)))

        XCTAssertTrue(PrivacyFilterReapply.markFocusManifest(captureFolder: folder, at: Date()))

        let manifest = try readJSON(folder.appendingPathComponent("manifest.json"))
        let setup = try XCTUnwrap(manifest["setup"] as? [String: Any])
        XCTAssertEqual(setup["privacyFilter"] as? Bool, true)
        XCTAssertEqual(setup["detail"] as? String, "splat")
        XCTAssertEqual(manifest["stills"] as? Int, 5)
        XCTAssertFalse(PrivacyFilterReapply.isUnfiltered(record: .focus(captureFolder: folder)))
    }

    // MARK: Which frames wait for a mask

    /// Only a scan the filter was applied to after capture waits for masks: one captured with the
    /// filter on also lacks masks for its first frames, and those keep the export's fallback.
    func testOnlyAnAppliedScanWaitsForMasks() throws {
        try writeFrame("frame_00000")
        try writeJSON(["privacy_filter": true], to: raw.appendingPathComponent("scan4d_metadata.json"))
        XCTAssertFalse(PrivacyFilterReapply.masksPending(rawData: raw))

        XCTAssertTrue(PrivacyFilterReapply.markRoomMetadata(rawData: raw, scanDirectory: root, at: Date()))
        XCTAssertEqual(PrivacyFilterReapply.framesNeedingMasks(rawData: raw), ["frame_00000"])
    }

    func testFramesThatAlreadyHaveMasksAreLeftAlone() throws {
        for stem in ["frame_00000", "frame_00001", "frame_00002"] { try writeFrame(stem) }
        try writeJSON(["privacy_filter": false], to: raw.appendingPathComponent("scan4d_metadata.json"))
        XCTAssertTrue(PrivacyFilterReapply.markRoomMetadata(rawData: raw, scanDirectory: root, at: Date()))
        let masks = raw.appendingPathComponent("masks")
        try FileManager.default.createDirectory(at: masks, withIntermediateDirectories: true)
        let existing = try XCTUnwrap(PrivacyFilterReapply.filledMask(0))
        try existing.write(to: masks.appendingPathComponent("frame_00001.png"))

        XCTAssertEqual(PrivacyFilterReapply.framesNeedingMasks(rawData: raw), ["frame_00000", "frame_00002"])
        XCTAssertEqual(PrivacyFilterReapply.generateMasks(rawData: raw), 2)
        XCTAssertFalse(PrivacyFilterReapply.masksPending(rawData: raw), "the step is done once every photo has a mask")
        XCTAssertEqual(try Data(contentsOf: masks.appendingPathComponent("frame_00001.png")), existing,
                       "a capture-time mask is never replaced")
        for stem in ["frame_00000", "frame_00002"] {
            let png = try Data(contentsOf: masks.appendingPathComponent("\(stem).png"))
            XCTAssertEqual(try maskPixels(png).bitsPerPixel, 8, "8-bit gray, as capture writes")
        }
    }

    // MARK: Fail closed

    /// A frame the person check can't read gets a mask over the whole frame: the export pixelates
    /// all of it and zeroes its depth, and colorize takes no color from it.
    func testAnUnreadableFrameIsMaskedWhole() throws {
        for jpeg in [nil, Data("not a jpeg".utf8)] {
            let (png, checked) = PrivacyFilterReapply.maskPNG(forFrameJPEG: jpeg)
            XCTAssertFalse(checked)
            let pixels = try maskPixels(try XCTUnwrap(png))
            XCTAssertEqual(pixels.bitsPerPixel, 8)
            XCTAssertEqual(pixels.values, [255])
        }
    }

    func testFilledMasksAreUniform() throws {
        XCTAssertEqual(try maskPixels(try XCTUnwrap(PrivacyFilterReapply.filledMask(0))).values, [0])
        XCTAssertEqual(try maskPixels(try XCTUnwrap(PrivacyFilterReapply.filledMask(255))).values, [255])
    }
}
