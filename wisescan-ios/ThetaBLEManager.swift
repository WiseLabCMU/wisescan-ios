import Foundation
import CoreBluetooth
import os

/// PRODUCTION BLE link to the Theta X — the graduation of ThetaBLEProbe's seven field
/// rounds (2026-08-05/06, design doc → still-source-360.md BLE section). Every rule
/// here is field-proven:
///
/// - The X advertises its bare 8-digit serial; identity (Get Info) reads WITHOUT
///   pairing; every CONTROL write is gated by standard BLE bonding (one-time passkey
///   shown on the camera's screen). The v1 GATT family is vestigial on X — only the
///   Camera Control Command v2 + WLAN v2 characteristics are used.
/// - Wake = `SetOptions {"cameraPower":"on"}` (the camera keeps BLE alive while
///   asleep with Wi-Fi off; this brings the AP back — proven from cold sleep).
/// - Shutter = `{"name":"camera.takePicture"}`; the NEW file's URL arrives as a
///   NotifyState push (`_latestFileUrl`) — no OSC polling. BLE and the Wi-Fi AP
///   coexist, so this works mid-transfer.
/// - Request/response chars answer on the NOTIFY channel (X-only); direct reads can
///   return stale buffers with the lead byte clobbered to 0x82 — never trust them.
/// - The X withholds `_ssid`/`_password` over BLE (credential requests go
///   unanswered), so join credentials stay stored-SSID + serial-derived password.
///
/// One operation in flight at a time (callers are naturally serialized: pairing is
/// modal, wake precedes connect, the shutter is gated by isCapturing).
@Observable
@MainActor
final class ThetaBLEManager: NSObject {
    static let shared = ThetaBLEManager()

    enum LinkState: Equatable { case idle, scanning, connecting, ready, failed(String) }
    enum BLEError: Error, LocalizedError {
        case bluetoothOff
        case timeout(String)
        case writeFailed(String)
        case linkNotReady
        case unsupportedCamera(String)
        /// A V/Z1: identity read fine, but its CONTROL characteristics sit behind the
        /// v1 auth scheme (UUID registered over Wi-Fi first) and it never shows a
        /// pairing code — spec: "the camera does not use pairing". Carries the
        /// harvested identity so the caller can prefill manual setup.
        case needsWiFiSetup(model: String, serial: String)
        var errorDescription: String? {
            switch self {
            case .bluetoothOff: return "Bluetooth is off"
            case .timeout(let what): return "Timed out: \(what)"
            case .writeFailed(let what): return "Write failed: \(what)"
            case .linkNotReady: return "BLE link not ready"
            case .unsupportedCamera(let why): return why
            case .needsWiFiSetup(let model, _): return "\(model) needs Wi-Fi setup first"
            }
        }
    }

    struct Identity {
        let model: String
        let serial: String
        let firmware: String
    }

    /// A camera seen advertising, shown to the user BEFORE any connection attempt —
    /// auto-connecting to the first 8-digit name found is wrong the moment two bodies
    /// are in the room (field: an X and a Z1 on the same bench).
    struct Discovered: Identifiable, Equatable {
        let id: UUID          // CBPeripheral.identifier
        let serial: String    // the advertised name IS the serial on V/Z1/X
        var rssi: Int
    }

    // X-native v2 characteristics (see ThetaBLEProbe for the full discovery map).
    static let ccv2GetInfoChar = CBUUID(string: "A0452E2D-C7D8-4314-8CD6-7B8BBAB4D523")
    static let ccv2GetStateChar = CBUUID(string: "083D92B0-21E0-4FB2-9503-7D8B2C2BB1D1")
    static let ccv2NotifyStateChar = CBUUID(string: "D32CE140-B0C2-4C07-AF15-2301B5057B8C")
    /// Stamped whenever a GetState value lands — the liveness probe watches it change.
    var lastStateReadAt: Date?
    /// Latest `_captureStatus` seen on a GetState read. NotifyState never pushes this
    /// (probe rounds 4-8 — it only pushes _latestFileUrl, battery and temps), so it is
    /// only current if something is polling.
    var lastCaptureStatus: String?
    /// `_capturedPictures` from GetState — a second, independent signal for the probe:
    /// if `_captureStatus` never leaves idle for a single still (which earlier probe
    /// rounds suggest), the shot count incrementing still marks completion.
    var lastCapturedPictures: Int?

