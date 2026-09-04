import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Single decoder for the pipeline's 16-bit depth PNGs.
///
/// WHY A HEURISTIC AND NOT `CGBitmapInfo`: the capture path has written its depth PNGs
/// **byte-swapped** since the beginning — a `[UInt16]` little-endian buffer handed to
/// CoreGraphics under a big-endian `bitmapInfo`, so 1000 mm lands in the file as the
/// sample value 59395. The bytes on disk are right; the sample values are not. Every
/// reader that honoured `bitmapInfo` therefore got garbage, which is why keyframe
/// occlusion has never actually run. The writer was fixed in #93; scans captured before
/// it remain swapped on disk, so this reader stays era-tolerant rather than rewriting them.
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

    /// Writes 16-bit greyscale millimetres with the byte order **declared correctly**, so
    /// the sample values on disk are the values a spec-conforming reader gets back.
    ///
    /// This is what `depthMapToPNG16` got wrong before #93: it handed CoreGraphics a
    /// host-order (little-endian) `[UInt16]` under `CGBitmapInfo(rawValue: 0)`, which is
    /// `byteOrderDefault` — big-endian for 16-bit components — so every sample was encoded
    /// byte-swapped. Declaring `byteOrder16Little` for a little-endian buffer is what makes
    /// the two agree. Matches `FaceDepthRender.encodePNG`, generalised off square rasters.
    static func encode(_ values: [UInt16], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, values.count == width * height else { return nil }
        var bytes = values
        return bytes.withUnsafeMutableBytes { raw -> Data? in
            guard let base = raw.baseAddress,
                  let provider = CGDataProvider(dataInfo: nil, data: base,
                                                size: raw.count, releaseData: { _, _, _ in }),
                  let image = CGImage(width: width, height: height,
                                      bitsPerComponent: 16, bitsPerPixel: 16,
                                      bytesPerRow: width * 2,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGBitmapInfo.byteOrder16Little.union(
                                          CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)),
                                      provider: provider, decode: nil,
                                      shouldInterpolate: false, intent: .defaultIntent)
            else { return nil }
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                out, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return out as Data
        }
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
