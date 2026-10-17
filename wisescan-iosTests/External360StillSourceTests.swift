import XCTest
import UIKit
@testable import wisescan_ios

final class External360StillSourceTests: XCTestCase {
    private var createdDirs: [URL] = []

    override func tearDown() {
        for dir in createdDirs { try? FileManager.default.removeItem(at: dir) }
        createdDirs = []
        super.tearDown()
    }

    func testPendingImportTickets_onlyReturnsManualPlaceholdersWithoutJPEG() throws {
        let rawDataDir = try makeRawDataDir()
        try writeTicket(rawDataDir: rawDataDir, sequence: 1, capturedAtEpochMs: 1_000)
        try writeTicket(rawDataDir: rawDataDir, sequence: 2, capturedAtEpochMs: 2_000,
                        cameraFileURL: "http://192.168.1.1/files/live.jpg")
        try jpegData(color: .red).write(
            to: rawDataDir.appendingPathComponent("equirect_stills/still_0003.JPG"))
        try writeTicket(rawDataDir: rawDataDir, sequence: 3, capturedAtEpochMs: 3_000)

        let tickets = External360StillSource.pendingImportTickets(rawDataPath: rawDataDir)
        XCTAssertEqual(tickets.map(\.sequence), [1])
        XCTAssertEqual(tickets.first?.capturedAtEpochMs, 1_000)
    }

    func testImportPendingStills_matchesByTimestampAndIgnoresExtraLeadingShot() throws {
        let rawDataDir = try makeRawDataDir()
        try writeTicket(rawDataDir: rawDataDir, sequence: 1, capturedAtEpochMs: 10_000)
        try writeTicket(rawDataDir: rawDataDir, sequence: 2, capturedAtEpochMs: 20_000)
        try writeTicket(rawDataDir: rawDataDir, sequence: 3, capturedAtEpochMs: 30_000)

        let extra = try makeJPEG(name: "extra.jpg", color: .black, mtimeSeconds: 9)
        let first = try makeJPEG(name: "first.jpg", color: .red, mtimeSeconds: 10)
        let second = try makeJPEG(name: "second.jpg", color: .green, mtimeSeconds: 20)
        let third = try makeJPEG(name: "third.jpg", color: .blue, mtimeSeconds: 30)

        let outcome = External360StillSource.importPendingStills(
            rawDataPath: rawDataDir, from: [third, extra, second, first]
        )

        XCTAssertEqual(outcome.imported, 3)
        XCTAssertEqual(outcome.remaining, 0)
        XCTAssertEqual(outcome.ignored, 1)
        XCTAssertTrue(outcome.message.contains("1 extra file ignored"))
        XCTAssertEqual(
            try Data(contentsOf: rawDataDir.appendingPathComponent("equirect_stills/still_0001.JPG")),
            try jpegData(color: .red)
        )
        XCTAssertEqual(
            try Data(contentsOf: rawDataDir.appendingPathComponent("equirect_stills/still_0002.JPG")),
            try jpegData(color: .green)
        )
        XCTAssertEqual(
            try Data(contentsOf: rawDataDir.appendingPathComponent("equirect_stills/still_0003.JPG")),
            try jpegData(color: .blue)
        )
    }

    func testImportPendingStills_reportsLargeTimeMismatchAndRejectsPNG() throws {
        let rawDataDir = try makeRawDataDir()
        try writeTicket(rawDataDir: rawDataDir, sequence: 1, capturedAtEpochMs: 10_000)
        try writeTicket(rawDataDir: rawDataDir, sequence: 2, capturedAtEpochMs: 20_000)

        let first = try makeJPEG(name: "first.jpg", color: .red, mtimeSeconds: 10)
        let late = try makeJPEG(name: "late.jpg", color: .green, mtimeSeconds: 80)
        let mismatchOutcome = External360StillSource.importPendingStills(
            rawDataPath: rawDataDir, from: [late, first]
        )

        XCTAssertEqual(mismatchOutcome.imported, 2)
        XCTAssertTrue(mismatchOutcome.message.contains("largest time mismatch 60s"))

        let secondRawDataDir = try makeRawDataDir()
        try writeTicket(rawDataDir: secondRawDataDir, sequence: 1, capturedAtEpochMs: 10_000)
        let png = try makePNG(name: "pano.png", color: .purple)
        let pngOutcome = External360StillSource.importPendingStills(
            rawDataPath: secondRawDataDir, from: [png]
        )

        XCTAssertEqual(pngOutcome.imported, 0)
        XCTAssertEqual(pngOutcome.remaining, 1)
        XCTAssertTrue(pngOutcome.message.contains("No stitched equirect JPEGs were selected"))
    }

    private func makeRawDataDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("external360-\(UUID().uuidString)", isDirectory: true)
        let stillsDir = root.appendingPathComponent("equirect_stills", isDirectory: true)
        try FileManager.default.createDirectory(at: stillsDir, withIntermediateDirectories: true)
        createdDirs.append(root)
        return root
    }

    private func writeTicket(rawDataDir: URL,
                             sequence: Int,
                             capturedAtEpochMs: Int64,
                             cameraFileURL: String? = nil) throws {
        let sidecarURL = rawDataDir.appendingPathComponent(
            String(format: "equirect_stills/still_%04d.json", sequence)
        )
        let object: [String: Any] = [
            "sequence": sequence,
            "still_source": External360CameraModel.insta360X6.rawValue,
            "camera_model": "equirectangular",
            "camera_file_url": cameraFileURL ?? External360StillSource.pendingImportURL(sequence: sequence),
            "phone_transform": Array(repeating: 0.0, count: 16),
            "frame_timestamp": Double(sequence),
            "captured_at_epoch_ms": capturedAtEpochMs,
            "trigger_ms": 0,
            "shutter_path": "manual-import"
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: sidecarURL)
    }

    private func makeJPEG(name: String, color: UIColor, mtimeSeconds: TimeInterval) throws -> URL {
        let url = try makeImportedAssetURL(name: name)
        try jpegData(color: color).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: mtimeSeconds)],
            ofItemAtPath: url.path
        )
        return url
    }

    private func makePNG(name: String, color: UIColor) throws -> URL {
        let url = try makeImportedAssetURL(name: name)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100))
        let data = renderer.pngData { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }
        try data.write(to: url)
        return url
    }

    private func makeImportedAssetURL(name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("external360-picked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        createdDirs.append(dir)
        return dir.appendingPathComponent(name)
    }

    private func jpegData(color: UIColor) throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100))
        let imageData = renderer.jpegData(withCompressionQuality: 0.95) { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }
        return imageData
    }
}
