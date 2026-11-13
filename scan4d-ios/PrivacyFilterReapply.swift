import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

/// Applying the Privacy Filter to a scan captured with it off (docs/PRIVACY.md, "Applying the
/// filter after capture"). One-way: the scan is filtered from then on. Its original photos stay on
/// the device untouched, since blur happens at export, as it does for every scan.
///
/// A room scan gets what capture would have written with the filter on, so the existing export,
/// colorize and sync paths treat it exactly like one captured filtered:
/// - `privacy_filter: true` in its metadata, plus `privacy_filter_applied_after_capture` (when);
/// - a person mask for every photo that has none, from the person check focus stills get
///   (`PersonCheck`; `ScanPostprocessor.Step.privacyMasks`, run like any Process step, before
///   colorize, and holding the scan's upload until it is done);
/// - a recolor, since its mesh colors were sampled with people in view.
/// A focus scan only needs the flag (`setup.privacyFilter` in its manifest): its export already
/// checks every still with Vision. 360° stills and glasses frames are likewise checked at export.
///
/// The scan's files change, so its sync bundle's version does: the Scan4D server asks for the new
/// version and the phone sends it, blurred, replacing the copy the server held.
enum PrivacyFilterReapply {

    /// Metadata key recording when the filter was applied after capture (ISO 8601). Its presence
    /// is what makes missing masks a pending step: scans captured with the filter on also lack
    /// masks for their first frames (the stencil warms up), and those keep the export's fallback.
    static let appliedAfterCaptureKey = "privacy_filter_applied_after_capture"

    /// Metadata key for the person check the generated masks came from, and its current
    /// version. Masks from an older check are made again: 1 was Vision's person segmentation
    /// over the whole photo only, which missed people in the background; 2 is `PersonCheck`.
    static let masksVersionKey = "privacy_masks_version"
    static let masksVersion = 2

    // MARK: Which scans

    /// Captured with the Privacy Filter off and not filtered since: the scans the actions are
    /// offered for. A scan whose state can't be read is not offered. Reads the disk: off main.
    nonisolated static func isUnfiltered(record: ControlPlaneManifest.PrivacyRecord) -> Bool {
        ControlPlaneManifest.readPrivacyFilter(record) == false
    }

    static func record(for scan: CapturedScan) -> ControlPlaneManifest.PrivacyRecord {
        scan.isFocusScan ? .focus(captureFolder: scan.focusCaptureURL) : .room(rawData: scan.rawDataPath)
    }

    // MARK: Applying

    /// Applies the filter to `scans` (any that are already filtered are skipped): marks each, then
    /// runs the room scans' masks and recolor through Process, and asks for a sync so the server
    /// learns of the new versions. `completion` fires on main when Process is done. Returns the
    /// scans marked: only those are filtered from now on. Main thread.
    @discardableResult
    static func apply(to scans: [CapturedScan], modelContext: ModelContext,
                      progress: ((CapturedScan, String?) -> Void)? = nil,
                      completion: (() -> Void)? = nil) -> [UUID] {
        let now = Date()
        var rooms: [CapturedScan] = []
        var marked: [UUID] = []
        for scan in scans {
            let ok: Bool
            if scan.isFocusScan {
                ok = markFocusManifest(captureFolder: scan.focusCaptureURL, at: now)
            } else {
                ok = markRoomMetadata(rawData: scan.rawDataPath, scanDirectory: scan.scanDirectory, at: now)
                if ok {
                    // Its colors were sampled with people in view: any export or bundle recolors
                    // first (after the masks, which Process runs before colorize).
                    scan.isColored = false
                    rooms.append(scan)
                }
            }
            if ok {
                marked.append(scan.id)
                SettledScans.forget(scan.id)
            }
        }
        guard !marked.isEmpty else {
            completion?()
            return []
        }
        try? modelContext.save()
        BundleSync.shared.filterApplied(marked)
        PerfDiag.log("[Privacy] filter applied after capture to \(marked.count) scan(s), \(rooms.count) room")
        let finish = {
            ControlPlaneSync.shared.requestSync(after: .seconds(2))
            completion?()
        }
        if rooms.isEmpty {
            finish()
        } else {
            ScanPostprocessor.run(scans: rooms, colorize: true, modelContext: modelContext,
                                  progress: progress, completion: finish)
        }
        return marked
    }

    /// Sets `privacy_filter: true` and the applied-after-capture time in a room scan's metadata
    /// (`raw_data/scan4d_metadata.json`, which every reader tries first, and the copy at the scan's
    /// top level when there is one), keeping every other key. False when there is none to update.
    static func markRoomMetadata(rawData: URL, scanDirectory: URL, at date: Date) -> Bool {
        let stamp = ISO8601DateFormatter().string(from: date)
        return updateRoomMetadata(rawData: rawData, scanDirectory: scanDirectory) { meta in
            meta["privacy_filter"] = true
            meta[appliedAfterCaptureKey] = stamp
        }
    }

