import SwiftUI
import Observation
import SwiftData
import simd
import RoomPlan
import os               // os_proc_available_memory (per-app jetsam headroom)

// MARK: - Captured Scan Model

@Model
class CapturedScan {
    var id: UUID
    var name: String
    var capturedAt: Date
    var vertexCount: Int
    var faceCount: Int
    var hardwareDeviceModel: String = "Native iOS"
    var selectedFormatStr: String
    var uploadStatusStr: String
    var uploadProgress: Double
    var isColored: Bool = false
    /// Timestamp of the last successful upload to the server. `nil` means never uploaded.
    /// Updated automatically on HTTP 2xx; persists across launches for server cross-reference.
    var lastUploadedAt: Date?

    @Relationship(inverse: \ScanLocation.scans)
    var location: ScanLocation?

    // Stitch links where this scan is an endpoint. Cascade lives here so deleting a scan
    // (or its location, which cascades to its scans) removes every link touching it — the
    // referential integrity the file-based `stitching.json` model lacked. A scan is endpoint
    // A in some links and B in others; the full incident set is `linksAsA + linksAsB`.
    @Relationship(deleteRule: .cascade, inverse: \StitchLink.endpointAScan)
    var linksAsA: [StitchLink] = []
    @Relationship(deleteRule: .cascade, inverse: \StitchLink.endpointBScan)
    var linksAsB: [StitchLink] = []

    init(id: UUID = UUID(), name: String, capturedAt: Date = Date(), vertexCount: Int, faceCount: Int, hardwareDeviceModel: String = "Native iOS", isColored: Bool = false) {
        self.id = id
        self.name = name
        self.capturedAt = capturedAt
        self.vertexCount = vertexCount
        self.faceCount = faceCount
        self.hardwareDeviceModel = hardwareDeviceModel
        self.selectedFormatStr = ExportFormat.scan4d.rawValue
        self.uploadStatusStr = "pending"
        self.uploadProgress = 0.0
        self.isColored = isColored
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

    @Transient var isUploaded: Bool { lastUploadedAt != nil }

    @Transient var formattedUploadDate: String? {
        guard let date = lastUploadedAt else { return nil }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    // Configurable base Directory
    @Transient var scanDirectory: URL {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            // Fallback to temp directory if Documents is somehow unavailable
            return FileManager.default.temporaryDirectory.appendingPathComponent("Scans").appendingPathComponent(id.uuidString)
        }
        let locId = location?.id.uuidString ?? "unknown_location"
        return docs.appendingPathComponent("Scans").appendingPathComponent(locId).appendingPathComponent(id.uuidString)
    }

    @Transient var meshFileURL: URL { scanDirectory.appendingPathComponent("mesh.obj") }
    @Transient var colorsFileURL: URL { scanDirectory.appendingPathComponent("colors.bin") }
    @Transient var worldMapURL: URL { scanDirectory.appendingPathComponent("arworldmap.map") }
    @Transient var modelPreviewURL: URL { scanDirectory.appendingPathComponent("model_preview.jpg") }
    @Transient var thumbnailURL: URL { scanDirectory.appendingPathComponent("thumbnail.jpg") }
    @Transient var rawDataPath: URL { scanDirectory.appendingPathComponent("raw_data") }

    @Transient var roomPlanFileURL: URL { scanDirectory.appendingPathComponent("roomplan.json") }
    @Transient var roomPlanRawFileURL: URL { scanDirectory.appendingPathComponent("roomplan_raw.json") }

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
        if interval < 60 { return "\(max(0, Int(interval)))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        if interval < 31536000 { return "\(Int(interval / 86400))d ago" }
        return "\(Int(interval / 31536000))y ago"
    }
}

enum ExportFormat: String, CaseIterable, Codable {
    case scan4d = "Scan4D"
    case polycam = "Polycam"
    case raw = "RAW"
    case usdz = "USDZ"
    case ply = "PLY"
    case obj = "OBJ"

    var fileExtension: String {
        switch self {
        case .usdz: return "usdz"
        case .ply: return "ply"
        case .obj: return "obj"
        case .scan4d, .polycam, .raw: return "zip"
        }
    }

