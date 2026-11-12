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
/// FORMAT. The MakerNote is a TIFF IFD behind the header "Ricoh\0\0\0", and the vector sits
/// in a run of three consecutive 8-byte SRATIONALs sharing one denominator. It is NOT
/// reachable through the IFD's own tags, so it is located STRUCTURALLY: scan for three
/// consecutive rationals with a common scale-like denominator whose values form a unit
/// vector. That test validates itself and survives a layout change; a fixed offset does not.
///
/// Verified on two models, which is exactly why the search is structural — they agree on the
/// SEMANTICS and on nothing else:
///
///   THETA X  2.92.0  offset 848, denominator 100,000,000  (10 field stills)
///   THETA Z1 3.60.3  offset 904, denominator 1,048,576 = 2^20  (9 field stills)
///
/// Both were checked against ARKit by fitting the one constant phone→camera rotation that
/// should explain every still's reading: 1.57° mean residual on the X, 1.64° on the Z1, and
/// they put the same physical rig's rod within 1.5° of each other. Hard-coding either
/// model's denominator would silently lose the other.
///
/// The X also carries three further unit vectors later in its MakerNote (a near-identity
/// matrix, most likely the zenith rotation it applied). Gravity precedes them on both models,
/// so the FIRST match is taken — and the offset and denominator are logged, so a future model
/// that breaks that ordering shows up as a wrong number rather than a silent one.
enum ThetaGravity {
    /// Smallest denominator treated as a fixed-point scale rather than an ordinary ratio.
    private static let minimumScale: UInt32 = 1000

    /// Gravity direction in the CAMERA's body frame, unit length, or nil when this image
    /// carries no recognizable vector (different model, different firmware, stripped EXIF).
    static func parse(jpeg: Data) -> SIMD3<Float>? { parseDetailed(jpeg: jpeg)?.gravity }

    /// The vector plus where it was found — the provenance a new model needs to be verified
    /// from a field bundle rather than a teardown.
    static func parseDetailed(jpeg: Data) -> (gravity: SIMD3<Float>, offset: Int, scale: UInt32)? {
        guard let makerNote = makerNote(in: jpeg) else { return nil }
        return makerNote.withUnsafeBytes { raw -> (SIMD3<Float>, Int, UInt32)? in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let count = raw.count
            guard count >= 24 else { return nil }
            func be32(_ offset: Int) -> UInt32 {
                (UInt32(base[offset]) << 24) | (UInt32(base[offset + 1]) << 16)
                    | (UInt32(base[offset + 2]) << 8) | UInt32(base[offset + 3])
            }
            // Rationals are 4-byte aligned within the MakerNote on both verified models, but
            // step by 2 so a shifted layout is still found.
            var offset = 0
            while offset + 24 <= count {
                defer { offset += 2 }
                // One shared denominator across all three components: that is what makes this
                // a vector rather than three unrelated ratios that happen to sit together.
                let scale = be32(offset + 4)
                guard scale >= minimumScale,
                      be32(offset + 12) == scale,
                      be32(offset + 20) == scale else { continue }
                let vector = SIMD3<Float>(
                    Float(Int32(bitPattern: be32(offset))) / Float(scale),
                    Float(Int32(bitPattern: be32(offset + 8))) / Float(scale),
                    Float(Int32(bitPattern: be32(offset + 16))) / Float(scale))
                guard abs(simd_length(vector) - 1) < 0.01 else { continue }
                return (vector, offset, scale)
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
