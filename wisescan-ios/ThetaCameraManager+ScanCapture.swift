import Foundation
import simd

// Persistence for live-scan 360° stills: writes the equirect JPEG + a metadata sidecar
// into the scan's raw-data bundle. Split from ThetaCameraManager so the tens-of-MB file
// write is a `nonisolated static` helper that runs OFF the main actor (never block the
// capture thread), and to keep the manager file within the length limits.
//
// PRIVACY NOTE: these equirects are stored RAW (unblurred). A 360° still sees everything,
// including people behind the operator the phone's forward privacy stencil never saw.
// Per-face person blur for equirects is the design doc's P3 privacy invariant and is NOT
// applied here — so a scan exported while this spike is active includes unblurred 360°
// stills. Acceptable for on-device calibration testing on this branch ONLY; must land
// before any 360° source ships. See docs/design/still-source-360.md (Privacy).
extension ThetaCameraManager {

    /// Inputs for one live-scan still write, bundled so the writer keeps a small parameter list.
    struct ScanStillInput {
        let sequence: Int
        let phoneTransform: simd_float4x4
        let timestamp: TimeInterval
        let sourceURL: String
        let sourceModel: String
        let format: StillFormat?
        let triggerMs: Int
        let transferMs: Int
    }

    /// Writes the equirect + sidecar to `<rawDataDir>/equirect_stills/still_NNNN.{JPG,json}`
    /// — the camera-agnostic 360° contract (any equirectangular source writes here; the
    /// device identity travels in the sidecar's `still_source`, not in path names).
    /// Nonisolated so the file write runs off the main actor.
    nonisolated static func writeScanStill(data: Data, input: ScanStillInput, into rawDataDir: URL) throws {
        let dir = rawDataDir.appendingPathComponent("equirect_stills")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let base = String(format: "still_%04d", input.sequence)
        try data.write(to: dir.appendingPathComponent("\(base).JPG"))

        // Column-major 4×4 (matches the transforms.json convention used elsewhere).
        let matrix = input.phoneTransform
        let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
        let flatTransform = columns.flatMap { [$0.x, $0.y, $0.z, $0.w] }

        let metadata = EquirectStillMetadata(
            sequence: input.sequence,
            timestamp: input.timestamp,
            stillSource: input.sourceModel,
            cameraModel: "equirectangular",
            width: input.format?.width,
            height: input.format?.height,
            phoneTransform: flatTransform,
            cameraFileURL: input.sourceURL,
            triggerMs: input.triggerMs,
            transferMs: input.transferMs,
            bytes: data.count
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: dir.appendingPathComponent("\(base).json"))
    }
}

/// Sidecar written next to each live-scan 360° still. Records the **phone** pose (not the
/// camera pose — rig-extrinsic composition is the deferred P3 calibration) so downstream can
/// solve the hand–eye calibration from phone-pose ↔ equirect pairs. Snake_case keys match
/// the project's JSON conventions; kept separate from `transforms.json` for now (the design
/// doc's export section folds cube-faces into transforms once calibration + export land).
private struct EquirectStillMetadata: Encodable {
    let sequence: Int
    let timestamp: TimeInterval
    let stillSource: String
    let cameraModel: String
    let width: Int?
    let height: Int?
    let phoneTransform: [Float]
    let cameraFileURL: String
    let triggerMs: Int
    let transferMs: Int
    let bytes: Int

    enum CodingKeys: String, CodingKey {
        case sequence
        case timestamp
        case stillSource = "still_source"
        case cameraModel = "camera_model"
        case width
        case height
        case phoneTransform = "phone_transform"
        case cameraFileURL = "camera_file_url"
        case triggerMs = "trigger_ms"
        case transferMs = "transfer_ms"
        case bytes
    }
}
