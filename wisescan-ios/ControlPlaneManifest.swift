import Foundation
import SwiftData

// MARK: - Control plane sync manifest (scan4d-server README, "Sync")

/// This device's whole local inventory, as the control plane's sync takes it: every space (a
/// "map") with its base and tip, every scan, every stitch link. Sent whole on every sync, so a
/// missed or failed one heals on the next and neither side tracks changes.
///
/// Metadata: names, times, IDs, poses, the focus box, and which map-package files each scan has
/// (the files themselves go up separately, when the server asks; `ControlPlaneSync`). No images.
nonisolated struct ControlPlaneManifest: Encodable, Sendable {
    var version = 1
    var device: Device
    var generatedAt: Date
    var locations: [Location]
    var links: [Link]

    nonisolated struct Device: Encodable, Sendable {
        var deviceId: UUID
        var label: String
        var model: String
        var systemVersion: String
        var appVersion: String
        var appBuild: String
        var lidar: Bool
    }

    nonisolated struct Location: Encodable, Sendable {
        var locationId: UUID
        var name: String
        var updatedAt: Date
        /// The first room scan: its frame is the space's canonical frame, and every rescan
        /// registers against its RoomPlan.
        var baseScanId: UUID?
        /// The newest room scan: a rescan or focus scan relocalizes against its world map.
        var tipScanId: UUID?
        var scans: [Scan]
    }

    nonisolated struct Scan: Encodable, Sendable {
        var scanId: UUID
        var kind: String              // "room" | "focus"
        var name: String
        var capturedAt: Date
        var parentScanId: UUID?
        var captureSource: String
        var hasWorldMap = false       // read from disk off main (`readScanFiles`)
        var worldMapSuspect: Bool
        var stillCount: Int
        var registration: Registration?  // read from disk off main (`readScanFiles`)
        var focusRegion: FocusRegion?
        var upload: Upload
        var files: [PackageFile] = []    // read from disk off main (`readScanFiles`)
    }

    /// A map-package file this scan has (scan4d-server README, "Map packages"). The server
    /// answers with the ones it wants; size and time tell it which version it holds.
    nonisolated struct PackageFile: Encodable, Sendable {
        var name: String
        var size: Int64
        var modifiedAt: Date
    }

    /// A package file on disk, for the upload the server asks for.
    nonisolated struct LocalFile: Sendable {
        var url: URL
        var size: Int64
        var modifiedAt: Date
    }

    /// The scan's `registration.json` (`SaveRegistration.Sidecar`), the fields the server keeps:
    /// raw capture frame to the space's canonical frame. Decoded with the sidecar's own keys,
    /// encoded snake_case like the rest of the manifest.
    nonisolated struct Registration: Codable, Sendable {
        var applied: Bool
        var transform: [Float]?       // column-major; present iff applied
        var targetScanId: String?     // the space's base scan
    }

    nonisolated struct Upload: Encodable, Sendable {
        var status: String
        var lastUploadedAt: Date?
        var format: String
    }

    nonisolated struct Link: Encodable, Sendable {
        var linkId: UUID
        var scanAId: UUID?
        var scanBId: UUID?
        var locationAId: UUID?
        var locationBId: UUID?
        var anchorA: [Float]
        var anchorB: [Float]
        var anchorAId: UUID
        var anchorBId: UUID
        var anchorAHeading: Double?
        var anchorBHeading: Double?
        var sourceIsA: Bool
        var manual: Manual
        // The control plane revision `manual` was last synced to; the server resolves edits on it.
        var manualRevision: Int
        // What this device renders for the join: `manual`, or the solver's auto fix on an untuned one.
        var effectiveNudge: Manual
        var linkType: String
        var linkedAt: Date
    }

    /// The user's fine-tune of a join (`StitchLink.manualYawDeg` / `manualDX`...).
    nonisolated struct Manual: Encodable, Sendable {
        var yawDeg: Double
        var dx: Double
        var dy: Double
        var dz: Double
    }

    /// Where a scan's files are, captured on main with the snapshot. `package`: each map-package
    /// file's name and where to look for it, first match wins.
    nonisolated struct ScanFiles: Sendable {
        var directory: URL
        var worldMap: URL
        var package: [(name: String, candidates: [URL])]
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Fills the file-backed fields. File I/O, so off main. With `packages`, lists each scan's
    /// map-package files and returns where they are, for the uploads the server then asks for.
    @discardableResult
    mutating func readScanFiles(_ files: [UUID: ScanFiles], packages: Bool) -> [UUID: [String: LocalFile]] {
        let fm = FileManager.default
        var local: [UUID: [String: LocalFile]] = [:]
        for l in locations.indices {
            for s in locations[l].scans.indices {
                let scanId = locations[l].scans[s].scanId
                guard let paths = files[scanId] else { continue }
                locations[l].scans[s].hasWorldMap = fm.fileExists(atPath: paths.worldMap.path)
                locations[l].scans[s].registration = Self.readRegistration(scanDirectory: paths.directory)
                guard packages else { continue }
                for (name, candidates) in paths.package {
                    guard let found = candidates.lazy.compactMap(Self.localFile).first else { continue }
                    locations[l].scans[s].files.append(PackageFile(name: name, size: found.size,
                                                                   modifiedAt: found.modifiedAt))
                    local[scanId, default: [:]][name] = found
                }
            }
        }
        return local
    }

    /// Size and modification time, whole seconds: the manifest's ISO 8601 carries no fraction,
    /// and the server compares the time it was told at upload with the next sync's.
    static func localFile(_ url: URL) -> LocalFile? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return LocalFile(url: url, size: size, modifiedAt: Date(timeIntervalSince1970: modified.timeIntervalSince1970.rounded(.down)))
    }

    /// The scan's registration sidecar, where `SaveRegistration.loadSidecar` looks for it (top
    /// level first, then raw_data/). Read here rather than through it because that type is
    /// main-actor isolated and this runs off main.
    static func readRegistration(scanDirectory: URL) -> Registration? {
        let name = "registration.json"
        for url in [scanDirectory.appendingPathComponent(name),
                    scanDirectory.appendingPathComponent("raw_data").appendingPathComponent(name)] {
            if let data = try? Data(contentsOf: url),
               let registration = try? JSONDecoder().decode(Registration.self, from: data) {
                return registration
            }
        }
        return nil
    }
}