    /// Applies `change` to a room scan's metadata, both copies, keeping every other key. False
    /// when there is none to update.
    @discardableResult
    static func updateRoomMetadata(rawData: URL, scanDirectory: URL, _ change: (inout [String: Any]) -> Void) -> Bool {
        var updated = false
        for url in [rawData.appendingPathComponent("scan4d_metadata.json"),
                    scanDirectory.appendingPathComponent("scan4d_metadata.json")] {
            guard let data = try? Data(contentsOf: url),
                  var meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            change(&meta)
            guard let out = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]),
                  (try? out.write(to: url, options: .atomic)) != nil else { continue }
            updated = true
        }
        return updated
    }

    /// Sets `setup.privacyFilter: true` and the applied-after-capture time in a focus scan's
    /// capture manifest, keeping every other key.
    static func markFocusManifest(captureFolder: URL, at date: Date) -> Bool {
        let url = captureFolder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              var manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        var setup = manifest["setup"] as? [String: Any] ?? [:]
        setup["privacyFilter"] = true
        setup["privacyFilterAppliedAfterCapture"] = ISO8601DateFormatter().string(from: date)
        manifest["setup"] = setup
        guard let out = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else {
            return false
        }
        return (try? out.write(to: url, options: .atomic)) != nil
    }

    // MARK: Masks (the Process step)

    /// The room scan's photos (`images/frame_*.jpg`) still waiting for a generated mask: the
    /// filter was applied after capture and the photo has no `masks/frame_*.png`, or the masks
    /// came from an older person check (every photo then). Empty otherwise.
    static func framesNeedingMasks(rawData: URL) -> [String] {
        guard let meta = rawMetadata(rawData), meta[appliedAfterCaptureKey] != nil else { return [] }
        let current = masksAreCurrent(meta)
        let fm = FileManager.default
        let images = (try? fm.contentsOfDirectory(atPath: rawData.appendingPathComponent("images").path)) ?? []
        let masks = Set((try? fm.contentsOfDirectory(atPath: rawData.appendingPathComponent("masks").path)) ?? [])
        return images
            .filter { $0.hasPrefix("frame_") && $0.hasSuffix(".jpg") }
            .map { String($0.dropLast(4)) }
            .filter { !current || !masks.contains($0 + ".png") }
            .sorted()
    }

    static func masksPending(rawData: URL) -> Bool {
        !framesNeedingMasks(rawData: rawData).isEmpty
    }

    private static func rawMetadata(_ rawData: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: rawData.appendingPathComponent("scan4d_metadata.json")) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Masks recorded as made by the current person check. None recorded: the first check.
    private static func masksAreCurrent(_ meta: [String: Any]) -> Bool {
        (meta[masksVersionKey] as? Int ?? 1) >= masksVersion
    }

    /// Writes a mask for every photo waiting for one, in the format capture writes (an 8-bit gray
    /// PNG, people white, at any size: the export and colorize scale it to the frame). Masks from
    /// an older person check are removed first, and the current version recorded, so a run cut
    /// short picks up where it stopped. Every mask in such a scan was generated: one captured
    /// with the filter off has none of its own. Returns how many were written. Runs on Process's
    /// queue.
    @discardableResult
    static func generateMasks(rawData: URL, scanDirectory: URL, report: ((Int, Int) -> Void)? = nil) -> Int {
        var frames = framesNeedingMasks(rawData: rawData)
        guard !frames.isEmpty else { return 0 }
        let fm = FileManager.default
        let imagesDir = rawData.appendingPathComponent("images")
        let masksDir = rawData.appendingPathComponent("masks")
        if let meta = rawMetadata(rawData), !masksAreCurrent(meta) {
            let stale = ((try? fm.contentsOfDirectory(at: masksDir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "png" }
            stale.forEach { try? fm.removeItem(at: $0) }
            updateRoomMetadata(rawData: rawData, scanDirectory: scanDirectory) { $0[masksVersionKey] = masksVersion }
            if !stale.isEmpty {
                PerfDiag.log("[Privacy] \(stale.count) masks from an older person check removed, made again")
            }
            frames = framesNeedingMasks(rawData: rawData)
        }
        try? fm.createDirectory(at: masksDir, withIntermediateDirectories: true)
        var written = 0
        var failed = 0
        let started = DispatchTime.now().uptimeNanoseconds
        for (index, stem) in frames.enumerated() {
            report?(index + 1, frames.count)
            autoreleasepool {
                let jpeg = try? Data(contentsOf: imagesDir.appendingPathComponent(stem + ".jpg"))
                let (png, ok) = maskPNG(forFrameJPEG: jpeg)
                if !ok { failed += 1 }
                if let png, (try? png.write(to: masksDir.appendingPathComponent(stem + ".png"), options: .atomic)) != nil {
                    written += 1
                }
            }
        }
        PerfDiag.log({
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            return String(format: "[Privacy] masks generated: %d/%d, %d failed closed (whole frame masked), in %.1f s (%.0f ms a photo)",
                          written, frames.count, failed, seconds, seconds * 1000 / Double(frames.count))
        }())
        return written
    }

    /// The mask for one stored frame, and whether the person check ran. A frame the check can't
    /// read fails CLOSED: its mask covers the whole frame, so the export pixelates all of it, its
    /// depth is zeroed and colorize takes no color from it.
    static func maskPNG(forFrameJPEG jpeg: Data?) -> (png: Data?, checked: Bool) {
        guard let jpeg else { return (filledMask(255), false) }
        switch FocusStillPrivacy.sensorPersonMask(jpeg: jpeg) {
        case .success(let mask?):
            return (pngData(mask) ?? filledMask(255), true)
        case .success(nil):
            return (filledMask(0), true)
        case .failure:
            return (filledMask(255), false)
        }
    }

    /// A uniform mask: 0 = no person anywhere, 255 = the whole frame. Capture's size and aspect.
    static func filledMask(_ value: UInt8, width: Int = 256, height: Int = 192) -> Data? {
        let bytes = [UInt8](repeating: value, count: width * height)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        return pngData(image)
    }

    /// PNG bytes of a gray image, kept 8-bit gray (colorize reads masks one byte per pixel).
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
