import CoreGraphics
import Foundation

/// Single decoder for the pipeline's 16-bit depth PNGs.
///
/// WHY A HEURISTIC AND NOT `CGBitmapInfo`: the capture path has written its depth PNGs
/// **byte-swapped** since the beginning — a `[UInt16]` little-endian buffer handed to
/// CoreGraphics under a big-endian `bitmapInfo`, so 1000 mm lands in the file as the
/// sample value 59395. The bytes on disk are right; the sample values are not. Every
/// reader that honoured `bitmapInfo` therefore got garbage, which is why keyframe
/// occlusion has never actually run. Un-swapping the writer is a separate migration
/// (see the depth-PNG byte-order issue) because the archive would have to be rewritten.
///
/// Face depth PNGs (`FaceDepthRender.encodePNG`) declare `byteOrder16Little` correctly and
/// are NOT swapped, so a fixed rule cannot serve both. The plausible-range vote below
/// reads either correctly: real depth is metres-scale millimetres, and the wrong
/// interpretation scatters uniformly across the 16-bit range, so the two never tie in
/// practice (measured: 100% vs 15% on a capture frame).
enum DepthPNG {
    /// Depth is in millimetres and 0 means "no data"; anything outside this is nonsense
    /// for an indoor scan and votes against the interpretation that produced it.
    private static let plausibleRange: ClosedRange<UInt16> = 100...20000

    /// True when the raw byte stream must be read little-endian to recover millimetres.
    /// Sampled, not exhaustive — a few thousand pixels settle it decisively.
    static func needsLittleEndianByteStream(_ image: CGImage) -> Bool {
        guard image.bitsPerComponent == 16,
              let data = image.dataProvider?.data as Data? else { return false }
        let bytesPerRow = image.bytesPerRow
        let width = image.width, height = image.height
        guard data.count >= bytesPerRow * height else { return false }
        let stride = max(1, (width * height) / 4096)
        var littleVotes = 0, bigVotes = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var index = 0
            while index < width * height {
                let row = index / width, column = index % width
                let first = UInt16(base[row * bytesPerRow + column * 2])
                let second = UInt16(base[row * bytesPerRow + column * 2 + 1])
                let little = (second << 8) | first
                let big = (first << 8) | second
                if plausibleRange.contains(little) { littleVotes += 1 }
                if plausibleRange.contains(big) { bigVotes += 1 }
                index += stride
            }
        }
        return littleVotes > bigVotes
    }

    /// Millimetre samples, byte order resolved. 0 = no data, the pipeline's contract.
    static func millimetres(from image: CGImage) -> (values: [UInt16], width: Int, height: Int)? {
        guard image.bitsPerComponent == 16,
              let data = image.dataProvider?.data as Data? else { return nil }
        let width = image.width, height = image.height
        let bytesPerRow = image.bytesPerRow
        guard data.count >= bytesPerRow * height else { return nil }
        let little = needsLittleEndianByteStream(image)
        var out = [UInt16](repeating: 0, count: width * height)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for row in 0..<height {
                let rowBase = row * bytesPerRow
                for column in 0..<width {
                    let first = UInt16(base[rowBase + column * 2])
                    let second = UInt16(base[rowBase + column * 2 + 1])
                    out[row * width + column] = little ? (second << 8) | first : (first << 8) | second
                }
            }
        }
        return (out, width, height)
    }
}