    /// Polls GetState until `_captureStatus` leaves idle and returns again, timing both
    /// edges from `origin`. This is the ONLY direct measurement of when the shutter
    /// actually fires: the write-ack proves the camera ACCEPTED the command, and the
    /// sway window and the "you can move" release are both anchored on that assumption
    /// plus a fixed latency allowance. Field reports of the camera's own audible shutter
    /// landing later than our release are what this exists to settle.
    ///
    /// Developer Mode only — it adds BLE traffic during a capture, which is exactly when
    /// the link is busiest.
    func measureCaptureWindow(origin: Date, timeout: TimeInterval = 8) async {
        guard isLinkReady, let peripheral, let char = chars[Self.ccv2GetStateChar] else {
            PerfDiag.log("[360Still] shutter probe: no BLE link or GetState characteristic — skipped")
            return
        }
        // Clear first: a value left over from a previous read would read as "already
        // idle" and hide the transition we are looking for.
        lastCaptureStatus = nil
        lastCapturedPictures = nil

        var reads = 0
        var trace: [String] = []
        var lastKey: String?
        var sawChange = false
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let before = lastStateReadAt
            peripheral.readValue(for: char)
            try? await Task.sleep(nanoseconds: 40_000_000)
            if lastStateReadAt != before { reads += 1 } else { continue }

            let key = "\(lastCaptureStatus ?? "?")/\(lastCapturedPictures.map(String.init) ?? "?")"
            if key != lastKey {
                trace.append(String(format: "+%dms %@", Int(Date().timeIntervalSince(origin) * 1000), key))
                if lastKey != nil { sawChange = true }
                lastKey = key
            }
            // Stop once the camera has moved and settled back to idle.
            if sawChange, (lastCaptureStatus ?? "").lowercased() == "idle" { break }
        }

