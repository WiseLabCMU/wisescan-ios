import Foundation
import CoreBluetooth
import os

/// Developer-mode BLE probe bench for the Theta (BLE session, 2026-08-05/06).
///
/// ROUNDS 1-3 ANSWERED (360ble1/-R2/3): the X advertises its bare 8-digit serial;
/// the full GATT (10 services) enumerates unauthenticated; **the entire v1 family is
/// VESTIGIAL on X 2.92.0** — Camera Information reads, WLAN v1 Network Type, and the
/// Auth char all answer "handle is invalid", and `camera._setBluetoothDevice` (the
/// V/Z1 registration the auth write would need) is unsupported on X. The live paths
/// are the X-native v2 services, OPEN with no auth: Camera Control Command v2 Get
/// Info returned the full identity JSON (model/serial/firmware/MACs/uptime) in one
/// unauthenticated read.
///
/// ROUND 4 (this build) probes the v2 write paths, payload formats lifted from the
/// official SDK source (ricohapi/theta-ble-client): shutter = UTF-8
/// `{"name":"camera.takePicture"}`; wake AP = `{"type":"AP"}` to WRITE_SET_NETWORK_TYPE;
/// plus Get State / Get State2 / connected-Wi-Fi reads and the notify streams.
/// Findings feed the decided ideal connect flow: BLE scan → identity → wake AP →
/// derived SSID + factory password → NEHotspotConfiguration join → probe
/// (design doc → still-source-360.md, BLE section).
///
/// Camera-side prerequisite: Bluetooth turned ON on the X's touchscreen.
@Observable
@MainActor
final class ThetaBLEProbe: NSObject {
    static let shared = ThetaBLEProbe()

    // ── v1 services — VESTIGIAL ON X (handle-invalid; kept for a future V/Z1 path) ──
    static let cameraInfoService = CBUUID(string: "9A5ED1C5-74CC-4C50-B5B6-66A48E7CCFF1")
    static let modelNumberChar = CBUUID(string: "35FE6272-6AA5-44D9-88E1-F09427F51A71")
    static let serialNumberChar = CBUUID(string: "0D2FC4D5-5CB3-4CDE-B519-445E599957D8")
    static let firmwareChar = CBUUID(string: "B4EB8905-7411-40A6-A367-2834C2157EA7")
    static let takePictureCharV1 = CBUUID(string: "FEC1805C-8905-4477-B862-BA5E447528A5")
    static let networkTypeCharV1 = CBUUID(string: "9111CDD0-9F01-45C4-A2D4-E09E8FB0424D")
    static let authChar = CBUUID(string: "EBAFB2F0-0E0F-40A2-A84F-E2F098DC13C3")

    // ── X-native v2 map (UUIDs from ricohapi/theta-ble-client BleCharacteristic.kt) ──
    // Camera Control Command v2 service — OPEN, no auth (360ble3: GetInfo read worked
    // unauthenticated). All values UTF-8 JSON.
    static let ccv2Service = CBUUID(string: "B6AC7A7E-8C01-4A52-B188-68D53DF53EA2")
    static let ccv2GetInfoChar = CBUUID(string: "A0452E2D-C7D8-4314-8CD6-7B8BBAB4D523")
    static let ccv2GetStateChar = CBUUID(string: "083D92B0-21E0-4FB2-9503-7D8B2C2BB1D1")     // battery, _captureStatus, temps, _latestFileUrl
    static let ccv2GetState2Char = CBUUID(string: "8881CE4E-96FC-4C6C-8103-5DDA0AD138FB")
    static let ccv2NotifyStateChar = CBUUID(string: "D32CE140-B0C2-4C07-AF15-2301B5057B8C")
    static let ccv2GetOptionsChar = CBUUID(string: "7CFFAAE3-8467-4D0C-A9DD-7F70B4F52863")
    static let ccv2SetOptionsChar = CBUUID(string: "F0BCD2F9-5862-4653-B50D-80DC51E8CB82")
    static let ccv2ShutterChar = CBUUID(string: "6E2DEEBE-88B0-42A5-829D-1B2C6ABCE750")      // {"name":"camera.takePicture"}
    // WLAN control, v2 chars (same F37F568F service as the dead v1 network type).
    static let wlanV2SetNetworkTypeChar = CBUUID(string: "4B181146-EF3B-4619-8C82-1BA4A743ACFE")  // {"type":"AP"|"CLIENT"|"OFF"|"SCAN"}
    static let wlanV2WifiInfoReadChar = CBUUID(string: "01DFF9FF-00FA-44DD-AA6A-71D5E537ABCF")
    static let wlanV2WifiInfoNotifyChar = CBUUID(string: "A90381FC-2DDA-4EED-B24B-60F3E6651134")
    static let wlanV2ScannedSSIDChar = CBUUID(string: "60EEDCCC-426A-49CF-9AE1-F602284703D7")
    // Camera power (SDK: CAMERA_POWER) — R/W/N in the field discovery; format unprobed.
    static let cameraPowerChar = CBUUID(string: "B58CE84C-0666-4DE9-BEC8-2D27B27B3211")

