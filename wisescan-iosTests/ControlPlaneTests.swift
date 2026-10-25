import Foundation
import SwiftData
import XCTest
@testable import wisescan_ios

/// The control plane sync's device-side pieces that run without a server: the host field, the
/// manifest's wire format, the snapshot's base/tip, the registration sidecar read.
@MainActor
final class ControlPlaneTests: XCTestCase {

    func testHostWithoutSchemeIsHTTP() throws {
        let url = try XCTUnwrap(ControlPlaneClient.baseURL(fromHost: " 192.168.1.40:8000 "))
        XCTAssertEqual(url.absoluteString, "http://192.168.1.40:8000")
        XCTAssertEqual(url.appending(path: "v1/health").absoluteString, "http://192.168.1.40:8000/v1/health")
    }

    func testHostKeepsSchemeAndPathPrefix() throws {
        let url = try XCTUnwrap(ControlPlaneClient.baseURL(fromHost: "https://wiselambda4.lan.cmu.edu/scan4d/"))
        XCTAssertEqual(url.appending(path: "v1/health").absoluteString,
                       "https://wiselambda4.lan.cmu.edu/scan4d/v1/health")
    }

    func testUnusableHostsAreRefused() {
        XCTAssertNil(ControlPlaneClient.baseURL(fromHost: ""))
        XCTAssertNil(ControlPlaneClient.baseURL(fromHost: "   "))
        XCTAssertNil(ControlPlaneClient.baseURL(fromHost: "ftp://files.local"))
        XCTAssertNil(ControlPlaneClient.baseURL(fromHost: "http://"))
    }

    func testATSRefusalExplainsWhichHostsWork() {
        let failure = ControlPlaneClient.failure(for: URLError(.appTransportSecurityRequiresSecureConnection),
                                                 host: "wiselambda4.lan.cmu.edu")
        XCTAssertEqual(failure, .insecureHost("wiselambda4.lan.cmu.edu"))
    }

