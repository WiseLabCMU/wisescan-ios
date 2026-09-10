import XCTest
import SwiftData
@testable import wisescan_ios

/// Pins the content floor on the tracking-loss recovery save (issue #81, defect 2), and — more
/// importantly — pins what the below-floor path DOES.
///
/// When ARKit drops its mesh anchors mid-scan, `finishStopRecording` reaches its meshless branch
/// and — for a non-extend flow — persists what it has as a mesh-less, map-less "Recovered Scan".
/// That gate used to be `rawFrameCount > 0`, so a two- or three-frame stub became a scan. Such a
/// stub is not merely useless: locations sort newest-first (`LocationDetailView.swift:60`) and both
/// Rescan Space and Connect Adjacent consume `sortedScans.first` (`:126`) and hard-gate on that
/// scan's world map file existing (`:718`, `:743`) — which a recovery scan never has. So the stub
/// shadows the location's good scans and disables both actions for the whole location.
///
/// The branch's whole decision is expressed as pure functions on `FrameCaptureSession`, because
/// `finishStopRecording` is `private` inside a SwiftUI `View` extension and cannot be called from a
/// test:
///   - `capturedFrameCount(in:)` / `proxyFrameCount(in:)` / `equirectStillCount(in:)` — what a
///     finalized capture directory holds
///   - `recoveryHasEnoughContent(_:)` — whether that clears the floor
///   - `recoveryOutcome(content:isExtendFlow:)` — WHICH BRANCH RUNS: persist, refuse (keeping the
///     capture), or abort an extend flow
///   - `recoverySaveWouldPersist(...)` — the tracking-loss alert's "Save Anyway" gate, which must
///     agree with the floor so the app never offers a save the pipeline refuses
///   - `recoveryRefusedMessage(content:)` / `recoverySavedMessage(content:)` — the banners
@MainActor
final class RecoveryContentFloorTests: XCTestCase {

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
    /// (`frame_NNNNN.jpg`, the only name `captureFrame` writes, on every device class), plus the two
    /// other content streams that live in the same capture root — `proxy_images/` (same naming) and
    /// `equirect_stills/` (`still_NNNN.JPG` + `still_NNNN.json` sidecar).
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

    // MARK: - The floor's value

