import Foundation
import CoreBluetooth
import os

// CoreBluetooth delegate callbacks for ThetaBLEManager — split out so each file stays
// under the length limit and the state/flow layer reads without wire-protocol noise
// (same seam as ThetaCameraManager+OSC). See ThetaBLEManager.swift for the field rules.

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
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let isTheta = name.count == 8 && name.allSatisfy(\.isNumber)

        // Discovery mode: accumulate every Theta for the picker, never auto-connect.
        if isDiscovering {
            guard isTheta else { return }
            if let idx = discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
                discovered[idx].rssi = RSSI.intValue
            } else {
                discovered.append(Discovered(id: peripheral.identifier, serial: name, rssi: RSSI.intValue))
                discovered.sort { $0.rssi > $1.rssi }
            }
            return
        }

        guard scanPending != nil else { return }
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
        let services = peripheral.services ?? []
        pendingCharDiscoveries = services.count
        guard !services.isEmpty else {
            failLink("this camera exposed no BLE services")
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for char in service.characteristics ?? [] {
            chars[char.uuid] = char
            if char.uuid == Self.ccv2NotifyStateChar { peripheral.setNotifyValue(true, for: char) }
        }
        pendingCharDiscoveries = max(0, pendingCharDiscoveries - 1)
        guard linkPending != nil else { return }
        // MINIMUM working set = identity + state push. Both the X and a Z1 on
        // fw ≥ 3.10.2 expose these unauthenticated; the control characteristics are
        // a separate capability (canWake/canShutterOverBLE). Requiring all four made
        // every Z1 link hang until the watchdog cancelled it — the field's "link
        // dropped" was OUR cancel, not the camera (360ble10).
        if chars[Self.ccv2GetInfoChar] != nil, chars[Self.ccv2NotifyStateChar] != nil {
            clearWatchdog("link")
            linkState = .ready
            // Seed lastFileUrl so the first shutter can't match a stale URL
            // (NotifyState only pushes CHANGES).
            if let state = chars[Self.ccv2GetStateChar] { peripheral.readValue(for: state) }
            linkPending?.resume()
            linkPending = nil
        } else if pendingCharDiscoveries == 0 {
            failLink("this camera doesn't expose Camera Control v2 over Bluetooth")
        }
    }

    /// Resolve a pending link with a truthful error (discovery finished, working set
    /// absent) instead of leaving it for the watchdog.
    func failLink(_ why: String) {
        guard let pending = linkPending else { return }
        clearWatchdog("link")
        linkPending = nil
        linkState = .failed(why)
        pending.resume(throwing: BLEError.unsupportedCamera(why))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        switch characteristic.uuid {
        case Self.ccv2GetInfoChar: resolveIdentity(obj)
        case Self.ccv2GetStateChar:
            lastStateReadAt = Date()
            if let status = obj["_captureStatus"] as? String { lastCaptureStatus = status }
            if let shots = obj["_capturedPictures"] as? Int { lastCapturedPictures = shots }
            lastFileUrl = (obj["_latestFileUrl"] as? String) ?? lastFileUrl
        case Self.ccv2GetOptionsChar: resolveOptions(obj)
        case Self.ccv2NotifyStateChar: resolveNotifyState(obj)
        default: break
        }
    }

    private func resolveIdentity(_ obj: [String: Any]) {
        guard let pending = infoPending else { return }
        clearWatchdog("info")
        infoPending = nil
        pending.resume(returning: Identity(
            model: obj["model"] as? String ?? "RICOH THETA",
            serial: obj["serialNumber"] as? String ?? "",
            firmware: obj["firmwareVersion"] as? String ?? ""))
    }

    private func resolveOptions(_ obj: [String: Any]) {
        guard let pending = optionsPending else { return }
        clearWatchdog("options")
        optionsPending = nil
        pending.resume(returning: obj["_networkType"] as? String)
    }

    /// NotifyState pushes CHANGES only — a new `_latestFileUrl` is the shutter's
    /// completion signal and doubles as the download ticket.
    private func resolveNotifyState(_ obj: [String: Any]) {
        guard let url = obj["_latestFileUrl"] as? String, !url.isEmpty, url != lastFileUrl else { return }
        lastFileUrl = url
        guard let pending = shutterPending else { return }
        clearWatchdog("shutter")
        shutterPending = nil
        pending.resume(returning: url)
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
