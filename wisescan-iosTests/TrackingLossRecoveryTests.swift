import XCTest
import SwiftData
@testable import wisescan_ios

/// Pins what happens to a capture when tracking is lost mid-scan (issue #81, defect 2), and the
/// map gate that keeps the resulting map-less scan from blocking its space.
///
/// When ARKit drops its mesh anchors mid-scan, `finishStopRecording` reaches its meshless branch
/// and, for a non-extend flow, persists what it has as a mesh-less, map-less "Recovered Scan".
/// That gate used to be `images/` entries > 0: it missed wearable frames and 360° stills, and the
/// resulting scan, as the space's newest, blocked Rescan, Connect Adjacent and focus scans, which
/// all need the newest scan's world map. Now any content is saved and `latestRoomScan` skips scans
/// without a world map.
///
/// `finishStopRecording` is `private` inside a SwiftUI `View` extension, so the decision is
/// expressed as pure functions on `FrameCaptureSession` and tested here:
///   - `capturedFrameCount(in:)` / `proxyFrameCount(in:)` / `equirectStillCount(in:)` — what a
///     finalized capture directory holds
///   - `recoveryOutcome(content:isExtendFlow:)` — which branch runs
///   - `recoverySaveWouldPersist(...)` — the tracking-loss alert's "Save Anyway" gate
///   - `recoveryContentSummary(...)` / `recoverySavedMessage(content:)` — what the user is told
@MainActor
final class TrackingLossRecoveryTests: XCTestCase {

    /// Directories created on the real temp/Documents filesystem during a test, removed in tearDown.
    private var createdDirs: [URL] = []

    override func tearDown() {
        for dir in createdDirs { try? FileManager.default.removeItem(at: dir) }
        createdDirs = []
        super.tearDown()
    }

    /// Stand-in frame bytes. Never parsed by anything under test — the counters read names only,
    /// and `saveScan` copies the first frame to the thumbnail verbatim.
    private let frameBytes = Data([0xFF, 0xD8, 0xFF, 0xD9])

