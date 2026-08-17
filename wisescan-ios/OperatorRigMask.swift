import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

/// Per-still mask of everything that belongs to the CAPTURE APPARATUS rather than the
/// space: the rod, mount and tripod under the camera, plus the operator and any other
/// person in frame (REQ-033).
///
/// This is NOT a privacy artifact and it is built regardless of the privacy filter. It
/// exists because "content attached to the camera" is a systematic error source for two
/// different consumers, and both currently pay for it with a blunt instrument:
///
///  - THE SOLVER masks everything below −45° elevation, because the rod and the operator
///    move WITH the rig and act as attractors that pull the calibration (runs 8-10
///    pinned parameters against their bounds). That cutoff also discards a quarter of
///    the sphere of perfectly good floor — the geometry closest to the camera, and
///    therefore the best-conditioned edges it could solve against.
///  - DOWNSTREAM reconstruction sees the operator and rig as scene content and either
///    reconstructs them into the room or, if the privacy pass ran, reconstructs a
///    pixelated blob where they stood.
///
/// A per-pixel mask serves both: exclude precisely what moves with the camera, keep the
/// floor. The mask is the union of two sources with very different failure modes —
///
///  1. GEOMETRIC (nadir cone). The rod and mount hang below the camera by construction,
///     so their extent is predictable rather than detected. Field measurement
///     (staging_0755126C, tripod-mounted) puts the hardware between −73° and nadir,
///     about a 17° cone; the default carries a few degrees of margin over that.
///  2. SEGMENTED (people). The operator is NOT reliably under the camera — with the rig
///     on a tripod, or held out on a rod, they sit at ordinary elevations off to one
///     side (measured at −30° to −60° in the same bundle). Geometry cannot predict that;
///     Vision can, and `EquirectPrivacyBlur` already computes exactly this mask and
///     currently discards it after compositing.
///
/// MASK CONVENTION: white (255) = usable pixel, black (0) = ignore. That matches what
/// the consumers expect — COLMAP's `mask_path` ignores zero-valued pixels, and
/// Nerfstudio/gsplat treat 1 as keep — so the emitted PNG needs no reinterpretation
/// downstream.
enum OperatorRigMask {

    struct Mask {
        var bytes: [UInt8]        // width*height, 255 = keep, 0 = ignore
        let width: Int
        let height: Int
    }

    /// Equirect row at or below which everything is capture hardware. Rows map latitude
    /// as `row = (90 − lat)/180 × H`, so the cone's top edge is at `90 + cutoff`.
    static func nadirMaskStartRow(height: Int) -> Int {
        let cutoff = AppConstants.rigNadirMaskDeg          // e.g. 20 ⇒ everything below −70°
        let frac = (180 - cutoff) / 180
        return min(height, max(0, Int(Float(height) * frac)))
    }

    /// Mask with the nadir cone marked and everything else usable.
    static func nadirCone(width: Int, height: Int) -> Mask {
        var mask = Mask(bytes: [UInt8](repeating: 255, count: width * height),
                        width: width, height: height)
        let start = nadirMaskStartRow(height: height)
        guard start < height else { return mask }
        for row in start..<height {
            for column in 0..<width { mask.bytes[row * width + column] = 0 }
        }
        return mask
    }

    /// Paints a person mask (255 = person, in ITS own resolution) into this mask as
    /// ignore-pixels, rescaling by nearest neighbour. Both are equirects, so the mapping
    /// is a straight proportional one.
    static func subtractPeople(from mask: inout Mask,
                               people bytes: [UInt8], width peopleWidth: Int, height peopleHeight: Int) {
        guard peopleWidth > 0, peopleHeight > 0, bytes.count >= peopleWidth * peopleHeight else { return }
        for row in 0..<mask.height {
            let sourceRow = row * peopleHeight / mask.height
            for column in 0..<mask.width {
                let sourceColumn = column * peopleWidth / mask.width
                if bytes[sourceRow * peopleWidth + sourceColumn] > 0 {
                    mask.bytes[row * mask.width + column] = 0
                }
            }
        }
    }

