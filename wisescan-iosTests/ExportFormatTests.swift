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
}
