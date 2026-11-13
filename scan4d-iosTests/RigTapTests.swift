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

/// When the rig asks for an automatic 360° still: a deliberate pause on the rig, after the warm-up,
/// with nothing armed and nothing taken in this pause. Spacing, the camera and the switch are the
/// capture view's call (`CaptureView.automaticRigStill`).
@MainActor
final class RigAutoStillTests: XCTestCase {
    private let hold = AppConstants.stillnessDurationRequired + AppConstants.rigAutoStillHoldSeconds
    private let afterWarmup = AppConstants.roomStillWarmupSeconds + 1

    private func due(confirmedStill: Bool = true, isRig: Bool = true, requestArmed: Bool = false,
                     pauseDelivered: Bool = false, heldFor: TimeInterval? = nil,
                     sinceRecordingStart: TimeInterval? = nil) -> Bool {
        FrameCaptureSession.rigAutoStillDue(confirmedStill: confirmedStill, isRig: isRig,
                                            requestArmed: requestArmed, pauseDelivered: pauseDelivered,
                                            heldFor: heldFor ?? hold, sinceRecordingStart: sinceRecordingStart ?? afterWarmup)
    }

    func testDueAfterADeliberatePauseOnTheRig() {
        XCTAssertTrue(due())
        XCTAssertFalse(due(heldFor: hold - 0.1), "a brief stop is not a pause")
    }

    func testNotDueOffTheRigOrWhileMoving() {
        XCTAssertFalse(due(isRig: false))
        XCTAssertFalse(due(confirmedStill: false))
    }

    func testOnePerPauseAndNeverOverATap() {
        XCTAssertFalse(due(pauseDelivered: true), "this pause already gave its still")
        XCTAssertFalse(due(requestArmed: true), "a tap (or an earlier automatic request) is armed")
    }

    func testNotDuringTheWarmup() {
        XCTAssertFalse(due(sinceRecordingStart: AppConstants.roomStillWarmupSeconds - 1))
        XCTAssertFalse(FrameCaptureSession.rigAutoStillDue(confirmedStill: true, isRig: true, requestArmed: false,
                                                           pauseDelivered: false, heldFor: hold, sinceRecordingStart: nil))
    }
}
