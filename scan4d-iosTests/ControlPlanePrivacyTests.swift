import Foundation
import XCTest
@testable import wisescan_ios

/// The privacy field of the control plane sync: each scan's Privacy Filter state, so the server
/// can show which scans may have people unblurred.
@MainActor
final class ControlPlanePrivacyTests: XCTestCase {
    /// Each scan's Privacy Filter state as the server gets it: a room scan's masks or metadata
    /// flag, a focus scan's capture manifest; unknown is left out of the manifest, not guessed.
    func testPrivacyFilterStateIsReadPerScanKind() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cp_\(UUID().uuidString)")
        let raw = dir.appendingPathComponent("raw_data")
        let focus = dir.appendingPathComponent("focus")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: focus, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = raw.appendingPathComponent("scan4d_metadata.json")

        // Nothing recorded (or metadata older than the flag): unknown.
        XCTAssertNil(ControlPlaneManifest.readPrivacyFilter(.room(rawData: raw)))
        try Data(#"{"version": 1}"#.utf8).write(to: meta)
        XCTAssertNil(ControlPlaneManifest.readPrivacyFilter(.room(rawData: raw)))
        // The metadata flag, either way.
        try Data(#"{"privacy_filter": false}"#.utf8).write(to: meta)
        XCTAssertEqual(ControlPlaneManifest.readPrivacyFilter(.room(rawData: raw)), false)
        // Segmentation masks exist only when the filter was on, and win over the flag.
        let masks = raw.appendingPathComponent("masks")
        try FileManager.default.createDirectory(at: masks, withIntermediateDirectories: true)
        try Data([0]).write(to: masks.appendingPathComponent("frame_00001.png"))
        XCTAssertEqual(ControlPlaneManifest.readPrivacyFilter(.room(rawData: raw)), true)

        XCTAssertNil(ControlPlaneManifest.readPrivacyFilter(.focus(captureFolder: focus)))
        try Data(#"{"setup": {"privacyFilter": false}}"#.utf8).write(to: focus.appendingPathComponent("manifest.json"))
        XCTAssertEqual(ControlPlaneManifest.readPrivacyFilter(.focus(captureFolder: focus)), false)

        // Unknown is left out of the wire format rather than sent as a guess.
        let unknown = ControlPlaneManifest.Scan(scanId: UUID(), kind: "room", name: "s", capturedAt: Date(), parentScanId: nil,
                                                captureSource: "Native iOS", worldMapSuspect: false, stillCount: 0,
                                                focusRegion: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: ControlPlaneManifest.encoder.encode(unknown)) as? [String: Any])
        XCTAssertNil(json["privacy_filter"])
    }
}