    /// CLAIM: the floor is exactly ten frames. Every other assertion here is written in terms of
    /// `minRecoveryFrames`, which makes them true for ANY floor >= 2 — including a later raise to
    /// 500 that would silently start refusing real captures. The number is the riskiest part of this
    /// change (it is a judgement call, not a backend measurement), so it is pinned literally: a
    /// change to it has to be deliberate and has to come here.
    func testFloorValue_isPinned() {
        XCTAssertEqual(AppConstants.minRecoveryFrames, 10,
                       "the recovery floor is a judgement call — raising it must be deliberate")
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
    /// as zero frames — the same answer the replaced inline expression gave. Same for the two other
    /// streams, whose directories may not exist at all on a phone-only scan.
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
    /// `images/`. The floor decides the fate of the whole directory, so it has to see the whole
    /// directory — `proxy_images/` is a wearable session's payload, and `equirect_stills/` holds
    /// 360° stills whose camera-side originals are deleted once the bytes verify on disk.
    func testRecoveryContent_readsAllThreeStreams() throws {
        let captureDir = try makeCaptureDir(frameCount: 2, proxyFrames: 5, stills: 3)
        XCTAssertEqual(FrameCaptureSession.recoveryContent(in: captureDir),
                       FrameCaptureSession.RecoveryContent(frameCount: 2, proxyFrameCount: 5,
                                                           equirectStillCount: 3))
    }

    /// CLAIM: a still counts from its SIDECAR, not only from its JPG — the sidecar is written at
    /// trigger time and the equirect bytes drain later, so sidecar-present/JPG-missing means
    /// "captured, download pending". That is the counting rule `ScansListView` already uses
    /// (`:1160-1161`), and it matters here because a pending still is still captured content whose
    /// only home is the scan this decision may refuse to create.
    func testEquirectStillCount_countsPendingDownloadsFromSidecars() throws {
        let captureDir = try makeCaptureDir(frameCount: 1, stills: 1, stillsPendingDownload: 2)
        XCTAssertEqual(FrameCaptureSession.equirectStillCount(in: captureDir), 3,
                       "one drained still plus two pending sidecars is three captured stills")
    }

    // MARK: - The predicate

    /// CLAIM: an empty recovery does not clear the floor, so no "Recovered Scan" can come from it.
    func testEmptyRecovery_isRefused() throws {
        let captureDir = try makeCaptureDir(frameCount: 0)
        let content = FrameCaptureSession.recoveryContent(in: captureDir)

        XCTAssertEqual(content.frameCount, 0)
        XCTAssertFalse(FrameCaptureSession.recoveryHasEnoughContent(content),
                       "an empty capture must never persist as a scan")
    }

    /// CLAIM: the floor genuinely supersedes the old `rawFrameCount > 0` gate — the exact stub sizes
    /// named in the issue (one frame, three frames) are now refused, and so is floor-minus-one.
    func testStubRecovery_belowFloor_isRefused() throws {
        for frames in [1, 3, AppConstants.minRecoveryFrames - 1] {
            let captureDir = try makeCaptureDir(frameCount: frames)
            let content = FrameCaptureSession.recoveryContent(in: captureDir)
            XCTAssertEqual(content.frameCount, frames)
            XCTAssertFalse(FrameCaptureSession.recoveryHasEnoughContent(content),
                           "\(frames) frames is below the floor of \(AppConstants.minRecoveryFrames) and must be refused")
        }
    }

    /// CLAIM: the floor is inclusive — a capture holding exactly `minRecoveryFrames` frames, and
    /// anything above it, is accepted. The floor rejects stubs, not small-but-real captures.
    func testMinimalRealRecovery_atOrAboveFloor_isAccepted() throws {
        for frames in [AppConstants.minRecoveryFrames, AppConstants.minRecoveryFrames + 1, AppConstants.minRecoveryFrames * 4] {
            let captureDir = try makeCaptureDir(frameCount: frames)
            let content = FrameCaptureSession.recoveryContent(in: captureDir)
            XCTAssertEqual(content.frameCount, frames)
            XCTAssertTrue(FrameCaptureSession.recoveryHasEnoughContent(content),
                          "\(frames) frames clears the floor of \(AppConstants.minRecoveryFrames) and must be accepted")
        }
    }

    /// CLAIM: ANY 360° still clears the floor on its own, with no count threshold. A capture holding
    /// stills is not empty — each still is a deliberate ~7 s operator trigger, and once the bytes
    /// verify on disk the camera-side original is swept, so the copy in this directory can be the
    /// only one in existence. Refusing it would strand irreplaceable bytes with no scan to own them.
    /// This is also the rig workflow's shape: the operator stands still (so the movement gate
    /// suppresses stream frames) and taps, so `images/` is small exactly when stills are present.
    func testSingleEquirectStill_clearsFloorAloneEvenWithOneFrame() throws {
        let captureDir = try makeCaptureDir(frameCount: 1, stills: 1)
        let content = FrameCaptureSession.recoveryContent(in: captureDir)
        XCTAssertTrue(FrameCaptureSession.recoveryHasEnoughContent(content),
                      "a capture holding a 360° still must never be judged empty")
        XCTAssertEqual(FrameCaptureSession.recoveryOutcome(content: content, isExtendFlow: false),
                       .persistRecoveredScan)

        // And a pending-download still counts the same — it is captured, just not transferred yet.
        let pendingOnly = try makeCaptureDir(frameCount: 1, stillsPendingDownload: 1)
        XCTAssertTrue(FrameCaptureSession.recoveryHasEnoughContent(
            FrameCaptureSession.recoveryContent(in: pendingOnly)))
    }

    /// CLAIM: the floor applies to the SUM of the two stream frame counts. A wearable-driven capture
    /// legitimately carries almost all of its frames in `proxy_images/` (15 fps, no movement gate),
    /// so counting only `images/` would refuse a capture holding hundreds of real frames.
    func testProxyFrames_countTowardTheFloor() throws {
        let wearable = try makeCaptureDir(frameCount: 1, proxyFrames: AppConstants.minRecoveryFrames)
        XCTAssertTrue(FrameCaptureSession.recoveryHasEnoughContent(
            FrameCaptureSession.recoveryContent(in: wearable)),
                      "proxy frames are frames — a wearable capture must not read as empty")

        // Still a floor, though: the sum has to clear it.
        let tooFew = try makeCaptureDir(frameCount: 1, proxyFrames: 2)
        XCTAssertFalse(FrameCaptureSession.recoveryHasEnoughContent(
            FrameCaptureSession.recoveryContent(in: tooFew)))
    }

    /// CLAIM: the floor tests CONTENT, never vertices, so the Lite (no-LiDAR) case survives it.
    /// Lite devices have no `ARMeshAnchor`s at all and legitimately save `vertexCount: 0` scans
    /// whose raw frames are the entire payload (the deliberate 2026-07-22 fix). A vertex-count floor
    /// would have rejected every one of them; this predicate accepts them on frame count alone, and
    /// the scan still persists with its frames on disk.
    func testLegitimateZeroVertexScan_clearsFloorAndStillPersists() throws {
        let captureDir = try makeCaptureDir(frameCount: AppConstants.minRecoveryFrames)

        // The floor accepts it despite there being no mesh whatsoever.
        let content = FrameCaptureSession.recoveryContent(in: captureDir)
        XCTAssertTrue(FrameCaptureSession.recoveryHasEnoughContent(content),
                      "a capture with no vertices but real frames must clear the floor")

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
            "a zero-vertex scan must still save"
        )
        cleanupAfter(scan)

        XCTAssertEqual(scan.vertexCount, 0)
        XCTAssertEqual(scan.location?.id, locId)
        // The frames — the whole payload on this device class — reached the scan's raw_data.
        XCTAssertEqual(FrameCaptureSession.capturedFrameCount(in: scan.rawDataPath),
                       AppConstants.minRecoveryFrames,
                       "every frame should have moved into \(scan.rawDataPath.path)")
    }

