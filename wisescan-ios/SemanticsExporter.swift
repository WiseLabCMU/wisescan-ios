import Foundation

// MARK: - Semantics Data Model

/// Per-anchor semantic classification data for export.
struct AnchorSemantics {
    let anchorId: UUID
    let faceCount: Int
    /// Per-face classification index (maps to SemanticClass.allCases ordering).
    let classifications: [Int]
}

/// Aggregated semantic data from a mesh export.
struct SemanticsData {
    let anchors: [AnchorSemantics]
    let classesDetected: Set<String>
}

// MARK: - Semantics Exporter

/// Writes `semantics.json` sidecar files for Scan4D exports.
/// The JSON contains per-anchor, per-face classification integer IDs,
/// enabling downstream pipelines to reconstruct semantic labels without
/// re-running classification.
enum SemanticsExporter {

    /// Current schema version. Increment when the JSON structure changes.
    private static let schemaVersion = 1

    /// Writes `semantics.json` to the given URL.
    /// - Parameters:
    ///   - data: Aggregated semantic classification data from the mesh export.
    ///   - url: Destination file URL (typically `scanDirectory/semantics.json`).
    static func writeSemantics(_ data: SemanticsData, to url: URL) {
        let classNames = SemanticClass.allCases.map { $0.rawValue }

        var anchorsArray: [[String: Any]] = []
        for anchor in data.anchors {
            let anchorDict: [String: Any] = [
                "anchor_id": anchor.anchorId.uuidString,
                "face_count": anchor.faceCount,
                "classifications": anchor.classifications
            ]
            anchorsArray.append(anchorDict)
        }

        let root: [String: Any] = [
            "version": schemaVersion,
            "classes": classNames,
            "anchors": anchorsArray
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: root, options: .prettyPrinted) {
            try? jsonData.write(to: url, options: .atomic)
        }
    }
}
