import Foundation
import SwiftData

// MARK: - Control plane sync manifest (scan4d-server README, "Sync")

/// This device's whole local inventory, as the control plane's sync takes it: every space (a
/// "map") with its base and tip, every scan, every stitch link. Sent whole on every sync, so a
/// missed or failed one heals on the next and neither side tracks changes.
///
/// Metadata only: names, times, IDs, poses, the focus box. No images, meshes or world maps.
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

    /// Where a scan's files are, captured on main with the snapshot.
    nonisolated struct ScanFiles: Sendable {
        var directory: URL
        var worldMap: URL
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Fills the file-backed fields. File I/O, so off main.
    mutating func readScanFiles(_ files: [UUID: ScanFiles]) {
        let fm = FileManager.default
        for l in locations.indices {
            for s in locations[l].scans.indices {
                guard let paths = files[locations[l].scans[s].scanId] else { continue }
                locations[l].scans[s].hasWorldMap = fm.fileExists(atPath: paths.worldMap.path)
                locations[l].scans[s].registration = Self.readRegistration(scanDirectory: paths.directory)
            }
        }
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
                files[scan.id] = ScanFiles(directory: scan.scanDirectory, worldMap: scan.worldMapURL)
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
                 linkType: link.linkTypeStr,
                 linkedAt: link.linkedAt)
        }
        let manifest = ControlPlaneManifest(device: device, generatedAt: now,
                                            locations: entries, links: linkEntries)
        return (manifest, files)
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
