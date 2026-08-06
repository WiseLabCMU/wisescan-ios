import Foundation
import CoreBluetooth

// Link-establishment steps for ThetaBLEManager (power-on wait, scan, connect, identity
// read, JSON write). Split from the main file for the type-length limit; same single-
// module seam as ThetaBLEManager+Delegates.
extension ThetaBLEManager {

    // MARK: - Flow steps

    func waitForPowerOn(timeout: TimeInterval) async throws {
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
    func findCamera(serial: String?, timeout: TimeInterval) async throws -> CBPeripheral {
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

    func establishLink(_ target: CBPeripheral, timeout: TimeInterval) async throws {
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

    func readIdentity(timeout: TimeInterval) async throws -> Identity {
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

    func writeJSON(_ json: String, to uuid: CBUUID, timeout: TimeInterval) async throws {
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
}
