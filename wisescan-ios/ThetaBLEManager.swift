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
        var errorDescription: String? {
            switch self {
            case .bluetoothOff: return "Bluetooth is off"
            case .timeout(let what): return "Timed out: \(what)"
            case .writeFailed(let what): return "Write failed: \(what)"
            case .linkNotReady: return "BLE link not ready"
            }
        }
    }

    struct Identity {
        let model: String
        let serial: String
        let firmware: String
    }

    // X-native v2 characteristics (see ThetaBLEProbe for the full discovery map).
    static let ccv2GetInfoChar = CBUUID(string: "A0452E2D-C7D8-4314-8CD6-7B8BBAB4D523")
    static let ccv2GetStateChar = CBUUID(string: "083D92B0-21E0-4FB2-9503-7D8B2C2BB1D1")
    static let ccv2NotifyStateChar = CBUUID(string: "D32CE140-B0C2-4C07-AF15-2301B5057B8C")
    static let ccv2SetOptionsChar = CBUUID(string: "F0BCD2F9-5862-4653-B50D-80DC51E8CB82")
    static let ccv2ShutterChar = CBUUID(string: "6E2DEEBE-88B0-42A5-829D-1B2C6ABCE750")

    private(set) var linkState: LinkState = .idle
    var isLinkReady: Bool { linkState == .ready }
    /// Mirrors key events into ThetaCameraManager's card log (wired at its init).
    var onLog: ((String) -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var lastFileUrl = ""
    private static let log = Logger(subsystem: "org.arenaxr.scan4d", category: "thetaBLE")

    // Pending single-flight continuations, each with a watchdog (BLE delegate calls
    // never time out on their own — a sleeping camera pends connect() forever).
    private var powerOnPending: CheckedContinuation<Void, Error>?
    private var scanPending: CheckedContinuation<CBPeripheral, Error>?
    private var scanTargetSerial: String?
    private var linkPending: CheckedContinuation<Void, Error>?
    private var infoPending: CheckedContinuation<Identity, Error>?
    private var writePending: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var shutterPending: CheckedContinuation<String, Error>?
    /// One watchdog per slot key ("scan", "link", …, or a char UUID string), cancelled
    /// the moment its slot resumes — a stale long watchdog (pairing's 60 s) must never
    /// fire into a LATER pending operation on the same slot.
    private var watchdogs: [String: Task<Void, Never>] = [:]

    // MARK: - Public flows

    /// One-time pairing for the Add Camera flow: find ANY Theta (8-digit advertised
    /// name), connect, read identity (open), then force the bond with the first
    /// protected write — which is also the wake, so the AP starts rising while the
    /// caller derives credentials. `onStep` narrates for the sheet UI.
    func pairNewCamera(onStep: @escaping (String) -> Void) async throws -> Identity {
        onStep("Scanning for the camera…")
        let target = try await findCamera(serial: nil, timeout: 15)
        onStep("Found \(target.name ?? "camera") — connecting…")
        try await establishLink(target, timeout: 12)
        let identity = try await readIdentity(timeout: 8)
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
    func triggerShutter(timeout: TimeInterval = 15) async throws -> String {
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
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            shutterPending = cont
            armWatchdog("shutter", timeout) { [weak self] in
                self?.shutterPending?.resume(throwing: BLEError.timeout("no capture confirmation"))
                self?.shutterPending = nil
            }
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
        linkState = .idle
    }

    // MARK: - Flow steps

    private func waitForPowerOn(timeout: TimeInterval) async throws {
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        if central?.state == .poweredOn { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            powerOnPending = cont
            armWatchdog("powerOn", timeout) { [weak self] in
                self?.powerOnPending?.resume(throwing: BLEError.bluetoothOff)
                self?.powerOnPending = nil
            }
        }
    }

    /// Scan for a Theta: exact serial when given, else the first 8-digit-named ad.
    private func findCamera(serial: String?, timeout: TimeInterval) async throws -> CBPeripheral {
        try await waitForPowerOn(timeout: 5)
        guard let central else { throw BLEError.bluetoothOff }
        linkState = .scanning
        scanTargetSerial = serial
        defer { central.stopScan() }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CBPeripheral, Error>) in
            scanPending = cont
            armWatchdog("scan", timeout) { [weak self] in
                guard let self, let pending = self.scanPending else { return }
                self.scanPending = nil
                self.central?.stopScan()
                self.linkState = .failed("camera not found")
                pending.resume(throwing: BLEError.timeout("camera not advertising — is its Bluetooth on?"))
            }
            central.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    private func establishLink(_ target: CBPeripheral, timeout: TimeInterval) async throws {
        linkState = .connecting
        peripheral = target
        target.delegate = self
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            linkPending = cont
            armWatchdog("link", timeout) { [weak self] in
                guard let self, let pending = self.linkPending else { return }
                self.linkPending = nil
                self.linkState = .failed("connect timed out")
                if let peripheral = self.peripheral { self.central?.cancelPeripheralConnection(peripheral) }
                pending.resume(throwing: BLEError.timeout("camera did not answer the connection"))
            }
            central?.connect(target)
        }
    }

    private func readIdentity(timeout: TimeInterval) async throws -> Identity {
        guard let peripheral, let info = chars[Self.ccv2GetInfoChar] else { throw BLEError.linkNotReady }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Identity, Error>) in
            infoPending = cont
            armWatchdog("info", timeout) { [weak self] in
                self?.infoPending?.resume(throwing: BLEError.timeout("identity read"))
                self?.infoPending = nil
            }
            peripheral.readValue(for: info)
        }
    }

    private func writeJSON(_ json: String, to uuid: CBUUID, timeout: TimeInterval) async throws {
        guard let peripheral, let char = chars[uuid] else { throw BLEError.linkNotReady }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            writePending[uuid] = cont
            armWatchdog(uuid.uuidString, timeout) { [weak self] in
                self?.writePending.removeValue(forKey: uuid)?
                    .resume(throwing: BLEError.writeFailed("no acknowledgment"))
            }
            peripheral.writeValue(Data(json.utf8), for: char, type: .withResponse)
        }
    }

    // MARK: - Plumbing

    private func armWatchdog(_ key: String, _ seconds: TimeInterval,
                             _ fire: @escaping @MainActor () -> Void) {
        watchdogs[key]?.cancel()
        watchdogs[key] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            fire()
        }
    }

    private func clearWatchdog(_ key: String) {
        watchdogs.removeValue(forKey: key)?.cancel()
    }

    private func failAllPending(_ error: Error) {
        watchdogs.values.forEach { $0.cancel() }
        watchdogs.removeAll()
        powerOnPending?.resume(throwing: error); powerOnPending = nil
        scanPending?.resume(throwing: error); scanPending = nil
        linkPending?.resume(throwing: error); linkPending = nil
        infoPending?.resume(throwing: error); infoPending = nil
        shutterPending?.resume(throwing: error); shutterPending = nil
        for (_, cont) in writePending { cont.resume(throwing: error) }
        writePending.removeAll()
    }
}