    var contentType: String {
        switch self {
        case .usdz: return "model/vnd.usdz+zip"
        case .ply: return "application/x-ply"
        case .obj: return "application/x-wavefront-obj"
        case .scan4d, .polycam, .raw: return "application/zip"
        }
    }
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
        case .zipping: return "Converting..."
        case .uploading(let progress): return "Uploading (\(Int(progress * 100))%)..."
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

enum ScanCase: String, Codable, CaseIterable {
    case rescanSpace = "RescanSpace"
    case linkAdjacent = "LinkAdjacent"
}

// MARK: - Scan Hierarchy Model

@Model
class ScanLocation {
    var id: UUID
    var name: String
    var updatedAt: Date = Date()
    var remoteLocationId: String?
    var scanCaseStr: String = ScanCase.rescanSpace.rawValue
    var imagingPoseMatrix: [Float]?

    @Relationship(deleteRule: .cascade)
    var scans: [CapturedScan] = []

    init(id: UUID = UUID(), name: String, updatedAt: Date = Date(), remoteLocationId: String? = nil, scanCase: ScanCase = .rescanSpace) {
        self.id = id
        self.name = name
        self.updatedAt = updatedAt
        self.remoteLocationId = remoteLocationId
        self.scanCaseStr = scanCase.rawValue
    }

    @Transient var scanCase: ScanCase {
        get {
            // Legacy database compatibility: map old raw values to new enum cases.
            // The stored string is normalized on the next write (via the setter).
            // Reads must be pure to avoid SwiftData mutations during SwiftUI view evaluation.
            if scanCaseStr == "Rescan" { return .rescanSpace }
            if scanCaseStr == "Extend" { return .linkAdjacent }
            return ScanCase(rawValue: scanCaseStr) ?? .rescanSpace
        }
        set { scanCaseStr = newValue.rawValue }
    }
}

// MARK: - Capture Phase State Machine

/// Tracks the current phase of the capture flow for both mid-session
/// extend (Flow A) and cross-session alignment resume (Flow B).
enum CapturePhase: Equatable {
    case idle                          // Camera passthrough, not recording
    case recording                     // Active scan capture
    case extending                     // Pin dropped, save in progress, session restart pending
    case saving                        // Auto-saving (extend flow: between pin drop and session restart)
    case loadingWorldMap               // Cross-session: loading old world map (read-only) for relocalization
    case aligning                      // Cross-session: guiding user to old anchor
    case alignedReady                  // Cross-session: user is at anchor, can confirm

    /// Whether scene reconstruction should be active (mesh capture).
    /// Only true during recording and extending (we need the session alive for world map export).
    var isRecording: Bool {
        switch self {
        case .recording, .extending: return true
        default: return false
        }
    }
}

/// Holds both source and target anchor info for the two-phase extend flow.
/// Created incrementally during pin drop / alignment; consumed when the target
/// scan is saved and the real `targetScanId` is known.
struct PendingStitchLink {
    // Source (the original scan/location that was extended FROM)
    let sourceLocationId: UUID
    let sourceScanId: UUID
    let sourceAnchorId: UUID
    let sourceAnchorTransform: simd_float4x4
    let sourceAnchorCompassHeading: Double?

    // Target anchor (placed in the new session — scan ID is unknown until saved)
    let targetLocationId: UUID
    let targetAnchorId: UUID
    let targetAnchorTransform: simd_float4x4
    let targetAnchorCompassHeading: Double?
    let linkType: StitchingLink.LinkType
}

// MARK: - Scan Store (Runtime State for Capture)

@Observable
class ScanStore {

    // MARK: Relocalization State

    /// URL to the ARWorldMap archive for scan-to-scan relocalization.
    var activeRelocalizationMap: URL?
    /// The location being scanned into (nil = new location).
    var activeLocationForScan: UUID?
    /// The scan whose world map we loaded for extend/alignment.
    var activeScanToExtend: UUID?
    /// Whether the user chose "Rescan Space" or "Link Adjacent Space".
    var activeScanCase: ScanCase = .rescanSpace

    // MARK: Capture Phase

    /// State machine tracking the current phase of the capture flow.
    var capturePhase: CapturePhase = .idle
    /// Whether the cross-session world map failed to load
    var mapLoadFailed: Bool = false