    func testServerErrorDetailIsRead() {
        let body = Data(#"{"detail": "device.device_id does not match the URL"}"#.utf8)
        XCTAssertEqual(ControlPlaneClient.detail(from: body), "device.device_id does not match the URL")
        XCTAssertEqual(ControlPlaneClient.detail(from: Data("<html>".utf8)), "")
    }

    /// The server reads snake_case keys and ISO 8601 times (scan4d-server README, "Sync").
    func testManifestWireFormat() throws {
        let scanA = UUID(), scanB = UUID(), location = UUID()
        let region = FocusRegion(center: SIMD3(1, 0.5, -2), yaw: 0.3, size: SIMD3(0.8, 0.9, 0.6), label: "table",
                                 source: .user, detail: .detail, locationId: location)
        let manifest = ControlPlaneManifest(
            device: .init(deviceId: UUID(), label: "Lab iPhone", model: "iPhone16,2", systemVersion: "26.1",
                          appVersion: "1.9.0", appBuild: "412", lidar: true),
            generatedAt: Date(timeIntervalSince1970: 0),
            locations: [.init(locationId: location, name: "Lab", updatedAt: Date(timeIntervalSince1970: 0),
                              baseScanId: scanA, tipScanId: scanA,
                              scans: [.init(scanId: scanA, kind: "focus", name: "f", capturedAt: Date(timeIntervalSince1970: 0),
                                            parentScanId: scanB, captureSource: "Native iOS", worldMapSuspect: false,
                                            stillCount: 3,
                                            registration: .init(applied: true, transform: Array(repeating: 0, count: 16),
                                                                targetScanId: scanB.uuidString),
                                            focusRegion: region,
                                            upload: .init(status: "pending", lastUploadedAt: nil, format: "Scan4D"))])],
            links: [.init(linkId: UUID(), scanAId: scanA, scanBId: scanB, locationAId: location, locationBId: nil,
                          anchorA: Array(repeating: 0, count: 16), anchorB: Array(repeating: 0, count: 16),
                          anchorAId: UUID(), anchorBId: UUID(), anchorAHeading: 12, anchorBHeading: nil,
                          sourceIsA: true, manual: .init(yawDeg: 1, dx: 0, dy: 0, dz: 0),
                          linkType: "mid_session", linkedAt: Date(timeIntervalSince1970: 0))])
        let data = try ControlPlaneManifest.encoder.encode(manifest)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["generated_at"] as? String, "1970-01-01T00:00:00Z")
        let device = try XCTUnwrap(json["device"] as? [String: Any])
        XCTAssertNotNil(device["device_id"])
        XCTAssertEqual(device["system_version"] as? String, "26.1")

        let loc = try XCTUnwrap((json["locations"] as? [[String: Any]])?.first)
        XCTAssertEqual(loc["base_scan_id"] as? String, scanA.uuidString)
        let scan = try XCTUnwrap((loc["scans"] as? [[String: Any]])?.first)
        XCTAssertEqual(scan["parent_scan_id"] as? String, scanB.uuidString)
        XCTAssertEqual(scan["has_world_map"] as? Bool, false)
        XCTAssertEqual((scan["registration"] as? [String: Any])?["target_scan_id"] as? String, scanB.uuidString)
        // The focus region goes as focus_region.json, its own keys untouched.
        let focus = try XCTUnwrap(scan["focus_region"] as? [String: Any])
        XCTAssertEqual(focus["detail_level"] as? String, "detail")
        XCTAssertEqual((focus["center_m"] as? [Double])?.count, 3)

        let link = try XCTUnwrap((json["links"] as? [[String: Any]])?.first)
        for key in ["link_id", "scan_a_id", "location_a_id", "anchor_a", "anchor_a_id", "anchor_a_heading",
                    "source_is_a", "link_type", "linked_at"] {
            XCTAssertNotNil(link[key], key)
        }
        XCTAssertEqual((link["manual"] as? [String: Any])?["yaw_deg"] as? Double, 1)
    }

    /// Base is the first room scan, tip the newest; a focus scan is neither.
    func testSnapshotBaseTipAndKinds() throws {
        let context = try StitchTestSupport.makeInMemoryContext()
        let location = ScanLocation(name: "Lab")
        context.insert(location)
        let base = CapturedScan(name: "base", capturedAt: Date(timeIntervalSince1970: 100), vertexCount: 0, faceCount: 0)
        let rescan = CapturedScan(name: "rescan", capturedAt: Date(timeIntervalSince1970: 200), vertexCount: 0, faceCount: 0)
        let focus = CapturedScan(name: "focus", capturedAt: Date(timeIntervalSince1970: 300), vertexCount: 0, faceCount: 0)
        focus.scanKind = .focus
        focus.stillCount = 12
        for scan in [rescan, focus, base] {
            context.insert(scan)
            scan.location = location
        }
        let device = DeviceIdentity.manifestDevice(label: "test")
        let (manifest, files) = ControlPlaneManifest.snapshot(locations: [location], links: [], device: device)

        let entry = try XCTUnwrap(manifest.locations.first)
        XCTAssertEqual(entry.baseScanId, base.id)
        XCTAssertEqual(entry.tipScanId, rescan.id)
        XCTAssertEqual(entry.scans.map(\.scanId), [base.id, rescan.id, focus.id])
        XCTAssertEqual(entry.scans.map(\.kind), ["room", "room", "focus"])
        XCTAssertEqual(entry.scans.last?.stillCount, 12)
        XCTAssertEqual(files.count, 3)
    }

    /// The sidecar is written with SaveRegistration's own (camelCase) keys, at the scan's top level
    /// or under raw_data/.
    func testRegistrationSidecarIsReadFromEitherPlace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cp_\(UUID().uuidString)")
        let raw = dir.appendingPathComponent("raw_data")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(ControlPlaneManifest.readRegistration(scanDirectory: dir))

