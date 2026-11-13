import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Finds the people in an upright photo for the privacy blur, as one mask: 8-bit, 255 where a
/// person is, a quarter of the photo's size on each side (docs/PRIVACY.md, "Focus Scan Stills").
///
/// Two kinds of Vision model look at the photo, and a person is what a detector finds:
/// - Vision's body detectors (whole body and upper body) and face detector, over the whole photo
///   and again on overlapping tiles, where a person farther away fills more of what the detector
///   sees (360° stills get the same from their cube faces). Every box is masked, padded.
/// - Vision's person segmentation over the whole photo, which outlines a near person more closely
///   than a box does. A segmented region is masked when it touches a box; one that touches none
///   is dropped, and logged.
///
/// Why segmentation needs a box here, when the 360° pass uses it as given (EquirectPrivacyBlur):
/// it is a portrait matte, and it fails both ways on these photos. It misses people in the
/// background: on a 2026-11-13 room scan of a lounge it found nobody in five photos with people
/// seated in view. And on a photo with nobody in it, it outlines whatever the photo is of: on a
/// 2026-11-13 focus scan of an empty office it masked the plant being scanned, the table and the
/// sofa in 170 of 231 stills, which on a focus scan is the subject in most stills, not texture
/// that other stills recover. Run on tiles it did both more. The detectors found nothing in any
/// of those 231 stills, and on the lounge and office room scans they found every person the
/// segmentation found, plus one it missed.
///
/// Every request must succeed; one that fails fails the whole check (fail closed). Self-contained
/// (no app types), so it can be run on a Mac against exported photos.
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
    }

    struct Failure: Error, Sendable {
        let message: String
    }

    /// What one check did, for the perf log: where the time went, in milliseconds, and what it found.
    struct Report: Sendable {
        /// The whole photo: segmentation and the detectors, one Vision pass.
        var whole = 0.0
        /// The detectors on the tiles: each tile's crop and its Vision pass.
        var tiles = 0.0
        /// Combining the results into one mask, on the CPU.
        var combine = 0.0
        var total: Double { whole + tiles + combine }
        /// What found people, and the segmentation dropped for touching no box.
        var summary = ""
    }

    /// A mask pixel covers this many photo pixels on a side.
    static let maskScale = 4

    /// The person mask of `image` (upright), nil when nothing finds a person.
    static func mask(upright image: CGImage, settings: Settings) -> Result<Mask?, Failure> {
        var report = Report()
        return mask(upright: image, settings: settings, report: &report)
    }

    /// The same, recording where the time went and what was found in `report`.
    static func mask(upright image: CGImage, settings: Settings, report: inout Report) -> Result<Mask?, Failure> {
        let width = image.width, height = image.height
        let maskWidth = max(1, width / maskScale), maskHeight = max(1, height / maskScale)
        var boxes = [UInt8](repeating: 0, count: maskWidth * maskHeight)
        var segmentation = boxes
        var started = DispatchTime.now().uptimeNanoseconds
        func lap() -> Double {
            let now = DispatchTime.now().uptimeNanoseconds
            defer { started = now }
            return Double(now - started) / 1_000_000
        }

        // The whole photo: segmentation and the detectors share one handler.
        let whole = segmentationRequest()
        let wholeDetectors = Detectors()
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([whole] + wholeDetectors.requests)
        } catch {
            return .failure(Failure(message: "Vision person check failed: \(error.localizedDescription)"))
        }
        guard let wholeBuffer = whole.results?.first?.pixelBuffer else {
            return .failure(Failure(message: "Vision returned no segmentation mask"))
        }
        report.whole += lap()
        stamp(wholeBuffer, covering: CGRect(x: 0, y: 0, width: width, height: height), threshold: settings.maskThreshold,
              into: &segmentation, maskWidth: maskWidth, maskHeight: maskHeight)
        let wholeBoxes = wholeDetectors.boxes
        for box in wholeBoxes.bodies + wholeBoxes.faces {
            fill(normalizedBox: box, padding: settings.boxPadding, into: &boxes, maskWidth: maskWidth, maskHeight: maskHeight)
        }
        report.combine += lap()

        // The detectors again on overlapping tiles.
        var tileBodies = 0, tileFaces = 0
        for tile in tiles(width: width, height: height, columns: settings.tileColumns,
                          rows: settings.tileRows, overlap: settings.tileOverlap) {
            guard let crop = image.cropping(to: tile) else {
                return .failure(Failure(message: "tile crop failed"))
            }
            let detectors = Detectors()
            do {
                try VNImageRequestHandler(cgImage: crop, options: [:]).perform(detectors.requests)
            } catch {
                return .failure(Failure(message: "Vision tile detection failed: \(error.localizedDescription)"))
            }
            report.tiles += lap()
            let found = detectors.boxes
            tileBodies += found.bodies.count
            tileFaces += found.faces.count
            for box in found.bodies + found.faces {
                fill(normalizedBox: photoBox(box, inTile: tile, width: width, height: height), padding: settings.boxPadding,
                     into: &boxes, maskWidth: maskWidth, maskHeight: maskHeight)
            }
            report.combine += lap()
        }

        // Segmentation that touches a box.
        let regions = keepTouching(segmentation, boxes: boxes, width: maskWidth, height: maskHeight)
        var bytes = boxes
        for index in bytes.indices where regions.kept[index] != 0 { bytes[index] = 255 }
        report.combine += lap()

        report.summary = summary(bodies: (wholeBoxes.bodies.count, tileBodies), faces: (wholeBoxes.faces.count, tileFaces),
                                 regions: regions, maskPixels: bytes.count)
        guard bytes.contains(where: { $0 != 0 }) else { return .success(nil) }
        return .success(Mask(bytes: bytes, width: maskWidth, height: maskHeight))
    }

    /// What found people, for the log: box counts (whole photo, tiles), kept segmentation, and the
    /// segmentation dropped for touching no box.
    private static func summary(bodies: (whole: Int, tiles: Int), faces: (whole: Int, tiles: Int),
                                regions: Regions, maskPixels: Int) -> String {
        var found: [String] = []
        if bodies.whole + bodies.tiles > 0 { found.append("body boxes \(bodies.whole) + \(bodies.tiles) in tiles") }
        if faces.whole + faces.tiles > 0 { found.append("faces \(faces.whole) + \(faces.tiles) in tiles") }
        if regions.keptRegions > 0 { found.append("segmentation \(regions.keptRegions) regions") }
        var summary = found.isEmpty ? "no person" : found.joined(separator: ", ")
        if regions.droppedRegions > 0 {
            summary += String(format: "; segmentation dropped, no box: %d regions, %.1f%% of the photo",
                              regions.droppedRegions, Double(regions.droppedPixels) * 100 / Double(max(1, maskPixels)))
        }
        return summary
    }

    private static func segmentationRequest() -> VNGeneratePersonSegmentationRequest {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }

    /// The body (whole and upper) and face detectors for one image.
    private struct Detectors {
        let bodies: VNDetectHumanRectanglesRequest
        let upperBodies: VNDetectHumanRectanglesRequest
        let faces = VNDetectFaceRectanglesRequest()

        init() {
            bodies = VNDetectHumanRectanglesRequest()
            bodies.upperBodyOnly = false
            upperBodies = VNDetectHumanRectanglesRequest()
            upperBodies.upperBodyOnly = true
        }

        var requests: [VNRequest] { [bodies, upperBodies, faces] }

        /// What they found, as Vision boxes (normalized, origin bottom-left).
        var boxes: (bodies: [CGRect], faces: [CGRect]) {
            ((bodies.results ?? []).map(\.boundingBox) + (upperBodies.results ?? []).map(\.boundingBox),
             (faces.results ?? []).map(\.boundingBox))
        }
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

    /// A Vision box found in `tile` (normalized to the tile, origin bottom-left) as a box of the
    /// whole `width` x `height` photo (normalized, origin bottom-left). The tile is in photo
    /// pixels, origin top-left.
    static func photoBox(_ box: CGRect, inTile tile: CGRect, width: Int, height: Int) -> CGRect {
        let photoWidth = Double(width), photoHeight = Double(height)
        return CGRect(x: (tile.minX + box.minX * tile.width) / photoWidth,
                      y: (photoHeight - tile.maxY + box.minY * tile.height) / photoHeight,
                      width: box.width * tile.width / photoWidth,
                      height: box.height * tile.height / photoHeight)
    }

    /// Segmentation sorted by whether it touches a box.
    struct Regions: Sendable {
        /// The regions that touch a box, as a mask.
        var kept: [UInt8]
        var keptRegions = 0
        var droppedRegions = 0
        var droppedPixels = 0
    }

    /// The regions of `segmentation` (4-connected) that touch a pixel of `boxes`, both masks
    /// `width` x `height`, and how many regions and pixels were dropped.
    static func keepTouching(_ segmentation: [UInt8], boxes: [UInt8], width: Int, height: Int) -> Regions {
        var out = Regions(kept: [UInt8](repeating: 0, count: segmentation.count))
        var seen = [Bool](repeating: false, count: segmentation.count)
        var region: [Int] = [], stack: [Int] = []
        for start in segmentation.indices where segmentation[start] != 0 && !seen[start] {
            region.removeAll(keepingCapacity: true)
            stack.append(start)
            seen[start] = true
            var touches = false
            while let index = stack.popLast() {
                region.append(index)
                if boxes[index] != 0 { touches = true }
                let column = index % width, row = index / width
                for (nextColumn, nextRow) in [(column - 1, row), (column + 1, row), (column, row - 1), (column, row + 1)]
                where nextColumn >= 0 && nextRow >= 0 && nextColumn < width && nextRow < height {
                    let neighbour = nextRow * width + nextColumn
                    if segmentation[neighbour] != 0 && !seen[neighbour] {
                        seen[neighbour] = true
                        stack.append(neighbour)
                    }
                }
            }
            if touches {
                out.keptRegions += 1
                for index in region { out.kept[index] = 255 }
            } else {
                out.droppedRegions += 1
                out.droppedPixels += region.count
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