    // MARK: Boundary Anchor State

    /// World transform of the boundary anchor (set by AR delegate or pin drop).
    var boundaryAnchorTransform: simd_float4x4?
    /// ARAnchor identifier for the boundary anchor.
    var boundaryAnchorId: UUID?
    /// Distance from camera to boundary anchor (published by ARCoverageView for alignment UI).
    var distanceToBoundaryAnchor: Float?

    // MARK: Stitching State

    /// Pending stitch link built up during the extend flow; consumed when the target scan is saved.
    var pendingStitchLink: PendingStitchLink?

    // MARK: Background Processing

    /// Global state for background scan processing (set while a saved scan is being processed).
    var isProcessingScan: Bool = false
    var processingMessage: String?

    // MARK: Navigation

    /// Shared navigation path to allow programmatic pushes from capture to scan detail.
    var navigationPath = NavigationPath()

    // MARK: - AR View Hooks

    /// Stops the active recording-mode RoomPlan session promptly, populated by ARCoverageView.
    /// The stop normally happens in updateUIView's nominal-downgrade branch, but that runs on the
    /// main thread — which the post-Stop save pipeline stalls for 15–25s — so RoomPlan kept running
    /// (and re-basing its room, plus burning battery) long after Stop. The stop flow calls this right
    /// after snapshotting the room so RoomPlan ends immediately instead. `@ObservationIgnored`: it's a
    /// plumbing callback, not observable view state. Captures the coordinator weakly (no retain cycle).
    @ObservationIgnored var requestStopRoomPlan: (() -> Void)?

    /// [DEFERRED-ROOMPLAN] build hook: called by the save pipeline on a BACKGROUND queue, AFTER all
    /// pose-sensitive capture (mesh snapshot + world-map export) is finished. Waits (bounded) for the
    /// RoomPlan capture data and runs RoomBuilder off the live session, returning the reconstructed
    /// room to write into roomplan.json. Returns nil if RoomPlan was off / failed / timed out (scan
    /// then saves without a room). Weakly captures the coordinator. `@ObservationIgnored`: plumbing.
    @ObservationIgnored var awaitDeferredRoomPlan: ((TimeInterval) -> CapturedRoom?)?

    // MARK: - State Reset

    /// Resets all capture-related state to idle defaults.
    /// Call from `onDisappear`, `cancelAlignment`, or any flow that abandons the current capture.
    func resetCaptureState() {
        activeLocationForScan = nil
        activeRelocalizationMap = nil
        activeScanToExtend = nil
        activeScanCase = .rescanSpace
        capturePhase = .idle
        boundaryAnchorTransform = nil
        boundaryAnchorId = nil
        distanceToBoundaryAnchor = nil
        pendingStitchLink = nil
        // Clear the map-load failure latch too — otherwise a reset via a path that bypasses
        // CaptureView's onChange self-reset (onDisappear / cancelAlignment) leaves it true, and a
        // later identical failure can't re-fire the handler (no value change) → stuck failed state.
        mapLoadFailed = false
    }
}

// MARK: - Live Scan Stats (updated by ARCoverageView)

/// Typed representation of ARKit's ARCamera.TrackingState for use in
/// SwiftUI views and stats display — avoids fragile string comparisons.
enum TrackingStatus: Equatable {
    case notAvailable
    case normal
    case limited(reason: LimitedReason)

    enum LimitedReason: String {
        case excessiveMotion = "Excessive Motion"
        case insufficientFeatures = "Insufficient Features"
        case initializing = "Initializing"
        case relocalizing = "Relocalizing"
        case unknown = "Unknown"
    }

    /// Whether the session has full positional tracking.
    var isNormal: Bool { self == .normal }

    /// Whether tracking is established enough to BEGIN a recording. Blocks only the cold-start states
    /// where VIO isn't up yet (frames captured then have no reliable world frame). `.relocalizing` is
    /// intentionally allowed — rescan/adjacent flows establish their world frame via relocalization —
    /// and transient `.limited` reasons (motion/features) are left to ScanCoach rather than blocking.
    var isReadyToStartRecording: Bool {
        switch self {
        case .notAvailable, .limited(reason: .initializing): return false
        default: return true
        }
    }
}

@Observable
class ScanStats {
    // Existing metrics
    var totalVertices: Int = 0
    var totalFaces: Int = 0
    var averageQuality: Double = 0.0 // 0.0 to 1.0