        let target = UUID().uuidString
        let sidecar = """
        {"version": 2, "applied": true, "reason": "applied", "transform": [1,0,0,0, 0,1,0,0, 0,0,1,0, 0.1,0,0,1],
         "transM": 0.1, "yawDeg": 0, "initialRMSmm": 9, "finalRMSmm": 3, "matchedWalls": 3, "matchedFloors": 1,
         "weakAxisFrac": 0.2, "converged": true, "targetScanId": "\(target)", "note": ""}
        """
        try Data(sidecar.utf8).write(to: raw.appendingPathComponent("registration.json"))
        let registration = try XCTUnwrap(ControlPlaneManifest.readRegistration(scanDirectory: dir))
        XCTAssertTrue(registration.applied)
        XCTAssertEqual(registration.transform?.count, 16)
        XCTAssertEqual(registration.targetScanId, target)
    }

    /// Map-package files: first existing candidate wins, times are whole seconds (what the
    /// manifest's ISO 8601 and the upload header carry), nothing is listed with packages off.
    func testPackageFilesAreListedFromTheFirstCandidate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cp_\(UUID().uuidString)")
        let raw = dir.appendingPathComponent("raw_data")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("v 0 0 0\n".utf8).write(to: dir.appendingPathComponent("mesh.obj"))
        try Data(#"{"applied": false, "targetScanId": "x"}"#.utf8).write(to: raw.appendingPathComponent("registration.json"))

        let scanId = UUID()
        let scan = ControlPlaneManifest.Scan(scanId: scanId, kind: "room", name: "s", capturedAt: Date(), parentScanId: nil,
                                             captureSource: "Native iOS", worldMapSuspect: false, stillCount: 0,
                                             focusRegion: nil, upload: .init(status: "pending", lastUploadedAt: nil, format: "Scan4D"))
        let draft = ControlPlaneManifest(
            device: DeviceIdentity.manifestDevice(label: "test"), generatedAt: Date(),
            locations: [.init(locationId: UUID(), name: "Lab", updatedAt: Date(), baseScanId: scanId, tipScanId: scanId, scans: [scan])],
            links: [])
        let files = [scanId: ControlPlaneManifest.ScanFiles(
            directory: dir, worldMap: dir.appendingPathComponent("arworldmap.map"),
            package: [("registration.json", [dir.appendingPathComponent("registration.json"), raw.appendingPathComponent("registration.json")]),
                      ("arworldmap.map", [dir.appendingPathComponent("arworldmap.map")]),
                      ("mesh.obj", [dir.appendingPathComponent("mesh.obj")])])]

        var manifest = draft
        let local = manifest.readScanFiles(files, packages: true)
        let listed = try XCTUnwrap(manifest.locations.first?.scans.first)
        XCTAssertEqual(listed.files.map(\.name), ["registration.json", "mesh.obj"])
        XCTAssertEqual(listed.files.last?.size, 8)
        XCTAssertFalse(listed.hasWorldMap)
        XCTAssertEqual(listed.registration?.applied, false)
        XCTAssertEqual(local[scanId]?["registration.json"]?.url.lastPathComponent, "registration.json")
        XCTAssertEqual(local[scanId]?["registration.json"]?.url.deletingLastPathComponent().lastPathComponent, "raw_data")
        let time = try XCTUnwrap(listed.files.first?.modifiedAt.timeIntervalSince1970)
        XCTAssertEqual(time, time.rounded(.down))

        var off = draft
        XCTAssertTrue(off.readScanFiles(files, packages: false).isEmpty)
        XCTAssertEqual(off.locations.first?.scans.first?.files.count, 0)
    }

    func testDeviceIdIsStable() {
        XCTAssertEqual(DeviceIdentity.id, DeviceIdentity.id)
        XCTAssertFalse(DeviceIdentity.model.isEmpty)
    }
}