// MARK: - Taking the snapshot

extension ControlPlaneManifest {
    /// Reads the SwiftData side on main. The file-backed fields (world map present, registration)
    /// stay empty until `readScanFiles` fills them off main.
    @MainActor
    static func snapshot(locations: [ScanLocation], links: [StitchLink], device: Device,
                         now: Date = Date()) -> (manifest: ControlPlaneManifest, files: [UUID: ScanFiles]) {
        var files: [UUID: ScanFiles] = [:]
        let entries = locations.map { location -> Location in
            let base = location.roomScans.min(by: CapturedScan.canonicalOrder)
            let scans = location.scans.sorted(by: CapturedScan.canonicalOrder).map { scan -> Scan in
                files[scan.id] = ScanFiles(directory: scan.scanDirectory, worldMap: scan.worldMapURL,
                                           package: packageCandidates(scan))
                return Scan(scanId: scan.id,
                            kind: scan.isFocusScan ? "focus" : "room",
                            name: scan.name,
                            capturedAt: scan.capturedAt,
                            parentScanId: scan.parentScanId,
                            captureSource: scan.hardwareDeviceModel,
                            worldMapSuspect: scan.worldMapSuspect,
                            stillCount: scan.stillCount,
                            focusRegion: scan.isFocusScan ? scan.focusRegion : nil,
                            upload: Upload(status: uploadStatusName(scan.uploadStatus),
                                           lastUploadedAt: scan.lastUploadedAt,
                                           format: scan.selectedFormat.rawValue))
            }
            return Location(locationId: location.id, name: location.name, updatedAt: location.updatedAt,
                            baseScanId: base?.id, tipScanId: location.latestRoomScan?.id, scans: scans)
        }
        let linkEntries = links.map { link in
            Link(linkId: link.id,
                 scanAId: link.endpointAScan?.id,
                 scanBId: link.endpointBScan?.id,
                 locationAId: link.endpointAScan?.location?.id,
                 locationBId: link.endpointBScan?.location?.id,
                 anchorA: link.anchorAMatrix,
                 anchorB: link.anchorBMatrix,
                 anchorAId: link.anchorAId,
                 anchorBId: link.anchorBId,
                 anchorAHeading: link.anchorACompassHeading,
                 anchorBHeading: link.anchorBCompassHeading,
                 sourceIsA: link.sourceIsA,
                 manual: Manual(yawDeg: link.manualYawDeg, dx: link.manualDX, dy: link.manualDY, dz: link.manualDZ),
                 manualRevision: link.manualRevision,
                 effectiveNudge: effectiveNudge(link),
                 linkType: link.linkTypeStr,
                 linkedAt: link.linkedAt)
        }
        let manifest = ControlPlaneManifest(device: device, generatedAt: now,
                                            locations: entries, links: linkEntries)
        return (manifest, files)
    }

