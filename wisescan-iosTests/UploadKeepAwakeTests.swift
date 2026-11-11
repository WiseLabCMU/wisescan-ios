import Foundation
import SwiftData
import UIKit
import XCTest
@testable import wisescan_ios

/// The device-side rules behind keeping the screen on and flashing for every saved still: which
/// scans a relaunch marks interrupted, the screen-awake holders, and the flash strengths.
@MainActor
final class UploadKeepAwakeTests: XCTestCase {

    // MARK: InterruptedExports

    /// At launch no process is building an export any more, and nothing sends an older build's
    /// upload. Before this sweep such scans stayed in flight and refused every retry.
    func testLaunchSweepFailsOnlyWhatDiedWithTheApp() throws {
        XCTAssertTrue(InterruptedExports.isInterrupted(status: "zipping"))
        XCTAssertTrue(InterruptedExports.isInterrupted(status: "uploading"))
        for done in ["pending", "savedLocally", "success", "failed:Export failed"] {
            XCTAssertFalse(InterruptedExports.isInterrupted(status: done), done)
        }

        let container = try ModelContainer(for: ScanLocation.self, CapturedScan.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let converting = CapturedScan(name: "converting", vertexCount: 0, faceCount: 0)
        let orphaned = CapturedScan(name: "an older build's upload", vertexCount: 0, faceCount: 0)
        let shared = CapturedScan(name: "shared", vertexCount: 0, faceCount: 0)
        for scan in [converting, orphaned, shared] { context.insert(scan) }
        converting.uploadStatus = .zipping
        orphaned.uploadStatus = .uploading(progress: 0.3)
        shared.uploadStatus = .savedLocally

        InterruptedExports.sweep(context)
        XCTAssertEqual(converting.uploadStatus, .failed(InterruptedExports.message))
        XCTAssertEqual(orphaned.uploadStatus, .failed(InterruptedExports.message))
        XCTAssertEqual(shared.uploadStatus, .savedLocally)
        XCTAssertFalse(converting.uploadStatus.isInFlight, "Share can run again")
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

    /// Every export passes through the status setter, so it is the one place the
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
