import Foundation
import XCTest
@testable import scan4d_ios

/// Restore Default Developer Options and turning Developer Mode off share one list,
/// AppConstants.developerOptionDefaults. These pin what the list must guarantee: a restore brings
/// every option back, including the default-on switches read straight from UserDefaults, it leaves
/// Developer Mode on, and a launch with Developer Mode off puts every option back.
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
    /// typed reads the app uses (bool, integer, double, string), not only through @AppStorage.
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
            } else if let number = value as? Double {
                XCTAssertEqual(defaults.double(forKey: key), number, key)
            } else if let text = value as? String {
                XCTAssertEqual(defaults.string(forKey: key), text, key)
            } else {
                XCTFail("\(key): a developer default must be a Bool, Int, Double or String")
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
        // Off, Semantic Labeling leaves scans without room data and Rescan blocks them as bad scans.
        XCTAssertTrue(defaultOn.contains(AppConstants.Key.semanticLabeling))
        XCTAssertTrue(defaultOn.contains(AppConstants.Key.rawRejectBlur))
        for key in defaultOn { defaults.set(false, forKey: key) }
        AppConstants.restoreDeveloperDefaults(in: defaults)
        for key in defaultOn {
            XCTAssertTrue(defaults.bool(forKey: key), key)
        }
    }

    /// Developer Mode itself stays on through a restore.
    func testRestoreLeavesDeveloperModeOn() {
        XCTAssertNil(AppConstants.developerOptionDefaults[AppConstants.Key.developerMode])
        defaults.set(true, forKey: AppConstants.Key.developerMode)
        AppConstants.restoreDeveloperDefaults(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: AppConstants.Key.developerMode))
    }

    /// The tuning that left everyday Settings is in the list, so a restore covers it.
    func testMovedSettingsAreDeveloperOptions() {
        for key in [AppConstants.Key.rawOverlapMax, AppConstants.Key.rawRejectBlur, AppConstants.Key.semanticLabeling,
                    AppConstants.Key.activeMeshColor, AppConstants.Key.ghostMeshColor, AppConstants.Key.metaWearablesFPS] {
            XCTAssertNotNil(AppConstants.developerOptionDefaults[key], key)
        }
    }

    /// At launch with Developer Mode off, every option is put back: this is what clears a setting a
    /// user changed in everyday Settings before it moved into Developer Mode (Semantic Labeling off
    /// blocks every rescan, and its switch is no longer where they would look). With Developer Mode
    /// on, the bench setup is left alone.
    func testLaunchRestoresOptionsOnlyOutsideDeveloperMode() {
        defaults.set(false, forKey: AppConstants.Key.semanticLabeling)
        defaults.set(30.0, forKey: AppConstants.Key.rawOverlapMax)

        defaults.set(true, forKey: AppConstants.Key.developerMode)
        AppConstants.restoreDeveloperDefaultsOutsideDeveloperMode(in: defaults)
        XCTAssertFalse(defaults.bool(forKey: AppConstants.Key.semanticLabeling), "developer setup kept")

        defaults.set(false, forKey: AppConstants.Key.developerMode)
        AppConstants.restoreDeveloperDefaultsOutsideDeveloperMode(in: defaults)
        XCTAssertTrue(defaults.bool(forKey: AppConstants.Key.semanticLabeling))
        XCTAssertEqual(defaults.double(forKey: AppConstants.Key.rawOverlapMax), AppConstants.overlapMax)
        XCTAssertTrue(AppConstants.developerOptionsAreDefault(in: defaults))
    }

    /// The app registers every developer default at launch, so code that reads a key straight from
    /// UserDefaults sees the default after a restore removes the stored value.
    func testAppRegistersEveryDeveloperDefault() {
        let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        for (key, value) in AppConstants.developerOptionDefaults {
            XCTAssertEqual(registered[key] as? NSObject, value as? NSObject, key)
        }
    }

    /// A value the restore must undo: the opposite switch, another index or amount, another name.
    private static func nonDefault(_ value: Any) -> Any? {
        if let flag = value as? Bool { return !flag }
        if let number = value as? Int { return number + 1 }
        if let number = value as? Double { return number + 1 }
        if let text = value as? String { return text + "-changed" }
        return nil
    }
}