    // MARK: - Which branch runs

    /// CLAIM: this is the behaviour change. Above the floor the branch persists a "Recovered Scan";
    /// below it the branch REFUSES — `refuseKeepingCapture`, not "discard" — and an extend/stitch
    /// flow aborts regardless of how much content there is, because an extend needs a co-framed mesh
    /// and world map either way.
    func testRecoveryOutcome_selectsTheBranch() throws {
        let stub = FrameCaptureSession.RecoveryContent(frameCount: 3)
        let real = FrameCaptureSession.RecoveryContent(frameCount: AppConstants.minRecoveryFrames)
        let nothing = FrameCaptureSession.RecoveryContent()

        XCTAssertEqual(FrameCaptureSession.recoveryOutcome(content: real, isExtendFlow: false),
                       .persistRecoveredScan)
        XCTAssertEqual(FrameCaptureSession.recoveryOutcome(content: stub, isExtendFlow: false),
                       .refuseKeepingCapture, "a below-floor capture must be refused, not discarded")
        XCTAssertEqual(FrameCaptureSession.recoveryOutcome(content: nothing, isExtendFlow: false),
                       .refuseKeepingCapture)

        // The extend flow never persists a recovery, whatever the content — and never deletes either.
        for content in [nothing, stub, real] {
            XCTAssertEqual(FrameCaptureSession.recoveryOutcome(content: content, isExtendFlow: true),
                           .abortExtendFlow)
        }
    }

