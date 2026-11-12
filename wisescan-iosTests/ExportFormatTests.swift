import XCTest
@testable import wisescan_ios

/// The export format a stored name decodes to. Names persist in SwiftData
/// (`CapturedScan.selectedFormatStr`) and `@AppStorage`, so a format that is folded into another
/// must keep decoding, or every scan and preference holding it would fall back silently.
final class ExportFormatTests: XCTestCase {

    func testCurrentNamesDecodeToThemselves() {
        for format in ExportFormat.allCases {
            XCTAssertEqual(ExportFormat.persisted(format.rawValue), format)
        }
        XCTAssertEqual(ExportFormat.allCases, [.scan4d, .usdz, .ply, .obj])
    }

    /// Polycam, Nerfstudio (named RAW before it), and Flame3D were folded into Scan4D, which
    /// holds everything they did; the server makes their layouts from it.
    func testFoldedFormatsDecodeToScan4D() {
        for name in ["Polycam", "Nerfstudio", "Flame3D", "RAW"] {
            XCTAssertEqual(ExportFormat.persisted(name), .scan4d, name)
        }
    }

    func testUnknownNamesDecodeToNothing() {
        XCTAssertNil(ExportFormat.persisted(""))
        XCTAssertNil(ExportFormat.persisted("nerfstudio"))   // names are case-sensitive
        XCTAssertNil(ExportFormat.persisted("GLB"))
    }

    /// The format pickers bind the stored name as it is, so a retired one showed a blank picker
    /// until launch rewrote it as its replacement.
    @MainActor
    func testStoredSelectionIsRewrittenOnce() throws {
        let suite = "ExportFormatTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = AppConstants.Key.selectedExportFormat

        XCTAssertFalse(ExportFormat.migrateStoredSelection(defaults))   // nothing stored: the default holds
        defaults.set("Nerfstudio", forKey: key)
        XCTAssertTrue(ExportFormat.migrateStoredSelection(defaults))
        XCTAssertEqual(defaults.string(forKey: key), ExportFormat.scan4d.rawValue)
        XCTAssertFalse(ExportFormat.migrateStoredSelection(defaults))   // once

        defaults.set("GLB", forKey: key)                                // unknown: the default format
        XCTAssertTrue(ExportFormat.migrateStoredSelection(defaults))
        XCTAssertEqual(defaults.string(forKey: key), ExportFormat.scan4d.rawValue)

        defaults.set(ExportFormat.ply.rawValue, forKey: key)            // a current name stays
        XCTAssertFalse(ExportFormat.migrateStoredSelection(defaults))
        XCTAssertEqual(defaults.string(forKey: key), ExportFormat.ply.rawValue)
    }
}
