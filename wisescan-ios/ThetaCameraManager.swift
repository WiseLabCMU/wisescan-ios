import Foundation
import Observation
import UIKit
import ImageIO
import Network
import os
import simd

/// Connection + shutter-trigger + still-download manager for a Ricoh Theta 360° camera,
/// driving the **still-source spike** on `feat/still-source-360`
/// (see docs/design/still-source-360.md).
///
/// SPIKE SCOPE — deliberately minimal:
/// - Transport is **Wi‑Fi + raw OSC HTTP** (OSC Web API v2.1), no external dependencies.
///   The OSC/HTTP layer lives in `ThetaCameraManager+OSC.swift`; this file owns published
///   state, user actions, the event log, and Wi‑Fi reachability monitoring.
/// - The user joins the camera's Wi‑Fi AP **manually** (iOS Settings); connecting is an
///   explicit tap, so the Local Network prompt is tied to a deliberate action.
/// - Still resolution is read/set via OSC options; each capture and transfer is timed
///   (the P2 viability numbers) and appended to the event log.
/// - No BLE trigger, no `NEHotspotConfiguration` auto-join, no `theta-client` SDK, no rig
///   calibration / cube-map export — the design doc's P3/P4 work, out of scope here.
///
/// Theta X speaks OSC API level 2.1, so still capture needs no explicit `camera.startSession`.
@Observable
@MainActor
final class ThetaCameraManager {
    static let shared = ThetaCameraManager()

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(model: String, firmware: String)
        case failed(String)
    }

    /// Result of one successful shutter trigger — the file URL the camera assigned and the
    /// wall-clock round trip (trigger → "done").
    struct CaptureOutcome: Equatable {
        let fileURL: String
        let roundTripMs: Int
    }

    /// Result of downloading the triggered still — bytes and transfer wall-clock.
    struct DownloadOutcome: Equatable {
        let bytes: Int
        let elapsedMs: Int
        var megabytes: Double { Double(bytes) / 1_000_000 }
        var megabytesPerSecond: Double { elapsedMs > 0 ? megabytes / (Double(elapsedMs) / 1000) : 0 }
    }

    /// A still (JPEG) resolution, from the OSC `fileFormat` option.
    struct StillFormat: Equatable {
        let width: Int
        let height: Int
        var label: String { "\(width) × \(height)" }
        var megapixels: Int { Int((Double(width * height) / 1_000_000).rounded()) }
    }

    /// Known Theta X JPEG still sizes (model-specific presets for the spike; unsupported
    /// values are rejected by `camera.setOptions` and surfaced as a config event).
    static let stillFormatPresets: [StillFormat] = [
        StillFormat(width: 11008, height: 5504),   // ~60 MP
        StillFormat(width: 5504, height: 2752)     // ~15 MP
    ]

    private(set) var state: ConnectionState = .disconnected
    /// Battery charge 0…1 from `/osc/state`, when known.
    private(set) var batteryLevel: Double?
    /// Camera serial number from `/osc/info` (the device id shown on the card).
    private(set) var serialNumber: String?
    private(set) var isCapturing = false
    private(set) var lastCapture: CaptureOutcome?
    private(set) var isDownloading = false
    private(set) var lastDownload: DownloadOutcome?
    /// Downsampled preview of the most recent download (the full-res image is not retained).
    private(set) var previewImage: UIImage?
    /// Current still resolution read from the camera's `fileFormat` option.
    private(set) var currentStillFormat: StillFormat?
    /// Rolling spike event log, newest first (capped).
    private(set) var events: [ThetaEvent] = []
    /// Count of 360° stills captured into the current scan (reset at record start).
    private(set) var scanStillCount = 0
    private(set) var lastError: String?

    /// Theta **direct (AP) mode** default host. Client/LAN mode uses a different address;
    /// left mutable so the spike can point at either without a rebuild.
    var host = "192.168.1.1"
    var baseURL: URL { URL(string: "http://\(host)")! }

    /// Ephemeral, Wi‑Fi-only session (used by the OSC extension too). Cellular is forbidden
    /// since the camera AP has no internet; resource timeout accommodates tens-of-MB stills.
    let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false
        cfg.allowsCellularAccess = false
        return URLSession(configuration: cfg)
    }()

    private let logger = Logger(subsystem: "org.arenaxr.scan4d", category: "theta")
    private let pathMonitor = NWPathMonitor()
    private var lastPathSatisfied: Bool?

    private init() {
        startPathMonitoring()
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    // MARK: - Event log

    /// Appends an event (newest first, capped) and mirrors it to the unified log.
    func log(_ kind: ThetaEvent.Kind, _ message: String) {
        events.insert(ThetaEvent(date: Date(), kind: kind, message: message), at: 0)
        if events.count > 100 { events.removeLast(events.count - 100) }
        logger.info("[\(kind.rawValue, privacy: .public)] \(message, privacy: .public)")
    }

    /// Logs Wi‑Fi/network reachability transitions — the literal "Wi‑Fi connect/disconnect"
    /// events (joining/leaving the camera AP flips this). No SSID (that needs location
    /// permission); interface type is enough for the spike.
    private func startPathMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let usesWiFi = path.usesInterfaceType(.wifi)
            Task { @MainActor in
                guard let self, self.lastPathSatisfied != satisfied else { return }
                self.lastPathSatisfied = satisfied
                self.log(.network, satisfied ? "Network up\(usesWiFi ? " (Wi‑Fi)" : "")" : "Network down")
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.scan4d.theta.path", qos: .utility))
    }

    // MARK: - Connection

    /// Probes the camera (explicit Dashboard tap) to confirm the phone is on its network.
    func refreshConnection() {
        guard state != .connecting else { return }
        state = .connecting
        lastError = nil
        Task { await probe() }
    }

    private func probe() async {
        do {
            let info = try await fetchInfo()
            state = .connected(model: info.model, firmware: info.firmware)
            serialNumber = info.serial
            batteryLevel = try? await fetchBatteryLevel()
            log(.connection, "Connected: \(info.model) \(info.firmware)"
                + (info.serial.map { " · \($0)" } ?? ""))
            currentStillFormat = try? await fetchStillResolution()
        } catch {
            batteryLevel = nil
            serialNumber = nil
            let message = Self.describe(error)
            state = .failed(message)
            log(.connection, "Connection failed: \(message)")
        }
    }

    // MARK: - Trigger

    /// Fires the shutter and records the file URL + round-trip time. No-op unless connected
    /// and no capture is already in flight.
    func takePicture() {
        guard isConnected, !isCapturing else { return }
        isCapturing = true
        lastError = nil
        // Drop any prior download so the card never shows a stale preview against a new shot.
        lastDownload = nil
        previewImage = nil
        Task {
            let start = Date()
            do {
                let fileURL = try await triggerStill()
                let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
                lastCapture = CaptureOutcome(fileURL: fileURL, roundTripMs: elapsedMs)
                log(.capture, "Shutter fired — \(elapsedMs) ms")
                batteryLevel = try? await fetchBatteryLevel()
            } catch {
                let message = Self.describe(error)
                lastError = message
                log(.capture, "Capture failed: \(message)")
                // A capture failure often means the AP dropped — reflect that in the badge.
                if Self.isConnectivityError(error) { state = .failed(message) }
            }
            isCapturing = false
        }
    }

    // MARK: - Download

    /// Downloads the most-recent capture's JPEG to time the transfer (P2 viability), then
    /// keeps only a downsampled preview. Explicit action — not auto-run after the trigger —
    /// so the transfer cost stays visible and separate from trigger latency.
    func downloadLastCapture() {
        guard let capture = lastCapture, let url = URL(string: capture.fileURL),
              !isDownloading else { return }
        isDownloading = true
        lastError = nil
        previewImage = nil
        Task {
            let start = Date()
            do {
                let data = try await downloadData(from: url)
                let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
                let outcome = DownloadOutcome(bytes: data.count, elapsedMs: elapsedMs)
                lastDownload = outcome
                log(.transfer, String(format: "Downloaded %.1f MB in %d ms (%.1f MB/s)",
                                      outcome.megabytes, outcome.elapsedMs, outcome.megabytesPerSecond))
                // Downsample off the full JPEG so we never hold the ~60MP bitmap decoded.
                previewImage = Self.downsampledImage(from: data, maxPixel: 1200)
            } catch {
                let message = Self.describe(error)
                lastError = message
                log(.transfer, "Download failed: \(message)")
            }
            isDownloading = false
        }
    }

    /// ImageIO thumbnail decode — bounds peak memory to the preview size regardless of the
    /// source resolution (a full-res equirect decode would be hundreds of MB).
    private static func downsampledImage(from data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Still resolution

    /// Re-reads the current still resolution (e.g. after connecting). Fire-and-forget.
    func fetchStillFormat() {
        guard isConnected else { return }
        Task {
            do {
                currentStillFormat = try await fetchStillResolution()
            } catch {
                log(.config, "Couldn't read resolution: \(Self.describe(error))")
            }
        }
    }

    /// Applies a still resolution, then re-reads to confirm.
    func setStillFormat(_ format: StillFormat) {
        guard isConnected else { return }
        Task {
            do {
                try await applyStillResolution(format)
                currentStillFormat = try await fetchStillResolution()
                log(.config, "Resolution set to \(format.label) (\(format.megapixels) MP)")
            } catch {
                log(.config, "Set resolution failed: \(Self.describe(error))")
            }
        }
    }

    // MARK: - Live-scan capture

    /// Resets the per-scan still counter. Call at record start.
    func beginScanStillSession() { scanStillCount = 0 }

    /// Triggers a 360° still during a live scan, tags it with the **phone's** ARKit world
    /// pose + timestamp (captured by the caller at tap time), downloads the equirect, and
    /// writes it — JPEG + metadata sidecar — into the scan's raw-data dir under
    /// `theta_stills/`. Storing the phone pose (not the camera pose) is deliberate: it
    /// captures the phone-pose ↔ equirect pairs the deferred rig-extrinsic calibration (P3)
    /// needs. No-op unless connected and no capture is already in flight.
    func captureStillForScan(phoneTransform: simd_float4x4, timestamp: TimeInterval, into rawDataDir: URL) {
        guard isConnected, !isCapturing else { return }
        isCapturing = true
        lastError = nil
        lastDownload = nil
        previewImage = nil
        Task {
            let start = Date()
            do {
                let fileURL = try await triggerStill()
                let triggerMs = Int(Date().timeIntervalSince(start) * 1000)
                guard let url = URL(string: fileURL) else { throw URLError(.badURL) }
                let dlStart = Date()
                let data = try await downloadData(from: url)
                let transferMs = Int(Date().timeIntervalSince(dlStart) * 1000)
                let seq = scanStillCount + 1
                let input = ScanStillInput(
                    sequence: seq, phoneTransform: phoneTransform, timestamp: timestamp,
                    sourceURL: fileURL, format: currentStillFormat,
                    triggerMs: triggerMs, transferMs: transferMs)
                try await Self.writeScanStill(data: data, input: input, into: rawDataDir)
                scanStillCount = seq
                lastCapture = CaptureOutcome(fileURL: fileURL, roundTripMs: triggerMs)
                lastDownload = DownloadOutcome(bytes: data.count, elapsedMs: transferMs)
                previewImage = Self.downsampledImage(from: data, maxPixel: 1200)
                log(.capture, String(format: "Scan still #%d — trigger %d ms, %.1f MB in %d ms",
                                     seq, triggerMs, Double(data.count) / 1_000_000, transferMs))
            } catch {
                let message = Self.describe(error)
                lastError = message
                log(.capture, "Scan still failed: \(message)")
                if Self.isConnectivityError(error) { state = .failed(message) }
            }
            isCapturing = false
        }
    }
}

/// A timestamped spike event, shown in the card's recent-events list and mirrored to the
/// unified log (Console category `theta`). File-scope to keep type nesting shallow.
struct ThetaEvent: Identifiable {
    enum Kind: String { case connection, capture, transfer, config, network }
    let id = UUID()
    let date: Date
    let kind: Kind
    let message: String
}