    /// CLAIM: nothing on the below-floor path removes files. Issue #81 is explicit that today's
    /// failure is non-destructive — the frames survive on disk — and that the predicate must bias
    /// toward saving; the capture root also holds `equirect_stills/` and `proxy_images/`, and a
    /// verified 360° still has already been swept off the camera, so unlinking it destroys the only
    /// copy. Documented false halts (`ARCoverageView.swift:2812-2817`) land on short captures, i.e.
    /// exactly here.
    ///
    /// What this can and cannot check: `finishStopRecording` is `private` inside a SwiftUI `View`
    /// extension, so the branch itself is unreachable from a test. What is reachable — and what a
    /// regression would most plausibly change — is the decision, so this asserts the decision is
    /// PURE: taking it over a populated capture directory leaves every byte of all three streams in
    /// place. A `removeItem` reintroduced into the predicate, the counters, or the message would fail
    /// here; a `removeItem` reintroduced into the branch body needs a device.
    func testBelowFloorDecision_deletesNothing() throws {
        let captureDir = try makeCaptureDir(frameCount: 3, proxyFrames: 4, stills: 2)
        let fm = FileManager.default
        let before = try fm.subpathsOfDirectory(atPath: captureDir.path).sorted()
        XCTAssertFalse(before.isEmpty)

        let content = FrameCaptureSession.recoveryContent(in: captureDir)
        XCTAssertEqual(FrameCaptureSession.recoveryOutcome(content: content, isExtendFlow: false),
                       .refuseKeepingCapture, "3 + 4 frames is below the floor")
        _ = FrameCaptureSession.recoveryRefusedMessage(content: content)

        XCTAssertTrue(fm.fileExists(atPath: captureDir.path), "the capture root must survive a refusal")
        XCTAssertEqual(try fm.subpathsOfDirectory(atPath: captureDir.path).sorted(), before,
                       "a refused recovery must leave images/, proxy_images/ and equirect_stills/ intact")
    }

    // MARK: - The alert and the floor must agree

    /// CLAIM: the "Tracking Lost" alert's "Save Anyway" is offered exactly when the save pipeline
    /// would persist something. Gating it on `capturedCount > 0` promised to save 1–9 frames that
    /// the floor then refused. The predicate has three honourable cases, one per branch the pipeline
    /// can take: the Lite branch (any `images/` frame, no floor), a still-live mesh (the normal save
    /// flow runs, floor irrelevant), and otherwise the floor itself.
    func testAlertGate_agreesWithTheFloor() {
        let stub = FrameCaptureSession.RecoveryContent(frameCount: 3)
        let real = FrameCaptureSession.RecoveryContent(frameCount: AppConstants.minRecoveryFrames)
        let nothing = FrameCaptureSession.RecoveryContent()

        // LiDAR device, mesh anchors gone (the case that reaches the floor): the offer follows it.
        XCTAssertFalse(FrameCaptureSession.recoverySaveWouldPersist(
            content: stub, supportsLiDAR: true, liveMeshVertexCount: 0),
                       "a below-floor capture must not be offered a save the pipeline refuses")
        XCTAssertTrue(FrameCaptureSession.recoverySaveWouldPersist(
            content: real, supportsLiDAR: true, liveMeshVertexCount: 0))

        // LiDAR device with the mesh still live: the NORMAL save flow runs and produces a real scan
        // with a world map, so refusing to offer it would throw away a savable scan.
        XCTAssertTrue(FrameCaptureSession.recoverySaveWouldPersist(
            content: stub, supportsLiDAR: true, liveMeshVertexCount: 12_000),
                      "a live mesh means the normal save flow, where the floor does not apply")

        // Lite device: the Lite branch catches any images/ frame before the floor is consulted.
        XCTAssertTrue(FrameCaptureSession.recoverySaveWouldPersist(
            content: stub, supportsLiDAR: false, liveMeshVertexCount: 0),
                      "a Lite capture with frames saves through pendingScan — the floor never runs")
        // ...but a Lite capture with no images/ frame does fall through to the floor.
        XCTAssertFalse(FrameCaptureSession.recoverySaveWouldPersist(
            content: FrameCaptureSession.RecoveryContent(proxyFrameCount: 2),
            supportsLiDAR: false, liveMeshVertexCount: 0))
        XCTAssertTrue(FrameCaptureSession.recoverySaveWouldPersist(
            content: FrameCaptureSession.RecoveryContent(proxyFrameCount: AppConstants.minRecoveryFrames),
            supportsLiDAR: false, liveMeshVertexCount: 0))

        // A capture holding nothing is never offered a save, on any device.
        for lidar in [true, false] {
            XCTAssertFalse(FrameCaptureSession.recoverySaveWouldPersist(
                content: nothing, supportsLiDAR: lidar, liveMeshVertexCount: 0))
        }
    }