    struct Found: Identifiable {
        let id: UUID          // CBPeripheral.identifier
        let name: String
        var rssi: Int
        /// Field finding (360ble1): the X advertises its bare 8-digit serial — same
        /// convention as V/Z1. Float those to the top and tag them in the UI.
        var isLikelyTheta: Bool { name.count == 8 && name.allSatisfy(\.isNumber) }
    }

    private(set) var isScanning = false
    private(set) var found: [Found] = []
    private(set) var connectedName: String?
    private(set) var logLines: [String] = []

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var knownChars: [CBUUID: CBCharacteristic] = [:]
    private var wantsScan = false
    private var connectWatchdog: Task<Void, Never>?
    private static let oslog = Logger(subsystem: "org.arenaxr.scan4d", category: "bleprobe")

    // MARK: - Actions

    func startScan() {
        wantsScan = true
        found.removeAll()
        // Lazy central creation ties the Bluetooth permission prompt to this
        // deliberate tap (same ethos as the card's Local Network prompt).
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
            log("Bluetooth starting…")
            return   // scan begins in centralManagerDidUpdateState once poweredOn
        }
        beginScanIfPoweredOn()
    }

    func stopScan() {
        wantsScan = false
        isScanning = false
        central?.stopScan()
    }

    func connect(_ id: UUID) {
        guard let central, let target = central.retrievePeripherals(withIdentifiers: [id]).first else {
            log("⚠️ peripheral \(id) not retrievable")
            return
        }
        stopScan()
        peripheral = target
        target.delegate = self
        log("Connecting to \(target.name ?? id.uuidString)…")
        central.connect(target)
        // CBCentralManager.connect pends SILENTLY forever — without this, a camera
        // that stopped listening (BLE idles when the X sleeps) looks like a dead tap
        // (360ble1: zero feedback was indistinguishable from a missed touch).
        connectWatchdog?.cancel()
        connectWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let self, !Task.isCancelled, self.connectedName == nil, self.peripheral != nil else { return }
            self.log("⏱ still connecting after 10 s — wake the camera (its BLE idles in sleep), or toggle camera Bluetooth, then rescan")
        }
    }

    func disconnect() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        connectedName = nil
        knownChars.removeAll()
    }

    /// Shutter over the v2 command channel — OSC-shaped command as UTF-8 JSON
    /// (payload format from theta-ble-client requestShutterCommand).
    func takePicture() {
        write(Data("{\"name\":\"camera.takePicture\"}".utf8),
              to: Self.ccv2ShutterChar, label: "shutter camera.takePicture (v2)")
    }

    /// Wake the camera's own AP over the v2 WLAN char — `{"type":"AP"}`
    /// (payload format from theta-ble-client setNetworkType).
    func wakeAP() {
        write(Data("{\"type\":\"AP\"}".utf8),
              to: Self.wlanV2SetNetworkTypeChar, label: "networkType AP (v2)")
    }

    // MARK: - Internals

    private func beginScanIfPoweredOn() {
        guard let central, central.state == .poweredOn, wantsScan else { return }
        isScanning = true
        // No service filter: the X's advertisement content is exactly what we're here
        // to learn (V/Z1 advertise the serial; the X is undocumented).
        central.scanForPeripherals(withServices: nil, options: nil)
        log("Scanning (all peripherals — tap the Theta)…")
    }

    private func write(_ data: Data, to uuid: CBUUID, label: String) {
        guard let peripheral, let char = knownChars[uuid] else {
            log("⚠️ \(label): characteristic not discovered")
            return
        }
        log("→ write \(label)")
        peripheral.writeValue(data, for: char, type: .withResponse)
    }

    private func log(_ line: String) {
        Self.oslog.info("\(line, privacy: .public)")
        logLines.append(line)
        if logLines.count > 60 { logLines.removeFirst(logLines.count - 60) }
    }

    private static func describeProps(_ props: CBCharacteristicProperties) -> String {
        var out: [String] = []
        if props.contains(.read) { out.append("R") }
        if props.contains(.write) { out.append("W") }
        if props.contains(.writeWithoutResponse) { out.append("WwoR") }
        if props.contains(.notify) { out.append("N") }
        if props.contains(.indicate) { out.append("I") }
        return out.joined(separator: "/")
    }

    private static func shortUUID(_ uuid: CBUUID) -> String {
        let str = uuid.uuidString
        return str.count > 8 ? String(str.prefix(8)) : str
    }
}