    // New capacity metrics
    var anchorCount: Int = 0
    var trackingStatus: TrackingStatus = .notAvailable
    var sessionDuration: TimeInterval = 0
    var hasBoundaryAnchor: Bool = false
    var memoryUsageMB: Double = 0
    var baselineMemoryMB: Double = 0 // Captured at session start
    /// phys_footprint (the OOM metric) + os_proc_available_memory headroom, published at 10 Hz from
    /// updateStats. Drive `memoryPressure` off THESE (the true per-device ceiling), not resident.
    var footprintMB: Double = 0
    var availableMB: Double = 0
    /// Smoothed ARKit frame rate (~1s EMA), published from updateStats. The direct, device-adaptive
    /// compute-headroom signal — drives `fpsPressure`. Defaults to 60 so the bar reads healthy before
    /// the first sample lands.
    var smoothedFPS: Double = 60
    /// Smoothed total CPU usage across all cores as a percentage (100 = one core fully busy), published
    /// from updateStats. Divided by this device's core budget it becomes `cpuPressure` — the LEADING
    /// compute signal: it ramps as reconstruction scales, well before `fpsPressure` (which stays pinned
    /// at 60 fps until the device finally can't keep up). Defaults to 0 (healthy) pre-first-sample.
    var cpuPercent: Double = 0
    var driftEstimate: Double = 0 // 0.0 to 1.0
    var mappingStatus: String = "notAvailable" // ARFrame.WorldMappingStatus for cumulative relocalization quality
    var detectedClasses: Set<String> = [] // Semantic classes detected so far (for HUD display)
    var roomPlanInstruction: RoomCaptureSession.Instruction? // Latest RoomPlan coaching instruction

    // Photo coverage (sharp-keyframe voxel grid): how much of the depth-scanned mesh has
    // been covered by hi-res stills. Drives the coverage-debt coach tip and scan metadata.
    var photoCoverageCovered: Int = 0  // covered voxels
    var photoCoverageOccupied: Int = 0 // mesh-occupied voxels (denominator)
    /// Mean still-to-still overlap across the session's stills (0..1; photogrammetry target ~0.6).
    var meanStillOverlap: Double = 0
    /// Fraction of photo-covered voxels photographed from ≥2 distinct standpoints (parallax diversity).
    var standpointDiversity: Double = 0
    /// Fraction of mesh voxels covered by sharp keyframes (0 when no geometry yet).
    var photoCoverageFraction: Double {
        photoCoverageOccupied > 0 ? Double(photoCoverageCovered) / Double(photoCoverageOccupied) : 0
    }

    // MARK: - Space Analysis (pre-scan staging check)
    /// Latest ambient intensity from ARFrame.lightEstimate (lumens, ~0–2000). Updated per-frame
    /// during analysis phase; also available during recording for ScanCoach if desired.
    var ambientIntensity: CGFloat = 0
    /// Running average ambient intensity over the analysis window.
    var averageAmbientIntensity: CGFloat = 0
    /// Count of ambient light samples collected (for running average).
    var ambientLightSampleCount: Int = 0
    /// Latest CapturedRoom from RoomPlan (analysis or recording). Checked by SpaceAnalyzer
    /// for door/screen detection.
    var analysisRoom: CapturedRoom?
    /// Whether any person was detected (via segmentation stencil) during the analysis window.
    var personDetectedDuringAnalysis: Bool = false
    /// Latest camera yaw (radians, ±π) forwarded from ARFrame. SpaceAnalyzer uses this to
    /// track 360° coverage progress.
    var analysisYaw: Float = 0

