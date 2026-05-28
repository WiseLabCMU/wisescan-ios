import Foundation
import simd

// MARK: - Stitching Metadata

/// Per-location manifest that describes spatial links between this location and others.
/// Written to `Documents/Scans/{locationId}/stitching.json`.
/// Bundled into the scan4d export staging directory so every
/// uploaded zip is self-contained.
struct StitchingManifest: Codable, Sendable {
    var version: Int = 1
    var layout: MatrixLayout = .columnMajor
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
    let targetLocationId: UUID
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

/// Matrix layout convention for serialized 4×4 transforms.
enum MatrixLayout: String, Codable, Sendable {
    case columnMajor = "column_major"
    case rowMajor = "row_major"
}

// MARK: - Codable 4x4 Matrix

/// Wraps `simd_float4x4` for JSON serialization as a 4×4 array of floats.
///
/// Uses **column-major** layout: each inner array is one column of the matrix.
/// This matches the convention used by `transforms.json` and `scan4d_metadata.json`
/// so all matrix formats within a single export zip are consistent.
struct CodableMatrix4x4: Codable, Sendable {
    let matrix: simd_float4x4

    init(_ matrix: simd_float4x4) {
        self.matrix = matrix
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        // Column-major: each inner array is one column.
        // cols[col][row] → columns[col] = SIMD4(row0, row1, row2, row3)
        var cols: [SIMD4<Float>] = []
        for _ in 0..<4 {
            var colContainer = try container.nestedUnkeyedContainer()
            var elements: [Float] = []
            for _ in 0..<4 {
                elements.append(try colContainer.decode(Float.self))
            }
            cols.append(SIMD4<Float>(elements[0], elements[1], elements[2], elements[3]))
        }
        self.matrix = simd_float4x4(columns: (cols[0], cols[1], cols[2], cols[3]))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        // Column-major: each inner array is one COLUMN of the matrix.
        // Matches transforms.json / scan4d_metadata.json convention.
        let cols = [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
        for col in cols {
            var colContainer = container.nestedUnkeyedContainer()
            try colContainer.encode(col.x)
            try colContainer.encode(col.y)
            try colContainer.encode(col.z)
            try colContainer.encode(col.w)
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
    /// Private — external callers should use `readAsync` to avoid blocking the main thread.
    private static func read(locationId: UUID) -> StitchingManifest? {
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
    /// Private — external callers should use `hasLinksAsync` to avoid blocking the main thread.
    private static func hasLinks(locationId: UUID) -> Bool {
        guard let manifest = read(locationId: locationId) else { return false }
        return !manifest.links.isEmpty
    }

    /// Async version of `hasLinks` for use in SwiftUI `.task` modifiers.
    static func hasLinksAsync(locationId: UUID) async -> Bool {
        guard let manifest = await readAsync(locationId: locationId) else { return false }
        return !manifest.links.isEmpty
    }

}
