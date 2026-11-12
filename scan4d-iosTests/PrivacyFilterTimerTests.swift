import Foundation
import XCTest
@testable import scan4d_ios

/// The Privacy Filter's time limit: switched off, it turns itself back on after the limit, an
/// unknown switch-off time fails closed, and "None" never turns it back on.
@MainActor
final class PrivacyFilterTimerTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "PrivacyFilterTimerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.register(defaults: AppConstants.developerOptionDefaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    func testDefaultLimitIsADay() {
        XCTAssertEqual(AppConstants.privacyFilterTimeLimitHours, 24)
        XCTAssertEqual(defaults.integer(forKey: AppConstants.Key.privacyFilterTimeLimitHours), 24)
        XCTAssertTrue(AppConstants.privacyFilterTimeLimitChoices.contains(0), "None must be offered")
    }

    func testExpiresOnlyOnceTheLimitHasPassed() {
        XCTAssertFalse(PrivacyFilterTimer.hasExpired(offAt: hoursAgo(23.9), limitHours: 24, now: now))
        XCTAssertTrue(PrivacyFilterTimer.hasExpired(offAt: hoursAgo(24), limitHours: 24, now: now))
        XCTAssertTrue(PrivacyFilterTimer.hasExpired(offAt: hoursAgo(13), limitHours: 12, now: now))
        XCTAssertFalse(PrivacyFilterTimer.hasExpired(offAt: hoursAgo(100), limitHours: 168, now: now))
    }

    /// Off before this build (no switch-off time on record): fail closed, back on.
    func testUnknownSwitchOffTimeCountsAsExpired() {
        XCTAssertTrue(PrivacyFilterTimer.hasExpired(offAt: nil, limitHours: 24, now: now))
    }

    func testNoLimitNeverExpires() {
        XCTAssertFalse(PrivacyFilterTimer.hasExpired(offAt: hoursAgo(10_000), limitHours: 0, now: now))
        XCTAssertFalse(PrivacyFilterTimer.hasExpired(offAt: nil, limitHours: 0, now: now))
    }

    func testEnforceTurnsTheFilterBackOnAndForgetsTheTime() {
        defaults.set(false, forKey: AppConstants.Key.privacyFilter)
        PrivacyFilterTimer.noteSwitch(isOn: false, defaults: defaults, now: hoursAgo(25))

        XCTAssertTrue(PrivacyFilterTimer.enforce(defaults: defaults, now: now))
        XCTAssertTrue(defaults.bool(forKey: AppConstants.Key.privacyFilter))
        XCTAssertNil(defaults.object(forKey: AppConstants.Key.privacyFilterOffAt))
        // Already on: nothing more to do.
        XCTAssertFalse(PrivacyFilterTimer.enforce(defaults: defaults, now: now))
    }

    func testEnforceLeavesARecentSwitchOffAlone() {
        defaults.set(false, forKey: AppConstants.Key.privacyFilter)
        PrivacyFilterTimer.noteSwitch(isOn: false, defaults: defaults, now: hoursAgo(2))
        XCTAssertFalse(PrivacyFilterTimer.enforce(defaults: defaults, now: now))
        XCTAssertFalse(defaults.bool(forKey: AppConstants.Key.privacyFilter))
    }

    func testEnforceFollowsTheDeveloperLimit() {
        defaults.set(false, forKey: AppConstants.Key.privacyFilter)
        PrivacyFilterTimer.noteSwitch(isOn: false, defaults: defaults, now: hoursAgo(13))
        defaults.set(0, forKey: AppConstants.Key.privacyFilterTimeLimitHours)
        XCTAssertFalse(PrivacyFilterTimer.enforce(defaults: defaults, now: now), "None keeps it off")
        defaults.set(12, forKey: AppConstants.Key.privacyFilterTimeLimitHours)
        XCTAssertTrue(PrivacyFilterTimer.enforce(defaults: defaults, now: now))
    }

    /// The first launch after this shipped, with the filter already off: back on.
    func testOffWithNoRecordedTimeIsTurnedBackOn() {
        defaults.set(false, forKey: AppConstants.Key.privacyFilter)
        XCTAssertTrue(PrivacyFilterTimer.enforce(defaults: defaults, now: now))
        XCTAssertTrue(defaults.bool(forKey: AppConstants.Key.privacyFilter))
    }

    /// Never set: the filter is on by default, so there is nothing to enforce.
    func testUnsetFilterIsOn() {
        XCTAssertFalse(PrivacyFilterTimer.enforce(defaults: defaults, now: now))
        XCTAssertNil(defaults.object(forKey: AppConstants.Key.privacyFilter))
    }

    func testSwitchingOnForgetsTheSwitchOffTime() {
        PrivacyFilterTimer.noteSwitch(isOn: false, defaults: defaults, now: now)
        XCTAssertEqual(defaults.double(forKey: AppConstants.Key.privacyFilterOffAt), now.timeIntervalSince1970)
        PrivacyFilterTimer.noteSwitch(isOn: true, defaults: defaults, now: now)
        XCTAssertNil(defaults.object(forKey: AppConstants.Key.privacyFilterOffAt))
    }

    func testLimitNames() {
        XCTAssertEqual(PrivacyFilterTimer.describe(hours: 12), "12 h")
        XCTAssertEqual(PrivacyFilterTimer.describe(hours: 24), "24 h")
        XCTAssertEqual(PrivacyFilterTimer.describe(hours: 168), "1 week")
        XCTAssertEqual(PrivacyFilterTimer.describe(hours: 0), "no limit")
    }
}
