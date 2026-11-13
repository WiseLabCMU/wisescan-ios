import XCTest
@testable import scan4d_ios

/// The rig's shutter tap. The tap itself wobbles the device, so it arms the shot without needing
/// the device still at that moment, and the shot (with its 360° companion) waits for the device to
/// settle again after the tap. The settle and its timeout run on live ARKit frames
/// (`FrameCaptureSession.captureFrame`) and are checked on a device; these pin the tap's own rules.
@MainActor
final class RigTapTests: XCTestCase {

    /// A tap while the device is not still is accepted (it used to be refused with a warning
    /// haptic), and the 360° companion does not fire at the tap.
    func testTapArmsWhileNotStillAndWaitsToFire() {
        let session = FrameCaptureSession()
        XCTAssertFalse(session.isCurrentlyStill)
        var fired = 0
        XCTAssertTrue(session.requestStillCapture(onFire: { fired += 1 }))
        XCTAssertTrue(session.isStillCapturePending, "the reticle shows the shot waiting")
        XCTAssertEqual(fired, 0, "the 360° still waits for the device to settle after the tap")
    }

    /// One tap at a time: a second tap while the first waits or is in flight is refused.
    func testSecondTapWhileOneWaitsIsRefused() {
        let session = FrameCaptureSession()
        XCTAssertTrue(session.requestStillCapture())
        XCTAssertFalse(session.requestStillCapture())
        XCTAssertEqual(session.tapSettleTimeoutCount, 0)
    }

    /// No tap is armed once capture has ended.
    func testTapAfterCaptureEndsIsRefused() {
        let session = FrameCaptureSession()
        session.pauseCapture()
        XCTAssertFalse(session.requestStillCapture())
        XCTAssertFalse(session.isStillCapturePending)
    }
}
