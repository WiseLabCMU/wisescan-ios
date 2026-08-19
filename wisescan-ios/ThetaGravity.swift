import Foundation
import simd

/// The 360° camera's OWN accelerometer reading at the moment of capture, recovered from the
/// RICOH MakerNote in the equirect JPEG.
///
/// WHY THIS MATTERS. Everything the rig solver knows about the camera's orientation is
/// currently either assumed (the Theta's zenith correction leaves the pano level) or fitted
/// (`pitchResidual`, `elevation_offset_deg`). The camera measures its own attitude and
/// writes it into every still, which turns two of the three rotational degrees of freedom
/// from a fit into a measurement — independently of ARKit, the mesh, and the cost function.
///
/// It does NOT give heading: gravity is invariant under rotation about the vertical axis, so
/// yaw still has to come from the keyframe anchor. What it does give is a per-still check on
/// rig rigidity and on the zenith-correction assumption, neither of which has ever been
/// verified in the field.
///
/// FORMAT (THETA X 2.92.0, verified against 10 field stills): the MakerNote is a TIFF IFD
/// behind the header "Ricoh\0\0\0", and the vector sits in a run of three consecutive
/// 8-byte SRATIONALs with denominator 100,000,000. It is NOT reachable through the IFD's
/// own tags, so it is located STRUCTURALLY — scan for three consecutive rationals with that
/// denominator whose values form a unit vector. That test is self-validating and survives a
/// layout change; a fixed offset would not, and the layout is expected to differ by model
/// (the Z1 in particular is unverified — it has no field capture in the archive yet).
enum ThetaGravity {
    /// Denominator RICOH uses for the normalized accelerometer components.
    private static let scale: UInt32 = 100_000_000

    /// Gravity direction in the CAMERA's body frame, unit length, or nil when this image
    /// carries no recognizable vector (different model, different firmware, stripped EXIF).
    static func parse(jpeg: Data) -> SIMD3<Float>? {
        guard let makerNote = makerNote(in: jpeg) else { return nil }
        return makerNote.withUnsafeBytes { raw -> SIMD3<Float>? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let count = raw.count
            guard count >= 24 else { return nil }
            func be32(_ offset: Int) -> UInt32 {
                (UInt32(base[offset]) << 24) | (UInt32(base[offset + 1]) << 16)
                    | (UInt32(base[offset + 2]) << 8) | UInt32(base[offset + 3])
            }
            // Rationals are 4-byte aligned within the MakerNote in every sample seen, but
            // step by 2 so a shifted layout is still found.
            var offset = 0
            while offset + 24 <= count {
                defer { offset += 2 }
                guard be32(offset + 4) == scale,
                      be32(offset + 12) == scale,
                      be32(offset + 20) == scale else { continue }
                let vector = SIMD3<Float>(
                    Float(Int32(bitPattern: be32(offset))) / Float(scale),
                    Float(Int32(bitPattern: be32(offset + 8))) / Float(scale),
                    Float(Int32(bitPattern: be32(offset + 16))) / Float(scale))
                guard abs(simd_length(vector) - 1) < 0.01 else { continue }
                return vector
            }
            return nil
        }
    }

    /// The MakerNote payload (EXIF tag 0x927C), minus RICOH's 8-byte header.
    private static func makerNote(in jpeg: Data) -> Data? {
        guard let exif = exifTIFF(in: jpeg) else { return nil }
        return exif.withUnsafeBytes { raw -> Data? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  raw.count > 8 else { return nil }
            // RICOH writes big-endian ("MM"); anything else is not a camera we have verified.
            guard base[0] == 0x4D, base[1] == 0x4D else { return nil }
            func be16(_ o: Int) -> Int { (Int(base[o]) << 8) | Int(base[o + 1]) }
            func be32(_ o: Int) -> Int {
                (Int(base[o]) << 24) | (Int(base[o + 1]) << 16) | (Int(base[o + 2]) << 8) | Int(base[o + 3])
            }
            /// Value of one tag in the IFD at `ifdOffset`, as (offset, byteCount) into the TIFF.
            func find(_ wanted: Int, in ifdOffset: Int) -> (offset: Int, count: Int)? {
                guard ifdOffset + 2 <= raw.count else { return nil }
                let entries = be16(ifdOffset)
                guard entries < 512 else { return nil }
                for index in 0..<entries {
                    let entry = ifdOffset + 2 + index * 12
                    guard entry + 12 <= raw.count else { return nil }
                    guard be16(entry) == wanted else { continue }
                    let type = be16(entry + 2), count = be32(entry + 4)
                    let unit = [0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8][min(type, 10)]
                    let size = unit * count
                    let at = size <= 4 ? entry + 8 : be32(entry + 8)
                    guard at >= 0, at + size <= raw.count else { return nil }
                    return (at, size)
                }
                return nil
            }
            guard let exifIFD = find(0x8769, in: be32(4)) else { return nil }
            guard let note = find(0x927C, in: be32(exifIFD.offset)) else { return nil }
            // "Ricoh\0\0\0" then the IFD; the vector lives past it either way.
            let skip = note.count > 8 ? 8 : 0
            return Data(bytes: base + note.offset + skip, count: note.count - skip)
        }
    }

    /// The TIFF block inside the APP1/Exif segment.
    private static func exifTIFF(in jpeg: Data) -> Data? {
        let bytes = [UInt8](jpeg.prefix(256 * 1024))
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var index = 2
        while index + 4 <= bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            let marker = bytes[index + 1]
            if marker == 0xDA { return nil }                     // start of scan — no more metadata
            let length = (Int(bytes[index + 2]) << 8) | Int(bytes[index + 3])
            guard length >= 2, index + 2 + length <= bytes.count else { return nil }
            let payload = index + 4
            if marker == 0xE1, payload + 6 <= bytes.count,
               bytes[payload] == 0x45, bytes[payload + 1] == 0x78, bytes[payload + 2] == 0x69,
               bytes[payload + 3] == 0x66 {                      // "Exif"
                return Data(bytes[(payload + 6)..<(index + 2 + length)])
            }
            index += 2 + length
        }
        return nil
    }
}