    /// 8-bit grayscale PNG, the format both COLMAP and Nerfstudio read.
    static func encodePNG(_ mask: Mask) -> Data? {
        guard let provider = CGDataProvider(data: Data(mask.bytes) as CFData),
              let image = CGImage(width: mask.width, height: mask.height,
                                  bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: mask.width,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// The equirect-space person mask alone (255 = person), without compositing —
    /// the same detection `process` runs, surfaced for OperatorRigMask. nil when the
    /// still cannot be decoded or no person is present. Runs regardless of the privacy
    /// filter: this feeds reconstruction masking, not the blur.
    static func personMaskEquirect(equirectJPEG data: Data) -> EquirectPrivacyBlur.EquirectMask? {
        guard let working = EquirectPrivacyBlur.decodeWorkingBitmap(from: data) else { return nil }
        guard case .success(let segmented) = EquirectPrivacyBlur.segmentFaces(working: working),
              segmented.anyPerson else { return nil }
        // Reconstruction mask: the geometric prior is safe here — an error costs
        // coverage, not privacy. The blur path deliberately does NOT use it.
        return EquirectPrivacyBlur.buildEquirectMask(from: segmented.masks,
                                                     applyGeometricPrior: true)
    }

    /// Builds the full mask for one still: the geometric cone, plus whatever Vision
    /// finds. Detection runs regardless of the privacy filter — this mask is about
    /// reconstruction quality, and a person is equally wrong to reconstruct whether or
    /// not the operator consented to their pixels shipping.
    ///
    /// Resolution is the detection mask's (≈512×256): masks are used to reject regions,
    /// not to cut fine edges, and every consumer rescales to the image anyway.
    static func build(equirectJPEG data: Data, width: Int = 512) -> Mask {
        let height = max(1, width / 2)
        var mask = nadirCone(width: width, height: height)
        if let people = personMaskEquirect(equirectJPEG: data) {
            subtractPeople(from: &mask, people: people.bytes,
                           width: people.width, height: people.height)
        }
        return mask
    }
}

extension OperatorRigMask {
    /// Per-face detection stats — the numbers that separate a real person (small area,
    /// confident core) from the no-subject wash (large area, no core). Logged so the
    /// thresholds can be tuned from field runs rather than guessed.
    static func logFaceMask(masked: Int, core: Int, total: Int, accepted: Bool) {
        guard masked > 0 else { return }
        let denom = Double(max(1, total))
        PerfDiag.log(String(format: "[EqPrivacy] face mask: %.1f%% over threshold, %.2f%% core → %@",
                            Double(masked) * 100 / denom, Double(core) * 100 / denom,
                            accepted ? "person" : "REJECTED (no confident core)"))
    }
}

extension OperatorRigMask {
    /// Reprojects an equirect mask into one cube face, matching
    /// `EquirectFaceExport.renderFace`'s ray convention exactly — same NDC, same
    /// `dir = (x, y, -z)` flip, same elevation offset — so a face's mask lines up with
    /// its pixels. Rendered coarse (masks reject regions, they do not cut fine edges)
    /// and consumers rescale anyway.
    static func faceMask(from mask: Mask, rotation: simd_float3x3,
                         side: Int, vOffsetFrac: Float = 0) -> Mask {
        var out = Mask(bytes: [UInt8](repeating: 255, count: side * side),
                       width: side, height: side)
        for row in 0..<side {
            let ndcV = 1 - 2 * (Float(row) + 0.5) / Float(side)
            for col in 0..<side {
                let ndcU = 2 * (Float(col) + 0.5) / Float(side) - 1
                let camRay = simd_normalize(rotation * SIMD3<Float>(ndcU, ndcV, -1))
                let dir = SIMD3<Float>(camRay.x, camRay.y, -camRay.z)
                let lon = atan2(dir.x, dir.z)
                let lat = asin(max(-1, min(1, dir.y)))
                var vFrac = (0.5 - lat / .pi) + vOffsetFrac
                vFrac = max(0, min(0.999, vFrac))
                let srcCol = Int((lon / (2 * .pi) + 0.5) * Float(mask.width)) % max(1, mask.width)
                let srcRow = Int(vFrac * Float(mask.height))
                let column = srcCol < 0 ? srcCol + mask.width : srcCol
                let clampedRow = max(0, min(mask.height - 1, srcRow))
                out.bytes[row * side + col] = mask.bytes[clampedRow * mask.width + column]
            }
        }
        return out
    }
}

extension OperatorRigMask {
    /// Reads back an emitted mask PNG so the face pass can reuse it instead of running
    /// segmentation a second time per still.
    static func load(pngAt url: URL) -> Mask? {
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 255, count: width * height)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Mask(bytes: bytes, width: width, height: height) : nil
    }
}
