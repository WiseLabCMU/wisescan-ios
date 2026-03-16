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
        self.selectedFormatStr = ExportFormat.scan4d.rawValue
        self.uploadStatusStr = "pending"
        self.uploadProgress = 0.0
    }

    @Transient var selectedFormat: ExportFormat {
        get { ExportFormat(rawValue: selectedFormatStr) ?? .scan4d }
        set { selectedFormatStr = newValue.rawValue }
    }

    @Transient var uploadStatus: UploadStatus {
        get {
            if uploadStatusStr == "pending" { return .pending }
            if uploadStatusStr == "zipping" { return .zipping }
            if uploadStatusStr == "savedLocally" { return .savedLocally }
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
            case .zipping:
                uploadStatusStr = "zipping"
                uploadProgress = 0.0
            case .savedLocally:
                uploadStatusStr = "savedLocally"
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
    @Transient var thumbnailURL: URL { scanDirectory.appendingPathComponent("thumbnail.jpg") }
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
    case scan4d = "Scan4D"
    case polycam = "Polycam"
    case raw = "RAW"
    case usdz = "USDZ"
    case ply = "PLY"
    case obj = "OBJ"
}

enum UploadStatus: Equatable {
    case pending
    case zipping
    case uploading(progress: Double)
    case savedLocally
    case success
    case failed(String)

    var label: String {
        switch self {
        case .pending: return "Ready"
        case .zipping: return "Zipping..."
        case .uploading(let p): return "Uploading (\(Int(p * 100))%)..."
        case .savedLocally: return "Saved Locally"
        case .success: return "Uploaded"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    var isUploading: Bool {
        if case .uploading = self { return true }
        if case .zipping = self { return true }
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
    var updatedAt: Date = Date()
    var remoteLocationId: String?

    @Relationship(deleteRule: .cascade)
    var scans: [CapturedScan] = []

    init(id: UUID = UUID(), name: String, updatedAt: Date = Date(), remoteLocationId: String? = nil) {
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
        self.remoteLocationId = remoteLocationId
    }
}

// MARK: - Scan Store (Runtime State for Capture)

@Observable
class ScanStore {
    // Scan4D state for initiating a new scan of an existing location
    var activeRelocalizationMap: URL? = nil
    var activeLocationForScan: UUID? = nil
    
    // Shared navigation state to allow programmatic pushes
    var navigationPath = NavigationPath()
}

// MARK: - Live Scan Stats (updated by ARCoverageView)

@Observable
class ScanStats {
    // Existing metrics
    var totalVertices: Int = 0
    var totalFaces: Int = 0
    var averageQuality: Double = 0.0 // 0.0 to 1.0

    // New capacity metrics
    var anchorCount: Int = 0
    var trackingState: String = "notAvailable"
    var trackingReason: String = ""
    var sessionDuration: TimeInterval = 0
    var memoryUsageMB: Double = 0
    var baselineMemoryMB: Double = 0 // Captured at session start
    var driftEstimate: Double = 0 // 0.0 to 1.0

    // Capacity thresholds (tunable)
    private let maxPolygons: Double = 2_000_000
    private let maxMemoryDeltaMB: Double = 800 // Memory growth from scanning, not total app memory
    private let maxAnchors: Double = 500

    var estimatedSizeMB: Double {
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

    // MARK: - Capacity Score

    var polygonPressure: Double { min(Double(totalFaces) / maxPolygons, 1.0) }
    var memoryPressure: Double {
        let delta = max(0, memoryUsageMB - baselineMemoryMB)
        return min(delta / maxMemoryDeltaMB, 1.0)
    }
    var anchorPressure: Double { min(Double(anchorCount) / maxAnchors, 1.0) }

    /// Composite capacity: highest pressure factor wins (0.0 = fresh, 1.0 = at limit)
    var capacityScore: Double {
        max(polygonPressure, memoryPressure, anchorPressure, driftEstimate)
    }

    var isNearCapacity: Bool { capacityScore > 0.8 }
    var isAtCapacity: Bool { capacityScore > 0.95 }

    var capacityPercent: Int { Int(capacityScore * 100) }

    var capacityColor: (red: Double, green: Double) {
        // Green → Yellow → Red gradient
        let score = capacityScore
        if score < 0.5 { return (score * 2.0, 1.0) }
        return (1.0, max(0, 2.0 * (1.0 - score)))
    }

    var driftLabel: String {
        if driftEstimate < 0.2 { return "Low" }
        if driftEstimate < 0.5 { return "Med" }
        if driftEstimate < 0.8 { return "High" }
        return "Critical"
    }

    var formattedDuration: String {
        let mins = Int(sessionDuration) / 60
        let secs = Int(sessionDuration) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Memory Measurement

    static func currentMemoryUsageMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / (1024.0 * 1024.0) : 0
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
        worldMapURL: URL?,
        thumbnailData: Data? = nil
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
            // Create a new location with the provided name
            targetLocation = ScanLocation(name: name.isEmpty ? "New Space" : name)
            context.insert(targetLocation)
        }

        // Auto-generate scan name based on count: "Scan 1", "Scan 2", ...
        let scanNumber = targetLocation.scans.count + 1
        let scanName = "Scan \(scanNumber)"

        let newScan = CapturedScan(
            name: scanName,
            vertexCount: vertexCount,
            faceCount: faceCount
        )

        targetLocation.scans.append(newScan)
        newScan.location = targetLocation
        targetLocation.updatedAt = Date() // Bump to top of workflow list
        context.insert(newScan)

        do {
            try FileManager.default.createDirectory(at: newScan.scanDirectory, withIntermediateDirectories: true)
            try meshData.write(to: newScan.meshFileURL)
            if let colors = vertexColors { try colors.write(to: newScan.colorsFileURL) }
            if let map = worldMapURL { try FileManager.default.copyItem(at: map, to: newScan.worldMapURL) }
            if let thumb = thumbnailData { try thumb.write(to: newScan.thumbnailURL) }

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
