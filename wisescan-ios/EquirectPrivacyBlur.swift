import CoreGraphics
import CoreImage
import ImageIO
import UIKit
import Vision
import simd

/// Person-privacy blur for equirectangular 360° stills — the still-source-360 HARD invariant:
/// no unblurred person leaves the device (docs/design/still-source-360.md → Privacy).
///
/// POLICY — NO SECOND-GUESSING THE MODEL. Vision's answer is used as given. Two filters
/// were tried and both removed: a confident-core requirement (which discarded a real
/// person who was small on one cube face, leaving their head unmasked) and an
/// above-horizon ceiling-wash rejection. Neither is coming back, and the reason is
/// durability rather than the specific bugs: the segmentation model ships with iOS and
/// changes without notice, so a heuristic fitted to today's failure mode becomes
/// silently wrong on an OS update we do not control and cannot chase at release cadence.
/// A stale privacy filter fails in the direction that ships someone's face.
///
/// The cost is accepted deliberately: Vision over-masks flat ceilings, so those stills
/// lose ceiling texture. That loss is per-still and other stills of the same room
/// recover it. Per-face statistics are still logged, as OBSERVATION — so a regression
/// stays visible — but nothing branches on them.
///
/// Note what this does NOT cover: the nadir cone in OperatorRigMask is not second-
/// guessing anything. The rod and mount hang below the lens by construction; that is
/// measured geometry, not a judgement about the model's output.
///
/// Person detection directly on an equirect is unreliable (distortion grows toward the poles
/// and people wrap around the ±180° seam), so the still is resampled into 6 pinhole cube faces
/// — ordinary perspective images Vision was trained on — segmentation runs per face,
/// masks project back into equirect space, and person regions are pixelated
/// on the FULL-resolution equirect. Seam-straddlers are covered by personMaskUnion (two cube
/// orientations); the pole regions are the up/down faces' centers where the
/// pinhole projection is least distorted.
///
/// Memory: detection runs on a ≤4K-wide decode and 1024² faces; only the final composite
/// touches the full-resolution still, and it stays inside CoreImage's lazy/tiled pipeline
/// (11008×5504 Theta X stills decode ~242 MB — never held as a raw bitmap here).
///
/// Fail-CLOSED contract: `.failed` means the still could not be VERIFIED person-free or
/// blurred — the caller must exclude it from any export. Never ship the original on failure.
enum EquirectPrivacyBlur {

    enum Outcome {
        case clean            // verified: no person detected on any face — original may ship
        case blurred(Data)    // persons detected — ship THIS re-encoded JPEG instead
        case failed(String)   // verification impossible — do NOT ship the still
    }

    // MARK: - Tuning

    /// Cube-face edge in pixels for detection. 1024 ≈ what Vision's person model resolves well;
    /// faces render from the ≤4K working decode, so higher costs CPU, not fidelity.
    static let faceSize = 1024
    /// Equirect mask is built at 1/8 still resolution — plenty for pixelation blocks
    /// ~1% of image width, and it keeps the projection loop under a megapixel.
    static let maskScale = 8
    /// Vision confidence (0–255) at which a mask pixel counts as person.
    static let maskThreshold: UInt8 = 128
    /// OBSERVATION ONLY — nothing branches on this. Reported per face so a Vision
    /// failure (a flat ceiling returning high-confidence "person") stays visible in the
    /// logs, while the pipeline acts on none of it. See the type doc.
    static let coreThreshold: UInt8 = 210
    /// Binary dilation radius in mask-space pixels (~2×maskScale full-res px of safety margin).
    static let dilateRadius = 2
    /// Working-decode cap for face extraction (full res is only used for the final composite).
    private static let workingMaxPixel = 4096

    struct FaceBasis {
        let fwd: SIMD3<Float>
        let right: SIMD3<Float>
        let upv: SIMD3<Float>

        /// The same face, with the cube spun about the vertical axis.
        func rotatedAboutY(_ radians: Float) -> FaceBasis {
            guard radians != 0 else { return self }
            return FaceBasis(fwd: rotateAboutY(fwd, radians),
                             right: rotateAboutY(right, radians),
                             upv: rotateAboutY(upv, radians))
        }
    }

    /// Cube face bases: forward, right, up. Direction convention matches `direction(lon:lat:)`
    /// (lon 0 = equirect center = +Z, lat +90° = +Y).
    static let faceBases: [FaceBasis] = [
        FaceBasis(fwd: SIMD3(0, 0, 1), right: SIMD3(1, 0, 0), upv: SIMD3(0, 1, 0)),    // front
        FaceBasis(fwd: SIMD3(1, 0, 0), right: SIMD3(0, 0, -1), upv: SIMD3(0, 1, 0)),   // right
        FaceBasis(fwd: SIMD3(0, 0, -1), right: SIMD3(-1, 0, 0), upv: SIMD3(0, 1, 0)),  // back
        FaceBasis(fwd: SIMD3(-1, 0, 0), right: SIMD3(0, 0, 1), upv: SIMD3(0, 1, 0)),   // left
        FaceBasis(fwd: SIMD3(0, 1, 0), right: SIMD3(1, 0, 0), upv: SIMD3(0, 0, -1)),   // up
        FaceBasis(fwd: SIMD3(0, -1, 0), right: SIMD3(1, 0, 0), upv: SIMD3(0, 0, 1))    // down
        // (operator face: still BLURRED — it is only DISCARDED in cube-map exports; an
        // archived equirect keeps it)
    ]

