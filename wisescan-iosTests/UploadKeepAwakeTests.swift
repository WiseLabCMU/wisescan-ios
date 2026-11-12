import Foundation
import UIKit
import XCTest
@testable import wisescan_ios

/// The device-side rules behind finishing uploads with the screen locked and flashing for every
/// saved still: what a background transfer carries, how its result reads, which scans a relaunch
/// marks interrupted, the screen-awake holders, and the flash strengths.
@MainActor
final class UploadKeepAwakeTests: XCTestCase {

    // MARK: ExportUploader

    func testTicketRoundTripsThroughTheTaskDescription() throws {
        let ticket = ExportUploader.Ticket(scanId: UUID(), exportId: "exp-42", file: "ABC-scan.zip")
        let description = try XCTUnwrap(ticket.encoded)
        XCTAssertEqual(ExportUploader.Ticket.decode(description), ticket)
        let manual = ExportUploader.Ticket(scanId: UUID(), exportId: nil, file: "x.zip")
        XCTAssertEqual(ExportUploader.Ticket.decode(manual.encoded), manual)
    }

    /// A task from some other code path, or none at all, is not ours to act on.
    func testForeignTaskDescriptionsAreIgnored() {
        XCTAssertNil(ExportUploader.Ticket.decode(nil))
        XCTAssertNil(ExportUploader.Ticket.decode(""))
        XCTAssertNil(ExportUploader.Ticket.decode("upload of scan 7"))
        XCTAssertNil(ExportUploader.Ticket.decode(#"{"scanId":"not-a-uuid","file":"a.zip"}"#))
    }

    func testOnlyA2xxWithoutAnErrorIsSuccess() {
        XCTAssertEqual(ExportUploader.Outcome.of(statusCode: 200, error: nil), .success)
        XCTAssertEqual(ExportUploader.Outcome.of(statusCode: 204, error: nil), .success)
        // An expired grant answers 403; the code is kept so the card says why.
        XCTAssertEqual(ExportUploader.Outcome.of(statusCode: 403, error: nil), .failed("Server error (403)"))
        XCTAssertEqual(ExportUploader.Outcome.of(statusCode: nil, error: nil), .failed("No response"))
        let lost = URLError(.networkConnectionLost)
        XCTAssertEqual(ExportUploader.Outcome.of(statusCode: 200, error: lost), .failed(lost.localizedDescription))
    }

    /// At launch: no process is building a zip any more, and an upload with no transfer left
    /// will never finish. Before this sweep such scans stayed in flight and refused every retry.
    func testLaunchSweepFailsOnlyWhatDiedWithTheApp() {
        let converting = UUID(), orphaned = UUID(), stillSending = UUID()
        let stale = ExportUploader.interrupted(
            inFlight: [(id: converting, status: "zipping"), (id: orphaned, status: "uploading"),
                       (id: stillSending, status: "uploading")],
            liveScanIds: [stillSending])
        XCTAssertEqual(Set(stale), [converting, orphaned])
        // A live transfer cannot rescue a zip build: the zip was never handed to it.
        XCTAssertEqual(ExportUploader.interrupted(inFlight: [(id: converting, status: "zipping")],
                                                  liveScanIds: [converting]), [converting])
        XCTAssertTrue(ExportUploader.interrupted(inFlight: [], liveScanIds: [UUID()]).isEmpty)
    }

    // MARK: ScreenAwake

    func testScreenStaysAwakeUntilTheLastHolderLetsGo() {
        let before = UIApplication.shared.isIdleTimerDisabled
        defer { UIApplication.shared.isIdleTimerDisabled = before }
        let upload = ScreenAwake.uploadHolder(UUID())
        ScreenAwake.hold(upload)
        ScreenAwake.hold(ScreenAwake.captureHolder)
        ScreenAwake.hold(upload)                       // idempotent: one holder, not two
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)

        ScreenAwake.release(upload)
        XCTAssertTrue(ScreenAwake.isHeld(by: ScreenAwake.captureHolder))
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "the recording still needs the screen")

        ScreenAwake.release("never-held")              // harmless
        ScreenAwake.set(ScreenAwake.captureHolder, held: false)
        XCTAssertFalse(ScreenAwake.isHeld)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
    }

    /// Every export and upload passes through the status setter, so it is the one place the
    /// screen lease follows the pipeline, on every exit path.
    func testUploadStatusHoldsTheScreenWhileInFlight() {
        let before = UIApplication.shared.isIdleTimerDisabled
        defer { UIApplication.shared.isIdleTimerDisabled = before }
        let scan = CapturedScan(name: "lease", vertexCount: 0, faceCount: 0)
        let holder = ScreenAwake.uploadHolder(scan.id)
        scan.uploadStatus = .zipping
        XCTAssertTrue(ScreenAwake.isHeld(by: holder))
        scan.uploadStatus = .uploading(progress: 0.4)
        XCTAssertTrue(ScreenAwake.isHeld(by: holder))
        scan.uploadStatus = .failed("Server error (403)")
        XCTAssertFalse(ScreenAwake.isHeld(by: holder))
        scan.uploadStatus = .zipping
        scan.uploadStatus = .success
        XCTAssertFalse(ScreenAwake.isHeld(by: holder))
    }

    // MARK: CaptureFlash

    func testAutomaticStillsFlashSofterThanTappedOnes() {
        let tapped = CaptureFlash.style(for: .announced, dimFlashingLights: false)
        let automatic = CaptureFlash.style(for: .automatic, dimFlashingLights: false)
        XCTAssertEqual(tapped.peakOpacity, AppConstants.captureFlashOpacity)
        XCTAssertLessThan(automatic.peakOpacity, tapped.peakOpacity)
        XCTAssertGreaterThan(automatic.peakOpacity, 0, "an automatic still must still show")
        XCTAssertLessThanOrEqual(automatic.fadeSeconds, tapped.fadeSeconds)
    }

    func testDimFlashingLightsMakesEveryFlashFaint() {
        for kind in [CaptureFlash.Kind.announced, .automatic] {
            let dimmed = CaptureFlash.style(for: kind, dimFlashingLights: true)
            XCTAssertLessThan(dimmed.peakOpacity, CaptureFlash.style(for: .automatic, dimFlashingLights: false).peakOpacity)
            XCTAssertGreaterThan(dimmed.fadeSeconds, CaptureFlash.style(for: kind, dimFlashingLights: false).fadeSeconds)
        }
    }
}
