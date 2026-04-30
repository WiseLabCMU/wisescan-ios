import XCTest

/// UI tests for generating App Store screenshots via `fastlane snapshot`.
///
/// Screens captured:
///   1. ScansListView — Location grid overview
///   2. LocationDetailView — Scan cards with mesh preview + export options
///   3. SettingsView — Upload URL + capture configuration
///
/// Prerequisites:
///   1. Import real scan data into each Simulator (Documents/Scans/)
///   2. Run: `bundle exec fastlane screenshots`
@MainActor
final class ScreenshotTests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("--seed-demo-data")
        setupSnapshot(app)
        app.launch()

        // Dismiss the "Lite Mode — No LiDAR" alert that appears on Simulators
        let alertButton = app.alerts.buttons["Got it"]
        if alertButton.waitForExistence(timeout: 5) {
            alertButton.tap()
        }
    }

    /// Find and tap the "Scans" tab — handles both iPhone (bottom tab bar)
    /// and iPad (top floating tab bar / sidebar) layouts.
    private func tapScansTab() {
        // iPhone: standard bottom tab bar
        let tabBarButton = app.tabBars.buttons["Scans"]
        if tabBarButton.waitForExistence(timeout: 3) {
            tabBarButton.tap()
            return
        }

        // iPad (iPadOS 26+): floating top tab bar renders as regular buttons
        // Use firstMatch since there may be multiple elements with "Scans" label
        let scansButton = app.buttons.matching(identifier: "Scans").firstMatch
        if scansButton.waitForExistence(timeout: 3) {
            scansButton.tap()
            return
        }

        XCTFail("Could not find Scans tab on any device layout")
    }

    // MARK: - 1. Scans List (Location Grid)

    func test01_ScansList() {
        tapScansTab()

        // Wait for content to load
        sleep(3)
        snapshot("01_ScansList")
    }

    // MARK: - 2. Location Detail (Scan Cards + Mesh Preview)

    func test02_LocationDetail() {
        tapScansTab()
        sleep(2)

        // Tap the first location to enter detail view
        let firstCell = app.cells.firstMatch
        if firstCell.waitForExistence(timeout: 5) {
            firstCell.tap()
        } else {
            let firstButton = app.scrollViews.firstMatch.buttons.firstMatch
            XCTAssertTrue(firstButton.waitForExistence(timeout: 5), "No location cell found")
            firstButton.tap()
        }

        // Allow mesh preview to render
        sleep(3)
        snapshot("02_LocationDetail")
    }

    // MARK: - 3. Settings

    func test03_Settings() {
        // Open settings via the gear icon — search broadly
        let gearButton = app.buttons["gearshape"]
        if gearButton.waitForExistence(timeout: 3) {
            gearButton.tap()
        } else {
            let navGear = app.navigationBars.buttons["gearshape"]
            XCTAssertTrue(navGear.waitForExistence(timeout: 5), "Gear button not found")
            navGear.tap()
        }

        // Wait for settings sheet
        sleep(2)
        snapshot("03_Settings")
    }
}