    // Capacity thresholds (tunable)
    private let maxPolygons: Double = 2_000_000
    private let maxAnchors: Double = 500
    /// Bar is full when footprint reaches this fraction of the jetsam ceiling (margin before the kill).
    private let memoryWarnFraction: Double = 0.80
    /// FPS at/below which `fpsPressure` = 1.0. Set to 20 (not 30) to keep resolution INSIDE the danger
    /// zone: at 30 the bar saturates across sustained-mid-20s-fps scans and can't tell "rough" (~28,
    /// ~0.8) from "broken" (single digits, 1.0). Roughening is still ~0.67 by 40 fps.
    private let fpsFloor: Double = 20.0
    /// This device's total logical-core budget (×100 = the CPU% at full all-core saturation). Normalizing
    /// CPU% by THIS turns an absolute number that means nothing across chips into a device-relative
    /// saturation FRACTION: a faster or older device simply saturates at a different workload and the
    /// fraction self-adjusts — no per-device table. activeProcessorCount (not just the perflevel0 P-cores)
    /// because the reconstruction worker spills across P+E cores; total-core matched the observed fps
    /// behavior on the M1 iPad (0.63 at the heavy tail, where fps still held 60).
    private let cpuCoreBudget = Double(ProcessInfo.processInfo.activeProcessorCount) * 100.0
    /// Bar is full when CPU reaches this fraction of all-core saturation (margin before frames drop).
    private let cpuWarnFraction: Double = 0.85

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

    /// Fraction of THIS device's jetsam ceiling in use (footprint / (footprint + avail)), scaled so the
    /// bar is full at `memoryWarnFraction` of the ceiling — a safety margin before the OS kills us.
    /// Replaces the old (resident − baseline) / 800 heuristic, which was an indirect, miscalibrated
    /// proxy: it redlined at ~34% of the real ceiling on high-RAM devices. This is truthful and
    /// per-device (binds on the 12 GB iPhone; slack on the 16 GB iPad, where `fpsPressure` binds first).
    var memoryPressure: Double {
        // availableMB == 0 means os_proc_available_memory couldn't report a limit (Simulator, or the
        // documented "unlimited" case) — treat as NO SIGNAL, not "zero headroom". Guarding only on
        // ceiling > 0 would let footprint/footprint = 1.0 falsely peg the bar whenever avail is 0.
        guard availableMB > 0 else { return 0 }
        let ceiling = footprintMB + availableMB
        return min((footprintMB / ceiling) / memoryWarnFraction, 1.0)
    }
    var anchorPressure: Double { min(Double(anchorCount) / maxAnchors, 1.0) }

    /// Compute-headroom pressure from the smoothed frame rate. FPS is the direct, DEVICE-ADAPTIVE
    /// signal for "the device can't turn more geometry into frames" — the wall a fixed polygon budget
    /// can't see (FPS collapsed here at ~32% of maxPolygons). 0 above 60 fps; ~0.67 by 40 (roughening),
    /// ramps to full by `fpsFloor` (20). Leads `driftEstimate` (VIO actually breaking).
    var fpsPressure: Double {
        min(max(0, (60.0 - smoothedFPS) / (60.0 - fpsFloor)), 1.0)
    }

    /// Compute-saturation pressure: fraction of THIS device's cores in use, scaled so the bar is full at
    /// `cpuWarnFraction` of all-core saturation. The LEADING compute axis — it ramps with reconstruction
    /// load while `fpsPressure` is still 0 (fps holds 60 until the cliff, giving no runway). Portable by
    /// construction: the denominator is the device's own core count, so the same fraction means the same
    /// relative load on any chip. `fpsPressure` stays the device-INdependent backstop if this axis's
    /// calibration is off for a given device — the two cover each other (see the M1 iPad profiling run,
    /// where memory AND fps both read ~0 for the whole scan while CPU climbed to 0.63).
    var cpuPressure: Double {
        guard cpuCoreBudget > 0 else { return 0 }
        return min((cpuPercent / cpuCoreBudget) / cpuWarnFraction, 1.0)
    }

