import CoreGraphics
import Foundation
import ImageIO
import simd

/// Picks the yaw BASIN for the rig solve using the phone's own keyframes (solver v8).
///
/// THE PROBLEM. The edge-cost solve is precise once it is in the right basin (runs 13-14:
/// ±1°) but its basin CHOICE is scene-gameable: a rectangular room aliases every ~90°, so
/// the coarse full-circle scan can settle a quarter-turn out and the solve then converges
/// beautifully onto the wrong answer. The residual looks fine; the colour lands on the
/// wrong walls. Field runs 2026-08-17 solved yaw at −153.9° and +144.7° on the same rig
/// and both coloured visibly wrong across several axes.
///
/// WHY THE PHONE BREAKS THE TIE. Every candidate has to explain the same equirect, and
/// the equirect alone cannot distinguish rotations a symmetric room maps onto itself.
/// Keyframes can: ARKit poses are gravity-aligned and absolute, so a keyframe's imagery
/// says which way the room actually faces. Unprojecting its depth gives 3D points whose
/// appearance is known, and only the true yaw makes those points land on matching pixels
/// in the still.
///
/// WHAT WAS REJECTED, AND WHY IT MATTERS. Still↔still photometric consistency was tried
/// first and picks the wrong SIGN: with stills strung along a walk axis the score is
/// quasi-invariant under yaw reflection about that axis. Keyframe anchoring has no such
/// symmetry. A flip-only post-check was also rejected — the validated failure was 136°,
/// not 180°, so a flip would have "corrected" it to a different wrong answer.
///
/// The anchor only SEEDS: it narrows the edge-cost solve to ±35° of its winner, leaving
/// the precise local refinement to the cost function that is good at it.
///
/// v15: this file's idea became `PhotometricRigSolver`, the shipping solver — its coarse
/// full-circle scan IS this anchor. What remains here is the keyframe SAMPLING the
/// photometric cost feeds on; the anchor's own solve/score went with the edge cost.
enum EquirectYawAnchor {

    /// One depth-unprojected keyframe point: where it is, and how bright it looked.
    struct Sample {
        let world: SIMD3<Float>
        let gray: Float
    }

    private struct Gray {
        let pixels: [Float]      // 0-1
        let width: Int
        let height: Int

        func at(_ column: Int, _ row: Int) -> Float {
            pixels[min(max(row, 0), height - 1) * width + min(max(column, 0), width - 1)]
        }
    }

    // MARK: - Decoding

