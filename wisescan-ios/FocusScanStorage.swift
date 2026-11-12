import CoreImage
import Foundation
import ImageIO
import os
import SwiftData
import UIKit

// MARK: - Filing a focus scan (docs/design/capture-modes.md)

enum FocusScanSaveError: Error, LocalizedError {
    case locationMissing
    case fileMove(String)

    var errorDescription: String? {
        switch self {
        case .locationMissing: return "The space this focus scan belongs to no longer exists."
        case .fileMove(let reason): return "Could not file the stills: \(reason)"
        }
    }
}

extension ScanFileManager {

    private static let focusLog = Logger(subsystem: "org.arenaxr.scan4d", category: "save")

    /// Files a finished still capture (`ARStillCaptureSession`'s directory) as a focus scan of
    /// `locationId`: a `CapturedScan` of kind focus, its dump moved into the scan folder as
    /// `focus_capture/`, the region beside it, and the best still as the card thumbnail. The
    /// move is a rename (the capture was staged on the same volume). On failure nothing is
    /// inserted and the capture directory stays where it was.
    // swiftlint:disable:next function_parameter_count
    func saveFocusScan(context: ModelContext, locationId: UUID, parentScanId: UUID?, region: FocusRegion,
                       captureDirectory: URL, stillCount: Int,
                       hardwareDeviceModel: String) -> Result<CapturedScan, FocusScanSaveError> {
        let descriptor = FetchDescriptor<ScanLocation>(predicate: #Predicate { $0.id == locationId })
        guard let location = try? context.fetch(descriptor).first else { return .failure(.locationMissing) }

        let number = location.scans.filter(\.isFocusScan).count + 1
        let scan = CapturedScan(name: "Focus \(number)", vertexCount: 0, faceCount: 0,
                                hardwareDeviceModel: hardwareDeviceModel)
        scan.scanKind = .focus
        scan.scanCaseRaw = ScanCase.rescanSpace.rawValue
        scan.parentScanIdRaw = parentScanId?.uuidString ?? ""
        var filed = region
        filed.locationId = location.id
        scan.focusRegion = filed
        scan.stillCount = stillCount
        // Link first: scanDirectory derives from the location's id.
        location.scans.append(scan)
        scan.location = location
        location.updatedAt = Date()
        context.insert(scan)

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: scan.scanDirectory, withIntermediateDirectories: true)
            try fm.moveItem(at: captureDirectory, to: scan.focusCaptureURL)
        } catch {
            Self.focusLog.error("saveFocusScan ABORTED moving \(captureDirectory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            context.delete(scan)
            return .failure(.fileMove(error.localizedDescription))
        }
        if let data = filed.encoded(pretty: true) {
            try? data.write(to: scan.focusRegionFileURL, options: .atomic)
        }
        if let best = FocusScanThumbnail.bestStill(in: scan.focusCaptureURL),
           let thumbnail = FocusScanThumbnail.thumbnailJPEG(from: best) {
            try? thumbnail.write(to: scan.thumbnailURL, options: .atomic)
        }
        try? context.save()
        Self.focusLog.notice("focus scan \(scan.name, privacy: .public) filed: \(stillCount, privacy: .public) stills, region \(filed.displayName, privacy: .public)")
        return .success(scan)
    }
}

/// The one photo a focus scan's card shows: sharp at capture, and the region filling a good share
/// of the frame (close enough to read, not so close it is cropped).
enum FocusScanThumbnail {

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Reads photos.csv by column name, so it follows the header whatever columns were added.
    static func bestStill(in captureDir: URL) -> URL? {
        guard let text = try? String(contentsOf: captureDir.appendingPathComponent("photos.csv"), encoding: .utf8) else {
            return firstStill(in: captureDir)
        }
        let lines = text.split(whereSeparator: \.isNewline)
        guard let header = lines.first?.split(separator: ",", omittingEmptySubsequences: false).map(String.init),
              let fileIndex = header.firstIndex(of: "file") else { return firstStill(in: captureDir) }
        let overIndex = header.firstIndex(of: "capture_over_budget")
        let smearIndex = header.firstIndex(of: "capture_gyro_smear_rad")
        let coverageIndex = header.firstIndex(of: "region_frame_coverage")
        var best: (score: Double, smear: Double, file: String)?
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fileIndex < fields.count else { continue }
            if let overIndex, overIndex < fields.count, fields[overIndex] == "1" { continue }
            let smear = smearIndex.flatMap { $0 < fields.count ? Double(fields[$0]) : nil } ?? 0
            let coverage = coverageIndex.flatMap { $0 < fields.count ? Double(fields[$0]) : nil }
            let score = coverage.map { abs($0 - AppConstants.focusThumbnailIdealCoverage) } ?? 1
            if let current = best, score > current.score || (score == current.score && smear >= current.smear) {
                continue
            }
            best = (score, smear, fields[fileIndex])
        }
        guard let file = best?.file else { return firstStill(in: captureDir) }
        let url = captureDir.appendingPathComponent(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : firstStill(in: captureDir)
    }

    private static func firstStill(in captureDir: URL) -> URL? {
        let photos = captureDir.appendingPathComponent("photos")
        return ((try? FileManager.default.contentsOfDirectory(at: photos, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .min { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A small upright JPEG of a still (stills are in the sensor's landscape orientation; the
    /// capture view is portrait-locked, so upright is `.right`).
    static func thumbnailJPEG(from still: URL) -> Data? {
        guard let source = CGImageSourceCreateWithURL(still as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: AppConstants.focusThumbnailMaxPixel,
            kCGImageSourceCreateThumbnailWithTransform: false
        ]
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let upright = CIImage(cgImage: small).oriented(.right)
        guard let image = context.createCGImage(upright, from: upright.extent) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: AppConstants.focusThumbnailJPEGQuality)
    }
}
