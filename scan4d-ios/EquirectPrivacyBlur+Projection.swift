import CoreGraphics
import Foundation
import simd

// Equirect ↔ cube-face geometry for the privacy pass: direction lookup, face selection,
// and the projection of per-face masks back into equirect space.
//
// Split out of EquirectPrivacyBlur to keep that file within its length budget.
extension EquirectPrivacyBlur {
    /// Rotate a direction about the vertical axis.
    static func rotateAboutY(_ dir: SIMD3<Float>, _ radians: Float) -> SIMD3<Float> {
        let cosine = cos(radians), sine = sin(radians)
        return SIMD3<Float>(dir.x * cosine + dir.z * sine, dir.y, -dir.x * sine + dir.z * cosine)
    }

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
    static func extractFace(_ faceIndex: Int, from bmp: Bitmap) -> CGImage? {
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
    /// `yawOffset` must match the offset the faces were extracted with — the sampled
    /// direction is rotated back into that cube's frame before choosing its face.
    static func buildEquirectMask(from faceMasks: [FaceMask?], yawOffset: Float = 0) -> EquirectMask {
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
                let hit = dominantFace(for: yawOffset == 0 ? dir : rotateAboutY(dir, -yawOffset))
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
    /// Union of the person mask over BOTH cube orientations.
    ///
    /// A cube face is a 90° window and `dominantFace` assigns each direction to exactly
    /// ONE of them, so a person straddling a boundary is only ever sampled from the face
    /// that dominates — and if Vision clipped them at that face's edge, the mask has a
    /// hole (field run 2026-08-17: unmasked patches in the operator's head). The doc
    /// here used to claim seam-straddlers were covered by a union of both faces; they
    /// were not.
    ///
    /// The second pass spins the cube 45°, which puts every boundary where the first
    /// pass had a face CENTRE, so anything clipped in one orientation is interior in the
    /// other. Costs a second segmentation per still, paid at Process time, and it is the
    /// cheap half of the obvious alternative (re-detecting on a shifted equirect).
    static func personMaskUnion(working: Bitmap) -> EquirectMask? {
        var union: EquirectMask?
        for yaw in [Float(0), .pi / 4] {
            guard case .success(let segmented) = segmentFaces(working: working, yawOffset: yaw),
                  segmented.anyPerson else { continue }
            let mask = buildEquirectMask(from: segmented.masks, yawOffset: yaw)
            if union == nil {
                union = mask
            } else if union!.width == mask.width, union!.height == mask.height {
                for idx in 0..<mask.bytes.count where mask.bytes[idx] == 255 {
                    union!.bytes[idx] = 255
                }
            }
        }
        return union
    }

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
}