    /// Composite capacity: highest pressure factor wins (0.0 = fresh, 1.0 = at limit). On a
    /// compute-bound scan `cpuPressure` leads (then `fpsPressure` confirms); on a memory-bound one
    /// `memoryPressure` drives it.
    var capacityScore: Double {
        max(polygonPressure, memoryPressure, anchorPressure, driftEstimate, fpsPressure, cpuPressure)
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

    // MARK: - Relocalization Quality

    /// Whether the session has accumulated a robust enough map for relocalization.
    var hasEnoughFeaturesForRelocalization: Bool {
        // ARFrame.WorldMappingStatus: .mapped is the most reliable for consistent relocalization
        mappingStatus == "mapped"
    }

    var relocalizationLabel: String {
        switch mappingStatus {
        case "mapped": return "Good"
        case "extending": return "Poor"
        case "limited": return "Poor"
        default: return "None"
        }
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

    /// `phys_footprint` (TASK_VM_INFO) — the metric jetsam actually kills on (dirty + compressed
    /// pages counted against the app), NOT `resident_size` (which under-reports the memory the OS
    /// holds the app responsible for). Use THIS for OOM/jetsam profiling; `currentMemoryUsageMB`
    /// (resident) is kept for the existing capacity-score UI so those numbers stay comparable.
    static func currentFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / (1024.0 * 1024.0) : 0
    }

    /// One TASK_VM_INFO fetch → footprint + resident + compressed together (all three are fields of the
    /// same struct). Use this on hot paths (updateStats, 10 Hz) instead of calling currentFootprintMB /
    /// currentMemoryUsageMB / currentCompressedMB separately — each of those issues its own identical
    /// syscall for one field. All in MB; zeros on failure.
    static func currentVMInfoMB() -> (footprint: Double, resident: Double, compressed: Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0) }
        let mb = 1024.0 * 1024.0
        return (Double(info.phys_footprint) / mb, Double(info.resident_size) / mb, Double(info.compressed) / mb)
    }