    /// Downsampled grayscale for an image on disk.
    private static func gray(at url: URL, maxPixel: Int) -> Gray? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Gray(pixels: bytes.map { Float($0) / 255 }, width: width, height: height)
    }

    /// 16-bit depth PNG in millimetres, as written by the capture pipeline.
    struct DepthMap {
        let values: [UInt16]
        let width: Int, height: Int
    }

    private static func depthMillimetres(at url: URL) -> DepthMap? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let decoded = DepthPNG.millimetres(from: image) else { return nil }
        return DepthMap(values: decoded.values, width: decoded.width, height: decoded.height)
    }

    // MARK: - Keyframe samples

    /// Unprojects a spread of keyframes into world points carrying their own brightness.
    /// Strided rather than dense: the score only needs enough points to rank a yaw, and
    /// this runs inside the Process step alongside the solve itself.
    static func keyframeSamples(rawDataDir: URL, maxFrames: Int, pixelStride: Int) -> [Sample] {
        keyframeSampleGroups(rawDataDir: rawDataDir, maxFrames: maxFrames,
                             pixelStride: pixelStride).flatMap { $0 }
    }

    /// Same sampling, one array per keyframe: the photometric solver's ZNCC is computed
    /// per (keyframe, still) PAIR — exposure differs between keyframes, and pooling them
    /// would let one bright frame dominate the normalisation.
    static func keyframeSampleGroups(rawDataDir: URL, maxFrames: Int,
                                     pixelStride: Int) -> [[Sample]] {
        let camerasDir = rawDataDir.appendingPathComponent("cameras")
        let imagesDir = rawDataDir.appendingPathComponent("images")
        let depthDir = rawDataDir.appendingPathComponent("depth")
        // Only real capture keyframes: the colorize face probe writes its own camera
        // records into this same directory, and those have no matching depth/image pair
        // here — including them just wastes frames out of the maxFrames budget.
        guard let cameraFiles = try? FileManager.default.contentsOfDirectory(
            at: camerasDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("frame_") })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }), !cameraFiles.isEmpty
        else { return [] }

        // Even spread across the walk rather than the first N, which would cluster at one
        // end of the room and re-introduce the symmetry we are trying to break.
        let step = max(1, cameraFiles.count / max(1, maxFrames))
        var groups: [[Sample]] = []
        for file in Swift.stride(from: 0, to: cameraFiles.count, by: step).map({ cameraFiles[$0] }) {
            autoreleasepool {
                var samples: [Sample] = []
                let stem = file.deletingPathExtension().lastPathComponent
                guard let json = (try? Data(contentsOf: file)).flatMap({
                          try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
                      let intrinsics = intrinsics(from: json),
                      let camToWorld = transform(from: json),
                      let image = gray(at: imagesDir.appendingPathComponent("\(stem).jpg"), maxPixel: 256),
                      let depth = depthMillimetres(at: depthDir.appendingPathComponent("\(stem).png"))
                else { return }

                for row in Swift.stride(from: 0, to: depth.height, by: pixelStride) {
                    for column in Swift.stride(from: 0, to: depth.width, by: pixelStride) {
                        let millimetres = depth.values[row * depth.width + column]
                        guard millimetres > 300, millimetres < 8000 else { continue }   // skip no-data and far noise
                        let metres = Float(millimetres) / 1000
                        // Depth pixel → full-frame pixel → ARKit camera ray (looks down −Z).
                        let fullX = Float(column) / Float(depth.width) * Float(intrinsics.width)
                        let fullY = Float(row) / Float(depth.height) * Float(intrinsics.height)
                        let camera = SIMD3<Float>((fullX - intrinsics.centreX) * metres / intrinsics.focalX,
                                                  (intrinsics.centreY - fullY) * metres / intrinsics.focalY,
                                                  -metres)
                        let world = camToWorld * SIMD4<Float>(camera, 1)
                        let imageColumn = Int(Float(column) / Float(depth.width) * Float(image.width))
                        let imageRow = Int(Float(row) / Float(depth.height) * Float(image.height))
                        samples.append(Sample(world: SIMD3<Float>(world.x, world.y, world.z),
                                              gray: image.at(imageColumn, imageRow)))
                    }
                }
                if !samples.isEmpty { groups.append(samples) }
            }
        }
        return groups
    }

    struct Intrinsics {
        let focalX: Float, focalY: Float
        let centreX: Float, centreY: Float
        let width: Int, height: Int
    }

    private static func intrinsics(from json: [String: Any]) -> Intrinsics? {
        guard let focalX = (json["fx"] as? NSNumber)?.floatValue,
              let focalY = (json["fy"] as? NSNumber)?.floatValue,
              let centreX = (json["cx"] as? NSNumber)?.floatValue,
              let centreY = (json["cy"] as? NSNumber)?.floatValue,
              let width = (json["width"] as? NSNumber)?.intValue,
              let height = (json["height"] as? NSNumber)?.intValue else { return nil }
        return Intrinsics(focalX: focalX, focalY: focalY,
                          centreX: centreX, centreY: centreY, width: width, height: height)
    }

    /// Row-major `t_XX` camera-to-world, the same layout the colorizer reads.
    private static func transform(from json: [String: Any]) -> simd_float4x4? {
        var values = [Float](repeating: 0, count: 16)
        for row in 0..<4 {
            for column in 0..<4 {
                guard let value = (json["t_\(row)\(column)"] as? NSNumber)?.floatValue else {
                    // Bottom row is optional in these JSONs; supply [0,0,0,1]. The index is
                    // column-major like the assignment below — `values[12 + column]` wrote
                    // into the TRANSLATION column instead, parking every keyframe at the
                    // world origin and making the yaw score meaningless.
                    if row == 3 { values[column * 4 + 3] = column == 3 ? 1 : 0; continue }
                    return nil
                }
                values[column * 4 + row] = value      // row-major source → column-major simd
            }
        }
        return simd_float4x4(columns: (SIMD4(values[0], values[1], values[2], values[3]),
                                       SIMD4(values[4], values[5], values[6], values[7]),
                                       SIMD4(values[8], values[9], values[10], values[11]),
                                       SIMD4(values[12], values[13], values[14], values[15])))
    }

    // MARK: - Scoring


}
