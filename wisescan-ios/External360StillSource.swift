import Foundation
import ImageIO
import Observation
import simd

enum External360CameraModel: String, CaseIterable, Identifiable {
    case insta360X6 = "INSTA360 X6"
    case insta360X4 = "INSTA360 X4"
    case insta360X3 = "INSTA360 X3"
    case generic = "External Equirect Camera"

    var id: String { rawValue }
}

@Observable
@MainActor
final class External360StillSource: ScanStillSource {
    static let shared = External360StillSource()

    struct PendingImportTicket {
        let sequence: Int
        let sidecarURL: URL
    }

    struct ImportOutcome {
        let imported: Int
        let remaining: Int
        let ignored: Int
        let message: String
    }

    let kind: StillSourceKind = .deferredExternal
    private(set) var scanStillCount = 0
    private(set) var scanStillPositions: [SIMD3<Float>] = []
    private(set) var swayedStillCount = 0
    private(set) var cameraUnresponsive = false

    var selectedModel: External360CameraModel {
        get {
            External360CameraModel(rawValue: UserDefaults.standard.string(forKey: AppConstants.Key.external360CameraModel)
                                   ?? AppConstants.external360CameraModel) ?? .insta360X6
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: AppConstants.Key.external360CameraModel)
        }
    }

    var displayName: String { selectedModel.rawValue }
    var isAvailableForCapture: Bool { true }

    private init() {}

    func beginScanStillSession(rawDataDir: URL? = nil) {
        scanStillCount = 0
        swayedStillCount = 0
        cameraUnresponsive = false
        scanStillPositions.removeAll()
        if let dir = rawDataDir?.appendingPathComponent("equirect_stills"),
           let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            scanStillCount = files.compactMap { file -> Int? in
                guard file.hasPrefix("still_"), file.hasSuffix(".JPG") || file.hasSuffix(".json") else { return nil }
                return Int(file.dropFirst(6).prefix(4))
            }.max() ?? 0
        }
    }

    func endScanStillSession() {
        scanStillCount = 0
        swayedStillCount = 0
        cameraUnresponsive = false
        scanStillPositions.removeAll()
    }

    func verifyReadyForCapture() async -> Bool { true }

    @discardableResult
    func captureStillForScan(phoneTransform: simd_float4x4,
                             timestamp: TimeInterval,
                             into rawDataDir: URL,
                             samplePose: (() -> simd_float4x4?)? = nil) -> Bool {
        let seq = scanStillCount + 1
        let input = ThetaCameraManager.ScanStillInput(
            sequence: seq,
            phoneTransform: phoneTransform,
            frameTimestamp: timestamp,
            capturedAtEpochMs: Int64(Date().timeIntervalSince1970 * 1000),
            sourceURL: Self.pendingImportURL(sequence: seq),
            sourceModel: selectedModel.rawValue,
            format: nil,
            triggerMs: 0,
            triggerMotionM: nil,
            triggerMotionDeg: nil,
            exposureMotionM: nil,
            exposureMotionDeg: nil,
            shutterPath: "manual-import",
            shutterAckMs: nil,
            cameraClockOffsetMs: nil,
            cameraClockOffsetUncMs: nil,
            exposureWindowMs: nil,
            motionSamples: nil
        )
        do {
            try ThetaCameraManager.writeScanStillSidecar(input: input, into: rawDataDir)
            scanStillCount = seq
            scanStillPositions.append(SIMD3<Float>(phoneTransform.columns.3.x,
                                                   phoneTransform.columns.3.y,
                                                   phoneTransform.columns.3.z))
            return true
        } catch {
            return false
        }
    }

    nonisolated static func pendingImportURL(sequence: Int) -> String {
        String(format: "import://pending/still_%04d.jpg", sequence)
    }

    nonisolated static func isManualImportPlaceholder(_ url: String) -> Bool {
        url.hasPrefix("import://pending/")
    }

    nonisolated static func pendingImportTickets(rawDataPath: URL) -> [PendingImportTicket] {
        let dir = rawDataPath.appendingPathComponent("equirect_stills")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return files.compactMap { file in
            guard file.hasPrefix("still_"), file.hasSuffix(".json") else { return nil }
            let sidecarURL = dir.appendingPathComponent(file)
            let jpgURL = dir.appendingPathComponent(String(file.dropLast(5)) + ".JPG")
            guard !FileManager.default.fileExists(atPath: jpgURL.path),
                  let data = try? Data(contentsOf: sidecarURL),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let url = obj["camera_file_url"] as? String,
                  isManualImportPlaceholder(url),
                  let sequence = obj["sequence"] as? Int else { return nil }
            return PendingImportTicket(sequence: sequence, sidecarURL: sidecarURL)
        }
        .sorted { $0.sequence < $1.sequence }
    }

    nonisolated static func hasPendingImports(rawDataPath: URL) -> Bool {
        !pendingImportTickets(rawDataPath: rawDataPath).isEmpty
    }

    nonisolated static func importPendingStills(rawDataPath: URL, from pickedURLs: [URL]) -> ImportOutcome {
        let tickets = pendingImportTickets(rawDataPath: rawDataPath)
        guard !tickets.isEmpty else {
            return ImportOutcome(imported: 0, remaining: 0, ignored: pickedURLs.count,
                                 message: "No deferred 360° stills are waiting for import.")
        }

        let candidates = pickedURLs.compactMap(loadCandidate).sorted(by: candidateLessThan)
        guard !candidates.isEmpty else {
            return ImportOutcome(imported: 0, remaining: tickets.count, ignored: pickedURLs.count,
                                 message: "No valid 2:1 equirect JPGs were selected.")
        }

        let count = min(tickets.count, candidates.count)
        let stillsDir = rawDataPath.appendingPathComponent("equirect_stills")
        var imported = 0

        for index in 0..<count {
            let ticket = tickets[index]
            let candidate = candidates[index]
            let jpgURL = stillsDir.appendingPathComponent(String(format: "still_%04d.JPG", ticket.sequence))
            guard (try? candidate.data.write(to: jpgURL, options: .atomic)) != nil else { continue }
            stampImportedImageMetadata(sidecarURL: ticket.sidecarURL, width: candidate.width, height: candidate.height)
            ThetaCameraManager.annotateExifExposure(jpegData: candidate.data, sidecarURL: ticket.sidecarURL)
            imported += 1
        }

        let remaining = max(tickets.count - imported, 0)
        let ignored = max(candidates.count - imported, 0)
        let message: String
        if imported == 0 {
            message = "No 360° stills were imported."
        } else if remaining == 0, ignored == 0 {
            message = "Imported \(imported) deferred 360° still\(imported == 1 ? "" : "s")."
        } else {
            var parts = ["Imported \(imported) deferred 360° still\(imported == 1 ? "" : "s")"]
            if remaining > 0 { parts.append("\(remaining) still\(remaining == 1 ? "" : "s") still missing") }
            if ignored > 0 { parts.append("\(ignored) extra file\(ignored == 1 ? "" : "s") ignored") }
            message = parts.joined(separator: " — ") + "."
        }
        return ImportOutcome(imported: imported, remaining: remaining, ignored: ignored, message: message)
    }

    private struct Candidate {
        let url: URL
        let data: Data
        let width: Int
        let height: Int
        let timestamp: Date?
    }

    nonisolated private static func loadCandidate(from url: URL) -> Candidate? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              height > 0,
              abs(Double(width) / Double(height) - 2.0) < 0.05
        else { return nil }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let exifTime = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
        let timestamp = exifTime.flatMap(parseExifDate)
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey])).flatMap { $0.contentModificationDate }
        return Candidate(url: url, data: data, width: width, height: height, timestamp: timestamp)
    }

    nonisolated private static func parseExifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    nonisolated private static func candidateLessThan(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        switch (lhs.timestamp, rhs.timestamp) {
        case let (l?, r?) where l != r:
            return l < r
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return lhs.url.lastPathComponent.localizedCaseInsensitiveCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
    }

    nonisolated private static func stampImportedImageMetadata(sidecarURL: URL, width: Int, height: Int) {
        guard let data = try? Data(contentsOf: sidecarURL),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        obj["width"] = width
        obj["height"] = height
        guard let out = try? JSONSerialization.data(withJSONObject: obj,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? out.write(to: sidecarURL, options: .atomic)
    }
}