    /// VM compressor size (TASK_VM_INFO `compressed`) — bytes of the app's pages the kernel has
    /// squeezed into the compressor rather than paged out (iOS has no swap). It's counted INTO
    /// phys_footprint, so a rising `compressed` while footprint plateaus means the app is being held
    /// together by compression — and the CPU cost of (de)compressing pages is the leading suspect for
    /// the end-of-scan slowdown. Log it beside footprint to confirm that theory on-device.
    static func currentCompressedMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.compressed) / (1024.0 * 1024.0) : 0
    }

    /// Bytes remaining before THIS app hits its jetsam limit (`os_proc_available_memory`, iOS 13+).
    /// This is the real, per-device ceiling — a 12 GB iPhone hands the app a lower limit than the
    /// 16 GB iPad, which is exactly the lower ceiling observed anecdotally. Pairs with footprint:
    /// footprint + available ≈ the limit. Returns 0 if the OS can't report it (e.g. unlimited).
    static func currentAvailableMemoryMB() -> Double {
        Double(os_proc_available_memory()) / (1024.0 * 1024.0)
    }

    /// [MemDiag] Force the malloc allocator to return free-list pages to the OS so a subsequent
    /// footprint read reflects actually-reclaimed memory, not pages malloc is still caching — the fix
    /// for the lazy-free caveat that otherwise makes teardown free-deltas under-count. Dev-flag gated
    /// (`memDiagForceReclaim`, off by default even in dev): `malloc_zone_pressure_relief` walks every
    /// zone and decommits, real overhead we never want in the normal teardown path. No-op when off.
    /// Note: only touches malloc — Metal/GPU buffers (mesh wireframe, voxels) free on RealityKit's
    /// schedule, so this makes the delta a *floor* on what a subsystem releases, not the whole story.
    /// Double-gated: the reclaim only makes sense while measuring teardown deltas, so it also requires
    /// Perf Diagnostics on — matches the Settings copy and avoids paying the expensive main-thread pass
    /// with no diagnostics output if the dev flag is left set.
    static func forceReclaimIfEnabled() {
        guard PerfDiag.enabled,
              UserDefaults.standard.bool(forKey: AppConstants.Key.memDiagForceReclaim) else { return }
        malloc_zone_pressure_relief(nil, 0)
    }

    /// Instantaneous total CPU usage across all cores, as a percentage (can exceed 100 — e.g. 250 =
    /// 2.5 cores busy). Sums per-thread `cpu_usage` over all live, non-idle threads. Cheap enough to
    /// sample at 1 Hz; perfDiag-gated at the call sites. This is the direct CPU signal the fps/thermal
    /// proxies only hint at — use it to see RoomPlan's live CPU tax (on vs off) during a scan.
    static func currentCPUUsagePercent() -> Double {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else { return 0 }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threadList)),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threadList[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return total
    }

    /// [MemDiag] Per-thread-name CPU breakdown → attribute the total CPU% to subsystems WITHOUT
    /// Instruments. Groups live non-idle threads by their pthread name (GCD names a worker thread with
    /// its queue label while a block runs, so our `org.arenaxr.scan4d.*` queues, Apple's
    /// `com.apple.arkit.*` / RealityKit render threads, etc. surface) and sums each group's
    /// instantaneous `cpu_usage`. A 1 Hz snapshot catches whatever hot pass is executing at that
    /// instant. Names are shortened to their last dot-component; unnamed threads (incl. main) group as
    /// "unnamed". Returns the `topN` heaviest contributors, descending.
    static func currentCPUByThread(topN: Int = 6) -> [(name: String, percent: Double)] {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList else { return [] }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threadList)),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }
        var byName: [String: Double] = [:]
        var nameBuf = [CChar](repeating: 0, count: 64)
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threadList[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            guard kr == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            let pct = Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            if pct < 1 { continue } // ignore threads doing effectively nothing
            var label = "unnamed"
            if let pt = pthread_from_mach_thread_np(threadList[i]),
               pthread_getname_np(pt, &nameBuf, 64) == 0 {
                let full = String(cString: nameBuf)
                if !full.isEmpty { label = full.components(separatedBy: ".").last ?? full }
            }
            byName[label, default: 0] += pct
        }
        return byName.sorted { $0.value > $1.value }.prefix(topN).map { (name: $0.key, percent: $0.value) }
    }

    /// [MemDiag] Compact one-line rendering of `currentCPUByThread` for the timeline, e.g.
    /// "voxel=180% arkit=142% unnamed=90%".
    static func currentCPUByThreadString(topN: Int = 6) -> String {
        currentCPUByThread(topN: topN)
            .map { String(format: "%@=%.0f%%", $0.name, $0.percent) }
            .joined(separator: " ")
    }

    /// Cumulative CPU *time* (seconds) consumed by the whole task: terminated-thread time
    /// (TASK_BASIC_INFO) + live-thread time (TASK_THREAD_TIMES_INFO). The sum is monotonic (a thread's
    /// time moves from the live bucket to the terminated bucket when it exits), so a delta across a
    /// window measures CPU-seconds burned in that window — used to attribute the save-time RoomBuilder
    /// cost (Δcpu-seconds ÷ wall = average cores busy).
    static func currentCPUTimeSeconds() -> Double {
        var total = 0.0
        var basic = mach_task_basic_info()
        var bcount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        if withUnsafeMutablePointer(to: &basic, {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(bcount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &bcount)
            }
        }) == KERN_SUCCESS {
            total += Double(basic.user_time.seconds) + Double(basic.user_time.microseconds) / 1e6
            total += Double(basic.system_time.seconds) + Double(basic.system_time.microseconds) / 1e6
        }
        var times = task_thread_times_info()
        var tcount = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size) / 4
        if withUnsafeMutablePointer(to: &times, {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(tcount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &tcount)
            }
        }) == KERN_SUCCESS {
            total += Double(times.user_time.seconds) + Double(times.user_time.microseconds) / 1e6
            total += Double(times.system_time.seconds) + Double(times.system_time.microseconds) / 1e6
        }
        return total
    }
}

// MARK: - Disk Persistence Manager

@MainActor
class ScanFileManager {
    static let shared = ScanFileManager()

    private init() {}

