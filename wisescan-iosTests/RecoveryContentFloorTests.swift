import XCTest
import SwiftData
@testable import wisescan_ios

/// Pins the content floor on the tracking-loss recovery save (issue #81, defect 2).
///
/// When ARKit drops its mesh anchors mid-scan, `finishStopRecording` reaches its meshless branch
/// and — for a non-extend flow — persists what it has as a mesh-less, map-less "Recovered Scan".
/// That gate used to be `rawFrameCount > 0`, so a two- or three-frame stub became a scan. Such a
/// stub is not merely useless: locations sort newest-first (`LocationDetailView.swift:60`) and both
/// Rescan Space and Connect Adjacent consume `sortedScans.first` (`:126`) and hard-gate on that
/// scan's world map file existing (`:718`, `:743`) — which a recovery scan never has. So the stub
/// shadows the location's good scans and disables both actions for the whole location.
///
/// The floor is therefore a decision made at the call site, expressed as two testable pieces:
///   - `FrameCaptureSession.capturedFrameCount(in:)` — how many RGB frames a finalized capture holds
///   - `FrameCaptureSession.recoveryHasEnoughContent(frameCount:)` — whether that clears the floor
///
/// These tests pin the behaviour in BOTH directions: an empty (or near-empty) recovery is refused,
/// and a legitimate minimal capture — including the Lite `vertexCount: 0` case — is still accepted
/// and still persists.
@MainActor
final class RecoveryContentFloorTests: XCTestCase {

    /// Directories created on the real temp/Documents filesystem during a test, removed in tearDown.
    private var createdDirs: [URL] = []

    override func tearDown() {
        for dir in createdDirs { try? FileManager.default.removeItem(at: dir) }
        createdDirs = []
        super.tearDown()
    }

