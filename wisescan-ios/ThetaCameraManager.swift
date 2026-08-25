import AudioToolbox
import AVFoundation
import Foundation
import NetworkExtension
import Observation
import UIKit
import ImageIO
import Network
import os
import simd

/// Connection + shutter-trigger + still-download manager for the Ricoh Theta 360°
/// still source (REQUIREMENTS → REQ-033; decision journal in
/// docs/design/still-source-360.md).
///
/// - **Connect is BLE-first**: wake the paired camera over Bluetooth
///   (`ThetaBLEManager`), then join its AP programmatically via
///   `NEHotspotConfiguration` and probe with patience — the AP takes 5-15 s to rise
///   after a wake and DHCP a few seconds more, and a probe issued too early talks to
///   whatever network the phone is still on.
/// - **A camera ROSTER** (`CameraProfile`) holds every known body; the active one
///   occupies the single-camera defaults keys every path here reads.
/// - **Connect enforces the capture invariants**: firmware gate, zenith correction
///   (blocking — the face-export/solver convention depends on level panos), and
///   shooting-state normalization (image mode, self-timer off, running capture
///   stopped).
/// - **The shutter prefers BLE** when the link is up: the new file's URL arrives as a
///   NotifyState push, so there is no OSC round-trip; OSC is the fallback. Capture
///   writes the sidecar (phone pose + timestamps); JPGs drain through a queue that
///   yields to triggers, and download state is derived from disk.
/// - **Keep-awake is capture-tab-driven**, not connect-time: an idle camera returns to
///   its 180 s nap (a sleep/wake cycle re-derives the equirect yaw reference, which
///   the per-scan solve absorbs by design).
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
    struct StillFormat: Hashable {
        let width: Int
        let height: Int
        var label: String { "\(width) × \(height)" }
        var megapixels: Int { Int((Double(width * height) / 1_000_000).rounded()) }
    }

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
    /// JPEG resolutions the camera reports as supported (via `fileFormatSupport`); empty
    /// until a successful connect, or if the camera/firmware doesn't report them.
    private(set) var supportedStillFormats: [StillFormat] = []
    /// Rolling spike event log, newest first (capped).
    private(set) var events: [ThetaEvent] = []
    /// Count of 360° stills captured into the current scan (reset at record start).
    private(set) var scanStillCount = 0
    /// Stills this scan whose phone moved beyond the sway bounds during the exposure
    /// window — their recorded pose may not match what the camera saw. Drives the
    /// capture-time warning + chip count; the Process-step solve prefers clean stills.
    /// Setter is internal (not private) because the sway guard lives in the
    /// +StillMotion file split; treat as read-only outside the manager's own files.
    var swayedStillCount = 0
    /// Set when the camera stops answering mid-scan. The chip goes amber and the still
    /// path stops being attempted, so a dead camera taxes one keyframe rather than all
    /// of them; cleared by a successful still or a reconnect.
    private(set) var cameraUnresponsive = false
    /// True only while the operator must actually stand still: from the trigger until
    /// the 360° exposure has certainly closed. `isCapturing` outlives it by seconds
    /// (stitch + transfer), and waiting on THAT is what used to cost ~4 s per still.
    private(set) var isHoldingForExposure = false
    /// Which path fired the last still. Recorded per still because an OSC fallback's
    /// "ack" is a 3 s watchdog timeout plus an HTTP round trip, not a shutter time —
    /// tuning data has to be able to exclude those.
    private(set) var lastShutterPath = "unknown"
    /// Consecutive unacknowledged BLE writes. The link can stay CONNECTED while its data
    /// path degrades (RF congestion): characteristics are discovered, canShutterOverBLE
    /// reports true, and writes simply go unanswered. Field run 2026-08-17: still 1 over
    /// BLE at 262 ms, then three "write unacknowledged" fallbacks at ~3.2 s each.
    private var bleWriteFailures = 0
    /// Set after repeated write failures: BLE is skipped for the rest of the scan rather
    /// than spending the 3 s watchdog on every still to reach the same fallback.
    private(set) var bleShutterDegraded = false

    /// The shutter path a still would take right now — what the chip reports.
    var shutterPathIsBLE: Bool { ThetaBLEManager.shared.canShutterOverBLE && !bleShutterDegraded }

    /// One queued equirect transfer: the sidecar is already on disk; only the JPG bytes
    /// are outstanding on the camera.
    struct PendingStillDownload {
        let dir: URL
        let sequence: Int
        let fileURL: String
    }

    /// Deferred scan-still downloads, drained between triggers (a download must never
    /// delay the next still). Anything left when the scan ends — or that fails here —
    /// is swept by the Process step, which re-derives pending state from disk
    /// (sidecar present + JPG missing).
    private(set) var pendingStillDownloads: [PendingStillDownload] = []
    private var isDrainingStills = false

    /// Phone positions at each scan-still trigger — feeds the live calibration
    /// sufficiency meter (count + baseline spread).
    private(set) var scanStillPositions: [SIMD3<Float>] = []
    /// Camera-side file URLs already claimed by a still this session, and the newest image
    /// that existed before it started. Together they let a BLE capture whose confirmation
    /// was lost be recovered from the camera's file list without ever attaching a
    /// pre-existing frame to a fresh pose. See triggerStillPreferringBLE.
    private var seenStillURLs: Set<String> = []
    private var preScanLatestImageURL: String?
    /// Camera-vs-phone clock offset measured at scan start (see measureCameraClockOffset).
    /// Stamped into every still sidecar so shutter latency is recoverable from EXIF offline.
    private var cameraClockOffsetMs: Int64?
    private var cameraClockOffsetUncMs: Int?

    /// Max pairwise distance (m) between this scan's still positions: the calibration
    /// baseline. O(N²) over a handful of stills.
    var scanStillSpreadMeters: Float {
        guard scanStillPositions.count >= 2 else { return 0 }
        var best: Float = 0
        for i in 0..<(scanStillPositions.count - 1) {
            for j in (i + 1)..<scanStillPositions.count {
                best = max(best, simd_distance(scanStillPositions[i], scanStillPositions[j]))
            }
        }
        return best
    }
    private(set) var lastError: String?

    /// Theta **direct (AP) mode** default host. Client/LAN mode uses a different address;
    /// left mutable so the spike can point at either without a rebuild.
    var host = "192.168.1.1"
    var baseURL: URL { URL(string: "http://\(host)")! }

    /// Camera file URLs arrive in two shapes: the X pushes/lists them ABSOLUTE
    /// (`http://192.168.1.1/files/…`), the Z1 pushes `_latestFileUrl` over BLE as a bare
    /// PATH (`/files/…/R0010194.JPG`). URLSession rejects the latter ("unsupported URL") —
    /// field 2026-08-25: three BLE-triggered Z1 stills captured perfectly and all three
    /// downloads failed, then the Process-time sweep failed again off the persisted
    /// sidecars. Normalize at every consumer; camera.delete wants the absolute form too.
    /// `nonisolated static` so the background postprocessor can call it; the camera AP is
    /// always 192.168.1.1 (a CL-mode camera, #84, will need the real host threaded in).
    nonisolated static func absoluteCameraURLString(_ raw: String, host: String = "192.168.1.1") -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") { return trimmed }
        return "http://\(host)" + (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
    }

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
        ThetaBLEManager.shared.onLog = { [weak self] message in
            self?.log(.connection, message)
        }
        // Roster migration: a pre-roster install has active keys but no profiles —
        // seed the roster from them so the switcher sees the existing camera.
        if profiles.isEmpty,
           let ssid = UserDefaults.standard.string(forKey: AppConstants.Key.thetaSSID), !ssid.isEmpty,
           let pass = UserDefaults.standard.string(forKey: AppConstants.Key.thetaPassphrase) {
            upsertProfile(model: nil,
                          serial: UserDefaults.standard.string(forKey: AppConstants.Key.thetaBLESerial),
                          ssid: ssid, passphrase: pass,
                          bleID: UserDefaults.standard.string(forKey: AppConstants.Key.thetaBLEPeripheralID))
        }
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
        // notice, not info — info never reaches disk; see PerfDiag.log.
        logger.notice("[\(kind.rawValue, privacy: .public)] \(message, privacy: .public)")
    }

    /// Logs Wi‑Fi/network reachability transitions — the literal "Wi‑Fi connect/disconnect"
    /// events (joining/leaving the camera AP flips this) — and drives the self-heal
    /// probe, gated on the CURRENT SSID being the camera's own (see currentSSID()).
    private func startPathMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let usesWiFi = path.usesInterfaceType(.wifi)
            Task { @MainActor in
                guard let self, self.lastPathSatisfied != satisfied else { return }
                self.lastPathSatisfied = satisfied
                self.log(.network, satisfied ? "Network up\(usesWiFi ? " (Wi‑Fi)" : "")" : "Network down")
                // Fluid state: losing the network while connected drops the card to
                // disconnected immediately (no waiting for the next op to fail); the
                // network coming back with a stored camera silently re-probes — one
                // cheap /osc/info, no join — so a camera wake/roam self-heals.
                if !satisfied, self.isConnected {
                    self.state = .disconnected
                    self.log(.connection, "Camera network lost — disconnected")
                } else if satisfied, self.state == .disconnected, self.hasStoredNetwork {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)   // let the interface settle
                    guard self.state == .disconnected else { return }
                    // Probe ONLY when iOS confirms we're on the camera's own SSID. Any
                    // Wi-Fi coming up lands here — including home networks whose router
                    // typically shares the Theta's fixed 192.168.1.1, which a blind GET
                    // would interrogate on every roam. fetchCurrent answers for networks
                    // WE joined (NEHotspotConfiguration one-tap) — precisely the camera
                    // AP — and nil for foreign ones. A manual Settings join also reads
                    // nil and skips self-heal; the explicit Connect tap still probes.
                    let stored = UserDefaults.standard.string(forKey: AppConstants.Key.thetaSSID)
                    guard let ssid = await self.currentSSID(), ssid == stored else { return }
                    await self.probe(quiet: true)
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.scan4d.theta.path", qos: .utility))
    }

    // MARK: - Connection

    // MARK: - One-tap connect / disconnect (wearables-style flow)

    /// Whether a camera network is stored for one-tap join.
    var hasStoredNetwork: Bool {
        UserDefaults.standard.string(forKey: AppConstants.Key.thetaSSID)?.isEmpty == false
    }

    /// Factory Wi-Fi password for a Theta SSID — the 8 serial digits embedded in it
    /// (e.g. "THETAYR14100112.ASC" → "14100112"; suffix varies by model/firmware).
    /// nil when the SSID doesn't look like a Theta AP. Prefills the Add Camera sheet;
    /// the security plan's P2 warning fires when the live password still equals this.
    /// Ends the scan's still session: clears the per-scan counters and the ring
    /// positions, so the AR floor markers are torn down with the scan they belonged to.
    /// Called on every exit — save, discard, extend — because a discarded scan used to
    /// leave its markers floating in the live scene (field report 360update5).
    func endScanStillSession() {
        scanStillPositions.removeAll()
        scanStillCount = 0
        swayedStillCount = 0
    }

    /// Verify the camera is actually there before a scan starts, and recover if it
    /// isn't. The card can show "connected" long after the truth changed: the camera
    /// naps, or — more often — the phone roams off its AP, and nothing notices until a
    /// still fails mid-scan with the operator already walking.
    ///
    /// Cheap checks first: the stored SSID against the one iOS reports (no round trip
    /// at all), then a BLE state read, which works even when Wi-Fi has dropped. Only a
    /// real failure escalates to the full wake + rejoin.
    ///
    /// Returns true when the camera is ready; false means the operator should be told
    /// the scan will be phone-only.
    /// Settle which shutter path this scan actually has, BEFORE anything depends on the
    /// answer. A present shutter characteristic on a ready link is not evidence: on
    /// 2026-08-18 both held for the whole session while every control write was refused
    /// at the ATT layer, so `canShutterOverBLE` said yes, the record-start prompt never
    /// fired, and six stills silently ran OSC with a 3.4 s ack the sway window then
    /// anchored on. One probe write, and at most one reconnect-and-retry.
    func prepareShutterPath() async {
        // Either shutter surface counts: the X's CCv2 command or the Z1's v1 Take Picture.
        // Guarding on the X's alone made every Z1 record-start skip verification and fall
        // straight to the Reconnect prompt (2026-08-25). For a Z1 the verification is the
        // auth write itself, and recovery coalesces with any link already in flight.
        let ble = ThetaBLEManager.shared
        guard ble.chars[ThetaBLEManager.ccv2ShutterChar] != nil
                || ble.chars[ThetaBLEManager.v1TakePictureChar] != nil
                || (ble.linkIsZ1 && ble.z1Registered) else { return }
        if await ThetaBLEManager.shared.verifyControlWritable() { return }
        _ = await ThetaBLEManager.shared.recoverControlPlane()
    }

    @discardableResult
    func verifyReadyForCapture() async -> Bool {
        guard isConnected else { return false }
        cameraUnresponsive = false
        bleWriteFailures = 0
        bleShutterDegraded = false

        let stored = UserDefaults.standard.string(forKey: AppConstants.Key.thetaSSID)
        let onCameraNetwork = await currentSSID().map { $0 == stored } ?? true
        if onCameraNetwork, await ThetaBLEManager.shared.isCameraResponding() {
            await prepareShutterPath()
            return true
        }
        if onCameraNetwork, !ThetaBLEManager.shared.isLinkReady {
            // No BLE link to ask over (Z1, or a dropped link) — trust the network check
            // and let the first still surface any real failure.
            return true
        }

        log(.connection, onCameraNetwork
            ? "Camera didn't answer before recording — reconnecting…"
            : "Phone left the camera's Wi-Fi — reconnecting…")
        connect()
        // connect() runs its own wake/join/probe budget; wait for it to settle rather
        // than racing the scan's first still against it.
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if isConnected { return true }
            if case .failed = state { break }
        }
        cameraUnresponsive = true
        log(.connection, "360° camera unavailable — this scan will be phone-only until it reconnects")
        return false
    }

    /// SSID the phone is on right now, when iOS will say. Needs the Access Wi-Fi
    /// Information entitlement plus one of: this app joined the network via
    /// NEHotspotConfiguration, location permission, or a VPN. Foreign networks
    /// (home Wi-Fi) return nil — exactly the gate the self-heal probe needs.
    private func currentSSID() async -> String? {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
    }

    /// Serial of the ACTIVE stored camera when known: the BLE pairing's, else the
    /// 8-digit run in the factory SSID (the Theta's factory passphrase IS the serial).
    private var storedSerial: String? {
        if let serial = UserDefaults.standard.string(forKey: AppConstants.Key.thetaBLESerial),
           !serial.isEmpty {
            return serial
        }
        guard let ssid = UserDefaults.standard.string(forKey: AppConstants.Key.thetaSSID) else { return nil }
        return Self.factoryPassphrase(fromSSID: ssid)
    }

    static func factoryPassphrase(fromSSID ssid: String) -> String? {
        let trimmed = ssid.trimmingCharacters(in: .whitespaces).uppercased()
        guard trimmed.hasPrefix("THETA") else { return nil }
        let digits = trimmed.drop { !$0.isNumber }.prefix { $0.isNumber }
        return digits.count == 8 ? String(digits) : nil
    }

    func saveNetwork(ssid: String, passphrase: String) {
        UserDefaults.standard.set(ssid.trimmingCharacters(in: .whitespaces), forKey: AppConstants.Key.thetaSSID)
        UserDefaults.standard.set(passphrase, forKey: AppConstants.Key.thetaPassphrase)
        // Manual entry knows model/serial only by derivation; the roster entry
        // upgrades in place when a BLE pair or probe fills the blanks.
        upsertProfile(model: nil,
                      serial: Self.factoryPassphrase(fromSSID: ssid),
                      ssid: ssid.trimmingCharacters(in: .whitespaces),
                      passphrase: passphrase, bleID: nil)
    }

    // MARK: - Camera roster (multi-camera: switch per collection use case —
    // e.g. X for texture resolution, Z1 for low-light interiors)

    struct CameraProfile: Codable, Identifiable, Equatable {
        var model: String
        var serial: String?
        var ssid: String
        var passphrase: String
        var blePeripheralID: String?
        var id: String { serial ?? ssid }
        var displayName: String {
            let shortModel = model.replacingOccurrences(of: "RICOH ", with: "")
            return serial.map { "\(shortModel) · \($0)" } ?? shortModel
        }
    }

    private(set) var profiles: [CameraProfile] = ThetaCameraManager.loadProfiles()

    private static func loadProfiles() -> [CameraProfile] {
        guard let data = UserDefaults.standard.data(forKey: AppConstants.Key.thetaCameraProfiles),
              let list = try? JSONDecoder().decode([CameraProfile].self, from: data) else { return [] }
        return list
    }

    private func persistProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: AppConstants.Key.thetaCameraProfiles)
        }
    }

    /// Z1 BLE unlock, step 1 of 2 (#50): register this app's UUID with the camera over
    /// the Wi-Fi we are connected to right now (camera._setBluetoothDevice — Z1/V only;
    /// registration persists camera-side). Step 2 — writing that UUID to the BLE auth
    /// characteristic — runs inside every ensureLinkReady. Ride-along here because the
    /// first Wi-Fi connect is the one moment both transports' prerequisites are met, and
    /// it makes the unlock zero-touch: add a Z1, connect once, BLE wake works after.
    private func registerZ1BluetoothIfNeeded(model: String, oscSerial: String?) async {
        guard model.contains("Z1") else { return }
        let ble = ThetaBLEManager.shared
        // The BLE-advertised serial is the 8-digit tail; OSC may report a prefixed form.
        let digits = (oscSerial ?? "").drop { !$0.isNumber }.filter(\.isNumber)
        if UserDefaults.standard.string(forKey: AppConstants.Key.thetaBLESerial) == nil, digits.count == 8 {
            UserDefaults.standard.set(String(digits), forKey: AppConstants.Key.thetaBLESerial)
        }
        UserDefaults.standard.set(model, forKey: AppConstants.Key.thetaBLEModel)
        guard !ble.z1Registered else { return }
        do {
            let deviceName = try await registerBluetoothDevice(uuid: ble.z1AuthUUID)
            try? await setBluetoothPower(on: true)
            if let serial = UserDefaults.standard.string(forKey: AppConstants.Key.thetaBLESerial) {
                UserDefaults.standard.set(serial, forKey: AppConstants.Key.thetaZ1RegisteredSerial)
            }
            log(.connection, "Z1 Bluetooth control registered (deviceName \(deviceName ?? "?")) — "
                + "BLE wake and shutter engage from the next connect")
        } catch {
            // Non-fatal: Wi-Fi capture is unaffected; retried on every connect until it lands.
            log(.connection, "Z1 Bluetooth registration failed (\(Self.describe(error))) — will retry next connect")
        }
    }

    /// Z1: bring the BLE link up AFTER Wi-Fi connect, in the background. The X links
    /// during the wake that precedes the join, but a SLEEPING Z1 does not answer BLE
    /// connects at all (field 2026-08-25: two wake attempts timed out asleep, and the
    /// link was never retried once Wi-Fi proved the camera awake — so the per-session
    /// auth never ran and BLE shutter stayed unavailable all session while the probe
    /// connected fine). Post-connect is the one moment the camera is provably awake:
    /// link, authenticate (v1 per-session unlock), and let the post-auth re-discovery
    /// surface the auth-gated shooting service. Fire-and-forget — capture rides OSC
    /// until it lands, and a failure here costs nothing.
    private func ensureZ1LinkAfterConnect(model: String) {
        let ble = ThetaBLEManager.shared
        guard model.contains("Z1"), ble.z1Registered else { return }
        // "Ready" is not enough: the link that woke the camera is typically left ready
        // over a stripped control surface (didModifyServices on wake, re-discovery never
        // completing). Only a fresh scan-find sees the awake camera's 4 services — so if
        // the shutter path is not in hand now that Wi-Fi proves the camera awake, tear
        // down and re-link, rather than paying for it at the first still.
        if ble.isLinkReady, ble.hasZ1ControlSurface { return }
        Task {
            if ble.isLinkReady { ble.teardown() }
            try? await ble.ensureLinkReady()
        }
    }

    /// The roster entry matching the ACTIVE single-camera keys (which every existing
    /// code path — join, wake, factory password — continues to read unchanged).
    var activeProfile: CameraProfile? {
        let activeSSID = UserDefaults.standard.string(forKey: AppConstants.Key.thetaSSID)
        let activeSerial = UserDefaults.standard.string(forKey: AppConstants.Key.thetaBLESerial)
        return profiles.first { $0.serial != nil && $0.serial == activeSerial }
            ?? profiles.first { $0.ssid == activeSSID }
    }

    /// Add or refresh a roster entry (keyed by serial, else SSID). nil fields keep
    /// whatever the existing entry already knows.
    func upsertProfile(model: String?, serial: String?, ssid: String, passphrase: String, bleID: String?) {
        if let idx = profiles.firstIndex(where: { (serial != nil && $0.serial == serial) || $0.ssid == ssid }) {
            var entry = profiles[idx]
            if let model { entry.model = model }
            if let serial { entry.serial = serial }
            entry.ssid = ssid
            entry.passphrase = passphrase
            if let bleID { entry.blePeripheralID = bleID }
            profiles[idx] = entry
        } else {
            profiles.append(CameraProfile(model: model ?? "RICOH THETA", serial: serial,
                                          ssid: ssid, passphrase: passphrase, blePeripheralID: bleID))
        }
        persistProfiles()
    }

    /// Switch the active camera: load the profile into the single-camera keys every
    /// existing path reads, then connect (switching expresses intent to use it).
    func activateProfile(_ profile: CameraProfile) {
        guard profile.id != activeProfile?.id else { return }
        disconnect()
        ThetaBLEManager.shared.teardown()
        UserDefaults.standard.set(profile.ssid, forKey: AppConstants.Key.thetaSSID)
        UserDefaults.standard.set(profile.passphrase, forKey: AppConstants.Key.thetaPassphrase)
        // BLE identity is per-camera: nil REMOVES the previous camera's keys
        // (set(nil:) removes), so wake never targets the wrong body.
        UserDefaults.standard.set(profile.blePeripheralID != nil ? profile.serial : nil,
                                  forKey: AppConstants.Key.thetaBLESerial)
        UserDefaults.standard.set(profile.blePeripheralID, forKey: AppConstants.Key.thetaBLEPeripheralID)
        UserDefaults.standard.set(profile.model, forKey: AppConstants.Key.thetaBLEModel)
        log(.connection, "Switched camera → \(profile.displayName)")
        connect()
    }

    /// One-tap connect: join the stored camera Wi-Fi programmatically (no Settings
    /// round-trip), then probe with PATIENCE. Join outcomes that mean "already there"
    /// count as success; other join failures still probe — the user may be joined
    /// manually.
    ///
    /// The patience matters (360ble5, three first-taps failed / second taps always
    /// worked): NEHotspotConfiguration.apply completes when the ASSOCIATION is
    /// accepted, but the camera's DHCP/route takes several more seconds — a single
    /// 1.5 s-settle probe lands in that gap and fails, while the retry inherits the
    /// now-ready link. So: probe, and on failure keep retrying every 2 s for up to
    /// ~12 s before letting the failure stand.
    func connect() {
        guard state != .connecting else { return }
        state = .connecting
        lastError = nil
        Task {
            // BLE-first bootstrap: wake the paired camera so its AP exists to join.
            // No-op without a stored pairing; never fatal — the patient probe decides.
            let wokeOverBLE = await ThetaBLEManager.shared.wakeStoredCamera()
            var joined = await joinStoredNetworkIfNeeded()
            // A woken camera's AP takes 5-15 s to appear; a join issued too early gets
            // userDenied (SSID not in the air), and probing then talks to whatever
            // network the phone is still on — a home router 404s. Field pattern
            // "first tap fails, second succeeds" (360ble12) = exactly this window.
            var joinRetries = 0
            while !joined, wokeOverBLE, joinRetries < 3 {
                joinRetries += 1
                log(.connection, "Waiting for the camera's Wi-Fi to come up (retry \(joinRetries))…")
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                joined = await joinStoredNetworkIfNeeded()
            }
            for attempt in 1...5 {
                await probe()
                if isConnected { return }
                // Retry only the can't-reach class — a firmware gate or leveling
                // refusal is deterministic and its message should stand immediately.
                guard attempt < 5,
                      case .failed(let message) = state, message.hasPrefix("Can't reach") else { break }
                log(.connection, "Probe \(attempt) failed — link may still be settling, retrying…")
                // A failed probe after a SUCCESSFUL BLE wake is the client-mode signature
                // (camera awake, hosting no AP) — ask over BLE NOW, not after the loop.
                // First field exercise (2026-08-25, theta-comms2): the post-loop version
                // detected CL 61 s after the tap and connected at 76 s; checking on the
                // first failure moves detection to ~20 s. Once is enough — the answer
                // doesn't change while the loop runs, and a nil read (BLE momentarily
                // down) self-heals inside via ensureLinkReady. If the handler restores
                // AP and its own probe misses (AP still rising), the remaining loop
                // attempts keep probing the now-correct network.
                if attempt == 1, wokeOverBLE {
                    await handleClientModeIfDetected()
                    if isConnected { return }
                }
                state = .connecting
                lastError = nil
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            // Final state (.failed with its message) was set by the last probe.
        }
    }

    /// Returns whether the join is believed up (applied or already associated) —
    /// false lets the caller retry after a wake instead of probing a wrong network.
    @discardableResult
    private func joinStoredNetworkIfNeeded() async -> Bool {
        guard let ssid = UserDefaults.standard.string(forKey: AppConstants.Key.thetaSSID), !ssid.isEmpty,
              let pass = UserDefaults.standard.string(forKey: AppConstants.Key.thetaPassphrase), !pass.isEmpty
        else { return false }
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: pass, isWEP: false)
        config.joinOnce = false
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                NEHotspotConfigurationManager.shared.apply(config) { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
            log(.connection, "Joined camera Wi-Fi \(ssid)")
        } catch let error as NSError where error.domain == NEHotspotConfigurationErrorDomain
                    && error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
            log(.connection, "Already on camera Wi-Fi \(ssid)")
        } catch let error as NSError where error.domain == NEHotspotConfigurationErrorDomain
                    && error.code == NEHotspotConfigurationError.userDenied.rawValue {
            // iOS reports userDenied both for a tapped Cancel AND when the SSID simply
            // isn't in range (field: Z1 present, stored SSID was the X's) — name the
            // network so the cause is obvious.
            let hint = profiles.count > 1
                ? " — if you meant another camera, switch it on the card"
                : " — is that camera powered on with Wi-Fi enabled?"
            log(.connection, "⚠️ Couldn't join \(ssid)\(hint)")
            await warnIfClientMode()
            return false
        } catch {
            log(.connection, "⚠️ Wi-Fi join failed for \(ssid) (\(Self.describe(error))) — trying camera anyway")
        }
        // Known cosmetic (360post10, device-validated): iOS pops "Unable to join" for
        // the camera's internet-less AP even when the association is UP — the system's
        // captive-portal probe finds no internet and calls that a failure. The probe
        // below is the truth; the card state reflects it, never the OS alert.
        // Interface settle: HTTP to the camera flaps for a moment after association.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return true
    }

    /// Manual disconnect: kindly restore the camera's auto-sleep, release the phone from
    /// the camera's Wi-Fi (iOS returns to the previous network), and clear session
    /// state. Download state lives ON DISK (sidecar-derived), so pending JPGs simply
    /// resume on the next connect / Process pass.
    func disconnect() {
        let ssid = UserDefaults.standard.string(forKey: AppConstants.Key.thetaSSID)
        Task {
            try? await setSleepDelaySeconds(Self.kindSleepDelaySeconds)   // best-effort before dropping
            if let ssid, !ssid.isEmpty {
                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            }
            state = .disconnected
            serialNumber = nil
            batteryLevel = nil
            currentStillFormat = nil
            lastCapture = nil
            lastDownload = nil
            lastError = nil
            log(.connection, "Disconnected (manual) — camera auto-sleep restored, Wi-Fi released")
        }
    }

    // MARK: - Camera power profile

    /// Kind default when we're NOT actively capturing (matches the camera's own
    /// out-of-the-box behavior scale; the AR session has the same idle-teardown ethos).
    static let kindSleepDelaySeconds = 180

    /// Awake(true) = never sleep (active capture: yaw-reference stability + zero wake
    /// latency on still triggers). Awake(false) = restore auto-sleep so an idle camera
    /// naps. Driven by the capture tab's lifecycle (same timer as the AR idle teardown).
    func setKeepAwake(_ awake: Bool) {
        guard isConnected else { return }
        Task {
            do {
                try await setSleepDelaySeconds(awake ? 65535 : Self.kindSleepDelaySeconds)
                log(.connection, awake ? "Camera keep-awake ON (capture active)"
                                       : "Camera keep-awake off — auto-sleep restored (idle)")
            } catch {
                log(.connection, "⚠️ sleepDelay change failed: \(Self.describe(error))")
            }
        }
    }

    /// Leveling gate: the 360° face-pose export assumes zenith-corrected (level) panos.
    /// Surface the support tier at connect time so an unvalidated/unsupported camera is
    /// known BEFORE a scan, not at export (the event mirrors into the Dashboard card).
    private func logLevelingSupport(model: String) {
        switch EquirectFaceExport.levelingSupport(forModel: model) {
        case .validated:
            break
        case .assumedLevel:
            log(.connection, "⚠️ \(model): pano leveling not yet device-validated — "
                + "360° face poses will be marked unvalidated in exports")
        case .unsupported:
            log(.connection, "⚠️ \(model): unknown leveling behavior — stills capture "
                + "and archive, but pose-bearing 360° faces are not exported for this camera yet")
        }
    }

    /// `quiet` marks the background self-heal probe: it must never flip the card to
    /// .failed on its own (the user did nothing — a roam did), and it adopts the
    /// connection only for the SAVED camera's serial. The user's explicit Connect
    /// stays loud and unconditional.
    private func probe(quiet: Bool = false) async {
        do {
            let info = try await fetchInfo()

            // With the roster, a different body must not silently occupy a card the
            // user left pointed at another camera.
            if quiet, let expected = storedSerial?.suffix(8),
               let got = info.serial?.filter(\.isNumber).suffix(8),
               !got.isEmpty, got != expected {
                log(.connection, "Auto-reconnect reached \(info.model) (\(got)) — "
                    + "not the saved camera (\(expected)); staying disconnected")
                return
            }

            // Firmware Gate
            let isZ1 = info.model.contains("Z1")
            let isX = info.model.contains("X")
            let minFirmware = isZ1 ? AppConstants.Theta.minFirmwareZ1 : (isX ? AppConstants.Theta.minFirmwareX : "0")
            if info.firmware.compare(minFirmware, options: .numeric) == .orderedAscending {
                lastError = "Unsupported firmware \(info.firmware) (min: \(minFirmware))"
                if quiet {
                    log(.connection, "Auto-reconnect skipped: unsupported firmware \(info.firmware)")
                } else {
                    state = .failed("Firmware too old. Update via Ricoh app")
                }
                return
            }

            // Force Auto-Leveling for consistent mesh alignment
            do {
                try await setTopBottomCorrection(to: "Apply")
            } catch {
                let errorMsg = Self.describe(error)
                lastError = "Could not enforce zenith correction: \(errorMsg)"
                log(.connection, "⚠️ Failed to enable auto-leveling: \(errorMsg). Connection blocked.")
                if !quiet { state = .failed("Auto-leveling failed to apply") }
                return
            }

            await normalizeShootingStateLogged()

            state = .connected(model: info.model, firmware: info.firmware)
            serialNumber = info.serial
            batteryLevel = try? await fetchBatteryLevel()
            log(.connection, "Connected: \(info.model) \(info.firmware)"
                + (info.serial.map { " · \($0)" } ?? ""))
            logLevelingSupport(model: info.model)
            currentStillFormat = try? await fetchStillResolution()
            await refreshSupportedStillFormats()
            await registerZ1BluetoothIfNeeded(model: info.model, oscSerial: info.serial)
            ensureZ1LinkAfterConnect(model: info.model)
        } catch {
            batteryLevel = nil
            serialNumber = nil
            let message = Self.describe(error)
            if quiet {
                log(.connection, "Auto-reconnect probe failed: \(message) — staying disconnected")
            } else {
                state = .failed(message)
                log(.connection, "Connection failed: \(message)")
            }
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
                // Same contract as a scan still: bytes verified on the device means the
                // camera-side original goes. A test shot is a real photograph of a real
                // room, and leaving it on an open AP with a serial-derived password
                // because it came from the debug button is the kind of inconsistency
                // that turns into a leak.
                if !UserDefaults.standard.bool(forKey: AppConstants.Key.keepCameraOriginals),
                   data.count > 0 {
                    await deleteCameraFile(capture.fileURL)
                }
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
    nonisolated static func downsampledImage(from data: Data, maxPixel: CGFloat) -> UIImage? {
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

    /// Re-reads the current resolution and the supported list (e.g. after connecting).
        /// Refreshes `supportedStillFormats` from the camera; logs whether the camera
    /// reported a list (dynamic) or we'll fall back to the model presets.
    private func refreshSupportedStillFormats() async {
        do {
            let formats = try await fetchSupportedStillFormats()
            supportedStillFormats = formats
            log(.config, formats.isEmpty
                ? "No format list from camera; using model presets"
                : "\(formats.count) still format(s) reported by camera")
        } catch {
            supportedStillFormats = []
            log(.config, "Couldn't read format list: \(Self.describe(error))")
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
    func beginScanStillSession(rawDataDir: URL? = nil) {
        scanStillCount = 0
        swayedStillCount = 0
        cameraUnresponsive = false
        scanStillPositions.removeAll()
        // Baseline for confirmation-timeout recovery: anything newer than this on the
        // camera, and not already claimed by a still this session, was shot by us.
        seenStillURLs.removeAll()
        cameraClockOffsetMs = nil
        cameraClockOffsetUncMs = nil
        Task { [weak self] in
            guard let self else { return }
            self.preScanLatestImageURL = try? await self.latestImageURL()
            // Sequential, same Task: both are small OSC calls and the first still is
            // seconds away — no reason to race two requests on the camera's AP.
            if let clock = await self.measureCameraClockOffset() {
                self.cameraClockOffsetMs = clock.offsetMs
                self.cameraClockOffsetUncMs = clock.uncertaintyMs
                self.log(.capture, String(format: "Camera clock offset %+.2f s ±%dms — EXIF times decode to true shutter times this scan",
                                          Double(clock.offsetMs) / 1000, clock.uncertaintyMs))
            } else {
                // Say so — an absent offset in the sidecars must be distinguishable from
                // a build that never measured. Not fatal: this scan's EXIF just stays
                // latency-plus-offset, like every scan before it.
                self.log(.capture, "Camera clock offset unavailable (tick never caught) — EXIF stays uncorrected this scan")
            }
        }
        if let dir = rawDataDir?.appendingPathComponent("equirect_stills"),
           let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let maxSeq = files.compactMap { file -> Int? in
                if file.hasPrefix("still_"), file.hasSuffix(".JPG") || file.hasSuffix(".json") {
                    let seqStr = file.dropFirst(6).prefix(4)
                    return Int(seqStr)
                }
                return nil
            }.max() ?? 0
            scanStillCount = maxSeq
        }
    }

    /// Triggers a 360° still during a live scan, tags it with the **phone's** ARKit world
    /// pose + timestamp (captured by the caller at tap time), downloads the equirect, and
    /// writes it — JPEG + metadata sidecar — into the scan's raw-data dir under
    /// `equirect_stills/`. Storing the phone pose (not the camera pose) is deliberate: it
    /// captures the phone-pose ↔ equirect pairs the deferred rig-extrinsic calibration (P3)
    /// needs. No-op unless connected and no capture is already in flight.
    /// Returns false when the capture was NOT started (camera disconnected, or the previous
    /// still's ~7s trigger+download pipeline is still in flight) — the caller's toast must
    /// only show for captures that actually began, or fast taps display phantom stills.
    @discardableResult
    func captureStillForScan(phoneTransform: simd_float4x4, timestamp: TimeInterval,
                             into rawDataDir: URL,
                             samplePose: (() -> simd_float4x4?)? = nil) -> Bool {
        // Fail-soft: once the camera has gone, don't stall every keyframe waiting for a
        // trigger that can't succeed. Recovery is a reconnect, not a retry per still.
        guard isConnected, !isCapturing, !cameraUnresponsive else { return false }
        let capturedAtEpochMs = Int64(Date().timeIntervalSince1970 * 1000)
        isCapturing = true
        lastError = nil
        Task {
            let start = Date()
            // Trigger-window motion probe: samples the phone pose every 250 ms until
            // the camera reports the file. The sway verdict is applied afterwards over
            // the exposure window — anchored at the shutter ack, per-model length —
            // because that is the only stretch where motion corrupts the baked pose.
            let motionProbe = samplePose.map { makeStillMotionProbe(tapTransform: phoneTransform, sample: $0) }
            let connectedModel: String = if case .connected(let model, _) = state { model } else { "unknown-360" }
            do {
                var shutterAck: Date?
                isHoldingForExposure = true
                let fileURL = try await triggerStillPreferringBLE(onAck: { [weak self] in
                    shutterAck = Date()
                    // The camera has taken the shot; the pose-critical hold ends one
                    // shutter-latency + exposure later. Release the operator THERE, not
                    // when the file lands — stitch and transfer are the camera's problem
                    // and the download drains lazily in the background.
                    self?.scheduleHoldRelease(model: connectedModel)
                })
                let triggerMs = Int(Date().timeIntervalSince(start) * 1000)
                motionProbe?.cancel()
                let seq = scanStillCount + 1
                let motion = await resolveStillMotion(
                    probe: motionProbe,
                    timing: TriggerTiming(start: start, shutterAck: shutterAck,
                                          model: connectedModel, triggerMs: triggerMs),
                    seq: seq)
                // STOP-RACE GUARD: the trigger can still cross the scan's Stop — saveScan
                // MOVES the capture dir, and a sidecar written to the stale path creates an
                // orphaned equirect_stills/ the saved bundle never sees. Loud drop.
                guard FileManager.default.fileExists(atPath: rawDataDir.path) else {
                    log(.capture, "Scan still #\(seq) discarded — scan ended before the 360° trigger finished")
                    isCapturing = false
                    return
                }
                let input = ScanStillInput(
                    sequence: seq, phoneTransform: phoneTransform,
                    frameTimestamp: timestamp, capturedAtEpochMs: capturedAtEpochMs,
                    sourceURL: fileURL, sourceModel: connectedModel, format: currentStillFormat,
                    triggerMs: triggerMs,
                    triggerMotionM: motion?.totalM, triggerMotionDeg: motion?.totalDeg,
                    exposureMotionM: motion?.exposureM, exposureMotionDeg: motion?.exposureDeg,
                    shutterPath: lastShutterPath,
                    shutterAckMs: motion?.ackOffset.map { Int($0 * 1000) },
                    cameraClockOffsetMs: cameraClockOffsetMs,
                    cameraClockOffsetUncMs: cameraClockOffsetUncMs,
                    exposureWindowMs: motion.map { Int($0.window * 1000) },
                    motionSamples: motion?.samples)
                // Sidecar NOW (phone pose can't be reconstructed later); JPG via the queue;
                // cam_transform is baked by the Process step's calibration solve.
                try Self.writeScanStillSidecar(input: input, into: rawDataDir)
                // No cue here: "you can move" already fired at exposure close
                // (scheduleHoldRelease). The file landing is bookkeeping — the operator
                // should be walking by now.
                releaseExposureHold(playCue: false)   // no-op unless the ack never came
                scanStillCount = seq
                cameraUnresponsive = false
                scanStillPositions.append(SIMD3<Float>(phoneTransform.columns.3.x,
                                                       phoneTransform.columns.3.y,
                                                       phoneTransform.columns.3.z))
                lastCapture = CaptureOutcome(fileURL: fileURL, roundTripMs: triggerMs)
                pendingStillDownloads.append(PendingStillDownload(dir: rawDataDir, sequence: seq, fileURL: fileURL))
                log(.capture, String(format: "Scan still #%d — trigger %d ms, download queued (%d pending)",
                                     seq, triggerMs, pendingStillDownloads.count))
                isCapturing = false
                drainStillDownloads()
                return
            } catch {
                releaseExposureHold(playCue: false)   // failed shot: release, but don't say "done"
                let message = Self.describe(error)
                lastError = message
                log(.capture, "Scan still failed: \(message)")
                if Self.isConnectivityError(error) {
                    state = .failed(message)
                    cameraUnresponsive = true
                    log(.capture, "360° stills paused — reconnect the camera to resume")
                }
            }
            isCapturing = false
        }
        return true
    }

    /// Scan-capture shutter: BLE when the bonded link is ready (the file URL arrives
    /// as a NotifyState push — no OSC round-trip), OSC otherwise. Fallback rule from
    /// the probe rounds: only a failed WRITE falls back (the camera never fired); a
    /// confirmation timeout must NOT double-trigger, so it surfaces as the error.
    /// Recovery for a shutter whose fate is UNKNOWN — the write may have been accepted and
    /// the picture already taken, so re-triggering blind both double-shoots and (2026-08-25)
    /// draws a 503 from a camera busy with the shot it is still writing. A newer image than
    /// the one the scan started with, unclaimed by any other still, IS this shot. Both
    /// conditions matter: transferred stills are deleted camera-side as we go, but a camera
    /// holding pre-existing files must never hand a stale frame to this still's pose.
    private func recoverUnconfirmedShot() async -> String? {
        guard let latest = try? await latestImageURL(),
              latest != preScanLatestImageURL,
              !seenStillURLs.contains(latest) else { return nil }
        seenStillURLs.insert(latest)
        return latest
    }

    private func triggerStillPreferringBLE(onAck: (() -> Void)? = nil) async throws -> String {
        // Capability, not just link readiness: a Z1 link is ready for identity/state
        // but has no CCv2 shutter characteristic — asking anyway threw linkNotReady,
        // which the fallback below does not catch, failing the still outright.
        guard shutterPathIsBLE else {
            lastShutterPath = "osc"
            let url = try await triggerStill(onAck: onAck)
            seenStillURLs.insert(url)
            return url
        }
        do {
            // Absolutize at ingestion: the sidecar persists this string and the download,
            // delete sweep and seen-set comparisons (OSC lists absolute URLs) all read it.
            let url = Self.absoluteCameraURLString(try await ThetaBLEManager.shared.triggerShutter(onAck: onAck), host: host)
            log(.capture, "Shutter via BLE — file pushed")
            lastShutterPath = "ble"
            bleWriteFailures = 0
            seenStillURLs.insert(url)
            return url
        } catch ThetaBLEManager.BLEError.timeout(let what) {
            // The WRITE was accepted; only the NotifyState push carrying _latestFileUrl
            // never arrived — so the camera almost certainly took the picture, and
            // re-triggering would double-shoot. That rule is why this used to surface as a
            // hard failure, and on 2026-08-19 it cost a still outright.
            //
            // Ask the camera instead. A newer image than the one that existed when the scan
            // began, which no still has already claimed, IS this shot. Both conditions
            // matter: transferred stills are deleted camera-side as we go, but a camera with
            // pre-existing files must never hand a stale frame to this still's pose.
            if let latest = await recoverUnconfirmedShot() {
                lastShutterPath = "ble-unconfirmed"
                log(.capture, "BLE shutter fired but the camera never pushed the file URL (\(what)) — "
                    + "recovered it from the camera's file list")
                return latest
            }
            throw ThetaBLEManager.BLEError.timeout(what)
        } catch ThetaBLEManager.BLEError.linkNotReady {
            // The link died WHILE the shutter was in flight — the ~30 s ATT indication
            // timeout (#49), which on 2026-08-25 killed the link 29.3 s after ready and
            // failed the very next still outright with the camera reachable on Wi-Fi the
            // whole time (it had downloaded 11 MB seconds earlier).
            //
            // Do NOT re-trigger blind: failAllPending resolves every pending continuation,
            // including one whose write the camera already accepted, so a blind retry
            // double-shoots — the same hazard the .timeout branch exists to avoid. Ask the
            // camera first; a newer image than the scan started with, unclaimed by another
            // still, IS this shot.
            if let latest = await recoverUnconfirmedShot() {
                lastShutterPath = "ble-unconfirmed"
                log(.capture, "BLE link dropped mid-shutter — the camera had already taken it; "
                    + "recovered the file from its list")
                return latest
            }
            // Nothing new on the camera: the write never landed. Wi-Fi is a separate path
            // and still up, so take the shot there rather than lose it. Deliberately does
            // NOT set bleShutterDegraded — this is a transient drop, not a broken control
            // plane, and BLE's tighter exposure window is worth reclaiming if the link
            // returns.
            lastShutterPath = "osc"
            log(.capture, "BLE link dropped mid-shutter — taking this still over Wi-Fi")
            return try await triggerStill(onAck: onAck)
        } catch ThetaBLEManager.BLEError.controlRefused {
            // ONE strike, and a separate counter. The 2-strike rule below exists to stop
            // burning the 3 s write watchdog per still on a flaky link; a refusal costs
            // nothing to attempt and has never once recovered on the same link (0/4 on
            // 2026-08-18), so there is nothing to spend a second still learning. It also
            // must not consume bleWriteFailures — the two failures need separate budgets.
            if !bleShutterDegraded {
                bleShutterDegraded = true
                log(.connection, "The camera refused Bluetooth control — using Wi-Fi for the rest of this "
                    + "scan. To fix it: Settings → Bluetooth → tap ⓘ next to the camera → Forget This "
                    + "Device, then pair it again from Add Camera.")
            }
            lastShutterPath = "osc"
            return try await triggerStill(onAck: onAck)
        } catch ThetaBLEManager.BLEError.writeFailed(let why) {
            bleWriteFailures += 1
            log(.capture, "BLE shutter write failed (\(why)) — falling back to OSC")
            // Two in a row means the link is up but its data path is not. Every further
            // attempt costs the full watchdog before landing in the same place, so stop
            // attempting and say so — 3 s per still is worth more than the hope.
            if bleWriteFailures >= 2, !bleShutterDegraded {
                bleShutterDegraded = true
                log(.connection, "Bluetooth shutter unreliable (\(bleWriteFailures) unacknowledged writes) — "
                    + "using Wi-Fi for the rest of this scan. Reconnect the camera to retry Bluetooth.")
            }
            // An unacknowledged write is UNKNOWN, not failed: on 2026-08-25 the camera had
            // taken the shot anyway and answered the blind OSC retry 52 ms later with
            // "Service Unavailable" — busy writing the very image we were re-requesting —
            // and the still was lost. Ask before re-triggering, exactly as .timeout does.
            if let latest = await recoverUnconfirmedShot() {
                lastShutterPath = "ble-unconfirmed"
                log(.capture, "BLE shutter write went unacknowledged but the camera took it — "
                    + "recovered the file from its list")
                return latest
            }
            lastShutterPath = "osc"
            return try await triggerStill(onAck: onAck)
        }
    }

    /// Factory AP SSID for a camera identity — the exact string NEHotspotConfiguration
    /// needs. Model→prefix mapping is per Ricoh convention (field: X = "THETAYR");
    /// unknown models return nil and the Add flow falls back to manual entry.
    static func factorySSID(model: String, serial: String) -> String? {
        guard serial.count == 8, serial.allSatisfy(\.isNumber) else { return nil }
        // Prefixes verbatim from the official SDK (theta-ble-client ThetaModel.kt:
        // Z1 = "YN", X = "YR"); the X form is field-confirmed as THETAYR….OSC.
        if model.contains("THETA X") { return "THETAYR\(serial).OSC" }
        if model.contains("Z1") { return "THETAYN\(serial).OSC" }
        return nil
    }

    /// Shooting-state hygiene at connect: a self-timer or video mode left on the
    /// camera silently ruins scan stills (see normalizeShootingState), and a capture
    /// still running collides with our shutter. Non-fatal — log and continue.
    private func normalizeShootingStateLogged() async {
        do {
            if let changed = try await normalizeShootingState() {
                log(.config, "Camera shooting settings normalized — \(changed)")
            }
            if let interrupted = try await stopRunningCapture() {
                log(.config, "Camera was busy (\(interrupted)) — capture stopped")
            }
        } catch {
            log(.config, "⚠️ Could not normalize shooting settings: \(Self.describe(error))")
        }
    }

    // MARK: - Camera storage + WLAN mode

    /// File count on the camera (nil when it can't be asked).
    func cameraFileCount() async -> Int? {
        guard isConnected else { return nil }
        return try? await fetchFileCount()
    }

    /// Erase every photo/video on the camera. Caller confirms first — this is
    /// irreversible and unrelated to the per-scan security sweep.
    @discardableResult
    func deleteAllCameraFiles() async -> Bool {
        guard isConnected else { return false }
        do {
            let before = (try? await fetchFileCount()) ?? 0
            try await deleteAllFiles()
            let after = (try? await fetchFileCount()) ?? 0
            log(.transfer, "Erased camera storage — \(before) file(s) before, \(after) after")
            return true
        } catch {
            log(.transfer, "⚠️ Erase failed: \(Self.describe(error))")
            return false
        }
    }

    /// Client-mode (CL) gotcha: the camera has joined ANOTHER network, so it never
    /// advertises its own SSID and no amount of retrying will join it — but it looks
    /// perfectly healthy. Only BLE can ask while Wi-Fi is unreachable, so this runs
    /// off the bonded link when there is one, and stays silent otherwise.
    private func warnIfClientMode() async {
        await handleClientModeIfDetected()
    }

    /// CL-mode detection AND remedy. A stored AP profile is an explicit statement of
    /// intent — this flow exists to join the camera's own network — so when the camera
    /// reports CLIENT mode, switch it back to AP over BLE (the same CCv2 SetOptions path
    /// as wake) and rejoin, rather than telling the operator to dig through camera menus.
    /// Falls back to the Dashboard alert with the on-camera steps when the write fails.
    private func handleClientModeIfDetected() async {
        guard let mode = await ThetaBLEManager.shared.readNetworkType(),
              mode.uppercased().hasPrefix("CL") else { return }
        log(.connection, "⚠️ The camera is in CLIENT (CL) Wi-Fi mode — it isn't broadcasting "
            + "its own network (firmware updates can boot into CL). Switching it back over Bluetooth…")
        if await ThetaBLEManager.shared.restoreAPMode() {
            // AP takes a few seconds to rise after the mode flip — same rhythm as wake.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if await joinStoredNetworkIfNeeded() {
                state = .connecting
                lastError = nil
                await probe()
                if isConnected { return }
            }
            log(.connection, "Camera switched to AP mode — tap Connect again if it didn't come up.")
        } else {
            ThetaBLEManager.shared.actionRequired =
                "The camera is in CLIENT (CL) Wi-Fi mode, so it isn't broadcasting the network "
                + "this app joins — and switching it back over Bluetooth didn't work.\n\n"
                + "On the camera: Settings → Wi-Fi icon → select AP (Direct) mode. Firmware "
                + "updates can reset this to CL."
        }
    }

    /// Forget the ACTIVE camera: drop its roster entry and its Wi-Fi/hotspot/BLE
    /// state. If another camera remains, its profile is loaded (not auto-connected).
    /// The iOS-level Bluetooth BOND can only be removed in Settings → Bluetooth.
    func forgetCamera() {
        let forgotten = activeProfile
        disconnect()
        ThetaBLEManager.shared.teardown()
        if let forgotten {
            profiles.removeAll { $0.id == forgotten.id }
            persistProfiles()
        } else if let bleSerial = UserDefaults.standard.string(forKey: AppConstants.Key.thetaBLESerial) {
            // Half-state (field, 2026-08-25): a BLE-found camera whose Wi-Fi setup never
            // finished has a roster entry and BLE keys but NO active SSID — activeProfile
            // is nil, so the roster entry survived every forget and there was no way to
            // start again. Match it by the stored BLE serial instead.
            profiles.removeAll { $0.serial == bleSerial }
            persistProfiles()
        }
        // Adopt the next camera ONLY if we actually removed the active one — with no
        // match (roster/keys out of sync) adopting profiles.first would silently
        // re-store a camera the user just asked to forget.
        if forgotten != nil, let next = profiles.first {
            UserDefaults.standard.set(next.ssid, forKey: AppConstants.Key.thetaSSID)
            UserDefaults.standard.set(next.passphrase, forKey: AppConstants.Key.thetaPassphrase)
            UserDefaults.standard.set(next.serial, forKey: AppConstants.Key.thetaBLESerial)
            UserDefaults.standard.set(next.blePeripheralID, forKey: AppConstants.Key.thetaBLEPeripheralID)
            UserDefaults.standard.set(next.model, forKey: AppConstants.Key.thetaBLEModel)
            if UserDefaults.standard.string(forKey: AppConstants.Key.thetaZ1RegisteredSerial) != next.serial {
                UserDefaults.standard.removeObject(forKey: AppConstants.Key.thetaZ1RegisteredSerial)
            }
            log(.connection, "Camera forgotten — \(next.displayName) is now active")
        } else {
            UserDefaults.standard.removeObject(forKey: AppConstants.Key.thetaSSID)
            UserDefaults.standard.removeObject(forKey: AppConstants.Key.thetaPassphrase)
            UserDefaults.standard.removeObject(forKey: AppConstants.Key.thetaBLESerial)
            UserDefaults.standard.removeObject(forKey: AppConstants.Key.thetaBLEPeripheralID)
            UserDefaults.standard.removeObject(forKey: AppConstants.Key.thetaBLEModel)
            UserDefaults.standard.removeObject(forKey: AppConstants.Key.thetaZ1RegisteredSerial)
            log(.connection, "Camera forgotten — to fully reset, also remove it in iOS Settings → Bluetooth")
        }
    }

    /// Ends the hold one shutter-latency + exposure after the camera acknowledged the
    /// shutter — the measured moment the 360° exposure has certainly closed. Everything
    /// after it (stitch, listing, download) happens while the operator walks.
    private func scheduleHoldRelease(model: String) {
        let remaining = AppConstants.thetaShutterLatencyAllowance
            + Self.expectedExposureSeconds(forModel: model)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            self?.releaseExposureHold(playCue: true)
        }
    }

    /// Idempotent: whichever of the ack timer, the completed still, or the failure path
    /// arrives first ends the hold, and only the timer's path plays the tone.
    private func releaseExposureHold(playCue: Bool) {
        guard isHoldingForExposure else { return }
        isHoldingForExposure = false
        if playCue { playThetaDoneCue() }
    }

    /// Distinct completion tone + success haptic when a 360° still finishes (audio
    /// gated by the same capture-audio setting as the shutter click; haptic always —
    /// people scan with the ringer off).

    private func playThetaDoneCue() {
        let audioOn = (UserDefaults.standard.object(forKey: AppConstants.Key.captureAudioEnabled) as? Bool) ?? true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if audioOn { AudioServicesPlaySystemSound(1114) }
    }

    /// Drain queued equirect downloads one at a time, yielding to any in-flight trigger
    /// (a download must never delay the next still — that was the old inline pipeline's
    /// ~7 s tax). Re-kicked after each trigger completes. Failures and scan-ended-
    /// mid-download cases are dropped here without retry: the sidecar survives in the
    /// (possibly moved) bundle, and the Process step sweeps sidecar-present/JPG-missing
    /// stills to finish the job.
    func drainStillDownloads() {
        guard !isDrainingStills, !pendingStillDownloads.isEmpty, !isCapturing else { return }
        isDrainingStills = true
        Task {
            var drainedDirs = Set<URL>()   // scans whose bytes landed — security-P1 sweep targets
            while !pendingStillDownloads.isEmpty && !isCapturing {
                let item = pendingStillDownloads[0]
                guard let url = URL(string: Self.absoluteCameraURLString(item.fileURL, host: host)) else {
                    pendingStillDownloads.removeFirst()
                    continue
                }
                do {
                    let dlStart = Date()
                    let data = try await downloadData(from: url)
                    let ms = Int(Date().timeIntervalSince(dlStart) * 1000)
                    let stillsDir = item.dir.appendingPathComponent("equirect_stills")
                    if FileManager.default.fileExists(atPath: stillsDir.path) {
                        let preview = await Self.persistDrainedStill(
                            data: data, stillsDir: stillsDir, sequence: item.sequence)
                        drainedDirs.insert(item.dir)
                        lastDownload = DownloadOutcome(bytes: data.count, elapsedMs: ms)
                        previewImage = preview
                        log(.transfer, String(format: "Still #%d downloaded — %.1f MB in %d ms (%d queued)",
                                              item.sequence, Double(data.count) / 1_000_000, ms,
                                              pendingStillDownloads.count - 1))
                    } else {
                        log(.transfer, "Still #\(item.sequence): scan dir moved — download deferred to Process")
                    }
                } catch {
                    log(.transfer, "Still #\(item.sequence) download failed (\(Self.describe(error))) — deferred to Process")
                }
                pendingStillDownloads.removeFirst()
            }
            isDrainingStills = false
            // Security P1: bytes verified on disk → remove the originals from the camera
            // (sidecar-stamped, so nothing double-fires and Process finishes stragglers).
            // Skipped while a trigger is in flight — the camera would answer busy; the
            // next drain re-fires. Detached: the sweep does its own synchronous HTTP.
            if !isCapturing {
                for dir in drainedDirs {
                    Task.detached(priority: .utility) { [weak self] in
                        let count = ScanPostprocessor.sweepCameraOriginals(rawDataPath: dir)
                        if count > 0 {
                            await MainActor.run { self?.log(.transfer, "Deleted \(count) transferred still(s) from camera") }
                        }
                    }
                }
            }
            // A trigger may have interrupted the drain; if it finished before we exited,
            // pick the queue back up rather than stranding it until the next trigger.
            if !pendingStillDownloads.isEmpty && !isCapturing { drainStillDownloads() }
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