// MARK: - CBCentralManagerDelegate

extension ThetaBLEProbe: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Bluetooth state: \(central.state.rawValue) (\(central.state == .poweredOn ? "poweredOn" : "not ready"))")
        beginScanIfPoweredOn()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard let name = advName ?? peripheral.name, !name.isEmpty else { return }
        if let idx = found.firstIndex(where: { $0.id == peripheral.identifier }) {
            found[idx].rssi = RSSI.intValue
        } else {
            found.append(Found(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
            // Likely-Theta rows first (8-digit serial names), then by signal.
            found.sort {
                if $0.isLikelyTheta != $1.isLikelyTheta { return $0.isLikelyTheta }
                return $0.rssi > $1.rssi
            }
            log("Found \"\(name)\" rssi=\(RSSI.intValue)\(advName != nil ? " (advertised)" : " (GAP name)")")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectWatchdog?.cancel()
        connectedName = peripheral.name ?? peripheral.identifier.uuidString
        log("✅ Connected \(connectedName ?? "?") — discovering ALL services…")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("❌ Connect failed: \(error?.localizedDescription ?? "unknown")")
        self.peripheral = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("Disconnected\(error.map { " (\($0.localizedDescription))" } ?? "")")
        connectedName = nil
        knownChars.removeAll()
    }
}

// MARK: - CBPeripheralDelegate

extension ThetaBLEProbe: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("⚠️ service discovery: \(error.localizedDescription)"); return }
        for service in peripheral.services ?? [] {
            log("Service \(Self.shortUUID(service.uuid))…")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { log("⚠️ char discovery \(Self.shortUUID(service.uuid)): \(error.localizedDescription)"); return }
        for char in service.characteristics ?? [] {
            log("  char \(Self.shortUUID(char.uuid)) [\(Self.describeProps(char.properties))]")
            knownChars[char.uuid] = char
            switch char.uuid {
            case Self.ccv2GetInfoChar, Self.ccv2GetStateChar, Self.ccv2GetState2Char,
                 Self.wlanV2WifiInfoReadChar, Self.cameraPowerChar:
                if char.properties.contains(.read) { peripheral.readValue(for: char) }
            case Self.ccv2NotifyStateChar, Self.wlanV2WifiInfoNotifyChar, Self.wlanV2ScannedSSIDChar:
                if char.properties.contains(.notify) { peripheral.setNotifyValue(true, for: char) }
            default:
                break   // v1 chars are vestigial on X — reading them just logs noise
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let name: String = switch characteristic.uuid {
        case Self.ccv2GetInfoChar: "GetInfo(v2)"
        case Self.ccv2GetStateChar: "GetState(v2)"
        case Self.ccv2GetState2Char: "GetState2(v2)"
        case Self.ccv2NotifyStateChar: "NotifyState(v2)"
        case Self.ccv2ShutterChar: "Shutter(v2)"
        case Self.wlanV2SetNetworkTypeChar: "SetNetworkType(v2)"
        case Self.wlanV2WifiInfoReadChar, Self.wlanV2WifiInfoNotifyChar: "WifiInfo(v2)"
        case Self.wlanV2ScannedSSIDChar: "ScannedSSID(v2)"
        case Self.cameraPowerChar: "CameraPower"
        default: Self.shortUUID(characteristic.uuid)
        }
        if let error {
            // "Insufficient authentication/encryption" here = this char needs pairing —
            // exactly the kind of ground truth the probe exists to capture.
            log("⚠️ \(name) read: \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { log("\(name): <no data>"); return }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty,
           text.allSatisfy({ !$0.isASCII || ($0.asciiValue ?? 0) >= 0x20 }) {
            log("\(name) = \"\(text)\"")
        } else {
            log("\(name) = 0x\(data.map { String(format: "%02X", $0) }.joined())")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let name: String = switch characteristic.uuid {
        case Self.ccv2ShutterChar: "Shutter(v2)"
        case Self.wlanV2SetNetworkTypeChar: "SetNetworkType(v2)"
        default: Self.shortUUID(characteristic.uuid)
        }
        log(error.map { "❌ write \(name): \($0.localizedDescription)" } ?? "✅ write \(name) accepted")
    }
}
