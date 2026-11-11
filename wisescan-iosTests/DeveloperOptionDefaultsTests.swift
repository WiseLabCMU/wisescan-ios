import Foundation
import XCTest
@testable import wisescan_ios

/// Restore Default Developer Options and turning Developer Mode off share one list,
/// AppConstants.developerOptionDefaults. These pin what the list must guarantee: a restore brings
/// every option back, including the default-on switches read straight from UserDefaults, and it
/// leaves Developer Mode and Semantic Labeling alone.
@MainActor
final class DeveloperOptionDefaultsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "DeveloperOptionDefaultsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // As Scan4DApp.init does for the standard defaults.
        defaults.register(defaults: AppConstants.developerOptionDefaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// Every option set away from its default reads its default again after a restore, through the
    /// typed reads the app uses (bool(forKey:), integer(forKey:)), not only through @AppStorage.
    func testRestoreBringsEveryOptionBackToItsDefault() throws {
        for (key, value) in AppConstants.developerOptionDefaults {
            defaults.set(try XCTUnwrap(Self.nonDefault(value), "no non-default value for \(key)"), forKey: key)
        }
        XCTAssertFalse(AppConstants.developerOptionsAreDefault(in: defaults))

        AppConstants.restoreDeveloperDefaults(in: defaults)

        XCTAssertTrue(AppConstants.developerOptionsAreDefault(in: defaults))
        for (key, value) in AppConstants.developerOptionDefaults {
            if let flag = value as? Bool {
                XCTAssertEqual(defaults.bool(forKey: key), flag, key)
            } else if let number = value as? Int {
                XCTAssertEqual(defaults.integer(forKey: key), number, key)
            }
        }
    }

    /// One option off its default is enough to make the restore button live.
    func testOneChangedOptionIsNotDefault() {
        XCTAssertTrue(AppConstants.developerOptionsAreDefault(in: defaults))
        defaults.set(!AppConstants.keepCameraOriginals, forKey: AppConstants.Key.keepCameraOriginals)
        XCTAssertFalse(AppConstants.developerOptionsAreDefault(in: defaults))
        // Switching it back by hand stores the default explicitly: that still counts as default.
        defaults.set(AppConstants.keepCameraOriginals, forKey: AppConstants.Key.keepCameraOriginals)
        XCTAssertTrue(AppConstants.developerOptionsAreDefault(in: defaults))
    }

    /// Default-on switches must come back ON: a stored OFF that survived would silently drop mesh
    /// classification or the GPU colorize path outside Developer Mode.
    func testDefaultOnSwitchesComeBackOn() {
        let defaultOn = AppConstants.developerOptionDefaults.filter { ($0.value as? Bool) == true }.map(\.key)
        XCTAssertTrue(defaultOn.contains(AppConstants.Key.meshClassifier))
        XCTAssertTrue(defaultOn.contains(AppConstants.Key.captureAudioEnabled))
        for key in defaultOn { defaults.set(false, forKey: key) }
        AppConstants.restoreDeveloperDefaults(in: defaults)
        for key in defaultOn {
            XCTAssertTrue(defaults.bool(forKey: key), key)
        }
    }

    /// Developer Mode itself stays on through a restore, and Semantic Labeling is a Scan Capture
    /// setting, not a developer option.
    func testRestoreLeavesDeveloperModeAndSemanticLabelingAlone() {
        XCTAssertNil(AppConstants.developerOptionDefaults[AppConstants.Key.developerMode])
        XCTAssertNil(AppConstants.developerOptionDefaults[AppConstants.Key.semanticLabeling])
        defaults.set(true, forKey: AppConstants.Key.developerMode)
        defaults.set(false, forKey: AppConstants.Key.semanticLabeling)

        AppConstants.restoreDeveloperDefaults(in: defaults)

        XCTAssertTrue(defaults.bool(forKey: AppConstants.Key.developerMode))
        XCTAssertEqual(defaults.object(forKey: AppConstants.Key.semanticLabeling) as? Bool, false)
    }

    /// The app registers every developer default at launch, so code that reads a key straight from
    /// UserDefaults sees the default after a restore removes the stored value.
    func testAppRegistersEveryDeveloperDefault() {
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        for (key, value) in AppConstants.developerOptionDefaults {
            XCTAssertEqual(registered[key] as? NSObject, value as? NSObject, key)
        }
    }

    /// A value the restore must undo: the opposite switch, or another index.
    private static func nonDefault(_ value: Any) -> Any? {
        if let flag = value as? Bool { return !flag }
        if let number = value as? Int { return number + 1 }
        return nil
    }
}
