import SwiftUI
import Observation

// MARK: - Captured Scan Model

struct CapturedScan: Identifiable {
    let id = UUID()
    let name: String
    let capturedAt: Date
    let meshData: Data
    let vertexCount: Int
    let faceCount: Int
    var rawDataPath: URL? = nil
    var vertexColors: Data? = nil
    var worldMapURL: URL? = nil // Support for Scan4D anchoring
    var locationId: UUID? = nil
    var selectedFormat: ExportFormat = .obj
    var uploadStatus: UploadStatus = .pending

    var estimatedSizeMB: Double {
        Double(meshData.count) / (1024.0 * 1024.0)
    }

    var timeSinceCapture: String {
        let interval = Date().timeIntervalSince(capturedAt)
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }
}

enum ExportFormat: String, CaseIterable {
    case obj = "OBJ"
    case ply = "PLY"
    case usdz = "USDZ"
    case raw = "RAW"
    case polycam = "PLYCM"
}

enum UploadStatus: Equatable {
    case pending
    case uploading
    case success
    case failed(String)

    var label: String {
        switch self {
        case .pending: return "Ready"
        case .uploading: return "Uploading..."
        case .success: return "Uploaded"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }
}

// MARK: - Scan Hierarchy Model

struct ScanLocation: Identifiable {
    let id = UUID()
    var name: String
    var scans: [CapturedScan] = []
}

// MARK: - Scan Store (shared across views)

@Observable
class ScanStore {
    var locations: [ScanLocation] = []
    private var scanCounter = 0

    // Scan4D state for initiating a new scan of an existing location
    var activeRelocalizationMap: URL? = nil
    var activeLocationForScan: UUID? = nil

    func addLocation(name: String) -> ScanLocation {
        let location = ScanLocation(name: name)
        locations.insert(location, at: 0)
        return location
    }

    func addScan(meshData: Data, vertexCount: Int, faceCount: Int, rawDataPath: URL? = nil, vertexColors: Data? = nil, worldMapURL: URL? = nil, locationId: UUID? = nil) -> CapturedScan {
        scanCounter += 1

        // If no locations exist yet, create a default one
        if locations.isEmpty {
            let _ = addLocation(name: "Default Location")
        }

        let targetLocationId = locationId ?? locations[0].id

        let scan = CapturedScan(
            name: "Scan \(scanCounter)",
            capturedAt: Date(),
            meshData: meshData,
            vertexCount: vertexCount,
            faceCount: faceCount,
            rawDataPath: rawDataPath,
            vertexColors: vertexColors,
            worldMapURL: worldMapURL,
            locationId: targetLocationId
        )

        if let idx = locations.firstIndex(where: { $0.id == targetLocationId }) {
            locations[idx].scans.insert(scan, at: 0) // newest first
        }

        return scan
    }

    func updateScan(_ updatedScan: CapturedScan) {
        guard let locId = updatedScan.locationId,
              let lIdx = locations.firstIndex(where: { $0.id == locId }),
              let sIdx = locations[lIdx].scans.firstIndex(where: { $0.id == updatedScan.id }) else {
            return
        }
        locations[lIdx].scans[sIdx] = updatedScan
    }
}

// MARK: - Live Scan Stats (updated by ARCoverageView)

@Observable
class ScanStats {
    var totalVertices: Int = 0
    var totalFaces: Int = 0
    var averageQuality: Double = 0.0 // 0.0 to 1.0

    var estimatedSizeMB: Double {
        // Each vertex ~12 bytes (3 floats), each face ~12 bytes (3 uint32)
        let bytes = (totalVertices * 12) + (totalFaces * 12)
        return Double(bytes) / (1024.0 * 1024.0)
    }

    var formattedSize: String {
        if estimatedSizeMB < 1.0 {
            return String(format: "%.0f KB", estimatedSizeMB * 1024)
        }
        return String(format: "%.1f MB", estimatedSizeMB)
    }

    var formattedPolygons: String {
        if totalFaces >= 1_000_000 {
            return String(format: "%.1fM", Double(totalFaces) / 1_000_000.0)
        } else if totalFaces >= 1_000 {
            return String(format: "%.0fK", Double(totalFaces) / 1_000.0)
        }
        return "\(totalFaces)"
    }

    var qualityPercent: Int {
        Int(averageQuality * 100)
    }
}
