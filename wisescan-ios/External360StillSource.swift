import Foundation
import ImageIO
import Observation
import os
import UniformTypeIdentifiers
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
        let capturedAtEpochMs: Int64?
    }

    struct ImportOutcome {
        let imported: Int
        let remaining: Int
        let ignored: Int
        let message: String
    }

    private static let log = Logger(subsystem: "org.arenaxr.scan4d", category: "external360")
    private static let mismatchWarningThresholdMs: Int64 = 30_000
    private static let fallbackMatchCostMs: Int64 = 120_000

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
                  let sequence = intValue(obj["sequence"]) else { return nil }
            return PendingImportTicket(
                sequence: sequence,
                sidecarURL: sidecarURL,
                capturedAtEpochMs: int64Value(obj["captured_at_epoch_ms"])
            )
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
                                 message: "No stitched equirect JPEGs were selected.")
        }

        let stillsDir = rawDataPath.appendingPathComponent("equirect_stills")
        let matchPlan = matchTicketsToCandidates(tickets: tickets, candidates: candidates)
        var imported = 0
        var missingTimestamps = 0
        var largeResiduals: [Int64] = []

        for assignment in matchPlan.assignments {
            let ticket = tickets[assignment.ticketIndex]
            let candidate = candidates[assignment.candidateIndex]
            let jpgURL = stillsDir.appendingPathComponent(String(format: "still_%04d.JPG", ticket.sequence))
            guard let jpegData = readJPEGData(from: candidate.url) else { continue }
            guard (try? jpegData.write(to: jpgURL, options: .atomic)) != nil else { continue }
            stampImportedImageMetadata(sidecarURL: ticket.sidecarURL, width: candidate.width, height: candidate.height)
            ThetaCameraManager.annotateExifExposure(jpegData: jpegData, sidecarURL: ticket.sidecarURL)
            imported += 1
            if let residualMs = assignment.residualMs {
                if residualMs > mismatchWarningThresholdMs { largeResiduals.append(residualMs) }
                log.notice("Deferred 360 import still_\(ticket.sequence, privacy: .public) ← \(candidate.url.lastPathComponent, privacy: .public) Δt=\(residualMs, privacy: .public) ms")
            } else {
                missingTimestamps += 1
                log.warning("Deferred 360 import still_\(ticket.sequence, privacy: .public) ← \(candidate.url.lastPathComponent, privacy: .public) used fallback ordering (missing timestamp)")
            }
        }

        let remaining = max(tickets.count - imported, 0)
        let ignored = max(candidates.count - imported, 0)
        var messageParts: [String] = []
        if imported == 0 {
            messageParts.append("No 360° stills were imported")
        } else {
            messageParts.append("Imported \(imported) deferred 360° still\(imported == 1 ? "" : "s")")
        }
        if remaining > 0 { messageParts.append("\(remaining) still\(remaining == 1 ? "" : "s") still missing") }
        if ignored > 0 { messageParts.append("\(ignored) extra file\(ignored == 1 ? "" : "s") ignored") }
        if let worstResidual = largeResiduals.max() {
            messageParts.append("largest time mismatch \(worstResidual / 1000)s — verify the imported shot order")
        }
        if missingTimestamps > 0 {
            messageParts.append("\(missingTimestamps) match\(missingTimestamps == 1 ? "" : "es") fell back to file ordering")
        }
        if let offsetMs = matchPlan.estimatedOffsetMs {
            log.notice("Deferred 360 import estimated camera clock offset \(offsetMs, privacy: .public) ms")
        }
        return ImportOutcome(imported: imported, remaining: remaining, ignored: ignored,
                             message: messageParts.joined(separator: " — ") + ".")
    }

    private struct Candidate {
        let url: URL
        let width: Int
        let height: Int
        let timestamp: Date?
    }

    private struct Assignment {
        let ticketIndex: Int
        let candidateIndex: Int
        let residualMs: Int64?
    }

    private struct MatchPlan {
        let assignments: [Assignment]
        let estimatedOffsetMs: Int64?
    }

    private struct MatchScore {
        let matches: Int
        let costMs: Int64

        func adding(costMs: Int64) -> MatchScore {
            MatchScore(matches: matches + 1, costMs: self.costMs + costMs)
        }

        static func better(_ lhs: MatchScore, than rhs: MatchScore) -> Bool {
            if lhs.matches != rhs.matches { return lhs.matches > rhs.matches }
            return lhs.costMs < rhs.costMs
        }
    }

    nonisolated private static func loadCandidate(from url: URL) -> Candidate? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard ["jpg", "jpeg"].contains(url.pathExtension.lowercased()),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src) as String?,
              UTType(type)?.conforms(to: .jpeg) == true,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              height > 0,
              abs(Double(width) / Double(height) - 2.0) < 0.05,
              hasEquirectangularProjection(ifTaggedIn: url, imageProperties: props)
        else { return nil }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let exifTime = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
        let timestamp = exifTime.flatMap(parseExifDate)
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey])).flatMap { $0.contentModificationDate }
        return Candidate(url: url, width: width, height: height, timestamp: timestamp)
    }

    nonisolated private static func parseExifDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }

    nonisolated private static func hasEquirectangularProjection(ifTaggedIn url: URL,
                                                                 imageProperties: [CFString: Any]) -> Bool {
        if let tiff = imageProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let software = (tiff[kCGImagePropertyTIFFSoftware] as? String)?.lowercased(),
           software.contains(".insp") {
            return false
        }
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1) else { return true }
        guard text.localizedCaseInsensitiveContains("GPano:ProjectionType") else { return true }
        return text.range(of: #"GPano:ProjectionType[^>]*>\s*equirectangular\s*<"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
            || text.range(of: #"GPano:ProjectionType\s*=\s*"equirectangular""#,
                          options: [.regularExpression, .caseInsensitive]) != nil
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

    nonisolated private static func matchTicketsToCandidates(tickets: [PendingImportTicket],
                                                             candidates: [Candidate]) -> MatchPlan {
        guard !tickets.isEmpty, !candidates.isEmpty else { return MatchPlan(assignments: [], estimatedOffsetMs: nil) }
        let ticketTimes = tickets.map { $0.capturedAtEpochMs }
        let candidateTimes = candidates.map { $0.timestamp.map { Int64($0.timeIntervalSince1970 * 1000) } }
        let candidateOffsets = Set(ticketTimes.compactMap { ticketMs in
            guard let ticketMs else { return nil }
            return candidateTimes.compactMap { candidateMs in candidateMs.map { $0 - ticketMs } }
        }.flatMap { $0 })
        let offsetOptions: [Int64?] = candidateOffsets.isEmpty ? [nil] : candidateOffsets.sorted().map(Optional.some)

        var bestPlan = MatchPlan(assignments: [], estimatedOffsetMs: nil)
        var bestScore = MatchScore(matches: -1, costMs: .max)
        for offset in offsetOptions {
            let candidatePlan = buildAssignments(ticketTimes: ticketTimes,
                                                 candidateTimes: candidateTimes,
                                                 estimatedOffsetMs: offset)
            if MatchScore.better(candidatePlan.score, than: bestScore) {
                bestScore = candidatePlan.score
                bestPlan = MatchPlan(assignments: candidatePlan.assignments, estimatedOffsetMs: offset)
            }
        }
        return bestPlan
    }

    nonisolated private static func residualMs(ticketMs: Int64?,
                                               candidateMs: Int64?,
                                               estimatedOffsetMs: Int64?) -> Int64? {
        guard let ticketMs, let candidateMs else { return nil }
        return abs((candidateMs - ticketMs) - (estimatedOffsetMs ?? 0))
    }

    nonisolated private static func buildAssignments(ticketTimes: [Int64?],
                                                     candidateTimes: [Int64?],
                                                     estimatedOffsetMs: Int64?) -> (score: MatchScore, assignments: [Assignment]) {
        struct StateKey: Hashable { let ticketIndex: Int; let candidateIndex: Int }
        var memo: [StateKey: MatchScore] = [:]

        func bestScore(ticketIndex: Int, candidateIndex: Int) -> MatchScore {
            let key = StateKey(ticketIndex: ticketIndex, candidateIndex: candidateIndex)
            if let cached = memo[key] { return cached }
            let remainingTickets = ticketTimes.count - ticketIndex
            let remainingCandidates = candidateTimes.count - candidateIndex
            if remainingTickets == 0 || remainingCandidates == 0 {
                let score = MatchScore(matches: 0, costMs: 0)
                memo[key] = score
                return score
            }

            var best = bestScore(ticketIndex: ticketIndex + 1, candidateIndex: candidateIndex)
            let skipCandidate = bestScore(ticketIndex: ticketIndex, candidateIndex: candidateIndex + 1)
            if MatchScore.better(skipCandidate, than: best) { best = skipCandidate }

            let pairResidual = residualMs(ticketMs: ticketTimes[ticketIndex],
                                          candidateMs: candidateTimes[candidateIndex],
                                          estimatedOffsetMs: estimatedOffsetMs)
            let pairCost = pairResidual ?? fallbackMatchCostMs
            let pairScore = bestScore(ticketIndex: ticketIndex + 1, candidateIndex: candidateIndex + 1)
                .adding(costMs: pairCost)
            if MatchScore.better(pairScore, than: best) { best = pairScore }

            memo[key] = best
            return best
        }

        let score = bestScore(ticketIndex: 0, candidateIndex: 0)
        var assignments: [Assignment] = []
        var i = 0
        var j = 0
        while i < ticketTimes.count, j < candidateTimes.count {
            let current = memo[StateKey(ticketIndex: i, candidateIndex: j)] ?? MatchScore(matches: 0, costMs: 0)
            let skipTicket = memo[StateKey(ticketIndex: i + 1, candidateIndex: j)] ?? MatchScore(matches: 0, costMs: 0)
            if current.matches == skipTicket.matches, current.costMs == skipTicket.costMs {
                i += 1
                continue
            }
            let skipCandidate = memo[StateKey(ticketIndex: i, candidateIndex: j + 1)] ?? MatchScore(matches: 0, costMs: 0)
            if current.matches == skipCandidate.matches, current.costMs == skipCandidate.costMs {
                j += 1
                continue
            }
            let residual = residualMs(ticketMs: ticketTimes[i],
                                      candidateMs: candidateTimes[j],
                                      estimatedOffsetMs: estimatedOffsetMs)
            assignments.append(Assignment(ticketIndex: i, candidateIndex: j, residualMs: residual))
            i += 1
            j += 1
        }
        return (score, assignments)
    }

    nonisolated private static func readJPEGData(from url: URL) -> Data? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
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

    nonisolated private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    nonisolated private static func int64Value(_ value: Any?) -> Int64? {
        if let int = value as? Int64 { return int }
        if let int = value as? Int { return Int64(int) }
        if let number = value as? NSNumber { return number.int64Value }
        return nil
    }
}
