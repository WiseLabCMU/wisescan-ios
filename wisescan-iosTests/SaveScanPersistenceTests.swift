import XCTest
import SwiftData
@testable import wisescan_ios

/// Guards `ScanFileManager.saveScan`'s on-disk persistence path.
///
/// `CapturedScan.scanDirectory` is derived from `location?.id` (falling back to
/// "unknown_location" when nil), and `meshFileURL` / `rawDataPath` hang off it. So the scan MUST
/// be linked to its location BEFORE its files are written, otherwise:
///   - the mesh is written under .../Scans/unknown_location/<id>/ while the record points at the
///     location-scoped path (blank preview, failed export), and
///   - the raw_data move (which carries depth/, confidence/, images/) targets a parent directory
///     that was never created, so `moveItem` fails and that data — including depth — is lost.
///
/// Both regressed together once; these tests pin the file placement so it can't silently happen again.
@MainActor
final class SaveScanPersistenceTests: XCTestCase {

    /// Directories created on the real Documents/temp filesystem during a test, removed in tearDown.
    private var createdDirs: [URL] = []

    override func tearDown() {
        for dir in createdDirs { try? FileManager.default.removeItem(at: dir) }
        createdDirs = []
        super.tearDown()
    }

    /// Builds a temp directory shaped like what FrameCaptureSession hands to saveScan: a capture
    /// dir containing `depth/frame_00000.png`. saveScan moves this whole dir into the scan.
    private func makeRawDataDir(depthBytes: Data) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawdata-\(UUID().uuidString)", isDirectory: true)
        let depthDir = root.appendingPathComponent("depth", isDirectory: true)
        try FileManager.default.createDirectory(at: depthDir, withIntermediateDirectories: true)
        try depthBytes.write(to: depthDir.appendingPathComponent("frame_00000.png"))
        createdDirs.append(root)
        return root
    }

    /// Non-OBJ bytes: keeps the test hermetic by short-circuiting MeshPreviewView.generateSnapshot
    /// (it returns nil when the mesh doesn't parse), so no SceneKit/Metal work runs. saveScan still
    /// writes these bytes verbatim to mesh.obj, which is what we assert on.
    private let meshBytes = Data("WISESCAN_TEST_MESH".utf8)
    private let depthBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])

    /// Tracks the created location directory for cleanup and returns the scan.
    private func cleanupAfter(_ scan: CapturedScan) {
        createdDirs.append(scan.scanDirectory.deletingLastPathComponent()) // .../Scans/<locId>
    }

    func testSaveScan_existingLocation_writesMeshAndDepthUnderLocationScopedDir() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let locId = UUID()
        context.insert(ScanLocation(id: locId, name: "Garage"))
        let rawDir = try makeRawDataDir(depthBytes: depthBytes)

        let scan = try XCTUnwrap(
            ScanFileManager.shared.saveScan(
                context: context, locationId: locId, name: "Garage",
                meshData: meshBytes, vertexCount: 3, faceCount: 1,
                rawDataPath: rawDir, vertexColors: nil, worldMapURL: nil
            ),
            "saveScan should return a scan when the mesh write succeeds"
        )
        cleanupAfter(scan)

        // Linked to the location, and its directory is location-scoped (NOT the fallback).
        XCTAssertEqual(scan.location?.id, locId)
        XCTAssertTrue(scan.scanDirectory.path.contains(locId.uuidString),
                      "scanDirectory should be under the location id: \(scan.scanDirectory.path)")
        XCTAssertFalse(scan.scanDirectory.path.contains("unknown_location"))

        // Mesh exists at the FINAL location-scoped path (the regression stranded it under
        // unknown_location, so meshFileURL resolved to a missing file).
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.meshFileURL.path),
                      "mesh.obj missing at \(scan.meshFileURL.path)")
        XCTAssertEqual(try Data(contentsOf: scan.meshFileURL), meshBytes)

        // raw_data (with depth/) survived the move (the regression's moveItem failed because the
        // location-scoped parent never existed → depth lost).
        let movedDepth = scan.rawDataPath.appendingPathComponent("depth/frame_00000.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedDepth.path),
                      "depth frame missing at \(movedDepth.path)")
        XCTAssertEqual(try Data(contentsOf: movedDepth), depthBytes)
    }

    func testSaveScan_newLocationByName_createsLocationAndPlacesFiles() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let rawDir = try makeRawDataDir(depthBytes: depthBytes)

        let scan = try XCTUnwrap(
            ScanFileManager.shared.saveScan(
                context: context, locationId: nil, name: "New Space",
                meshData: meshBytes, vertexCount: 3, faceCount: 1,
                rawDataPath: rawDir, vertexColors: nil, worldMapURL: nil
            )
        )
        cleanupAfter(scan)

        // A location was created and the files are scoped under its id, not "unknown_location".
        let newLoc = try XCTUnwrap(scan.location, "saveScan should create and link a new location")
        XCTAssertTrue(scan.scanDirectory.path.contains(newLoc.id.uuidString))
        XCTAssertFalse(scan.scanDirectory.path.contains("unknown_location"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.meshFileURL.path))
        let movedDepth = scan.rawDataPath.appendingPathComponent("depth/frame_00000.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedDepth.path),
                      "depth frame missing at \(movedDepth.path)")
    }
}
