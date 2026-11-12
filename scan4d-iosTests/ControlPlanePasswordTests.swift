import Foundation
import XCTest
@testable import scan4d_ios

/// The control plane host's TestFlight default and the password prompt's rule: a tapped Sync
/// waits for Settings only when its server has refused a request for want of a password.
@MainActor
final class ControlPlanePasswordTests: XCTestCase {

    /// Only TestFlight builds start with the lab's control plane set;
    /// tests, like Xcode and App Store builds, start with none.
    func testControlPlaneHostIsEmptyOutsideTestFlight() {
        XCTAssertFalse(AppConstants.isTestFlight)
        XCTAssertEqual(AppConstants.controlPlaneHost, "")
    }

    /// A 401 to a request sent without a password marks that server as wanting one; a success
    /// without one (an open development server) clears it. Other servers are unaffected.
    func testServerThatRefusedWantsAPassword() throws {
        let key = AppConstants.Key.controlPlanePasswordWanted
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let lab = try XCTUnwrap(ControlPlaneClient.baseURL(fromHost: "https://wiselambda4.lan.cmu.edu"))
        let other = try XCTUnwrap(ControlPlaneClient.baseURL(fromHost: "192.168.1.40:8000"))

        XCTAssertFalse(ControlPlaneSecret.isMissing(forHost: "https://wiselambda4.lan.cmu.edu", password: ""))
        ControlPlaneSecret.noteReply(from: lab, refused: true)
        XCTAssertTrue(ControlPlaneSecret.isWanted(by: lab))
        XCTAssertTrue(ControlPlaneSecret.isMissing(forHost: " https://wiselambda4.lan.cmu.edu ", password: ""))
        XCTAssertFalse(ControlPlaneSecret.isMissing(forHost: "https://wiselambda4.lan.cmu.edu", password: "typed"))
        XCTAssertFalse(ControlPlaneSecret.isMissing(forHost: "192.168.1.40:8000", password: ""))
        XCTAssertFalse(ControlPlaneSecret.isMissing(forHost: "", password: ""))

        ControlPlaneSecret.noteReply(from: other, refused: false)   // another server's answer
        XCTAssertTrue(ControlPlaneSecret.isWanted(by: lab))
        ControlPlaneSecret.noteReply(from: lab, refused: false)     // it runs open after all
        XCTAssertFalse(ControlPlaneSecret.isWanted(by: lab))
    }

    /// A tapped Sync runs at once unless its server wants a password the phone lacks;
    /// then it waits for the prompt, which runs it when Settings closes.
    func testTappedActionWaitsOnlyForAWantedPassword() throws {
        let key = AppConstants.Key.controlPlanePasswordWanted
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let host = "https://wiselambda4.lan.cmu.edu"
        var runs = 0

        XCTAssertNil(ControlPlanePendingAction.runOrHold(host: host, password: "") { runs += 1 })
        XCTAssertEqual(runs, 1, "a server not known to want a password: runs now")

        ControlPlaneSecret.noteReply(from: try XCTUnwrap(ControlPlaneClient.baseURL(fromHost: host)), refused: true)
        let held = try XCTUnwrap(ControlPlanePendingAction.runOrHold(host: host, password: "") { runs += 1 })
        XCTAssertEqual(runs, 1, "held for the prompt")
        held.run()
        XCTAssertEqual(runs, 2)

        XCTAssertNil(ControlPlanePendingAction.runOrHold(host: host, password: "typed") { runs += 1 })
        XCTAssertEqual(runs, 3, "with a password: runs now")
    }
}