    // MARK: - What the user is told

    /// CLAIM: the refusal message is pluralized and says "Not saved", not "Discarded". "only 1
    /// frames captured" is reachable (one frame is below the floor), and "Discarded" would be a lie
    /// now that the path deletes nothing. The zero case gets its own wording rather than
    /// "only 0 frames".
    func testRefusedMessage_isAccurateAndPluralized() {
        XCTAssertEqual(FrameCaptureSession.recoveryRefusedMessage(
            content: FrameCaptureSession.RecoveryContent(frameCount: 1)),
                       "Not saved — only 1 frame captured")
        XCTAssertEqual(FrameCaptureSession.recoveryRefusedMessage(
            content: FrameCaptureSession.RecoveryContent(frameCount: 3)),
                       "Not saved — only 3 frames captured")
        XCTAssertEqual(FrameCaptureSession.recoveryRefusedMessage(
            content: FrameCaptureSession.RecoveryContent()),
                       "Not saved — no frames captured")
        // Proxy frames are part of the count the user is quoted, because they are part of the floor.
        XCTAssertEqual(FrameCaptureSession.recoveryRefusedMessage(
            content: FrameCaptureSession.RecoveryContent(frameCount: 2, proxyFrameCount: 1)),
                       "Not saved — only 3 frames captured")

        for message in [FrameCaptureSession.recoveryRefusedMessage(content: .init(frameCount: 1)),
                        FrameCaptureSession.recoveryRefusedMessage(content: .init())] {
            XCTAssertFalse(message.contains("Discard"), "nothing is discarded on this path")
            XCTAssertFalse(message.contains("1 frames"), "the message must be pluralized")
        }
    }

    /// CLAIM: the saved message is pluralized too, and names the 360° stills — which can be all of
    /// what cleared the floor, in which case "Saved 1 frames" would be both ungrammatical and wrong
    /// about what was kept.
    func testSavedMessage_isAccurateAndPluralized() {
        XCTAssertEqual(FrameCaptureSession.recoverySavedMessage(
            content: FrameCaptureSession.RecoveryContent(frameCount: 12)),
                       "Saved 12 frames (mesh lost to tracking interruption)")
        XCTAssertEqual(FrameCaptureSession.recoverySavedMessage(
            content: FrameCaptureSession.RecoveryContent(frameCount: 1, equirectStillCount: 2)),
                       "Saved 1 frame + 2 × 360° (mesh lost to tracking interruption)")
        XCTAssertEqual(FrameCaptureSession.recoverySavedMessage(
            content: FrameCaptureSession.RecoveryContent(equirectStillCount: 1)),
                       "Saved 1 × 360° (mesh lost to tracking interruption)")
    }

    // MARK: - Where the floor cannot live

    /// CLAIM (characterization, and the reason the floor lives at the call site): `saveScan` imposes
    /// no content floor of its own. Handed an empty mesh, zero vertices and a frameless raw dir it
    /// persists a scan happily. So the gate cannot be moved down into persistence without breaking
    /// the legitimate zero-vertex save above — it has to be the call-site predicate these tests pin.
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