        // ALWAYS report. The previous version returned nil on every unhappy path, which
        // is why three field runs produced no probe output at all and we could not tell
        // a missed transition from a camera that never reports one.
        if reads == 0 {
            PerfDiag.log("[360Still] shutter probe: no GetState reads landed in \(Int(timeout))s "
                + "— BLE reads are not completing during capture")
        } else if !sawChange {
            PerfDiag.log("[360Still] shutter probe: \(reads) reads, state never changed "
                + "(\(lastKey ?? "?")) — this camera does not report a single still's shutter, "
                + "so ack + allowance stays the only estimate")
        } else {
            PerfDiag.log("[360Still] shutter probe: \(reads) reads — \(trace.joined(separator: " | "))")
        }
    }
    static let ccv2SetOptionsChar = CBUUID(string: "F0BCD2F9-5862-4653-B50D-80DC51E8CB82")
    static let ccv2ShutterChar = CBUUID(string: "6E2DEEBE-88B0-42A5-829D-1B2C6ABCE750")
    static let ccv2GetOptionsChar = CBUUID(string: "7CFFAAE3-8467-4D0C-A9DD-7F70B4F52863")

    /// Cameras currently advertising (discovery mode only, strongest signal first).
    var discovered: [Discovered] = []
    var isDiscovering = false

    /// `internal(set)` rather than `private(set)`: the delegate callbacks live in
    /// ThetaBLEManager+Delegates.swift and Swift's `private` does not cross files.
    var linkState: LinkState = .idle
    var isLinkReady: Bool { linkState == .ready }

    /// A ready link is NOT automatically a controllable one. The X exposes the CCv2
    /// control characteristics openly; a Z1 (fw ≥ 3.10.2) exposes only the read-only
    /// CCv2 subset — its control surface is the v1 family, gated behind the auth
    /// write that requires `camera._setBluetoothDevice` over Wi-Fi (field: 360ble9,
    /// Z1 fw 3.60.3 — GetInfo/GetState read fine unregistered, every v1 char and the
    /// auth char itself answered handle-invalid).
    var canWakeOverBLE: Bool { isLinkReady && chars[Self.ccv2SetOptionsChar] != nil }
    var canShutterOverBLE: Bool { isLinkReady && chars[Self.ccv2ShutterChar] != nil }
    /// Mirrors key events into ThetaCameraManager's card log (wired at its init).
    var onLog: ((String) -> Void)?

    var central: CBCentralManager?
    var peripheral: CBPeripheral?
    var chars: [CBUUID: CBCharacteristic] = [:]
    /// Outstanding per-service characteristic discoveries — lets us tell "still
    /// enumerating" from "enumeration finished and the working set never appeared",
    /// so an unsupported camera fails with the TRUTH instead of eating the link
    /// watchdog and reporting "camera did not answer" (which it plainly did).
    var pendingCharDiscoveries = 0
    var lastFileUrl = ""
    static let log = Logger(subsystem: "org.arenaxr.scan4d", category: "thetaBLE")

    // Pending single-flight continuations, each with a watchdog (BLE delegate calls
    // never time out on their own — a sleeping camera pends connect() forever).
    var powerOnPending: CheckedContinuation<Void, Error>?
    var scanPending: CheckedContinuation<CBPeripheral, Error>?
    var scanTargetSerial: String?
    var linkPending: CheckedContinuation<Void, Error>?
    var infoPending: CheckedContinuation<Identity, Error>?
    var writePending: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    var shutterPending: CheckedContinuation<String, Error>?
    var optionsPending: CheckedContinuation<String?, Never>?
    /// One watchdog per slot key ("scan", "link", …, or a char UUID string), cancelled
    /// the moment its slot resumes — a stale long watchdog (pairing's 60 s) must never
    /// fire into a LATER pending operation on the same slot.
    var watchdogs: [String: Task<Void, Never>] = [:]

    // MARK: - Public flows

    /// Begin listing nearby cameras. Runs until `stopDiscovery()`; results land in
    /// `discovered` for the UI to present. Throws only if Bluetooth is unavailable.
    func startDiscovery() async throws {
        try await waitForPowerOn(timeout: 5)
        guard let central else { throw BLEError.bluetoothOff }
        discovered.removeAll()
        isDiscovering = true
        linkState = .scanning
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func stopDiscovery() {
        isDiscovering = false
        central?.stopScan()
        if linkState == .scanning { linkState = .idle }
    }

    /// Pair the camera the USER picked: connect, read identity (open on X and on a
    /// Z1 ≥ 3.10.2), then force the bond with the first protected write — which is
    /// also the wake, so the AP starts rising while the caller derives credentials.
    /// `onStep` narrates for the sheet UI.
    func pairCamera(id: UUID, onStep: @escaping (String) -> Void) async throws -> Identity {
        stopDiscovery()
        guard let central, let target = central.retrievePeripherals(withIdentifiers: [id]).first else {
            throw BLEError.timeout("that camera is no longer reachable")
        }
        onStep("Connecting to \(target.name ?? "camera")…")
        try await establishLink(target, timeout: 12)
        let identity = try await readIdentity(timeout: 8)
        // Only the X takes the bond-and-wake path. Bail on anything else BEFORE the
        // 60 s protected write — on a V/Z1 that write can never succeed and no code
        // ever appears on the camera, so the old flow showed a false "enter the code"
        // prompt for a minute (360ble10). The identity we just harvested rides along
        // so the caller can prefill manual setup.
        guard chars[Self.ccv2SetOptionsChar] != nil else {
            teardown()
            throw BLEError.needsWiFiSetup(model: identity.model, serial: identity.serial)
        }
        onStep("Pairing — enter the code shown on the camera's screen")
        // Protected write: triggers the one-time iOS passkey dialog, generous timeout
        // for code entry. Bonded thereafter; also wakes the camera's AP.
        try await writeJSON("{\"cameraPower\":\"on\"}", to: Self.ccv2SetOptionsChar, timeout: 60)
        UserDefaults.standard.set(identity.serial, forKey: AppConstants.Key.thetaBLESerial)
        UserDefaults.standard.set(peripheral?.identifier.uuidString, forKey: AppConstants.Key.thetaBLEPeripheralID)
        onStep("Paired \(identity.serial) — waking the camera…")
        Self.log.info("paired \(identity.serial, privacy: .public) (\(identity.model, privacy: .public) \(identity.firmware, privacy: .public))")
        return identity
    }

    /// Best-effort wake before a Wi-Fi connect: reach the stored camera (bond makes
    /// this silent), write cameraPower=on, give the AP a beat to rise. Failure is
    /// never fatal — the caller's patient Wi-Fi probe is the real arbiter.
    @discardableResult
    func wakeStoredCamera() async -> Bool {
        guard UserDefaults.standard.string(forKey: AppConstants.Key.thetaBLESerial) != nil else { return false }
        do {
            try await ensureLinkReady()
            guard canWakeOverBLE else {
                onLog?("BLE wake not available on this camera — using Wi-Fi directly")
                return false
            }
            try await writeJSON("{\"cameraPower\":\"on\"}", to: Self.ccv2SetOptionsChar, timeout: 8)
            onLog?("BLE wake sent — waiting for the camera's Wi-Fi")
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // AP rise headstart
            return true
        } catch {
            onLog?("BLE wake unavailable (\(error.localizedDescription)) — trying Wi-Fi directly")
            return false
        }
    }

    /// BLE shutter: write the take-picture command and await NotifyState's pushed
    /// `_latestFileUrl` — the returned URL is the download ticket, identical to what
    /// the OSC path returns. Throws on write failure (caller may fall back to OSC)
    /// or on confirmation timeout (caller must NOT double-trigger).
    /// `onAck` fires the moment the camera ACKNOWLEDGES the write — within tens of
    /// ms of shutter-open (the X fires immediately; fixed focus, no hunt). This is the
    /// sway guard's exposure-window anchor.
    func triggerShutter(timeout: TimeInterval = 15, onAck: (() -> Void)? = nil) async throws -> String {
        guard isLinkReady, let peripheral, let shutter = chars[Self.ccv2ShutterChar] else {
            throw BLEError.linkNotReady
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writePending[Self.ccv2ShutterChar] = cont
            armWatchdog(Self.ccv2ShutterChar.uuidString, 3) { [weak self] in
                self?.writePending.removeValue(forKey: Self.ccv2ShutterChar)?
                    .resume(throwing: BLEError.writeFailed("shutter write unacknowledged"))
            }
            peripheral.writeValue(Data("{\"name\":\"camera.takePicture\"}".utf8), for: shutter, type: .withResponse)
        }
        onAck?()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            shutterPending = cont
            armWatchdog("shutter", timeout) { [weak self] in
                self?.shutterPending?.resume(throwing: BLEError.timeout("no capture confirmation"))
                self?.shutterPending = nil
            }
        }
    }

    /// Is the camera answering RIGHT NOW? Reads GetState over the existing link — the
    /// cheapest truth available, and the only one that works when the phone has left
    /// the camera's Wi-Fi. Does not wake, join, or reconfigure anything.
    func isCameraResponding(timeout: TimeInterval = 3) async -> Bool {
        guard isLinkReady, let peripheral, let char = chars[Self.ccv2GetStateChar] else { return false }
        peripheral.readValue(for: char)
        let deadline = Date().addingTimeInterval(timeout)
        let before = lastStateReadAt
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if lastStateReadAt != before { return true }
        }
        return false
    }

    /// Ask the camera which WLAN mode it is in ("AP" / "CL") over BLE — the only
    /// channel that works when the camera is in CL mode and its AP is therefore
    /// absent. Probe round 7 proved GetOptions answers on the NOTIFY, not the read,
    /// so the response arrives via didUpdateValueFor. nil when unavailable.
    func readNetworkType() async -> String? {
        guard (try? await ensureLinkReady()) != nil, isLinkReady,
              let peripheral, let char = chars[Self.ccv2GetOptionsChar] else { return nil }
        if char.properties.contains(.notify) { peripheral.setNotifyValue(true, for: char) }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            optionsPending = cont
            armWatchdog("options", 5) { [weak self] in
                self?.optionsPending?.resume(returning: nil)
                self?.optionsPending = nil
            }
            peripheral.writeValue(Data("{\"optionNames\":[\"_networkType\"]}".utf8),
                                  for: char, type: .withResponse)
        }
    }

    /// Reach the stored camera and get the link to ready (services discovered,
    /// notify subscribed). Fast path: retrieve the bonded peripheral by identifier —
    /// no scan needed; the X answers connects even while asleep (BLE stays on).
    func ensureLinkReady() async throws {
        if isLinkReady { return }
        try await waitForPowerOn(timeout: 5)
        var target: CBPeripheral?
        if let idString = UserDefaults.standard.string(forKey: AppConstants.Key.thetaBLEPeripheralID),
           let id = UUID(uuidString: idString) {
            target = central?.retrievePeripherals(withIdentifiers: [id]).first
        }
        if target == nil, let serial = UserDefaults.standard.string(forKey: AppConstants.Key.thetaBLESerial) {
            target = try await findCamera(serial: serial, timeout: 8)
        }
        guard let target else { throw BLEError.timeout("stored camera not found") }
        try await establishLink(target, timeout: 10)
    }

    /// Drop the link (scan stop + disconnect). Pending operations fail immediately.
    func teardown() {
        failAllPending(BLEError.linkNotReady)
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        chars.removeAll()
        pendingCharDiscoveries = 0
        linkState = .idle
    }

    // MARK: - Plumbing

    func armWatchdog(_ key: String, _ seconds: TimeInterval,
                     _ fire: @escaping @MainActor () -> Void) {
        watchdogs[key]?.cancel()
        watchdogs[key] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            fire()
        }
    }

    func clearWatchdog(_ key: String) {
        watchdogs.removeValue(forKey: key)?.cancel()
    }

    func failAllPending(_ error: Error) {
        watchdogs.values.forEach { $0.cancel() }
        watchdogs.removeAll()
        powerOnPending?.resume(throwing: error); powerOnPending = nil
        scanPending?.resume(throwing: error); scanPending = nil
        linkPending?.resume(throwing: error); linkPending = nil
        infoPending?.resume(throwing: error); infoPending = nil
        shutterPending?.resume(throwing: error); shutterPending = nil
        optionsPending?.resume(returning: nil); optionsPending = nil
        for (_, cont) in writePending { cont.resume(throwing: error) }
        writePending.removeAll()
    }
}
