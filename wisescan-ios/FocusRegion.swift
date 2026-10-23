import Foundation
import simd

// MARK: - Focus scan region and detail level (docs/design/capture-modes.md)

/// How much a focus scan captures. Spacing is the view change between stills (turn or parallax at
/// the region); the target is the still count the coverage display fills toward. Starting values,
/// to tune from field captures.
nonisolated enum FocusDetailLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case check
    case detail
    case splat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .check: return "Check"
        case .detail: return "Detail"
        case .splat: return "Splat"
        }
    }

    var summary: String {
        switch self {
        case .check: return "A few photos: what is there now"
        case .detail: return "A close look from all around"
        case .splat: return "Dense coverage for reconstruction"
        }
    }

    var systemImage: String {
        switch self {
        case .check: return "eye"
        case .detail: return "viewfinder"
        case .splat: return "cube.transparent"
        }
    }

    var spacingDeg: Double {
        switch self {
        case .check: return AppConstants.focusCheckSpacingDeg
        case .detail: return AppConstants.focusDetailSpacingDeg
        case .splat: return AppConstants.focusSplatSpacingDeg
        }
    }

    var targetStills: Int {
        switch self {
        case .check: return AppConstants.focusCheckTargetStills
        case .detail: return AppConstants.focusDetailTargetStills
        case .splat: return AppConstants.focusSplatTargetStills
        }
    }

    /// Check finishes by itself at the target; the others run until the user stops.
    var finishesAtTarget: Bool { self == .check }
}