    /// Builds a temp directory shaped like the one `FrameCaptureSession.stop()` returns: a capture
    /// dir containing `images/frame_NNNNN.jpg` — the only place and only name `captureFrame` writes
    /// RGB frames to, on every device class.
    private func makeCaptureDir(frameCount: Int, extraFiles: [String] = []) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
        let imagesDir = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        createdDirs.append(root)
        for index in 0..<frameCount {
            let name = String(format: "frame_%05d.jpg", index)
            try frameBytes.write(to: imagesDir.appendingPathComponent(name))
        }
        for name in extraFiles {
            try frameBytes.write(to: imagesDir.appendingPathComponent(name))
        }
        return root
    }

    /// Stand-in frame bytes. Never parsed by anything under test — `capturedFrameCount` reads names
    /// only, and `saveScan` copies the first frame to the thumbnail verbatim.
    private let frameBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])

    private func cleanupAfter(_ scan: CapturedScan) {
        createdDirs.append(scan.scanDirectory.deletingLastPathComponent()) // .../Scans/<locId>
    }

    // MARK: - What the floor counts

    /// CLAIM: the count is FRAME FILES, not directory entries. The old inline gate counted
    /// `contentsOfDirectory` entries, so any stray file read as "this capture has content".
    func testCapturedFrameCount_countsOnlyFrameJPEGs() throws {
        let captureDir = try makeCaptureDir(
            frameCount: 3,
            extraFiles: [".DS_Store", "notes.txt", "frame_00009.png", "thumbnail.jpg"]
        )

        // 7 entries in images/, but only 3 of them are frames.
        let entries = try FileManager.default.contentsOfDirectory(atPath: captureDir.appendingPathComponent("images").path)
        XCTAssertEqual(entries.count, 7, "fixture should hold 3 frames plus 4 non-frame files")
        XCTAssertEqual(FrameCaptureSession.capturedFrameCount(in: captureDir), 3,
                       "only images/frame_*.jpg may count as frames")
    }

    /// CLAIM: a nil capture dir, a capture dir with no `images/`, and an empty `images/` all count
    /// as zero frames — the same answer the replaced inline expression gave.
    func testCapturedFrameCount_absentOrEmptyImagesDir_isZero() throws {
        XCTAssertEqual(FrameCaptureSession.capturedFrameCount(in: nil), 0)

        let noImagesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-noimages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: noImagesDir, withIntermediateDirectories: true)
        createdDirs.append(noImagesDir)
        XCTAssertEqual(FrameCaptureSession.capturedFrameCount(in: noImagesDir), 0)

        let emptyImages = try makeCaptureDir(frameCount: 0)
        XCTAssertEqual(FrameCaptureSession.capturedFrameCount(in: emptyImages), 0)
    }

    // MARK: - An empty / near-empty recovery is refused

    /// CLAIM: an empty recovery does not clear the floor, so the recovery save is not taken and no
    /// "Recovered Scan" can be persisted from it.
    func testEmptyRecovery_isRefused() throws {
        let captureDir = try makeCaptureDir(frameCount: 0)
        let frames = FrameCaptureSession.capturedFrameCount(in: captureDir)

        XCTAssertEqual(frames, 0)
        XCTAssertFalse(FrameCaptureSession.recoveryHasEnoughContent(frameCount: frames),
                       "an empty capture must never persist as a scan")
    }

    /// CLAIM: the floor genuinely supersedes the old `rawFrameCount > 0` gate — the exact stub sizes
    /// named in the issue (one frame, three frames) are now refused, and so is floor-minus-one.
    func testStubRecovery_belowFloor_isRefused() throws {
        XCTAssertGreaterThan(AppConstants.minRecoveryFrames, 1,
                            "a floor of 1 or 0 would be the old > 0 gate under a new name")

        for frames in [1, 3, AppConstants.minRecoveryFrames - 1] {
            let captureDir = try makeCaptureDir(frameCount: frames)
            XCTAssertEqual(FrameCaptureSession.capturedFrameCount(in: captureDir), frames)
            XCTAssertFalse(FrameCaptureSession.recoveryHasEnoughContent(frameCount: frames),
                           "\(frames) frames is below the floor of \(AppConstants.minRecoveryFrames) and must be refused")
        }
    }

    // MARK: - A legitimate minimal capture is still accepted

    /// CLAIM: the floor is inclusive — a capture holding exactly `minRecoveryFrames` frames, and
    /// anything above it, is accepted. The floor rejects stubs, not small-but-real captures.
    func testMinimalRealRecovery_atOrAboveFloor_isAccepted() throws {
        for frames in [AppConstants.minRecoveryFrames, AppConstants.minRecoveryFrames + 1, AppConstants.minRecoveryFrames * 4] {
            let captureDir = try makeCaptureDir(frameCount: frames)
            XCTAssertEqual(FrameCaptureSession.capturedFrameCount(in: captureDir), frames)
            XCTAssertTrue(FrameCaptureSession.recoveryHasEnoughContent(frameCount: frames),
                          "\(frames) frames clears the floor of \(AppConstants.minRecoveryFrames) and must be accepted")
        }
    }

    /// CLAIM: the floor tests FRAMES, never vertices, so the Lite (no-LiDAR) case survives it.
    /// Lite devices have no `ARMeshAnchor`s at all and legitimately save `vertexCount: 0` scans
    /// whose raw frames are the entire payload (the deliberate 2026-07-22 fix). A vertex-count floor
    /// would have rejected every one of them; this predicate accepts them on frame count alone, and
    /// the scan still persists with its frames on disk.
    func testLegitimateLiteScan_zeroVertices_clearsFloorAndStillPersists() throws {
        let captureDir = try makeCaptureDir(frameCount: AppConstants.minRecoveryFrames)

        // The floor accepts it despite there being no mesh whatsoever.
        let frames = FrameCaptureSession.capturedFrameCount(in: captureDir)
        XCTAssertTrue(FrameCaptureSession.recoveryHasEnoughContent(frameCount: frames),
                      "a Lite capture with no vertices but real frames must clear the floor")

        // And it still persists: empty mesh, zero vertices, no world map — exactly the Lite save.
        let context = try StitchTestSupport.makeInMemoryContext()
        let locId = UUID()
        context.insert(ScanLocation(id: locId, name: "Hallway"))

        let scan = try XCTUnwrap(
            ScanFileManager.shared.saveScan(
                context: context, locationId: locId, name: "Hallway",
                meshData: Data(), vertexCount: 0, faceCount: 0,
                rawDataPath: captureDir, vertexColors: nil, worldMapURL: nil
            ),
            "a zero-vertex Lite scan must still save"
        )
        cleanupAfter(scan)

        XCTAssertEqual(scan.vertexCount, 0)
        XCTAssertEqual(scan.location?.id, locId)
        // The frames — the whole payload on this device class — reached the scan's raw_data.
        XCTAssertEqual(FrameCaptureSession.capturedFrameCount(in: scan.rawDataPath),
                       AppConstants.minRecoveryFrames,
                       "every frame should have moved into \(scan.rawDataPath.path)")
    }

    /// CLAIM (characterization, and the reason the floor lives at the call site): `saveScan` imposes
    /// no content floor of its own. Handed an empty mesh, zero vertices and a frameless raw dir it
    /// persists a scan happily. So the gate cannot be moved down into persistence without breaking
    /// the legitimate Lite save above — it has to be the call-site predicate these tests pin.
    func testSaveScan_imposesNoContentFloorItself() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let locId = UUID()
        context.insert(ScanLocation(id: locId, name: "Garage"))
        let emptyCapture = try makeCaptureDir(frameCount: 0)

        let scan = try XCTUnwrap(
            ScanFileManager.shared.saveScan(
                context: context, locationId: locId, name: "Recovered Scan",
                meshData: Data(), vertexCount: 0, faceCount: 0,
                rawDataPath: emptyCapture, vertexColors: nil, worldMapURL: nil
            ),
            "saveScan is expected to accept this — that is exactly why the floor must gate the caller"
        )
        cleanupAfter(scan)
        XCTAssertEqual(FrameCaptureSession.capturedFrameCount(in: scan.rawDataPath), 0)
    }
}
