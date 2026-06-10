import Foundation
import RoomPlan
import simd

// MARK: - RoomPlan Export Data Model

/// Clean, human-readable representation of a CapturedRoom for `roomplan.json` export.
/// This is a controlled schema (not Apple's opaque Codable format), providing only the
/// fields needed for downstream visualization, coaching, and pipeline integration.
struct RoomPlanExportData: Codable {
    let version: Int
    let surfaces: [ExportSurface]
    let objects: [ExportObject]

    struct ExportSurface: Codable {
        let id: String
        let category: String
        let dimensions: Dimensions
        let transform: [Float]  // column-major 4x4
        let confidence: String
    }

    struct ExportObject: Codable {
        let id: String
        let category: String
        let dimensions: Dimensions
        let transform: [Float]  // column-major 4x4
        let confidence: String
    }

    struct Dimensions: Codable {
        let width: Float
        let height: Float
        let depth: Float
    }
}

// MARK: - RoomPlan Exporter

/// Writes `roomplan.json` (clean schema) and `roomplan_raw.json` (Apple Codable)
/// sidecar files for Scan4D exports.
enum RoomPlanExporter {

    /// Current schema version for `roomplan.json`. Increment when structure changes.
    private static let schemaVersion = 1

    /// Writes both `roomplan.json` and `roomplan_raw.json` to the given directory.
    /// - Parameters:
    ///   - room: The final CapturedRoom from RoomPlan.
    ///   - directory: Destination directory (scan directory or export staging).
    static func writeRoomPlan(_ room: CapturedRoom, to directory: URL) {
        writeCleanJSON(room, to: directory)
        writeRawJSON(room, to: directory)
    }

    /// Writes the clean, human-readable `roomplan.json`.
    private static func writeCleanJSON(_ room: CapturedRoom, to directory: URL) {
        let allSurfaces = room.walls + room.floors + room.doors + room.windows + room.openings
        let exportSurfaces = allSurfaces.map { surface -> RoomPlanExportData.ExportSurface in
            RoomPlanExportData.ExportSurface(
                id: surface.identifier.uuidString,
                category: categoryString(for: surface.category),
                dimensions: RoomPlanExportData.Dimensions(
                    width: surface.dimensions.x,
                    height: surface.dimensions.y,
                    depth: surface.dimensions.z
                ),
                transform: flattenMatrix(surface.transform),
                confidence: confidenceString(for: surface.confidence)
            )
        }

        let exportObjects = room.objects.map { object -> RoomPlanExportData.ExportObject in
            RoomPlanExportData.ExportObject(
                id: object.identifier.uuidString,
                category: objectCategoryString(for: object.category),
                dimensions: RoomPlanExportData.Dimensions(
                    width: object.dimensions.x,
                    height: object.dimensions.y,
                    depth: object.dimensions.z
                ),
                transform: flattenMatrix(object.transform),
                confidence: confidenceString(for: object.confidence)
            )
        }

        let exportData = RoomPlanExportData(
            version: schemaVersion,
            surfaces: exportSurfaces,
            objects: exportObjects
        )

        let url = directory.appendingPathComponent("roomplan.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let jsonData = try? encoder.encode(exportData) {
            try? jsonData.write(to: url, options: .atomic)
            print("[RoomPlanExporter] ✓ wrote roomplan.json (\(exportSurfaces.count) surfaces, \(exportObjects.count) objects)")
        }
    }

    /// Writes the raw Apple Codable blob as `roomplan_raw.json` for future round-tripping.
    private static func writeRawJSON(_ room: CapturedRoom, to directory: URL) {
        let url = directory.appendingPathComponent("roomplan_raw.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let jsonData = try? encoder.encode(room) {
            try? jsonData.write(to: url, options: .atomic)
            print("[RoomPlanExporter] ✓ wrote roomplan_raw.json")
        }
    }

    // MARK: - Category String Helpers

    private static func categoryString(for category: CapturedRoom.Surface.Category) -> String {
        switch category {
        case .wall:            return "wall"
        case .floor:           return "floor"
        case .door(isOpen: _): return "door"
        case .window:          return "window"
        case .opening:         return "opening"
        @unknown default: return "unknown"
        }
    }

    private static func objectCategoryString(for category: CapturedRoom.Object.Category) -> String {
        switch category {
        case .table:        return "table"
        case .chair:        return "chair"
        case .sofa:         return "sofa"
        case .bed:          return "bed"
        case .storage:      return "storage"
        case .refrigerator: return "refrigerator"
        case .stove:        return "stove"
        case .sink:         return "sink"
        case .washerDryer:  return "washer_dryer"
        case .dishwasher:   return "dishwasher"
        case .oven:         return "oven"
        case .fireplace:    return "fireplace"
        case .television:   return "television"
        case .bathtub:      return "bathtub"
        case .toilet:       return "toilet"
        @unknown default:   return "unknown"
        }
    }

    private static func confidenceString(for confidence: CapturedRoom.Confidence) -> String {
        switch confidence {
        case .low:    return "low"
        case .medium: return "medium"
        case .high:   return "high"
        @unknown default: return "unknown"
        }
    }

    /// Flatten a 4x4 matrix to 16 floats (column-major, matching stitching.json convention).
    private static func flattenMatrix(_ m: simd_float4x4) -> [Float] {
        [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
         m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
         m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
         m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
    }
}
