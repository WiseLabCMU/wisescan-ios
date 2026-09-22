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
    ///
    /// `withMetadata` plants the `scan4d_metadata.json` capture-stop writes, which is the file
    /// saveScan patches with `incomplete_artifacts`; without it that patch is a silent no-op and
    /// the artifact-failure assertions below would pass vacuously.
    private func makeRawDataDir(depthBytes: Data, withMetadata: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawdata-\(UUID().uuidString)", isDirectory: true)
        let depthDir = root.appendingPathComponent("depth", isDirectory: true)
        try FileManager.default.createDirectory(at: depthDir, withIntermediateDirectories: true)
        try depthBytes.write(to: depthDir.appendingPathComponent("frame_00000.png"))
        if withMetadata {
            let meta = try JSONSerialization.data(withJSONObject: ["scan4d_version": 1])
            try meta.write(to: root.appendingPathComponent("scan4d_metadata.json"))
        }
        createdDirs.append(root)
        return root
    }

    /// Builds the temp world-map export exactly as `VertexColorAccumulator.exportWorldMap` leaves
    /// it: `worldmap_<hex>.worldmap` with its DERIVED-STEM sidecars beside it. Each sidecar is
    /// planted only when its bytes are non-nil, so a caller can model "that sidecar's write
    /// failed" — which is the only way to reach saveScan's two divergent missing-sidecar paths.
    ///
    /// Everything is synthesized in-process: saveScan promotes these files by name and never
    /// parses them, so no ARWorldMap and no captured fixture data is involved.
    private func makeWorldMapExport(features: Data?, relocQuality: Data?) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("worldmap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        createdDirs.append(root)

        let mapURL = root.appendingPathComponent("worldmap_\(UUID().uuidString.prefix(8)).worldmap")
        try mapBytes.write(to: mapURL)
        if let features {
            try features.write(to: FeaturePointCloudFile.tempURL(besideWorldMap: mapURL))
        }
        if let relocQuality {
            try relocQuality.write(to: PromotionGate.tempURL(besideWorldMap: mapURL))
        }
        return mapURL
    }

    /// Where the promoted quality report has to land: `reloc_quality.json` at the scan directory's
    /// top level, beside the promoted map and feature cloud. Spelled from `PromotionGate.filename`
    /// rather than a literal so producer and consumer can never drift apart on the name.
    private func relocQualityURL(of scan: CapturedScan) -> URL {
        scan.scanDirectory.appendingPathComponent(PromotionGate.filename)
    }

    /// The `incomplete_artifacts` list saveScan patches into the moved `scan4d_metadata.json`,
    /// or nil when the key was never written (i.e. nothing was reported missing).
    private func incompleteArtifacts(in scan: CapturedScan) throws -> [String]? {
        let data = try Data(contentsOf: scan.rawDataPath.appendingPathComponent("scan4d_metadata.json"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any],
                                 "scan4d_metadata.json should still be a JSON object after the patch")
        return json["incomplete_artifacts"] as? [String]
    }

    /// Non-OBJ bytes: keeps the test hermetic by short-circuiting MeshPreviewView.generateSnapshot
    /// (it returns nil when the mesh doesn't parse), so no SceneKit/Metal work runs. saveScan still
    /// writes these bytes verbatim to mesh.obj, which is what we assert on.
    private let meshBytes = Data("WISESCAN_TEST_MESH".utf8)
    private let depthBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])

    /// World map + sidecar payloads. Deliberately not real archives/clouds: saveScan promotes all
    /// three by name and reads none of them, so distinct marker bytes prove WHICH temp file landed
    /// at WHICH final name (a swapped promotion would otherwise look like a pass).
    private let mapBytes = Data("WISESCAN_TEST_WORLDMAP".utf8)
    private let featureBytes = Data("WISESCAN_TEST_FEATURES".utf8)
    private let relocQualityBytes = Data(#"{"test":"reloc_quality"}"#.utf8)

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

        // The raw-dir mesh mirror exists and carries the same bytes. It is hard-linked from the
        // top-level copy (with an atomic-write fallback), so a silent total link failure would
        // otherwise be invisible: nothing else asserts this file.
        let rawMesh = scan.rawDataPath.appendingPathComponent("mesh.obj")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawMesh.path),
                      "raw_data/mesh.obj mirror missing at \(rawMesh.path)")
        XCTAssertEqual(try Data(contentsOf: rawMesh), meshBytes)
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

    // MARK: - World-map promotion

    /// The happy path of the `worldMapURL` branch: map + both derived-stem sidecars promoted into
    /// the scan directory under their final names. Every case above passes `worldMapURL: nil`, so
    /// without this the whole promotion block — including the SHIPPING feature cloud — is unrun.
    func testSaveScan_worldMapWithSidecars_promotesFeatureCloudAndRelocQuality() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let locId = UUID()
        context.insert(ScanLocation(id: locId, name: "Lab"))
        let rawDir = try makeRawDataDir(depthBytes: depthBytes, withMetadata: true)
        let mapURL = try makeWorldMapExport(features: featureBytes, relocQuality: relocQualityBytes)

        let scan = try XCTUnwrap(
            ScanFileManager.shared.saveScan(
                context: context, locationId: locId, name: "Lab",
                meshData: meshBytes, vertexCount: 3, faceCount: 1,
                rawDataPath: rawDir, vertexColors: nil, worldMapURL: mapURL
            )
        )
        cleanupAfter(scan)

        // The map itself (hard-linked, with a copy fallback) lands at the fixed scan-dir name.
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.worldMapURL.path),
                      "world map missing at \(scan.worldMapURL.path)")
        XCTAssertEqual(try Data(contentsOf: scan.worldMapURL), mapBytes)

        // arkit_features.bin: the shipping artifact, looked up beside the temp map by derived stem.
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.featurePointsURL.path),
                      "\(FeaturePointCloudFile.filename) missing at \(scan.featurePointsURL.path)")
        XCTAssertEqual(try Data(contentsOf: scan.featurePointsURL), featureBytes,
                       "the feature cloud sidecar's bytes should reach featurePointsURL verbatim")

        // reloc_quality.json: the promoted diagnostic, same derived-stem mechanism.
        XCTAssertTrue(FileManager.default.fileExists(atPath: relocQualityURL(of: scan).path),
                      "reloc_quality.json missing at \(relocQualityURL(of: scan).path)")
        XCTAssertEqual(try Data(contentsOf: relocQualityURL(of: scan)), relocQualityBytes)

        // Nothing was lost, so the bundle must NOT advertise itself as incomplete.
        XCTAssertEqual(ScanFileManager.shared.lastSaveArtifactFailures, [])
        XCTAssertNil(try incompleteArtifacts(in: scan),
                     "a complete save should leave incomplete_artifacts unwritten")
    }

    /// Regression net for the bare-`try?` decision on the reloc-quality promotion: it is a
    /// DIAGNOSTIC file, excluded from exports and from the metadata schema, so a missing one is
    /// not a defect of the bundle and must never be named in `incomplete_artifacts`. Refactoring
    /// that promotion into `bestEffort` (which is what the neighbouring lines look like) would
    /// start reporting every map-less-diagnostic save as incomplete — and fail here.
    func testSaveScan_relocQualitySidecarMissing_savesWithoutNamingIt() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let locId = UUID()
        context.insert(ScanLocation(id: locId, name: "Lab"))
        let rawDir = try makeRawDataDir(depthBytes: depthBytes, withMetadata: true)
        let mapURL = try makeWorldMapExport(features: featureBytes, relocQuality: nil)

        let scan = try XCTUnwrap(
            ScanFileManager.shared.saveScan(
                context: context, locationId: locId, name: "Lab",
                meshData: meshBytes, vertexCount: 3, faceCount: 1,
                rawDataPath: rawDir, vertexColors: nil, worldMapURL: mapURL
            ),
            "a missing diagnostic sidecar must not cost the operator the save"
        )
        cleanupAfter(scan)

        // The shipping artifacts are unaffected by the diagnostic's absence.
        XCTAssertTrue(FileManager.default.fileExists(atPath: scan.worldMapURL.path))
        XCTAssertEqual(try Data(contentsOf: scan.featurePointsURL), featureBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: relocQualityURL(of: scan).path),
                       "nothing should have been promoted to reloc_quality.json")

        XCTAssertFalse(ScanFileManager.shared.lastSaveArtifactFailures.contains(PromotionGate.filename),
                       "reloc_quality.json is a diagnostic; its absence is not a bundle defect: " +
                       "\(ScanFileManager.shared.lastSaveArtifactFailures)")
        XCTAssertEqual(ScanFileManager.shared.lastSaveArtifactFailures, [],
                       "no artifact failure at all should be recorded for a missing diagnostic")
        XCTAssertNil(try incompleteArtifacts(in: scan),
                     "incomplete_artifacts should not even be written for a missing diagnostic")
    }

    /// The other half of the deliberate asymmetry: the feature cloud DOES ship, every exported map
    /// writes one (a point-less cloud is still a header-only file), so its absence means the
    /// save-time write failed and a consumer must be told. Pins that `arkit_features.bin` — and
    /// only it — reaches the failure list and `incomplete_artifacts`.
    func testSaveScan_featureSidecarMissing_namesFeatureCloudOnly() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let locId = UUID()
        context.insert(ScanLocation(id: locId, name: "Lab"))
        let rawDir = try makeRawDataDir(depthBytes: depthBytes, withMetadata: true)
        let mapURL = try makeWorldMapExport(features: nil, relocQuality: relocQualityBytes)

        let scan = try XCTUnwrap(
            ScanFileManager.shared.saveScan(
                context: context, locationId: locId, name: "Lab",
                meshData: meshBytes, vertexCount: 3, faceCount: 1,
                rawDataPath: rawDir, vertexColors: nil, worldMapURL: mapURL
            ),
            "a missing feature cloud is reported, not fatal — the save still returns a scan"
        )
        cleanupAfter(scan)

        XCTAssertFalse(FileManager.default.fileExists(atPath: scan.featurePointsURL.path),
                       "nothing should have been promoted to \(FeaturePointCloudFile.filename)")
        // The two promotions are independent: one missing sidecar must not skip the other.
        XCTAssertEqual(try Data(contentsOf: relocQualityURL(of: scan)), relocQualityBytes)

        XCTAssertTrue(ScanFileManager.shared.lastSaveArtifactFailures.contains(FeaturePointCloudFile.filename),
                      "a lost shipping artifact must be named: \(ScanFileManager.shared.lastSaveArtifactFailures)")
        XCTAssertFalse(ScanFileManager.shared.lastSaveArtifactFailures.contains(PromotionGate.filename))

        let missing = try XCTUnwrap(try incompleteArtifacts(in: scan),
                                    "incomplete_artifacts should be patched into scan4d_metadata.json")
        XCTAssertEqual(missing, [FeaturePointCloudFile.filename],
                       "only the shipping artifact belongs in the bundle's self-description")
    }
}
