import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import os
import UIKit

// MARK: - Focus scan export (docs/design/capture-modes.md)

extension ScanExportManager {

    private static let focusLog = Logger(subsystem: "org.arenaxr.scan4d", category: "export")

    /// A focus scan's one export: its still-capture folder as captured (photos/, photo_depth/,
    /// photo_confidence/, photos.csv, frames.csv, IMU logs, events.log, manifest.json,
    /// world_map_registration.json) with `focus_region.json` beside them, zipped under one folder
    /// named after the export.
    ///
    /// Privacy (CONTRIBUTING, the invariant): with the privacy filter on for this capture
    /// (`manifest.json` setup.privacyFilter; unreadable or missing reads as on), every still is
    /// checked for people, and the check fails CLOSED per still: a still that cannot be verified
    /// or blurred is left out (its depth and confidence with it) and listed in
    /// `privacy_excluded.json`. A blurred still also has the person zeroed in its depth map.
    static func prepareFocusExport(filename: String, scanDir: URL,
                                   phase: ((ExportPhase) -> Void)? = nil) -> URL? {
        let fm = FileManager.default
        let source = scanDir.appendingPathComponent(AppConstants.focusCaptureFolder)
        let parent = fm.temporaryDirectory.appendingPathComponent("staging_\(UUID().uuidString)")
        let staging = parent.appendingPathComponent((filename as NSString).deletingPathExtension)
        defer { try? fm.removeItem(at: parent) }
        phase?(ExportPhase("Copying stills…"))
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: staging)
        } catch {
            focusLog.error("focus export: staging failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let regionFile = scanDir.appendingPathComponent(AppConstants.focusRegionFilename)
        if fm.fileExists(atPath: regionFile.path) {
            try? fm.copyItem(at: regionFile, to: staging.appendingPathComponent(AppConstants.focusRegionFilename))
        }
        if focusPrivacyFilterWasOn(captureDir: source) {
            runFocusPrivacyPass(stagingDir: staging, phase: phase)
        } else {
            focusLog.notice("focus export: stills staged unblurred, privacy filter was off for this capture")
        }

        phase?(ExportPhase("Zipping…"))
        let zipURL = fm.temporaryDirectory.appendingPathComponent(filename)
        try? fm.removeItem(at: zipURL)
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &error) { temp in
            try? fm.copyItem(at: temp, to: zipURL)
        }
        guard error == nil, fm.fileExists(atPath: zipURL.path) else {
            focusLog.error("focus export: zip failed: \(error?.localizedDescription ?? "no archive", privacy: .public)")
            return nil
        }
        return zipURL
    }

    /// The capture's privacy filter state from its manifest; anything unreadable reads as on.
    static func focusPrivacyFilterWasOn(captureDir: URL) -> Bool {
        guard let data = try? Data(contentsOf: captureDir.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let setup = manifest["setup"] as? [String: Any],
              let flag = setup["privacyFilter"] as? Bool else { return true }
        return flag
    }

    private static func runFocusPrivacyPass(stagingDir: URL, phase: ((ExportPhase) -> Void)?) {
        let fm = FileManager.default
        let photosDir = stagingDir.appendingPathComponent("photos")
        let depthDir = stagingDir.appendingPathComponent("photo_depth")
        let confidenceDir = stagingDir.appendingPathComponent("photo_confidence")
        let stills = ((try? fm.contentsOfDirectory(at: photosDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var clean = 0, blurred = 0
        var excluded: [String] = []
        for (index, url) in stills.enumerated() {
            phase?(.counted("Privacy check", index + 1, of: stills.count))
            // Per-still pool: each check decodes a working copy and, for a blur, renders the full
            // 12MP still through autoreleased CF/CI transients.
            autoreleasepool {
                let stem = url.deletingPathExtension().lastPathComponent
                let outcome: FocusStillPrivacy.Outcome
                if let data = try? Data(contentsOf: url) {
                    outcome = FocusStillPrivacy.process(jpeg: data)
                } else {
                    outcome = .failed("could not read the staged still")
                }
                switch outcome {
                case .clean:
                    clean += 1
                case .blurred(let jpeg, let mask):
                    if (try? jpeg.write(to: url, options: .atomic)) != nil {
                        _ = maskStagedDepth(named: stem, maskCGImage: mask, depthDir: depthDir)
                        blurred += 1
                    } else {
                        excluded.append(stem)
                    }
                case .failed(let reason):
                    focusLog.error("focus still \(stem, privacy: .public) failed the person check (\(reason, privacy: .public)): excluded")
                    excluded.append(stem)
                }
                if excluded.last == stem {
                    try? fm.removeItem(at: url)
                    try? fm.removeItem(at: depthDir.appendingPathComponent("\(stem).png"))
                    try? fm.removeItem(at: confidenceDir.appendingPathComponent("\(stem).png"))
                }
            }
        }
        if !excluded.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: ["excluded_stills": excluded,
                                                                   "reason": "privacy filter on; the person check could not verify or blur these"],
                                                  options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: stagingDir.appendingPathComponent("privacy_excluded.json"))
        }
        focusLog.notice("focus privacy pass: \(clean, privacy: .public) clean, \(blurred, privacy: .public) blurred, \(excluded.count, privacy: .public) excluded of \(stills.count, privacy: .public)")
    }
}

/// Person check for one focus still (12MP, sensor landscape). Vision runs on a small upright copy:
/// the capture view is portrait-locked, so people stand along the sensor image's width, and the
/// model is trained on upright people. The mask comes back to the sensor's orientation for the blur.
/// Same model policy as `EquirectPrivacyBlur` (it reuses its per-image `personMask`): Vision's
/// answer stands, any person pixel means blur.
enum FocusStillPrivacy {

    enum Outcome {
        /// No person: the original bytes ship (EXIF intact).
        case clean
        /// The re-encoded still, and the person mask in sensor orientation (for the depth map).
        case blurred(Data, CGImage)
        /// Could not verify: the still must not ship.
        case failed(String)
    }

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func process(jpeg data: Data) -> Outcome {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return .failed("decode failed") }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: AppConstants.focusPrivacyWorkingMaxPixel,
            kCGImageSourceCreateThumbnailWithTransform: false
        ]
        guard let working = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .failed("working decode failed")
        }
        // Sensor landscape to the portrait the operator held: the capture view's fixed map.
        let upright = CIImage(cgImage: working).oriented(.right)
        guard let uprightImage = context.createCGImage(upright, from: upright.extent) else {
            return .failed("upright render failed")
        }
        switch EquirectPrivacyBlur.personMask(for: uprightImage) {
        case .failure(let error):
            return .failed(error.message)
        case .success(nil):
            return .clean
        case .success(let mask?):
            guard let sensorMask = sensorOrientationMask(mask) else { return .failed("mask rotation failed") }
            guard let blurred = pixelate(jpeg: data, mask: sensorMask) else { return .failed("blur render failed") }
            return .blurred(blurred, sensorMask)
        }
    }

    /// The upright (portrait) mask back in the sensor's landscape orientation, as an 8-bit gray
    /// image. `.oriented(.right)` sends sensor pixel (xs, ys) to upright pixel (Wu - 1 - ys, xs),
    /// where Wu, the upright width, is the sensor height.
    static func sensorOrientationMask(_ mask: EquirectPrivacyBlur.FaceMask) -> CGImage? {
        let uprightWidth = mask.width, uprightHeight = mask.height
        let width = uprightHeight, height = uprightWidth
        var bytes = [UInt8](repeating: 0, count: width * height)
        for ys in 0..<height {
            for xs in 0..<width {
                bytes[ys * width + xs] = mask.bytes[xs * uprightWidth + (uprightWidth - 1 - ys)]
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Pixelates the masked region of the full-resolution still and re-encodes it.
    private static func pixelate(jpeg data: Data, mask: CGImage) -> Data? {
        guard let image = CIImage(data: data) else { return nil }
        let extent = image.extent
        let maskImage = CIImage(cgImage: mask)
        let scaled = maskImage.transformed(by: CGAffineTransform(scaleX: extent.width / maskImage.extent.width,
                                                                 y: extent.height / maskImage.extent.height))
        let dilate = CIFilter.morphologyMaximum()
        dilate.inputImage = scaled
        dilate.radius = AppConstants.focusPrivacyDilateRadiusPx
        let grown = (dilate.outputImage ?? scaled).cropped(to: extent)
        let pixellate = CIFilter.pixellate()
        pixellate.inputImage = image
        pixellate.scale = AppConstants.focusPrivacyPixelateScale
        guard let pixelated = pixellate.outputImage else { return nil }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = pixelated
        blend.backgroundImage = image
        blend.maskImage = grown
        guard let output = blend.outputImage?.cropped(to: extent),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let quality = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: AppConstants.arStillJPEGQuality]
        return context.jpegRepresentation(of: output, colorSpace: space, options: quality)
    }
}
