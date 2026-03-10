import SwiftUI
import Observation
import SwiftData

// MARK: - Captured Scan Model

@Model
class CapturedScan {
    var id: UUID
    var name: String
    var capturedAt: Date
    var vertexCount: Int
    var faceCount: Int
    var selectedFormatStr: String
    var uploadStatusStr: String
    var uploadProgress: Double

    @Relationship(inverse: \ScanLocation.scans)
    var location: ScanLocation?

    init(id: UUID = UUID(), name: String, capturedAt: Date = Date(), vertexCount: Int, faceCount: Int) {
        self.id = id
        self.name = name
        self.capturedAt = capturedAt
        self.vertexCount = vertexCount
        self.faceCount = faceCount
        self.selectedFormatStr = ExportFormat.polycam.rawValue
        self.uploadStatusStr = "pending"
        self.uploadProgress = 0.0
    }

    @Transient var selectedFormat: ExportFormat {
        get { ExportFormat(rawValue: selectedFormatStr) ?? .obj }
        set { selectedFormatStr = newValue.rawValue }
    }

    @Transient var uploadStatus: UploadStatus {
        get {
            if uploadStatusStr == "pending" { return .pending }
            if uploadStatusStr == "success" { return .success }
            if uploadStatusStr.starts(with: "failed:") {
                let msg = String(uploadStatusStr.dropFirst(7))
                return .failed(msg)
            }
            if uploadStatusStr == "uploading" {
                return .uploading(progress: uploadProgress)
            }
            return .pending
        }
        set {
            switch newValue {
            case .pending:
                uploadStatusStr = "pending"
                uploadProgress = 0.0
            case .success:
                uploadStatusStr = "success"
                uploadProgress = 1.0
            case .failed(let msg):
                uploadStatusStr = "failed:\(msg)"
                uploadProgress = 0.0
            case .uploading(let prog):
                uploadStatusStr = "uploading"
                uploadProgress = prog
            }
        }
    }

    // Configurable base Directory
    @Transient var scanDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let locId = location?.id.uuidString ?? "unknown_location"
        return docs.appendingPathComponent("Scans").appendingPathComponent(locId).appendingPathComponent(id.uuidString)
    }

    @Transient var meshFileURL: URL { scanDirectory.appendingPathComponent("mesh.obj") }
    @Transient var colorsFileURL: URL { scanDirectory.appendingPathComponent("colors.bin") }
    @Transient var worldMapURL: URL { scanDirectory.appendingPathComponent("arworldmap.map") }
    @Transient var rawDataPath: URL { scanDirectory.appendingPathComponent("raw_data") }

    @Transient var estimatedSizeMB: Double {
        // Compute dynamically by checking disk if needed, or fallback to an estimate
        var size: Int64 = 0
        if let attr = try? FileManager.default.attributesOfItem(atPath: meshFileURL.path) {
            size += attr[.size] as? Int64 ?? 0
        }
        if let attr = try? FileManager.default.attributesOfItem(atPath: colorsFileURL.path) {
            size += attr[.size] as? Int64 ?? 0
        }
        return size > 0 ? Double(size) / (1024.0 * 1024.0) : Double(vertexCount * 12 + faceCount * 12) / (1024.0 * 1024.0)
    }

    @Transient var timeSinceCapture: String {
        let interval = Date().timeIntervalSince(capturedAt)
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        return "\(Int(interval / 3600))h ago"
    }
}

enum ExportFormat: String, CaseIterable, Codable {
    case polycam = "PLYCM"
    case raw = "RAW"
    case usdz = "USDZ"
    case ply = "PLY"
    case obj = "OBJ"
}

enum UploadStatus: Equatable {
    case pending
    case uploading(progress: Double)
    case success
    case failed(String)

    var label: String {
        switch self {
        case .pending: return "Ready"
        case .uploading(let p): return "Uploading (\(Int(p * 100))%)..."
        case .success: return "Uploaded"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    var isUploading: Bool {
        if case .uploading = self { return true }
        return false
    }

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - Scan Hierarchy Model

@Model
class ScanLocation {
    var id: UUID
    var name: String
    var remoteLocationId: String?

    @Relationship(deleteRule: .cascade)
    var scans: [CapturedScan] = []

    init(id: UUID = UUID(), name: String, remoteLocationId: String? = nil) {
        self.id = id
        self.name = name
        self.remoteLocationId = remoteLocationId
    }
}

// MARK: - Scan Store (Runtime State for Capture)

@Observable
class ScanStore {
    // Scan4D state for initiating a new scan of an existing location
    var activeRelocalizationMap: URL? = nil
    var activeLocationForScan: UUID? = nil
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

// MARK: - Disk Persistence Manager

@MainActor
class ScanFileManager {
    static let shared = ScanFileManager()

    private init() {}

    func saveScan(
        context: ModelContext,
        locationId: UUID?,
        name: String,
        meshData: Data,
        vertexCount: Int,
        faceCount: Int,
        rawDataPath: URL?,
        vertexColors: Data?,
        worldMapURL: URL?
    ) -> CapturedScan {
        let targetLocation: ScanLocation

        if let locId = locationId {
            let descriptor = FetchDescriptor<ScanLocation>(predicate: #Predicate { $0.id == locId })
            if let existing = try? context.fetch(descriptor).first {
                targetLocation = existing
            } else {
                targetLocation = ScanLocation(name: "Default Location")
                context.insert(targetLocation)
            }
        } else {
            let descriptor = FetchDescriptor<ScanLocation>()
            if let allLocs = try? context.fetch(descriptor), let first = allLocs.first {
                targetLocation = first
            } else {
                targetLocation = ScanLocation(name: "Default Location")
                context.insert(targetLocation)
            }
        }

        let newScan = CapturedScan(
            name: name,
            vertexCount: vertexCount,
            faceCount: faceCount
        )

        targetLocation.scans.append(newScan)
        newScan.location = targetLocation
        context.insert(newScan)

        do {
            try FileManager.default.createDirectory(at: newScan.scanDirectory, withIntermediateDirectories: true)
            try meshData.write(to: newScan.meshFileURL)
            if let colors = vertexColors { try colors.write(to: newScan.colorsFileURL) }
            if let map = worldMapURL { try FileManager.default.copyItem(at: map, to: newScan.worldMapURL) }

            if let raw = rawDataPath, FileManager.default.fileExists(atPath: raw.path) {
                // Remove existing if any, then move
                try? FileManager.default.removeItem(at: newScan.rawDataPath)
                try FileManager.default.moveItem(at: raw, to: newScan.rawDataPath)
            }
        } catch {
            print("Failed to save scan files to disk: \(error)")
        }

        enforceRetentionPolicy(location: targetLocation, context: context)
        try? context.save()

        return newScan
    }

    func enforceRetentionPolicy(location: ScanLocation, context: ModelContext) {
        // Keep Last 2 Rule
        let sortedScans = location.scans.sorted { $0.capturedAt > $1.capturedAt }
        guard sortedScans.count > 2 else { return }

        let toDelete = sortedScans.dropFirst(2)
        for scan in toDelete {
            deleteScan(scan, context: context)
        }
    }

    func deleteScan(_ scan: CapturedScan, context: ModelContext) {
        try? FileManager.default.removeItem(at: scan.scanDirectory)
        context.delete(scan)
        try? context.save()
    }

    func addLocation(name: String, context: ModelContext) -> ScanLocation {
        let loc = ScanLocation(name: name)
        context.insert(loc)
        try? context.save()
        return loc
    }
}