    // MARK: - Entry

    /// Verify/blur one equirectangular JPEG. Pure function of the data; call off-main
    /// (export queue) inside the caller's per-still autoreleasepool.
    /// Runs person segmentation across the six cube faces. Shared by `process` (which
    /// composites the blur) and `personMaskEquirect` (which wants the mask alone).
    struct SegmentationFailure: Error { let reason: String }

    /// `yawOffset` rotates the whole cube before extraction, so a second pass lands its
    /// face BOUNDARIES where the first pass had face CENTRES.
    static func segmentFaces(working: Bitmap, yawOffset: Float = 0)
        -> Result<(masks: [FaceMask?], anyPerson: Bool), SegmentationFailure> {
        // Upload working bitmap to GPU texture once; reused for all 6 face dispatches.
        let gpuTexture = EquirectGPU.isAvailable
            ? EquirectGPU.makeTexture(from: working.pixels, width: working.width, height: working.height)
            : nil

        var faceMasks: [FaceMask?] = []
        var anyPerson = false
        for faceIndex in 0..<faceBases.count {
            var failure: String?
            autoreleasepool {
                let base = faceBases[faceIndex].rotatedAboutY(yawOffset)
                let face: CGImage?
                if let gpuTexture {
                    face = PerfDiag.timed("eq_face_extract_gpu") {
                        EquirectGPU.extractFace(from: gpuTexture,
                                               fwd: base.fwd, right: base.right, up: base.upv,
                                               faceSize: faceSize)
                    }
                } else {
                    face = PerfDiag.timed("eq_face_extract_cpu") { extractFace(faceIndex, from: working) }
                }
                guard let face else {
                    failure = "face \(faceIndex) extraction failed"
                    return
                }
                let segResult = PerfDiag.timed("eq_vision_segment") { personMask(for: face) }
                switch segResult {
                case .success(let mask):
                    faceMasks.append(mask)
                    if let mask { anyPerson = anyPerson || mask.hasPerson }
                case .failure(let reason):
                    failure = "face \(faceIndex): \(reason)"
                }
            }
            if let failure { return .failure(SegmentationFailure(reason: failure)) }
        }
        return .success((faceMasks, anyPerson))
    }

    static func process(equirectJPEG data: Data) -> Outcome {
        let working: Bitmap? = PerfDiag.timed("eq_decode") { decodeWorkingBitmap(from: data) }
        guard let working else {
            return .failed("equirect decode failed")
        }
        let masked: EquirectMask? = PerfDiag.timed("eq_mask_project") {
            personMaskUnion(working: working)
        }
        guard let eqMask = masked else { return .clean }
        let composited: Data? = PerfDiag.timed("eq_pixelate") { composite(original: data, mask: eqMask) }
        guard let composited else {
            return .failed("composite/encode failed")
        }
        return .blurred(composited)
    }

    // MARK: - Working decode

    struct Bitmap {
        let pixels: [UInt8]   // RGBA8, premultiplied
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }

    /// Decode the equirect once at ≤4K width for face extraction (ImageIO downsamples during
    /// decode, so the 61 MP original is never fully materialized here).
    static func decodeWorkingBitmap(from data: Data) -> Bitmap? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: workingMaxPixel,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? Bitmap(pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow) : nil
    }

    // MARK: - Sphere math

    // MARK: - Full-res composite

    /// Pixelate person regions of the ORIGINAL full-res equirect through CoreImage's lazy
    /// pipeline (the 61 MP still is never materialized as a raw bitmap) and re-encode to JPEG.
    private static func composite(original: Data, mask: EquirectMask) -> Data? {
        guard let source = CIImage(data: original) else { return nil }
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        var maskCG: CGImage?
        var bytes = mask.bytes
        bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: mask.width, height: mask.height,
                                      bitsPerComponent: 8, bytesPerRow: mask.width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            maskCG = ctx.makeImage()
        }
        guard let maskCG else { return nil }

        // Pixelation blocks ~1/128 of width (≈86 px on an 11K Theta X still) — identity-erasing
        // at any viewing zoom while keeping the scene readable.
        let blockScale = max(extent.width / 128, 32)
        let pixellated = source
            .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: blockScale])
            .cropped(to: extent)
        let maskImage = CIImage(cgImage: maskCG).transformed(by: CGAffineTransform(
            scaleX: extent.width / CGFloat(mask.width),
            y: extent.height / CGFloat(mask.height)))
        let blended = pixellated.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: source,
            kCIInputMaskImageKey: maskImage
        ])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return PrivacyBlurUtil.sharedContext.jpegRepresentation(
            of: blended, colorSpace: colorSpace,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9])
    }
}
