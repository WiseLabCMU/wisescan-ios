import UIKit
import ImageIO

/// Decodes downsampled thumbnails from disk and caches them in memory.
///
/// Scan previews/thumbnails on disk are full-resolution camera frames (multiple
/// megapixels). Decoding those at native size just to show a ~120-180pt cell wastes
/// CPU and memory on every list render/scroll. This uses ImageIO to decode directly at
/// the target size (no full-res intermediate) and caches by path + modification time, so
/// a re-colorized preview (which rewrites the file) is picked up automatically.
enum ThumbnailCache {
    nonisolated(unsafe) static let cache = NSCache<NSString, UIImage>()

    /// Returns a downsampled, cached thumbnail for `url`, or nil if the file is missing /
    /// undecodable. Runs the decode off the calling actor. `maxPixel` is in pixels.
    static func image(for url: URL, maxPixel: CGFloat = 600) async -> UIImage? {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path) else { return nil }
            let mtime = ((try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
            let key = "\(url.path)|\(Int(mtime))|\(Int(maxPixel))" as NSString
            if let cached = cache.object(forKey: key) { return cached }
            guard let image = downsample(url: url, maxPixelSize: maxPixel) else { return nil }
            cache.setObject(image, forKey: key)
            return image
        }.value
    }

    /// Decode `url` directly at a reduced size via ImageIO (avoids a full-res decode).
    private static func downsample(url: URL, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honor EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