    /// Builds a temp directory shaped like the one `FrameCaptureSession.stop()` returns: `images/`
    /// (`frame_NNNNN.jpg`, on every device class), plus the two other content streams that live in
    /// the same capture root — `proxy_images/` (same naming) and `equirect_stills/`
    /// (`still_NNNN.JPG` + `still_NNNN.json` sidecar).
    private func makeCaptureDir(frameCount: Int, proxyFrames: Int = 0, stills: Int = 0,
                                stillsPendingDownload: Int = 0, extraFiles: [String] = []) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("recovery-\(UUID().uuidString)", isDirectory: true)
        let imagesDir = root.appendingPathComponent("images", isDirectory: true)
        try fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        createdDirs.append(root)
        for index in 0..<frameCount {
            try frameBytes.write(to: imagesDir.appendingPathComponent(String(format: "frame_%05d.jpg", index)))
        }
        for name in extraFiles {
            try frameBytes.write(to: imagesDir.appendingPathComponent(name))
        }
        if proxyFrames > 0 {
            let proxyDir = root.appendingPathComponent("proxy_images", isDirectory: true)
            try fm.createDirectory(at: proxyDir, withIntermediateDirectories: true)
            for index in 0..<proxyFrames {
                try frameBytes.write(to: proxyDir.appendingPathComponent(String(format: "frame_%05d.jpg", index)))
            }
        }
        if stills > 0 || stillsPendingDownload > 0 {
            let stillsDir = root.appendingPathComponent("equirect_stills", isDirectory: true)
            try fm.createDirectory(at: stillsDir, withIntermediateDirectories: true)
            for seq in 1...(stills + stillsPendingDownload) {
                // Sidecar always (written at trigger time); JPG only for the drained ones.
                try Data("{}".utf8).write(to: stillsDir.appendingPathComponent(String(format: "still_%04d.json", seq)))
                if seq <= stills {
                    try frameBytes.write(to: stillsDir.appendingPathComponent(String(format: "still_%04d.JPG", seq)))
                }
            }
        }
        return root
    }

    private func cleanupAfter(_ scan: CapturedScan) {
        createdDirs.append(scan.scanDirectory.deletingLastPathComponent()) // .../Scans/<locId>
    }

    // MARK: - What a capture holds

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

        // Stray files alone are not content.
        let strayOnly = try makeCaptureDir(frameCount: 0, extraFiles: [".DS_Store", "notes.txt"])
        XCTAssertTrue(FrameCaptureSession.recoveryContent(in: strayOnly).isEmpty)
    }

    /// CLAIM: a nil capture dir, a capture dir with no `images/`, and an empty `images/` all count
    /// as zero frames. Same for the two other streams, whose directories may not exist at all on a
    /// phone-only scan.
    func testCapturedFrameCount_absentOrEmptyImagesDir_isZero() throws {
        XCTAssertEqual(FrameCaptureSession.capturedFrameCount(in: nil), 0)
        XCTAssertEqual(FrameCaptureSession.proxyFrameCount(in: nil), 0)
        XCTAssertEqual(FrameCaptureSession.equirectStillCount(in: nil), 0)

        let noImagesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovery-noimages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: noImagesDir, withIntermediateDirectories: true)
        createdDirs.append(noImagesDir)
        XCTAssertEqual(FrameCaptureSession.capturedFrameCount(in: noImagesDir), 0)
        XCTAssertEqual(FrameCaptureSession.proxyFrameCount(in: noImagesDir), 0)
        XCTAssertEqual(FrameCaptureSession.equirectStillCount(in: noImagesDir), 0)

        let emptyImages = try makeCaptureDir(frameCount: 0)
        XCTAssertEqual(FrameCaptureSession.recoveryContent(in: emptyImages),
                       FrameCaptureSession.RecoveryContent(),
                       "a capture with an empty images/ and no other stream holds nothing")
    }

    /// CLAIM: `recoveryContent` reads all three streams that share the capture root, not just
    /// `images/`: `proxy_images/` is a wearable session's payload, and `equirect_stills/` holds
    /// 360° stills whose camera-side originals are deleted once the bytes verify on disk.
    func testRecoveryContent_readsAllThreeStreams() throws {
        let captureDir = try makeCaptureDir(frameCount: 2, proxyFrames: 5, stills: 3)
        XCTAssertEqual(FrameCaptureSession.recoveryContent(in: captureDir),
                       FrameCaptureSession.RecoveryContent(frameCount: 2, proxyFrameCount: 5,
                                                           equirectStillCount: 3))
    }

    /// CLAIM: a still counts from its SIDECAR, not only from its JPG — the sidecar is written at
    /// trigger time and the equirect bytes drain later, so sidecar-present/JPG-missing means
    /// "captured, download pending", the counting rule `ScansListView` already uses.
    func testEquirectStillCount_countsPendingDownloadsFromSidecars() throws {
        let captureDir = try makeCaptureDir(frameCount: 1, stills: 1, stillsPendingDownload: 2)
        XCTAssertEqual(FrameCaptureSession.equirectStillCount(in: captureDir), 3,
                       "one drained still plus two pending sidecars is three captured stills")
    }

    // MARK: - Which branch runs

    /// CLAIM: any content is saved, there is no floor. One photo, one glasses frame, or one 360°
    /// still (even one still downloading) each make a Recovered Scan; with automatic room-scan
    /// photos a floor stranded early tracking losses in the temp directory, invisible to the user.
    func testRecoveryOutcome_anyContentIsSaved() throws {
        let cases: [(String, URL)] = [
            ("one photo", try makeCaptureDir(frameCount: 1)),
            ("one glasses frame", try makeCaptureDir(frameCount: 0, proxyFrames: 1)),
            ("one 360° photo", try makeCaptureDir(frameCount: 0, stills: 1)),
            ("one 360° photo still downloading", try makeCaptureDir(frameCount: 0, stillsPendingDownload: 1)),
        ]
        for (label, captureDir) in cases {
            let content = FrameCaptureSession.recoveryContent(in: captureDir)
            XCTAssertEqual(FrameCaptureSession.recoveryOutcome(content: content, isExtendFlow: false),
                           .persistRecoveredScan, "\(label) must be saved")
        }
    }

    /// CLAIM: a capture holding nothing creates no scan, and an extend/stitch flow never persists a
    /// recovery whatever it holds, because an extend needs a co-framed mesh and world map.
    func testRecoveryOutcome_nothingCapturedAndExtendFlow() {
        let nothing = FrameCaptureSession.RecoveryContent()
        let some = FrameCaptureSession.RecoveryContent(frameCount: 3, equirectStillCount: 1)

        XCTAssertEqual(FrameCaptureSession.recoveryOutcome(content: nothing, isExtendFlow: false),
                       .nothingCaptured)
        for content in [nothing, some] {
            XCTAssertEqual(FrameCaptureSession.recoveryOutcome(content: content, isExtendFlow: true),
                           .abortExtendFlow)
        }
    }

    /// CLAIM: taking the decision removes no files. An extend abort leaves a capture that can hold
    /// content in the temp directory (the only completion handler shows a toast and returns), and
    /// 360° stills there can be the only copy. A `removeItem` added to the counters, the predicate
    /// or the messages would fail here; one added to the branch body itself needs a device.
    func testRecoveryDecision_deletesNothing() throws {
        let captureDir = try makeCaptureDir(frameCount: 3, proxyFrames: 4, stills: 2)
        let fm = FileManager.default
        let before = try fm.subpathsOfDirectory(atPath: captureDir.path).sorted()
        XCTAssertFalse(before.isEmpty)

        let content = FrameCaptureSession.recoveryContent(in: captureDir)
        XCTAssertEqual(FrameCaptureSession.recoveryOutcome(content: content, isExtendFlow: true),
                       .abortExtendFlow)
        _ = FrameCaptureSession.recoveryOutcome(content: content, isExtendFlow: false)
        _ = FrameCaptureSession.recoverySavedMessage(content: content)

        XCTAssertEqual(try fm.subpathsOfDirectory(atPath: captureDir.path).sorted(), before,
                       "deciding must leave images/, proxy_images/ and equirect_stills/ intact")
    }

    /// CLAIM: a Recovered Scan persists with no mesh and no world map, and its frames reach the
    /// scan's raw data. This is also the Lite (no-LiDAR) save's shape: `vertexCount: 0` scans whose
    /// frames are the whole payload (the deliberate 2026-07-22 fix).
    func testZeroVertexMaplessScan_persistsWithItsFrames() throws {
        let captureDir = try makeCaptureDir(frameCount: 2)
        let context = try StitchTestSupport.makeInMemoryContext()
        let locId = UUID()
        context.insert(ScanLocation(id: locId, name: "Hallway"))

        let scan = try XCTUnwrap(
            ScanFileManager.shared.saveScan(
                context: context, locationId: locId, name: "Recovered Scan",
                meshData: Data(), vertexCount: 0, faceCount: 0,
                rawDataPath: captureDir, vertexColors: nil, worldMapURL: nil, sweepCoverage: nil
            ),
            "a zero-vertex, map-less scan must still save"
        )
        cleanupAfter(scan)

        XCTAssertEqual(scan.vertexCount, 0)
        XCTAssertEqual(scan.location?.id, locId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scan.worldMapURL.path))
        XCTAssertEqual(FrameCaptureSession.capturedFrameCount(in: scan.rawDataPath), 2,
                       "every frame should have moved into \(scan.rawDataPath.path)")
    }

    // MARK: - The tracking-loss alert

    /// CLAIM: "Save Anyway" is offered whenever the save pipeline will keep something: a mesh made
    /// during this recording (the normal save runs; room scans take no photos in their first 10 s,
    /// so early on this is the only content), or any photo, glasses frame or 360° still. A capture
    /// holding nothing is not offered a save.
    func testAlertGate_offersSaveWheneverSomethingWillBeKept() {
        let nothing = FrameCaptureSession.RecoveryContent()

        XCTAssertTrue(FrameCaptureSession.recoverySaveWouldPersist(
            content: nothing, liveMeshVertexCount: 12_000),
                      "mesh but no photos yet: the normal save keeps the mesh and world map")
        for content in [FrameCaptureSession.RecoveryContent(frameCount: 1),
                        FrameCaptureSession.RecoveryContent(proxyFrameCount: 1),
                        FrameCaptureSession.RecoveryContent(equirectStillCount: 1)] {
            XCTAssertTrue(FrameCaptureSession.recoverySaveWouldPersist(
                content: content, liveMeshVertexCount: 0), "\(content) must be offered a save")
        }
        XCTAssertFalse(FrameCaptureSession.recoverySaveWouldPersist(
            content: nothing, liveMeshVertexCount: 0))
    }

    // MARK: - What the user is told

    /// CLAIM: the summary names each kind of content, pluralized, in the order photos, glasses
    /// frames, 360° photos, mesh; and a mesh with nothing else says why there are no photos.
    func testContentSummary_namesWhatWasCaptured() {
        typealias C = FrameCaptureSession.RecoveryContent
        let summary = FrameCaptureSession.recoveryContentSummary
        XCTAssertEqual(summary(C(frameCount: 1), false), "1 photo")
        XCTAssertEqual(summary(C(frameCount: 12), true), "12 photos and the mesh")
        XCTAssertEqual(summary(C(frameCount: 12, proxyFrameCount: 1, equirectStillCount: 3), true),
                       "12 photos, 1 glasses frame, 3 360° photos and the mesh")
        XCTAssertEqual(summary(C(equirectStillCount: 1), false), "1 360° photo")
        XCTAssertEqual(summary(C(), true), "the mesh (no photos yet)")
        XCTAssertEqual(summary(C(), false), "nothing")
    }

    /// CLAIM: the saved banner uses the same summary.
    func testSavedMessage_namesWhatWasKept() {
        XCTAssertEqual(FrameCaptureSession.recoverySavedMessage(
            content: FrameCaptureSession.RecoveryContent(frameCount: 2, equirectStillCount: 1)),
                       "Saved 2 photos and 1 360° photo (mesh lost to tracking interruption)")
    }

    // MARK: - The map gate

    /// Inserts a room scan into `location` captured at `capturedAt`, with a world map file on disk
    /// when `hasMap` is set.
    private func addRoomScan(to location: ScanLocation, in context: ModelContext,
                             capturedAt: Date, hasMap: Bool) throws -> CapturedScan {
        let scan = CapturedScan(name: "scan", capturedAt: capturedAt, vertexCount: 0, faceCount: 0)
        context.insert(scan)
        scan.location = location
        if hasMap {
            try FileManager.default.createDirectory(at: scan.scanDirectory, withIntermediateDirectories: true)
            try Data([1]).write(to: scan.worldMapURL)
        }
        cleanupAfter(scan)
        return scan
    }

    /// CLAIM: the space's latest room scan skips scans without a world map, so a Recovered Scan
    /// (or any scan whose map failed to save) no longer blocks Rescan, Connect Adjacent and focus
    /// scans, which all start from it and require its map.
    func testLatestRoomScan_skipsScansWithoutAWorldMap() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let location = ScanLocation(id: UUID(), name: "Lab")
        context.insert(location)
        let now = Date()

        let mapped = try addRoomScan(to: location, in: context, capturedAt: now.addingTimeInterval(-60), hasMap: true)
        XCTAssertEqual(location.latestRoomScan?.id, mapped.id)

        let recovered = try addRoomScan(to: location, in: context, capturedAt: now, hasMap: false)
        XCTAssertEqual(location.roomScans.count, 2)
        XCTAssertEqual(location.latestRoomScan?.id, mapped.id,
                       "a newer map-less scan must not become the rescan source")

        // A newer mapped scan wins again.
        let rescan = try addRoomScan(to: location, in: context, capturedAt: now.addingTimeInterval(60), hasMap: true)
        XCTAssertEqual(location.latestRoomScan?.id, rescan.id)
        XCTAssertNotEqual(location.latestRoomScan?.id, recovered.id)
    }

    /// CLAIM: when no room scan has a map, the newest room scan is still returned, as before: the
    /// space keeps a tile and its "no world map" warnings still have a scan to point at.
    func testLatestRoomScan_withNoMapsIsTheNewest() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let location = ScanLocation(id: UUID(), name: "Lite")
        context.insert(location)
        let now = Date()

        _ = try addRoomScan(to: location, in: context, capturedAt: now.addingTimeInterval(-60), hasMap: false)
        let newest = try addRoomScan(to: location, in: context, capturedAt: now, hasMap: false)
        XCTAssertEqual(location.latestRoomScan?.id, newest.id)

        let empty = ScanLocation(id: UUID(), name: "Empty")
        context.insert(empty)
        XCTAssertNil(empty.latestRoomScan)
    }

    // MARK: - Where the decision cannot live

    /// CLAIM (characterization, and the reason the decision lives at the call site): `saveScan`
    /// imposes no content check of its own. Handed an empty mesh, zero vertices and a frameless raw
    /// dir it persists a scan happily, so the empty case has to be stopped by `recoveryOutcome`.
    func testSaveScan_imposesNoContentCheckItself() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let locId = UUID()
        context.insert(ScanLocation(id: locId, name: "Garage"))
        let emptyCapture = try makeCaptureDir(frameCount: 0)

        let scan = try XCTUnwrap(
            ScanFileManager.shared.saveScan(
                context: context, locationId: locId, name: "Recovered Scan",
                meshData: Data(), vertexCount: 0, faceCount: 0,
                rawDataPath: emptyCapture, vertexColors: nil, worldMapURL: nil, sweepCoverage: nil
            ),
            "saveScan is expected to accept this — that is exactly why the caller must decide"
        )
        cleanupAfter(scan)
        XCTAssertEqual(FrameCaptureSession.capturedFrameCount(in: scan.rawDataPath), 0)
    }
}