// MARK: - CBCentralManagerDelegate

extension ThetaBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            clearWatchdog("powerOn")
            powerOnPending?.resume(); powerOnPending = nil
        } else if central.state == .poweredOff || central.state == .unauthorized {
            failAllPending(BLEError.bluetoothOff)
            linkState = .failed("Bluetooth unavailable")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanPending != nil else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let isTheta = name.count == 8 && name.allSatisfy(\.isNumber)
        let matches = scanTargetSerial.map { name == $0 } ?? isTheta
        guard matches else { return }
        central.stopScan()
        clearWatchdog("scan")
        scanPending?.resume(returning: peripheral)
        scanPending = nil
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        linkState = .failed(error?.localizedDescription ?? "connect failed")
        linkPending?.resume(throwing: BLEError.timeout(error?.localizedDescription ?? "connect failed"))
        linkPending = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Self.log.info("link dropped\(error.map { " (\($0.localizedDescription))" } ?? "", privacy: .public)")
        chars.removeAll()
        linkState = .idle
        failAllPending(BLEError.linkNotReady)
    }
}

// MARK: - CBPeripheralDelegate

extension ThetaBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for char in service.characteristics ?? [] {
            chars[char.uuid] = char
            if char.uuid == Self.ccv2NotifyStateChar { peripheral.setNotifyValue(true, for: char) }
        }
        // Ready once the working set is present (services arrive per-service; the
        // needed four live across two services).
        let needed = [Self.ccv2GetInfoChar, Self.ccv2SetOptionsChar, Self.ccv2ShutterChar, Self.ccv2NotifyStateChar]
        if linkPending != nil, needed.allSatisfy({ chars[$0] != nil }) {
            clearWatchdog("link")
            linkState = .ready
            // Seed lastFileUrl so the first shutter can't match a stale URL
            // (NotifyState only pushes CHANGES).
            if let state = chars[Self.ccv2GetStateChar] { peripheral.readValue(for: state) }
            linkPending?.resume()
            linkPending = nil
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        switch characteristic.uuid {
        case Self.ccv2GetInfoChar:
            if let pending = infoPending {
                clearWatchdog("info")
                infoPending = nil
                pending.resume(returning: Identity(
                    model: obj["model"] as? String ?? "RICOH THETA",
                    serial: obj["serialNumber"] as? String ?? "",
                    firmware: obj["firmwareVersion"] as? String ?? ""))
            }
        case Self.ccv2GetStateChar:
            if let url = obj["_latestFileUrl"] as? String { lastFileUrl = url }
        case Self.ccv2NotifyStateChar:
            if let url = obj["_latestFileUrl"] as? String, !url.isEmpty, url != lastFileUrl {
                lastFileUrl = url
                if let pending = shutterPending {
                    clearWatchdog("shutter")
                    shutterPending = nil
                    pending.resume(returning: url)
                }
            }
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let pending = writePending.removeValue(forKey: characteristic.uuid) else { return }
        clearWatchdog(characteristic.uuid.uuidString)
        if let error {
            pending.resume(throwing: BLEError.writeFailed(error.localizedDescription))
        } else {
            pending.resume()
        }
    }
}
