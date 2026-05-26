import Foundation
import simd

// MARK: - Stitching Metadata

/// Per-location manifest that describes spatial links between this location and others.
/// Written to `Documents/Scans/{locationId}/stitching.json`.
/// Bundled into the scan4d export staging directory so every
/// uploaded zip is self-contained.
struct StitchingManifest: Codable, Sendable {
    var version: Int = 1
    var layout: String = "row_major"
    var links: [StitchingLink]

    init(links: [StitchingLink] = []) {
        self.links = links
    }
}

/// A single spatial link between two scans in different locations.
/// The "source" is the original scan where Pin A was dropped.
/// The "target" is the new scan (in this location) where Pin B was dropped.
struct StitchingLink: Codable, Identifiable, Sendable {
    var id: UUID = UUID()

    // Source (the original scan/location that was extended FROM)
    let sourceLocationId: UUID
    let sourceScanId: UUID
    let sourceAnchorId: UUID
    let sourceAnchorTransform: CodableMatrix4x4
    let sourceAnchorCompassHeading: Double?

    // Target (the new scan in THIS location)
    let targetLocationId: UUID?
    let targetScanId: UUID
    let targetAnchorId: UUID
    let targetAnchorTransform: CodableMatrix4x4
    let targetAnchorCompassHeading: Double?

    // Metadata
    let linkedAt: Date
    let linkType: LinkType

    enum LinkType: String, Codable, Sendable {
        case midSession = "mid_session"
        case crossSession = "cross_session"
    }
}

// MARK: - Codable 4x4 Matrix

/// Wraps `simd_float4x4` for JSON serialization as a 4×4 array of floats.
struct CodableMatrix4x4: Codable, Sendable {
    let matrix: simd_float4x4

    init(_ matrix: simd_float4x4) {
        self.matrix = matrix
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var rows: [[Float]] = []
        for _ in 0..<4 {
            var rowContainer = try container.nestedUnkeyedContainer()
            var row: [Float] = []
            for _ in 0..<4 {
                row.append(try rowContainer.decode(Float.self))
            }
            rows.append(row)
        }
        // Column-major: rows[row][col] → columns[col][row]
        self.matrix = simd_float4x4(columns: (
            SIMD4<Float>(rows[0][0], rows[1][0], rows[2][0], rows[3][0]),
            SIMD4<Float>(rows[0][1], rows[1][1], rows[2][1], rows[3][1]),
            SIMD4<Float>(rows[0][2], rows[1][2], rows[2][2], rows[3][2]),
            SIMD4<Float>(rows[0][3], rows[1][3], rows[2][3], rows[3][3])
        ))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        let m = matrix
        // Row-major 4×4 array: each inner array is one ROW of the matrix.
        // NOTE: This differs from transforms.json / scan4d_metadata.json which use
        // column-major (each inner array = one column). The decoder above handles
        // the transpose correctly. If standardizing later, a migration is needed.
        for row in 0..<4 {
            var rowContainer = container.nestedUnkeyedContainer()
            try rowContainer.encode(m.columns.0[row])
            try rowContainer.encode(m.columns.1[row])
            try rowContainer.encode(m.columns.2[row])
            try rowContainer.encode(m.columns.3[row])
        }
    }
}

// MARK: - Read / Write Helpers

enum StitchingMetadataManager {
    /// Filename used within location directories and scan export bundles.
    static let filename = "stitching.json"

    /// Dedicated serial queue for stitching file I/O — avoids blocking the main thread
    /// during writes while preventing concurrent read/write races.
    private static let ioQueue = DispatchQueue(label: "com.wisescan.stitchingIO", qos: .utility)

    /// Returns the `stitching.json` URL for a given location directory.
    static func url(forLocationDir locationDir: URL) -> URL {
        locationDir.appendingPathComponent(filename)
    }

    /// Returns the location directory for a given location ID.
    /// Path: `Documents/Scans/{locationId}/`
    static func locationDirectory(for locationId: UUID) -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return docs.appendingPathComponent("Scans").appendingPathComponent(locationId.uuidString)
    }

    /// Reads the stitching manifest for a location, returning nil if it doesn't exist.
    /// Synchronous — acceptable for small JSON files. Prefer `readAsync` from SwiftUI `.task` modifiers.
    static func read(locationId: UUID) -> StitchingManifest? {
        guard let locDir = locationDirectory(for: locationId) else { return nil }
        let fileURL = url(forLocationDir: locDir)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StitchingManifest.self, from: data)
    }

    /// Async version of `read` for use in SwiftUI `.task` modifiers.
    /// Dispatches to the serial I/O queue to avoid blocking the main thread.
    static func readAsync(locationId: UUID) async -> StitchingManifest? {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: read(locationId: locationId))
            }
        }
    }

    /// Internal write routine — MUST be called from `ioQueue`.
    /// Encodes the manifest and writes it atomically to disk.
    private static func writeInternal(_ manifest: StitchingManifest, locationId: UUID) -> Bool {
        guard let locDir = locationDirectory(for: locationId) else { return false }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manifest) else { return false }

        try? FileManager.default.createDirectory(at: locDir, withIntermediateDirectories: true)
        let fileURL = url(forLocationDir: locDir)
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            print("[StitchingMetadata] Failed to write stitching.json: \(error)")
            return false
        }
    }

    /// Writes a stitching manifest to a location's directory on the serial I/O queue.
    /// Creates the directory if needed. Calls the optional completion on the main queue.
    static func write(_ manifest: StitchingManifest, locationId: UUID, completion: ((Bool) -> Void)? = nil) {
        ioQueue.async {
            let success = writeInternal(manifest, locationId: locationId)
            if let completion = completion {
                DispatchQueue.main.async { completion(success) }
            }
        }
    }

    /// Appends a link to an existing manifest (or creates a new one).
    /// The entire read-modify-write cycle runs on the serial I/O queue to prevent
    /// concurrent access races when multiple links are added in quick succession.
    static func addLink(_ link: StitchingLink, locationId: UUID, completion: ((Bool) -> Void)? = nil) {
        ioQueue.async {
            var manifest = read(locationId: locationId) ?? StitchingManifest()
            manifest.links.append(link)

            let success = writeInternal(manifest, locationId: locationId)
            if let completion = completion {
                DispatchQueue.main.async { completion(success) }
            }
        }
    }

    /// Checks whether a location has any stitching links.
    /// Synchronous — reads a small JSON file. Prefer `hasLinksAsync` from SwiftUI `.task` modifiers.
    static func hasLinks(locationId: UUID) -> Bool {
        guard let manifest = read(locationId: locationId) else { return false }
        return !manifest.links.isEmpty
    }

    /// Async version of `hasLinks` for use in SwiftUI `.task` modifiers.
    static func hasLinksAsync(locationId: UUID) async -> Bool {
        guard let manifest = await readAsync(locationId: locationId) else { return false }
        return !manifest.links.isEmpty
    }

}