    /// The join as the app draws it (`StitchGraphModel.effectiveNudge`): the fine-tune, or the
    /// solver's auto fix when "always autocorrect" seeds an untuned join. The solve reads two RoomPlan
    /// files, so it runs once per link per launch.
    @MainActor
    static func effectiveNudge(_ link: StitchLink) -> Manual {
        let manual = link.manualNudge
        if !manual.isZero { return asManual(manual) }
        if let cached = autoNudgeCache[link.id] { return cached }
        let auto = asManual(StitchGraphModel.effectiveNudge(for: link))
        autoNudgeCache[link.id] = auto
        return auto
    }

    @MainActor private static var autoNudgeCache: [UUID: Manual] = [:]

    @MainActor
    static func asManual(_ nudge: ManualNudge) -> Manual {
        Manual(yawDeg: Double(nudge.yawDeg), dx: Double(nudge.dx), dy: Double(nudge.dy), dz: Double(nudge.dz))
    }

    /// A scan's map-package files (scan4d-server README, "Map packages"), smallest first. Room
    /// scans: the registration and room layout (top level, else raw_data/ like the export), the
    /// relocalization map, the mesh. Focus scans: the region.
    @MainActor
    static func packageCandidates(_ scan: CapturedScan) -> [(name: String, candidates: [URL])] {
        let dir = scan.scanDirectory
        let raw = dir.appendingPathComponent("raw_data")
        if scan.isFocusScan {
            return [(AppConstants.focusRegionFilename, [scan.focusRegionFileURL])]
        }
        return [
            ("registration.json", [dir.appendingPathComponent("registration.json"),
                                   raw.appendingPathComponent("registration.json")]),
            ("roomplan.json", [scan.roomPlanFileURL, raw.appendingPathComponent("roomplan.json")]),
            ("arworldmap.map", [scan.worldMapURL]),
            ("mesh.obj", [scan.meshFileURL]),
            // What the change evaluator joins on id, and (once recorded) where the sweep looked.
            (FeaturePointCloudFile.filename, [dir.appendingPathComponent(FeaturePointCloudFile.filename)]),
            ("sweep_coverage.bin", [dir.appendingPathComponent("sweep_coverage.bin")])
        ]
    }

    /// The stored status without its failure message: what the fleet view sorts on.
    @MainActor
    static func uploadStatusName(_ status: UploadStatus) -> String {
        switch status {
        case .pending: return "pending"
        case .zipping: return "zipping"
        case .uploading: return "uploading"
        case .savedLocally: return "saved_locally"
        case .success: return "success"
        case .failed: return "failed"
        }
    }
}
