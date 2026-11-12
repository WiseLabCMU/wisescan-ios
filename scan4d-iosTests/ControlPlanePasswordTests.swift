import Foundation
import XCTest
@testable import scan4d_ios

/// The control plane host's default, the server a device that synced through the old TestFlight
/// prefill keeps, and the password prompt's rule: a tapped Sync waits for Settings only when its
/// server has refused a request for want of a password.
@MainActor
final class ControlPlanePasswordTests: XCTestCase {

    /// Every build starts with no Scan4D server, TestFlight included.
    func testControlPlaneHostStartsEmpty() {
        XCTAssertEqual(AppConstants.controlPlaneHost, "")
    }

    /// A scratch defaults domain, removed after the test.
    private func scratchDefaults() throws -> UserDefaults {
        let name = "ControlPlanePasswordTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    /// A device that synced through the old TestFlight prefill (a first-sync time, no saved host)
    /// keeps its server: the one its last sync came from, else the one that asked for a password.
    func testDeviceThatSyncedKeepsItsRecordedServer() throws {
        let defaults = try scratchDefaults()
        defaults.set(1_700_000_000.0, forKey: AppConstants.Key.controlPlaneJoinedAt)
        defaults.set("https://example.com", forKey: AppConstants.Key.controlPlanePasswordWanted)
        AppConstants.keepPrefilledControlPlaneHost(in: defaults)
        XCTAssertEqual(defaults.string(forKey: AppConstants.Key.controlPlaneHost), "https://example.com")

        let both = try scratchDefaults()
        both.set(1_700_000_000.0, forKey: AppConstants.Key.controlPlaneJoinedAt)
        both.set("https://example.com/asked", forKey: AppConstants.Key.controlPlanePasswordWanted)
        both.set("https://example.com/synced", forKey: AppConstants.Key.controlPlaneStateServer)
        AppConstants.keepPrefilledControlPlaneHost(in: both)
        XCTAssertEqual(both.string(forKey: AppConstants.Key.controlPlaneHost), "https://example.com/synced",
                       "the server the last sync came from wins")

        // The kept URL is the same server the device's sync state belongs to.
        let kept = try XCTUnwrap(both.string(forKey: AppConstants.Key.controlPlaneHost))
        XCTAssertEqual(ControlPlaneClient.baseURL(fromHost: kept)?.absoluteString, "https://example.com/synced")
    }

    /// Nothing is saved for a device that never synced, one with no recorded server, or one whose
    /// user typed or cleared the host (a cleared host stays cleared).
    func testOtherDevicesAreLeftAlone() throws {
        let neverSynced = try scratchDefaults()
        neverSynced.set("https://example.com", forKey: AppConstants.Key.controlPlanePasswordWanted)
        AppConstants.keepPrefilledControlPlaneHost(in: neverSynced)
        XCTAssertNil(neverSynced.object(forKey: AppConstants.Key.controlPlaneHost))

        let noRecord = try scratchDefaults()
        noRecord.set(1_700_000_000.0, forKey: AppConstants.Key.controlPlaneJoinedAt)
        AppConstants.keepPrefilledControlPlaneHost(in: noRecord)
        XCTAssertNil(noRecord.object(forKey: AppConstants.Key.controlPlaneHost))

        for typed in ["", "192.168.1.40:8000"] {
            let defaults = try scratchDefaults()
            defaults.set(typed, forKey: AppConstants.Key.controlPlaneHost)
            defaults.set(1_700_000_000.0, forKey: AppConstants.Key.controlPlaneJoinedAt)
            defaults.set("https://example.com", forKey: AppConstants.Key.controlPlaneStateServer)
            AppConstants.keepPrefilledControlPlaneHost(in: defaults)
            XCTAssertEqual(defaults.string(forKey: AppConstants.Key.controlPlaneHost), typed)
        }
    }

    /// A 401 to a request sent without a password marks that server as wanting one; a success
    /// without one (an open development server) clears it. Other servers are unaffected.
    func testServerThatRefusedWantsAPassword() throws {
        let key = AppConstants.Key.controlPlanePasswordWanted
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let server = try XCTUnwrap(ControlPlaneClient.baseURL(fromHost: "https://example.com"))
        let other = try XCTUnwrap(ControlPlaneClient.baseURL(fromHost: "192.168.1.40:8000"))

        XCTAssertFalse(ControlPlaneSecret.isMissing(forHost: "https://example.com", password: ""))
        ControlPlaneSecret.noteReply(from: server, refused: true)
        XCTAssertTrue(ControlPlaneSecret.isWanted(by: server))
        XCTAssertTrue(ControlPlaneSecret.isMissing(forHost: " https://example.com ", password: ""))
        XCTAssertFalse(ControlPlaneSecret.isMissing(forHost: "https://example.com", password: "typed"))
        XCTAssertFalse(ControlPlaneSecret.isMissing(forHost: "192.168.1.40:8000", password: ""))
        XCTAssertFalse(ControlPlaneSecret.isMissing(forHost: "", password: ""))

        ControlPlaneSecret.noteReply(from: other, refused: false)   // another server's answer
        XCTAssertTrue(ControlPlaneSecret.isWanted(by: server))
        ControlPlaneSecret.noteReply(from: server, refused: false)     // it runs open after all
        XCTAssertFalse(ControlPlaneSecret.isWanted(by: server))
    }

    /// A tapped Sync runs at once unless its server wants a password the phone lacks;
    /// then it waits for the prompt, which runs it when Settings closes.
    func testTappedActionWaitsOnlyForAWantedPassword() throws {
        let key = AppConstants.Key.controlPlanePasswordWanted
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let host = "https://example.com"
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