    // swiftlint:disable:next function_parameter_count
    func saveScan(
        context: ModelContext,
        locationId: UUID?,
        name: String,
        meshData: Data,
        vertexCount: Int,
        faceCount: Int,
        hardwareDeviceModel: String = "Native iOS",
        rawDataPath: URL?,
        vertexColors: Data?,
        worldMapURL: URL?,
        thumbnailData: Data? = nil,
        scanCase: ScanCase = .rescanSpace
    ) -> CapturedScan? {
        let targetLocation: ScanLocation
        // Track a location we create here so we can roll it back if the required mesh write fails
        // (otherwise a failed save would leave behind an empty, undeletable location).
        var createdLocation: ScanLocation?

        if let locId = locationId {
            let descriptor = FetchDescriptor<ScanLocation>(predicate: #Predicate { $0.id == locId })
            if let existing = try? context.fetch(descriptor).first {
                targetLocation = existing
            } else {
                targetLocation = ScanLocation(name: "Default Location", scanCase: scanCase)
                context.insert(targetLocation)
                createdLocation = targetLocation
            }
        } else {
            // Create a new location with the provided name
            targetLocation = ScanLocation(name: name.isEmpty ? "New Space" : name, scanCase: scanCase)
            context.insert(targetLocation)
            createdLocation = targetLocation
        }

        // Auto-generate scan name based on count: "Scan 1", "Scan 2", ...
        let scanNumber = targetLocation.scans.count + 1
        let scanName = "Scan \(scanNumber)"

        let newScan = CapturedScan(
            name: scanName,
            vertexCount: vertexCount,
            faceCount: faceCount,
            hardwareDeviceModel: hardwareDeviceModel
        )

        // Link to the location FIRST: scanDirectory/meshFileURL derive from location?.id, so the
        // files must be written under the final, location-scoped path (not "unknown_location").
        targetLocation.scans.append(newScan)
        newScan.location = targetLocation
        targetLocation.updatedAt = Date() // Bump to top of workflow list
        context.insert(newScan)

        // Create scan directory and write mesh (required). If this fails, roll back the inserted
        // record (and any location we just created) so we never persist an orphan whose mesh.obj
        // never reached disk (blank preview, every export fails).
        do {
            try FileManager.default.createDirectory(at: newScan.scanDirectory, withIntermediateDirectories: true)
            try meshData.write(to: newScan.meshFileURL)
        } catch {
            print("[ScanFileManager] Failed to create scan directory or write mesh; aborting save: \(error)")
            context.delete(newScan)
            if let created = createdLocation { context.delete(created) }
            return nil
        }

        // Optional files — failures must not block the critical raw data move
        if let colors = vertexColors {
            do { try colors.write(to: newScan.colorsFileURL) } catch { print("[ScanFileManager] Failed to write colors: \(error)") }
        }
        if let map = worldMapURL {
            do { try FileManager.default.copyItem(at: map, to: newScan.worldMapURL) } catch { print("[ScanFileManager] Failed to copy worldmap: \(error)") }
        }
        if let thumb = thumbnailData {
            do { try thumb.write(to: newScan.thumbnailURL) } catch { print("[ScanFileManager] Failed to write thumbnail: \(error)") }
        }

        // Critical: move raw data directory (images, depth, cameras, metadata)
        if let raw = rawDataPath, FileManager.default.fileExists(atPath: raw.path) {
            try? FileManager.default.removeItem(at: newScan.rawDataPath)
            do {
                try FileManager.default.moveItem(at: raw, to: newScan.rawDataPath)

                // Extract first RGB frame to thumbnailURL
                let imagesDir = newScan.rawDataPath.appendingPathComponent("images")
                if let files = try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path),
                   let firstImage = files.sorted().first(where: { $0.hasSuffix(".jpg") || $0.hasSuffix(".png") }) {
                    let firstImageURL = imagesDir.appendingPathComponent(firstImage)
                    try? FileManager.default.removeItem(at: newScan.thumbnailURL) // Remove existing if any
                    try? FileManager.default.copyItem(at: firstImageURL, to: newScan.thumbnailURL)
                }
            } catch {
                print("[ScanFileManager] Failed to move raw data: \(error)")
            }

            // Promote RoomPlan files from raw_data to scan directory top level (for export lookup)
            for rpFile in ["roomplan.json", "roomplan_raw.json"] {
                let src = newScan.rawDataPath.appendingPathComponent(rpFile)
                let dst = newScan.scanDirectory.appendingPathComponent(rpFile)
                if FileManager.default.fileExists(atPath: src.path) {
                    try? FileManager.default.copyItem(at: src, to: dst)
                }
            }
        }

        // Generate 2D model preview if pose is available or default
        if let img = MeshPreviewView.generateSnapshot(meshURL: newScan.meshFileURL, colorsURL: newScan.colorsFileURL, poseMatrix: targetLocation.imagingPoseMatrix),
           let data = img.jpegData(compressionQuality: 0.8) {
            try? data.write(to: newScan.modelPreviewURL)
        }

        try? context.save()

        return newScan
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
