import Foundation
import CoreBluetooth
import os

/// Developer-mode BLE probe bench for the Theta (BLE session kickoff, 2026-08-05).
///
/// Purpose: field-answer the unknowns before the production BLE bootstrap is built —
/// (1) what name the THETA X actually advertises, (2) which GATT services and
/// characteristics this firmware exposes (FULL discovery is logged, not just the ones
/// we know), (3) whether Camera Information reads work without authentication (spec:
/// X needs no UUID registration; V/Z1 do, once, over Wi-Fi), (4) whether Take Picture
/// triggers, and (5) whether writing Network Type = 1 (Direct) wakes the camera's own
/// AP. Findings feed the decided ideal connect flow: BLE scan → read model/serial →
/// wake AP → derived SSID + factory password → NEHotspotConfiguration join → probe
/// (design doc → still-source-360.md, BLE section).
///
/// UUIDs verbatim from ricohapi/theta-api-specs → theta-bluetooth-api (2026-08-05).
/// Camera-side prerequisite: Bluetooth turned ON on the X's touchscreen.
@Observable
@MainActor
final class ThetaBLEProbe: NSObject {
    static let shared = ThetaBLEProbe()

    // Camera Information service — read-only identity (V/Z1/X).
    static let cameraInfoService = CBUUID(string: "9A5ED1C5-74CC-4C50-B5B6-66A48E7CCFF1")
    static let modelNumberChar = CBUUID(string: "35FE6272-6AA5-44D9-88E1-F09427F51A71")
    static let serialNumberChar = CBUUID(string: "0D2FC4D5-5CB3-4CDE-B519-445E599957D8")
    static let firmwareChar = CBUUID(string: "B4EB8905-7411-40A6-A367-2834C2157EA7")
    // Shooting Control — write 1 = take picture; notify carries shooting status.
    static let shootingService = CBUUID(string: "1D0F3602-8DFB-4340-9045-513040DAD991")
    static let takePictureChar = CBUUID(string: "FEC1805C-8905-4477-B862-BA5E447528A5")
    // WLAN Control — Network Type: 0 OFF / 1 Direct (camera's own AP) / 2 Client.
    static let wlanService = CBUUID(string: "F37F568F-9071-445D-A938-5441F2E82399")
    static let networkTypeChar = CBUUID(string: "9111CDD0-9F01-45C4-A2D4-E09E8FB0424D")
    // Bluetooth Control — Auth Bluetooth Device (write-only, UTF-8 UUID string).
    // Field finding (360ble1-R2): the X enumerates its FULL GATT unauthenticated but
    // every functional read/write returns "handle is invalid" until this is written —
    // the spec's "X does not require these steps" evidently means only the Wi-Fi-side
    // UUID registration; the auth write itself still gates. Probe: a self-generated
    // UUID (persisted, no camera._setBluetoothDevice) — does the X accept it?
    static let authService = CBUUID(string: "0F291746-0C80-4726-87A7-3C501FD3B4B6")
    static let authChar = CBUUID(string: "EBAFB2F0-0E0F-40A2-A84F-E2F098DC13C3")
    // Camera Control Command v2 — Get Info (UTF-8 JSON: model/serial/firmware/MACs/
    // uptime in ONE read; X ≥2.20.1). The X-native identity path.
    static let ccv2Service = CBUUID(string: "B6AC7A7E-8C01-4A52-B188-68D53DF53EA2")
    static let ccv2GetInfoChar = CBUUID(string: "A0452E2D-C7D8-4314-8CD6-7B8BBAB4D523")

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
    /// One re-discovery pass per connection, run after the auth write is accepted —
    /// probes whether auth unlocks handles (and whether hidden services appear).
    private var didPostAuthRediscover = false

    /// Self-generated auth identity, persisted so the camera sees the SAME central
    /// UUID across sessions (V/Z1 semantics; harmless if the X ignores it).
    private var authUUID: String {
        if let stored = UserDefaults.standard.string(forKey: "bleProbeAuthUUID") { return stored }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: "bleProbeAuthUUID")
        return fresh
    }
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
        didPostAuthRediscover = false
    }

    /// Probe #4: one-byte 1 → the camera should click (notify logs status bytes).
    func takePicture() {
        write(Data([0x01]), to: Self.takePictureChar, label: "TakePicture=1")
    }

    /// Probe #5: Network Type = 1 (Direct) → the camera's own AP should come up.
    func wakeAP() {
        write(Data([0x01]), to: Self.networkTypeChar, label: "NetworkType=1 (Direct)")
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
            case Self.authChar:
                // Auth FIRST — everything else answered "handle is invalid" without it
                // (360ble1-R2). Success path re-discovers and re-reads (didWriteValueFor).
                log("→ auth write \(authUUID)")
                peripheral.writeValue(Data(authUUID.utf8), for: char, type: .withResponse)
            case Self.modelNumberChar, Self.serialNumberChar, Self.firmwareChar, Self.ccv2GetInfoChar:
                peripheral.readValue(for: char)   // pre-auth attempt = comparison data
            case Self.takePictureChar, Self.networkTypeChar:
                if char.properties.contains(.notify) { peripheral.setNotifyValue(true, for: char) }
                if char.properties.contains(.read) { peripheral.readValue(for: char) }
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let name: String = switch characteristic.uuid {
        case Self.modelNumberChar: "Model"
        case Self.serialNumberChar: "Serial"
        case Self.firmwareChar: "Firmware"
        case Self.ccv2GetInfoChar: "GetInfo(v2)"
        case Self.takePictureChar: "TakePicture(status)"
        case Self.networkTypeChar: "NetworkType"
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
        if characteristic.uuid == Self.authChar {
            if let error {
                log("❌ auth: \(error.localizedDescription)")
                return
            }
            log("✅ auth accepted — re-discovering (do handles unlock? do hidden services appear?)")
            if !didPostAuthRediscover {
                didPostAuthRediscover = true
                peripheral.discoverServices(nil)
            }
            return
        }
        let name = Self.shortUUID(characteristic.uuid)
        log(error.map { "❌ write \(name): \($0.localizedDescription)" } ?? "✅ write \(name) accepted")
    }
}
