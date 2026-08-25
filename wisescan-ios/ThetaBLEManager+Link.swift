import Foundation
import CoreBluetooth
import os

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
        // Control writability is a property of the physical link, not the app session —
        // a new connection is exactly the event that can change the answer.
        controlVerifiedForLink = false
        // AND NEITHER IS A CHARACTERISTIC. CBCharacteristic objects belong to the
        // connection that discovered them; handing one to a DIFFERENT CBPeripheral makes
        // CoreBluetooth resolve it through internal bookkeeping that no longer describes
        // it, and it dispatches into whatever now occupies that allocation. That is the
        // 2026-08-21/25 crash — `-[CBCharacteristic handleCharacteristicsDiscovered:]:
        // unrecognized selector` — thrown from inside CoreBluetooth, three times, always
        // through the same code path, on both a cold connect and a post-forget reconnect.
        //
        // `chars` used to survive across connections: this method never cleared it, so
        // didDiscoverCharacteristicsFor's `chars[ccv2GetStateChar]` read could return the
        // PREVIOUS link's characteristic and pass it to the new peripheral. Clear it here,
        // where the previous link definitively ends.
        chars.removeAll()
        pendingCharDiscoveries = 0
        // DIAGNOSTIC (unproven cause): a peripheral from retrievePeripherals can arrive
        // already carrying `services` from a prior process. Whether that is the crash's
        // trigger is not yet established — log it so the next occurrence says so.
        if let stale = target.services, !stale.isEmpty {
            Self.log.notice("target arrived with \(stale.count, privacy: .public) pre-existing service(s) — possible stale-object hazard")
        }
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
        guard let peripheral, let info = liveCharacteristic(Self.ccv2GetInfoChar) else { throw BLEError.linkNotReady }
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
        guard let peripheral, let char = liveCharacteristic(uuid) else { throw BLEError.linkNotReady }
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
