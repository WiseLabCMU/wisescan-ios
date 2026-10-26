import Foundation
import SwiftData
import simd
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
                          sourceIsA: true, manual: .init(yawDeg: 1, dx: 0, dy: 0, dz: 0), manualRevision: 3,
                          effectiveNudge: .init(yawDeg: 1, dx: 0, dy: 0, dz: 0),
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
                    "source_is_a", "link_type", "linked_at", "effective_nudge"] {
            XCTAssertNotNil(link[key], key)
        }
        XCTAssertEqual((link["manual"] as? [String: Any])?["yaw_deg"] as? Double, 1)
        XCTAssertEqual(link["manual_revision"] as? Int, 3)
    }

    /// A sync response as scan4d-server sends it: fine-tunes to apply, the upload route, and a
    /// task whose region is a focus_region.json (decoded with its own keys).
    func testSyncReplyCarriesUpdatesUploadsAndTasks() throws {
        let task = UUID(), map = UUID(), link = UUID()
        let body = """
        {"server_time": "2026-10-25T08:00:00Z", "device_id": "\(UUID().uuidString.lowercased())",
         "maps": 2, "scans": 4, "links": 1, "marked_gone": 0, "wanted": [],
         "link_updates": [{"link_id": "\(link.uuidString.lowercased())", "revision": 2,
                           "manual": {"yaw_deg": 2.0, "dx": 0.05, "dy": 0.0, "dz": -0.02}}],
         "upload_target": {"available": true, "revoked": false, "bucket": "scan4d"},
         "tasks": [{"task_id": "\(task.uuidString.lowercased())", "map_id": "\(map.uuidString.lowercased())",
                    "map_name": "Lab 2F", "reason": "change near the window", "status": "delivered", "priority": "high",
                    "created_at": "2026-10-25T08:00:00Z",
                    "region": {"version": 1, "location_id": "\(map.uuidString.lowercased())",
                               "center_m": [1.2, 0.45, -2.3], "yaw_rad": 0.0, "size_m": [1.0, 0.9, 1.2],
                               "label": "change: 207 new", "source": "import", "detail_level": "detail",
                               "frame_is_canonical": true, "task_id": "\(task.uuidString.lowercased())"}}]}
        """
        let data = Data(body.utf8)
        let reply = try ControlPlaneClient.decode(ControlPlaneClient.SyncReply.self, from: data)
        XCTAssertEqual(reply.linkUpdates?.first?.revision, 2)
        XCTAssertEqual(reply.linkUpdates?.first?.manual.dz, -0.02)
        XCTAssertEqual(UUID(uuidString: reply.linkUpdates?.first?.linkId ?? ""), link)
        XCTAssertEqual(reply.uploadTarget, .init(available: true, revoked: false, bucket: "scan4d"))

        let tasks = ControlPlaneClient.tasks(from: data)
        XCTAssertEqual(tasks.count, 1)
        let region = try XCTUnwrap(tasks.first?.region)
        XCTAssertEqual(tasks.first?.id, task)
        XCTAssertEqual(region.taskId, task)
        XCTAssertEqual(region.locationId, map)
        XCTAssertEqual(region.detail, .detail)
        XCTAssertEqual(region.size.z, 1.2, accuracy: 1e-6)
        XCTAssertEqual(tasks.first?.isUrgent, true)
    }

    /// The task id rides the region through save and sync: that is how the server learns the
    /// focus scan answered it.
    func testFocusRegionKeepsItsTaskId() throws {
        let task = UUID()
        let region = FocusRegion(center: SIMD3(0, 0.5, 0), size: SIMD3(1, 1, 1), taskId: task)
        let data = try XCTUnwrap(region.encoded())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["task_id"] as? String, task.uuidString)
        XCTAssertEqual(FocusRegion.decode(data)?.taskId, task)
        let plain = FocusRegion(center: .zero, size: SIMD3(1, 1, 1))
        XCTAssertNil(FocusRegion.decode(try XCTUnwrap(plain.encoded()))?.taskId)
    }

    /// Partial packages: the server says why it wants a file; a large one held back on a metered
    /// network is "waiting", not a failure.
    func testWantedReasonAndTheWiFiWait() throws {
        let body = #"{"maps": 1, "scans": 1, "links": 0, "marked_gone": 0, "wanted": [{"scan_id": "x", "name": "mesh.obj", "size": 41000000, "reason": "requested: web 3D view"}]}"#
        let reply = try ControlPlaneClient.decode(ControlPlaneClient.SyncReply.self, from: Data(body.utf8))
        XCTAssertEqual(reply.wanted?.first?.reason, "requested: web 3D view")
        XCTAssertGreaterThanOrEqual(reply.wanted?.first?.size ?? 0, AppConstants.controlPlaneLargeFileBytes)

        let cellular = URLError(.notConnectedToInternet, userInfo: [
            NSURLErrorNetworkUnavailableReasonKey: URLError.NetworkUnavailableReason.expensive.rawValue])
        XCTAssertEqual(ControlPlaneClient.failure(for: cellular, host: "h"), .waitingForUnmeteredNetwork)
        XCTAssertEqual(ControlPlaneClient.failure(for: URLError(.notConnectedToInternet), host: "h"), .unreachable("h"))
    }

    func testManualUploadURLIsThePlainPut() throws {
        let target = try XCTUnwrap(ExportUploadTarget.manual("https://wiselambda4.lan.cmu.edu/wisescan-uploads",
                                                              filename: "a.zip", contentType: "application/zip"))
        XCTAssertEqual(target.request.url?.absoluteString, "https://wiselambda4.lan.cmu.edu/wisescan-uploads/a.zip")
        XCTAssertEqual(target.request.httpMethod, "PUT")
        XCTAssertEqual(target.request.value(forHTTPHeaderField: "Content-Type"), "application/zip")
        XCTAssertNil(ExportUploadTarget.manual("  ", filename: "a.zip", contentType: "application/zip"))
        XCTAssertTrue(ExportUploadTarget.isConfigured(manualURL: "", controlPlaneHost: "192.168.1.40:8000"))
        XCTAssertFalse(ExportUploadTarget.isConfigured(manualURL: "", controlPlaneHost: ""))
    }

    /// Without a working control plane an export goes where it did before one existed.
    func testDeadControlPlaneFallsBackToTheUploadURL() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: AppConstants.Key.controlPlaneHost)
        defer { defaults.set(saved, forKey: AppConstants.Key.controlPlaneHost) }
        defaults.set("127.0.0.1:9", forKey: AppConstants.Key.controlPlaneHost)   // nothing listens: refused at once
        let target = try await ExportUploadTarget.resolve(
            scanId: UUID(), filename: "a.zip", contentType: "application/zip", format: .scan4d,
            manualURL: "https://wiselambda4.lan.cmu.edu/wisescan-uploads/")
        XCTAssertEqual(target.request.url?.absoluteString, "https://wiselambda4.lan.cmu.edu/wisescan-uploads/a.zip")
        XCTAssertNil(target.exportId)
        // With no Upload URL there is nothing to fall back to: the control plane's reason surfaces.
        do {
            _ = try await ExportUploadTarget.resolve(scanId: UUID(), filename: "a.zip", contentType: "application/zip",
                                                     format: .scan4d, manualURL: "")
            XCTFail("expected the control plane's error")
        } catch {
            XCTAssertNotNil(error as? ControlPlaneClient.Failure, "\(error)")
        }
    }

    /// The certificate override is scoped to hosts the control plane named.
    func testTrustIsOnlyForNamedHosts() {
        ControlPlaneSession.allow(host: "Versity.LAN.cmu.edu")
        XCTAssertTrue(ControlPlaneSession.isAllowed(host: "versity.lan.cmu.edu"))
        XCTAssertFalse(ControlPlaneSession.isAllowed(host: "example.com"))
        _ = ControlPlaneClient(baseURL: URL(string: "https://scan4d.lan.cmu.edu:8443")!)
        XCTAssertTrue(ControlPlaneSession.isAllowed(host: "scan4d.lan.cmu.edu"))
    }

    // MARK: - Stitch math, against scan4d-server's reference vectors (api/tests/stitch.vectors.json)

    private func matrix(_ values: [Float]) -> simd_float4x4 {
        simd_float4x4(SIMD4(values[0], values[1], values[2], values[3]), SIMD4(values[4], values[5], values[6], values[7]),
                      SIMD4(values[8], values[9], values[10], values[11]), SIMD4(values[12], values[13], values[14], values[15]))
    }

    private func assertClose(_ a: simd_float4x4, _ b: simd_float4x4, file: StaticString = #filePath, line: UInt = #line) {
        for col in 0..<4 {
            XCTAssertLessThan(simd_length(a[col] - b[col]), 1e-5, "column \(col)", file: file, line: line)
        }
    }

    /// The web composes joins with a port of this math; both are checked against one reference.
    func testNudgeMatrixMatchesTheServerReference() {
        let nudge = ManualNudge(yawDeg: 12, dx: 0.2, dy: 0, dz: -0.1)
        let expected = matrix([0.978147600734, 0, -0.207911690818, 0, 0, 1, 0, 0,
                               0.207911690818, 0, 0.978147600734, 0, 0.637675780902, 0, 0.064206892285, 1])
        assertClose(nudge.matrix(pivot: SIMD3(1, 0.5, -2)), expected)
    }

    /// `StitchGraphModel.placeScans`' edge: (T_src . A_src) . inverse(T_tgt . A_tgt), the nudge
    /// applied about the source pin.
    func testCorrectedEdgeMatchesTheServerReference() {
        let tSrc = matrix([0.999390827019, 0, -0.034899496703, 0, 0, 1, 0, 0, 0.034899496703, 0, 0.999390827019, 0, 0.03, 0, 0.01, 1])
        let aSrc = matrix([0.984807753012, 0, -0.173648177667, 0, 0, 1, 0, 0, 0.173648177667, 0, 0.984807753012, 0, 1, 0, 2, 1])
        let tTgt = matrix([0.998629534755, 0, 0.052335956243, 0, 0, 1, 0, 0, -0.052335956243, 0, 0.998629534755, 0, 0, 0.02, 0.1, 1])
        let aTgt = matrix([-0.087155742748, 0, -0.996194698092, 0, 0, 1, 0, 0, 0.996194698092, 0, -0.087155742748, 0, -0.5, 0, 0.3, 1])
        let expected = matrix([0.300705799504, 0, 0.953716950748, 0, 0, 1, 0, 0,
                               -0.953716950748, 0, 0.300705799504, 0, 1.66019580964, -0.04, 2.452771396358, 1])
        let mSrc = tSrc * aSrc
        let r = mSrc * simd_inverse(tTgt * aTgt)
        let pin = mSrc.columns.3
        let edge = ManualNudge(yawDeg: 7.5, dx: 0.05, dy: -0.02, dz: 0.1).matrix(pivot: SIMD3(pin.x, pin.y, pin.z)) * r
        assertClose(edge, expected)
        // The flattening the manifest uses is the same column-major layout.
        XCTAssertEqual(StitchLink.flatten(expected)[12], Float(1.66019580964), accuracy: 1e-6)
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
