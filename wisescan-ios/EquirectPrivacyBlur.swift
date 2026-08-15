import CoreGraphics
import CoreImage
import ImageIO
import UIKit
import Vision
import simd

/// Person-privacy blur for equirectangular 360° stills — the still-source-360 HARD invariant:
/// no unblurred person leaves the device (docs/design/still-source-360.md → Privacy).
///
/// Person detection directly on an equirect is unreliable (distortion grows toward the poles
/// and people wrap around the ±180° seam), so the still is resampled into 6 pinhole cube faces
/// — ordinary perspective images Vision was trained on — segmentation runs per face,
/// masks project back into equirect space, and person regions are pixelated
/// on the FULL-resolution equirect. A person straddling a face seam is covered by the union of
/// the partial masks on both faces; the pole regions are the up/down faces' centers where the
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
    private static let maskScale = 8
    /// Vision confidence (0–255) at which a mask pixel counts as person.
    static let maskThreshold: UInt8 = 128
    /// Confidence a face must reach SOMEWHERE before its mask is trusted, and how many
    /// such pixels are required. Vision has no "no subject here" output: on flat bright
    /// surfaces it returns diffuse activation that clears 128 across a whole ceiling
    /// (field run staging_C629FA75, stills 2/4/5). Real people have confident cores, so
    /// the core is the discriminator. The bar is deliberately low — a person at 5 m
    /// fills ~15 000 px of a 1024² face — which keeps the fail-closed posture.
    static let coreThreshold: UInt8 = 210
    static let minCorePixels = 250
    /// Binary dilation radius in mask-space pixels (~2×maskScale full-res px of safety margin).
    private static let dilateRadius = 2
    /// Working-decode cap for face extraction (full res is only used for the final composite).
    private static let workingMaxPixel = 4096

    private struct FaceBasis {
        let fwd: SIMD3<Float>
        let right: SIMD3<Float>
        let upv: SIMD3<Float>
    }

    /// Cube face bases: forward, right, up. Direction convention matches `direction(lon:lat:)`
    /// (lon 0 = equirect center = +Z, lat +90° = +Y).
    private static let faceBases: [FaceBasis] = [
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

    static func segmentFaces(working: Bitmap)
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
                let base = faceBases[faceIndex]
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
        let segmented: (masks: [FaceMask?], anyPerson: Bool)
        switch segmentFaces(working: working) {
        case .success(let value): segmented = value
        case .failure(let failure): return .failed(failure.reason)
        }
        guard segmented.anyPerson else { return .clean }

        let eqMask = PerfDiag.timed("eq_mask_project") { buildEquirectMask(from: segmented.masks) }
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

    private static func direction(lon: Float, lat: Float) -> SIMD3<Float> {
        SIMD3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
    }

    /// Bilinear RGB sample of the working bitmap at equirect coords derived from `dir`.
    /// Longitude wraps; latitude clamps.
    private static func sampleEquirect(_ bmp: Bitmap, dir: SIMD3<Float>) -> SIMD3<Float> {
        let lat = asin(max(-1, min(1, dir.y)))
        let lon = atan2(dir.x, dir.z)
        let eqX = (lon + .pi) / (2 * .pi) * Float(bmp.width) - 0.5
        let eqY = (Float.pi / 2 - lat) / .pi * Float(bmp.height) - 0.5
        let floorX = floor(eqX), floorY = floor(eqY)
        let wgtX = eqX - floorX, wgtY = eqY - floorY
        func texel(_ col: Int, _ row: Int) -> SIMD3<Float> {
            let wrapped = ((col % bmp.width) + bmp.width) % bmp.width
            let clamped = max(0, min(bmp.height - 1, row))
            let base = clamped * bmp.bytesPerRow + wrapped * 4
            return SIMD3(Float(bmp.pixels[base]), Float(bmp.pixels[base + 1]), Float(bmp.pixels[base + 2]))
        }
        let col0 = Int(floorX), row0 = Int(floorY)
        let top = simd_mix(texel(col0, row0), texel(col0 + 1, row0), SIMD3(repeating: wgtX))
        let bot = simd_mix(texel(col0, row0 + 1), texel(col0 + 1, row0 + 1), SIMD3(repeating: wgtX))
        return simd_mix(top, bot, SIMD3(repeating: wgtY))
    }

    // MARK: - Face extraction

    /// Render one 90°-FOV pinhole face from the working equirect bitmap.
    private static func extractFace(_ faceIndex: Int, from bmp: Bitmap) -> CGImage? {
        let base = faceBases[faceIndex]
        let side = faceSize
        var buf = [UInt8](repeating: 255, count: side * side * 4)
        for row in 0..<side {
            let ndcV = 1 - 2 * (Float(row) + 0.5) / Float(side)
            for col in 0..<side {
                let ndcU = 2 * (Float(col) + 0.5) / Float(side) - 1
                let dir = simd_normalize(base.fwd + ndcU * base.right + ndcV * base.upv)
                let rgb = sampleEquirect(bmp, dir: dir)
                let out = (row * side + col) * 4
                buf[out] = UInt8(max(0, min(255, rgb.x)))
                buf[out + 1] = UInt8(max(0, min(255, rgb.y)))
                buf[out + 2] = UInt8(max(0, min(255, rgb.z)))
            }
        }
        return buf.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }

    // MARK: - Equirect mask

    struct EquirectMask {
        var bytes: [UInt8]
        let width: Int
        let height: Int
    }

    /// Project the per-face person masks into a 1/`maskScale` equirect mask, then
    /// dilate for margin. Faces with no person contribute nothing (nil entries).
    static func buildEquirectMask(from faceMasks: [FaceMask?]) -> EquirectMask {
        // Dims derive from DETECTION space; the composite rescales to full res, so only
        // the 2:1 equirect aspect matters.
        let width = faceSize * 4 / maskScale       // ~512 for 1024 faces: plenty
        let height = width / 2
        var mask = EquirectMask(bytes: [UInt8](repeating: 0, count: width * height),
                                width: width, height: height)
        for row in 0..<height {
            let lat = Float.pi / 2 - (Float(row) + 0.5) / Float(height) * .pi
            for col in 0..<width {
                let lon = (Float(col) + 0.5) / Float(width) * 2 * .pi - .pi
                let dir = direction(lon: lon, lat: lat)
                let hit = dominantFace(for: dir)
                guard let faceMask = faceMasks[hit.index] else { continue }
                let mcol = max(0, min(faceMask.width - 1, Int((hit.faceU + 1) / 2 * Float(faceMask.width))))
                let mrow = max(0, min(faceMask.height - 1, Int((1 - (hit.faceV + 1) / 2) * Float(faceMask.height))))
                if faceMask.bytes[mrow * faceMask.width + mcol] >= maskThreshold {
                    mask.bytes[row * width + col] = 255
                }
            }
        }
        dilate(&mask, radius: dilateRadius)
        return mask
    }

    private struct FaceHit {
        let index: Int
        let faceU: Float
        let faceV: Float
    }

    /// Dominant-axis cube face for a direction + its face-plane UV in [-1, 1].
    private static func dominantFace(for dir: SIMD3<Float>) -> FaceHit {
        let absDir = simd_abs(dir)
        let faceIndex: Int
        if absDir.y >= absDir.x && absDir.y >= absDir.z {
            faceIndex = dir.y >= 0 ? 4 : 5
        } else if absDir.x >= absDir.z {
            faceIndex = dir.x >= 0 ? 1 : 3
        } else {
            faceIndex = dir.z >= 0 ? 0 : 2
        }
        let base = faceBases[faceIndex]
        let denom = simd_dot(dir, base.fwd)
        return FaceHit(index: faceIndex,
                       faceU: simd_dot(dir, base.right) / denom,
                       faceV: simd_dot(dir, base.upv) / denom)
    }

    /// Separable binary max-filter (horizontal then vertical). Longitude wraps so a person on
    /// the ±180° seam keeps their margin across it.
    private static func dilate(_ mask: inout EquirectMask, radius: Int) {
        guard radius > 0 else { return }
        let width = mask.width, height = mask.height
        var pass = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width where mask.bytes[row * width + col] == 255 {
                for off in -radius...radius {
                    let wrapped = ((col + off) % width + width) % width
                    pass[row * width + wrapped] = 255
                }
            }
        }
        for row in 0..<height {
            for col in 0..<width where pass[row * width + col] == 255 {
                for off in -radius...radius {
                    let clamped = max(0, min(height - 1, row + off))
                    mask.bytes[clamped * width + col] = 255
                }
            }
        }
    }

}

// MARK: - Vision + composite stages
// (Separate extension keeps the enum body inside the type_body_length budget.)
extension EquirectPrivacyBlur {

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