/// The box a focus scan captures: gravity-aligned (yaw about +Y only), centre and size in metres,
/// in the frame of the room-scan mesh it was drawn on. That is the location's canonical frame (the
/// original scan's) when the viewed scan's registration was applied (`frameIsCanonical`), else the
/// viewed scan's raw capture frame.
///
/// Also the `focus_region.json` format (`schemas/focus_region.schema.json`): a focus scan writes
/// its region there, and a downstream processor (a VLM) can hand the app one to capture.
nonisolated struct FocusRegion: Codable, Equatable, Sendable {
    nonisolated enum Source: String, Codable, Sendable {
        /// Drawn in the scan viewer (dropped on the mesh, then adjusted).
        case user
        /// Taken from a RoomPlan object's box, then adjusted.
        case roomplan
        /// Handed to the app (deep link or file).
        case imported = "import"
    }

    var version = 1
    var locationId: UUID?
    var center: SIMD3<Float>
    var yaw: Float
    /// Width (x), height (y), depth (z), metres.
    var size: SIMD3<Float>
    var label: String
    var source: Source
    var detail: FocusDetailLevel
    /// The room scan whose mesh frame `center` and `yaw` are in.
    var frameScanId: UUID?
    var frameIsCanonical: Bool
    /// UTC epoch milliseconds.
    var createdAtMs: Int64

    enum CodingKeys: String, CodingKey {
        case version
        case locationId = "location_id"
        case center = "center_m"
        case yaw = "yaw_rad"
        case size = "size_m"
        case label
        case source
        case detail = "detail_level"
        case frameScanId = "frame_scan_id"
        case frameIsCanonical = "frame_is_canonical"
        case createdAtMs = "created_at_ms"
    }

    init(center: SIMD3<Float>, yaw: Float = 0, size: SIMD3<Float>, label: String = "", source: Source = .user,
         detail: FocusDetailLevel = .check, locationId: UUID? = nil, frameScanId: UUID? = nil,
         frameIsCanonical: Bool = true, createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.center = center
        self.yaw = yaw
        self.size = size
        self.label = label
        self.source = source
        self.detail = detail
        self.locationId = locationId
        self.frameScanId = frameScanId
        self.frameIsCanonical = frameIsCanonical
        self.createdAtMs = createdAtMs
    }

    /// Lenient: only the box (centre, size) is required, so a hand-written or VLM-written file
    /// can leave the rest out. Yaw defaults to 0, the detail level to Check, the frame to canonical.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        locationId = try c.decodeIfPresent(UUID.self, forKey: .locationId)
        center = try c.decode(SIMD3<Float>.self, forKey: .center)
        yaw = try c.decodeIfPresent(Float.self, forKey: .yaw) ?? 0
        size = try c.decode(SIMD3<Float>.self, forKey: .size)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .imported
        detail = try c.decodeIfPresent(FocusDetailLevel.self, forKey: .detail) ?? .check
        frameScanId = try c.decodeIfPresent(UUID.self, forKey: .frameScanId)
        frameIsCanonical = try c.decodeIfPresent(Bool.self, forKey: .frameIsCanonical) ?? true
        createdAtMs = try c.decodeIfPresent(Int64.self, forKey: .createdAtMs)
            ?? Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// A usable box: finite, positive size no larger than `focusRegionMaxSizeM` on any side.
    var isValid: Bool {
        let values = [center.x, center.y, center.z, yaw, size.x, size.y, size.z]
        guard values.allSatisfy(\.isFinite) else { return false }
        return size.min() > 0 && size.max() <= AppConstants.focusRegionMaxSizeM
    }

    /// Box to frame: rotate about +Y by `yaw`, then translate to `center`. The box spans
    /// +-size/2 on each local axis.
    var transform: simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)))
        m.columns.3 = SIMD4<Float>(center, 1)
        return m
    }

    var halfExtents: SIMD3<Float> { size / 2 }

    /// The 8 corners in the region's frame.
    var corners: [SIMD3<Float>] { Self.corners(of: transform, halfExtents: halfExtents) }

    static func corners(of boxToFrame: simd_float4x4, halfExtents h: SIMD3<Float>) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(8)
        for sx in [Float(-1), 1] {
            for sy in [Float(-1), 1] {
                for sz in [Float(-1), 1] {
                    let p = boxToFrame * SIMD4<Float>(sx * h.x, sy * h.y, sz * h.z, 1)
                    out.append(SIMD3<Float>(p.x, p.y, p.z))
                }
            }
        }
        return out
    }

    /// Whether `point` (in the region's frame) lies inside the box.
    func contains(_ point: SIMD3<Float>) -> Bool {
        let local = transform.inverse * SIMD4<Float>(point, 1)
        let h = halfExtents
        return abs(local.x) <= h.x && abs(local.y) <= h.y && abs(local.z) <= h.z
    }

    /// A short label for cards and logs: the label, else the size.
    var displayName: String {
        if !label.isEmpty { return label }
        return String(format: "%.1f x %.1f x %.1f m region", size.x, size.y, size.z)
    }

    // MARK: JSON

    static func decode(_ data: Data) -> FocusRegion? {
        try? JSONDecoder().decode(FocusRegion.self, from: data)
    }

    func encoded(pretty: Bool = false) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try? encoder.encode(self)
    }
}

/// What the Rescan sheet hands the capture flow for a focus scan.
nonisolated struct FocusCaptureRequest: Equatable, Sendable {
    var region: FocusRegion
}

/// A region's box in the raw capture frame of the world map a capture relocalizes into: what the
/// AR view draws (riding the ghost's seat until Start) and what the capture gate tests against.
nonisolated struct FocusBoxPlacement: Equatable, Sendable {
    var boxToMap: simd_float4x4
    var halfExtents: SIMD3<Float>
}

extension FocusRegion {
    /// This region in the raw capture frame of `mapScanId`, the scan whose world map is loaded.
    /// A canonical-frame region comes back through the inverse of that scan's applied
    /// registration (`SaveRegistration.appliedTransform`, identity when none was applied); a
    /// raw-frame region drawn on that same scan is already there. A raw-frame region drawn on a
    /// different, unregistered scan has no known path and is treated as canonical.
    func placement(inRawFrameOf mapScanId: UUID, appliedRegistration: simd_float4x4?) -> FocusBoxPlacement {
        let toMap: simd_float4x4
        if !frameIsCanonical, frameScanId == mapScanId {
            toMap = transform
        } else {
            toMap = (appliedRegistration ?? matrix_identity_float4x4).inverse * transform
        }
        return FocusBoxPlacement(boxToMap: toMap, halfExtents: halfExtents)
    }
}
