import Foundation
import simd

/// On-disk format for the ARKit sparse feature point cloud (`arkit_features.bin`).
///
/// **Layout.** A fixed 128-byte ASCII header followed by packed little-endian records of
/// exactly 20 bytes each — `id: UInt64`, `x: Float32`, `y: Float32`, `z: Float32`. Packed
/// means packed: no padding, no alignment, no separators. The header is four lines, then
/// space padding, with byte 128 being `\n`:
///
/// ```
/// ARKITFEAT 1
/// count <N>
/// dtype id:u8,x:f4,y:f4,z:f4
/// frame raw
/// ```
///
/// **Frame.** `frame raw` records that the points are in the scan's RAW capture frame — the
/// same frame as `arworldmap.map` and `cameras/`, **not** `mesh.obj`'s canonical frame.
/// `registration.json` carries the raw→canonical transform; apply it before comparing these
/// points to the mesh.
///
/// **Reading it.** One line of Python, no parser:
///
/// ```python
/// np.fromfile(p, dtype=np.dtype([('id','<u8'),('x','<f4'),('y','<f4'),('z','<f4')]), offset=128)
/// ```
///
/// **Why not PLY.** PLY has no uint64, and Open3D silently drops vertex properties it does
/// not recognize — so the ARKit identifier, which is the entire point of this file (the same
/// identifiers survive save → load → save round trips), would be lost by the most common
/// Python reader. The name `sparse_pc.ply` is separately reserved for the training-side seed
/// cloud the pipeline writes; this file must never cause `ply_file_path` to be set.
///
/// An empty cloud is written as a valid header with `count 0` and no records — never as a
/// missing file. Consumers must not have to branch on existence.
///
/// Deliberately free of ARKit and RealityKit imports so it is testable in the Simulator.
enum FeaturePointCloudFile {

    /// Filename inside a scan directory / exported bundle.
    static let filename = "arkit_features.bin"

    /// Extension for the pre-promotion temp file written next to the world map.
    static let tempExtension = "features"

    /// Header size in bytes. Records start at exactly this offset.
    static let headerByteCount = 128

    /// Version stamped in the `ARKITFEAT` line.
    static let formatVersion = 1

    /// Bytes per record: `UInt64` id + three `Float32` coordinates, packed.
    static let recordByteCount = 20

    // MARK: - Encoding

    /// Encodes `ids` and `points` into the 128-byte-header + packed-record format.
    ///
    /// The two arrays are paired positionally and truncated to `min(ids.count, points.count)`;
    /// that count is what the header declares, so the header can never disagree with the
    /// payload. An empty input produces a valid 128-byte file with `count 0`.
    static func encode(ids: [UInt64], points: [SIMD3<Float>]) -> Data {
        let count = min(ids.count, points.count)

        var out = Data()
        out.reserveCapacity(headerByteCount + count * recordByteCount)
        out.append(header(count: count))

        // Append a value's little-endian bytes (correct on any host endianness).
        func putUInt64(_ u: UInt64) {
            var le = u.littleEndian
            Swift.withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        func putFloat(_ f: Float) {
            var le = f.bitPattern.littleEndian
            Swift.withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }

        for i in 0..<count {
            putUInt64(ids[i])
            let p = points[i]
            putFloat(p.x); putFloat(p.y); putFloat(p.z)
        }

        return out
    }

    /// The fixed-size ASCII header for a record count. Always exactly `headerByteCount` bytes.
    private static func header(count: Int) -> Data {
        var text = "ARKITFEAT \(formatVersion)\n"
        text += "count \(count)\n"
        text += "dtype id:u8,x:f4,y:f4,z:f4\n"
        text += "frame raw\n"

        // Pad with spaces so the final byte of the 128 is a newline. The four lines total
        // 56 + digits(count) bytes, so the padding stays positive for any plausible count
        // (a 20-digit UInt64 count still leaves 51 spaces).
        var bytes = [UInt8](text.utf8)
        precondition(bytes.count < headerByteCount, "FeaturePointCloudFile header overflow")
        bytes.append(contentsOf: repeatElement(UInt8(ascii: " "),
                                               count: headerByteCount - bytes.count - 1))
        bytes.append(UInt8(ascii: "\n"))
        return Data(bytes)
    }

    // MARK: - Temp file placement

    /// Temp URL for the feature cloud belonging to the scan whose world map is `mapURL`:
    /// `worldmap_<8hex>.features` beside `worldmap_<8hex>.worldmap`.
    ///
    /// The name is derived, never fixed. `saveScan` promotes this file *by name*, so a fixed
    /// name in the temp root would let two in-flight saves (or a retried export) silently
    /// attach scan A's feature cloud to scan B's bundle.
    static func tempURL(besideWorldMap mapURL: URL) -> URL {
        mapURL.deletingPathExtension().appendingPathExtension(tempExtension)
    }
}
