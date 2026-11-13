import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Finds the people in an upright photo for the privacy blur, as one mask: 8-bit, 255 where a
/// person is, a quarter of the photo's size on each side (docs/PRIVACY.md, "Focus Scan Stills").
///
/// Vision's person segmentation alone is a portrait matte: it outlines the photo's main subject
/// and drops people in the background, even ones a third of the frame tall. On a 2026-11-13 room
/// scan of a lounge it found nobody in five photos with people seated in view. So the mask is
/// the union of four looks at the photo:
/// - person segmentation over the whole photo, which outlines near people best;
/// - person segmentation on overlapping tiles, where a person farther away fills more of what
///   the model sees (360° stills get the same from their cube faces);
/// - Vision's human body boxes, whole body and upper body, filled;
/// - face boxes, filled.
///
/// Whatever any of them finds is masked: over-masking costs some texture, under-masking ships a
/// person. Every request must succeed; one that fails fails the whole check (fail closed).
/// Self-contained (no app types), so it can be run on a Mac against exported photos.
nonisolated enum PersonCheck {

    struct Settings: Sendable {
        var tileColumns: Int
        var tileRows: Int
        /// The fraction of a tile shared with its neighbour.
        var tileOverlap: Double
        /// Segmentation value counted as a person (0-255).
        var maskThreshold: UInt8
        /// Added on every side of a body or face box, as a fraction of the box's size.
        var boxPadding: Double
    }

    struct Mask: Sendable {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        /// What found people, for the log: segmentation (whole, tiles) and boxes.
        let summary: String
    }

    struct Failure: Error, Sendable {
        let message: String
    }

    /// A mask pixel covers this many photo pixels on a side.
    static let maskScale = 4

    /// The person mask of `image` (upright), nil when nothing finds a person.
    static func mask(upright image: CGImage, settings: Settings) -> Result<Mask?, Failure> {
        let width = image.width, height = image.height
        let maskWidth = max(1, width / maskScale), maskHeight = max(1, height / maskScale)
        var bytes = [UInt8](repeating: 0, count: maskWidth * maskHeight)

        // The whole photo: segmentation and the three box detectors share one handler.
        let whole = segmentationRequest()
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = false
        let upperBodies = VNDetectHumanRectanglesRequest()
        upperBodies.upperBodyOnly = true
        let faces = VNDetectFaceRectanglesRequest()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([whole, bodies, upperBodies, faces])
        } catch {
            return .failure(Failure(message: "Vision person check failed: \(error.localizedDescription)"))
        }
        guard let wholeBuffer = whole.results?.first?.pixelBuffer else {
            return .failure(Failure(message: "Vision returned no segmentation mask"))
        }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let wholeHits = stamp(wholeBuffer, covering: full, threshold: settings.maskThreshold,
                              into: &bytes, maskWidth: maskWidth, maskHeight: maskHeight)

        // Overlapping tiles.
        var tileHits = 0
        for tile in tiles(width: width, height: height, columns: settings.tileColumns,
                          rows: settings.tileRows, overlap: settings.tileOverlap) {
            guard let crop = image.cropping(to: tile) else {
                return .failure(Failure(message: "tile crop failed"))
            }
            let request = segmentationRequest()
            do {
                try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
            } catch {
                return .failure(Failure(message: "Vision tile segmentation failed: \(error.localizedDescription)"))
            }
            guard let buffer = request.results?.first?.pixelBuffer else {
                return .failure(Failure(message: "Vision returned no tile segmentation mask"))
            }
            if stamp(buffer, covering: tile, threshold: settings.maskThreshold,
                     into: &bytes, maskWidth: maskWidth, maskHeight: maskHeight) > 0 {
                tileHits += 1
            }
        }

        // Boxes.
        let bodyBoxes = (bodies.results ?? []).map(\.boundingBox) + (upperBodies.results ?? []).map(\.boundingBox)
        let faceBoxes = (faces.results ?? []).map(\.boundingBox)
        for box in bodyBoxes + faceBoxes {
            fill(normalizedBox: box, padding: settings.boxPadding, into: &bytes, maskWidth: maskWidth, maskHeight: maskHeight)
        }

        guard bytes.contains(where: { $0 != 0 }) else { return .success(nil) }
        let summary = "whole \(wholeHits > 0 ? "yes" : "no"), tiles \(tileHits), body boxes \(bodyBoxes.count), faces \(faceBoxes.count)"
        return .success(Mask(bytes: bytes, width: maskWidth, height: maskHeight, summary: summary))
    }

    private static func segmentationRequest() -> VNGeneratePersonSegmentationRequest {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }

    /// Overlapping tiles covering a `width` x `height` image, `columns` x `rows`, each sharing
    /// `overlap` of its size with its neighbour, in image pixels (origin top-left).
    static func tiles(width: Int, height: Int, columns: Int, rows: Int, overlap: Double) -> [CGRect] {
        func spans(_ length: Int, _ count: Int) -> [(start: Int, size: Int)] {
            guard count > 1 else { return [(0, length)] }
            let size = min(length, Int((Double(length) / (Double(count) - overlap * Double(count - 1))).rounded(.up)))
            return (0..<count).map { index in
                (min(length - size, Int((Double(index) * Double(size) * (1 - overlap)).rounded())), size)
            }
        }
        var out: [CGRect] = []
        for row in spans(height, max(1, rows)) {
            for column in spans(width, max(1, columns)) {
                out.append(CGRect(x: column.start, y: row.start, width: column.size, height: row.size))
            }
        }
        return out
    }

    /// Marks the mask pixels inside `region` (image pixels, origin top-left) where the
    /// segmentation `buffer`, which covers that region, reads a person. Returns how many.
    @discardableResult
    static func stamp(_ buffer: CVPixelBuffer, covering region: CGRect, threshold: UInt8,
                      into bytes: inout [UInt8], maskWidth: Int, maskHeight: Int) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let bufferWidth = CVPixelBufferGetWidth(buffer), bufferHeight = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let scale = Double(maskScale)
        let firstColumn = max(0, Int(region.minX / scale)), lastColumn = min(maskWidth, Int((region.maxX / scale).rounded(.up)))
        let firstRow = max(0, Int(region.minY / scale)), lastRow = min(maskHeight, Int((region.maxY / scale).rounded(.up)))
        var hits = 0
        for maskY in firstRow..<lastRow {
            // The mask pixel's centre, in the region's own 0...1.
            let v = ((Double(maskY) + 0.5) * scale - region.minY) / region.height
            guard v >= 0, v < 1 else { continue }
            let bufferY = min(bufferHeight - 1, Int(v * Double(bufferHeight)))
            for maskX in firstColumn..<lastColumn {
                let u = ((Double(maskX) + 0.5) * scale - region.minX) / region.width
                guard u >= 0, u < 1 else { continue }
                let bufferX = min(bufferWidth - 1, Int(u * Double(bufferWidth)))
                if pixels[bufferY * stride + bufferX] >= threshold {
                    if bytes[maskY * maskWidth + maskX] == 0 { hits += 1 }
                    bytes[maskY * maskWidth + maskX] = 255
                }
            }
        }
        return hits
    }

    /// Fills a Vision box (normalized, origin bottom-left) grown by `padding` of its size on
    /// every side, clipped to the mask (origin top-left).
    static func fill(normalizedBox box: CGRect, padding: Double, into bytes: inout [UInt8],
                     maskWidth: Int, maskHeight: Int) {
        let padX = box.width * padding, padY = box.height * padding
        let left = max(0, box.minX - padX), right = min(1, box.maxX + padX)
        let top = max(0, 1 - box.maxY - padY), bottom = min(1, 1 - box.minY + padY)
        guard right > left, bottom > top else { return }
        let firstColumn = Int(left * Double(maskWidth)), lastColumn = min(maskWidth, Int((right * Double(maskWidth)).rounded(.up)))
        let firstRow = Int(top * Double(maskHeight)), lastRow = min(maskHeight, Int((bottom * Double(maskHeight)).rounded(.up)))
        for row in firstRow..<lastRow {
            for column in firstColumn..<lastColumn {
                bytes[row * maskWidth + column] = 255
            }
        }
    }
}
