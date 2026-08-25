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
        guard isTracked(peripheral) else { return }
        // PERMANENT discovery breadcrumb (one .notice per connect, see also
        // didDiscoverServices / didDiscoverCharacteristicsFor). Kept, not diagnostic
        // scaffolding: on 2026-08-25 these three lines localised an uncatchable
        // CoreBluetooth crash that a backtrace alone could not — the last one printed
        // before the process died named the call site — and then read the stale-cache
        // recovery end-to-end. BLE is this app's most failure-prone subsystem and this
        // costs nothing per frame, so the trail stays. `.notice` to survive an export.
        Self.log.notice("BLE step: connected, discovering the CCv2 service on \(peripheral.identifier.uuidString, privacy: .public)")
        // Scoped, NOT nil. Discovering all services made CoreBluetooth reconcile the whole
        // cached attribute table — 10 services on a device that exposes far fewer, i.e. a
        // stale/duplicated GATT cache (#49) — and it crashed dispatching an internal service
        // callback onto a mismatched handle (2026-08-25, five reproductions). We need only
        // the CCv2 service, so ask for only it: CoreBluetooth then reconciles one handle,
        // not ten, and the corrupt cached extras are never touched. Correct production
        // practice regardless of the crash — nil-discovery never belonged here.
        peripheral.discoverServices([Self.ccv2Service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard isTracked(peripheral) else { return }
        linkState = .failed(error?.localizedDescription ?? "connect failed")
        linkPending?.resume(throwing: BLEError.timeout(error?.localizedDescription ?? "connect failed"))
        linkPending = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // CoreBluetooth is finished with it: safe to drop the reference teardown() held
        // across the async cancel. Runs BEFORE the isTracked gate, because a peripheral we
        // deliberately retired is by definition no longer the tracked one.
        releaseRetired(peripheral.identifier)
        // Characteristics belong to the link that just ended, tracked or not — dropping
        // them here is what stops a later call handing one to a different peripheral.
        chars = chars.filter { $0.value.service?.peripheral?.identifier != peripheral.identifier }
        guard isTracked(peripheral) else { return }
        // `.notice` + onLog, not `.info`: `.info` is memory-only in the unified log, so a
        // mid-scan link drop never reached a pulled diagnostics bundle. On 2026-08-18 the
        // link dropped after one refused write and the remaining five stills quietly ran
        // OSC — with nothing in the export saying the link had gone.
        let detail = error.map { " (" + $0.localizedDescription + ")" } ?? ""
        Self.log.notice("link dropped\(detail, privacy: .public)")
        onLog?("BLE link dropped\(detail)")
        noteUnproductiveLink(error)
        chars.removeAll()
        linkState = .idle
        controlVerifiedForLink = false
        failAllPending(BLEError.linkNotReady)
    }
}

// MARK: - CBPeripheralDelegate

extension ThetaBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        // Only act on the peripheral this manager is actually driving, and only when the
        // discovery SUCCEEDED. Discovering characteristics against a service from a
        // superseded connection is how CoreBluetooth ends up dispatching an internal
        // service callback to a reused object — the
        // "-[CBCharacteristic handleCharacteristicsDiscovered:]" crash seen 2026-08-21.
        guard isTracked(peripheral) else { return }
        if let error {
            Self.log.notice("service discovery failed: \(error.localizedDescription, privacy: .public)")
            failLink("service discovery failed")
            return
        }
        let services = peripheral.services ?? []
        pendingCharDiscoveries = services.count
        guard !services.isEmpty else {
            failLink("this camera exposed no BLE services")
            return
        }
        Self.log.notice("BLE step: \(services.count, privacy: .public) service(s) found, discovering CCv2 characteristics")
        for service in services {
            peripheral.discoverCharacteristics(Self.ccv2Characteristics, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard isTracked(peripheral) else { return }
        if let error {
            Self.log.notice("characteristic discovery failed on \(service.uuid.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            pendingCharDiscoveries = max(0, pendingCharDiscoveries - 1)
            return
        }
        let found = service.characteristics ?? []
        Self.log.notice("BLE step: \(found.count, privacy: .public) characteristic(s) on service \(service.uuid.uuidString.prefix(8), privacy: .public)")
        for char in found {
            chars[char.uuid] = char
        }
        pendingCharDiscoveries = max(0, pendingCharDiscoveries - 1)
        // Collect only; issue no CoreBluetooth call until every service's discovery has
        // completed. Making a peripheral call from inside a per-service callback while
        // siblings are still in flight is needless re-entrancy — hygiene, not the crash
        // fix (that was scoping discovery to one service; see didConnect). Subscribe once,
        // after the storm.
        guard pendingCharDiscoveries == 0 else { return }
        subscribeNotifyState(peripheral)
        guard linkPending != nil else { return }
        // MINIMUM working set = identity + state push. Both the X and a Z1 on
        // fw ≥ 3.10.2 expose these unauthenticated; the control characteristics are
        // a separate capability (canWake/canShutterOverBLE). Requiring all four made
        // every Z1 link hang until the watchdog cancelled it — the field's "link
        // dropped" was OUR cancel, not the camera (360ble10).
        if chars[Self.ccv2GetInfoChar] != nil, chars[Self.ccv2NotifyStateChar] != nil {
            clearWatchdog("link")
            linkState = .ready
            controlVerifiedForLink = false
            linkReadyAt = Date()
            staleCacheStrikes = 0
            actionRequired = nil
            // Property bitmasks at link-ready settle the next refusal in one line: if a
            // control characteristic still advertises .write when the camera answers ATT
            // 0x03, the attribute table iOS cached has moved (stale GATT cache); if .write
            // is gone, the camera itself withdrew the capability.
            let controlProps = [Self.ccv2ShutterChar, Self.ccv2SetOptionsChar, Self.ccv2GetOptionsChar]
                .compactMap { uuid -> String? in
                    guard let char = chars[uuid] else { return nil }
                    return "\(uuid.uuidString.prefix(8))=\(ThetaBLEProbe.describeProps(char.properties))"
                }.joined(separator: " ")
            onLog?("BLE link ready — control chars: \(controlProps.isEmpty ? "none" : controlProps)")
            // Seed lastFileUrl so the first shutter can't match a stale URL
            // (NotifyState only pushes CHANGES).
            // Read through the validator, never the raw dictionary — see liveCharacteristic.
            if let state = liveCharacteristic(Self.ccv2GetStateChar) { peripheral.readValue(for: state) }
            linkPending?.resume()
            linkPending = nil
        } else if pendingCharDiscoveries == 0 {
            // The CCv2 service was found but its characteristics did not populate — the
            // stale/corrupt iOS GATT cache from #49, now corrupt WITHIN the service itself
            // (2026-08-25: service B6AC7A7E present, 0 characteristics). Discovering only
            // this service stopped the crash, but the cache still cannot serve a working
            // link, and no app-side call can repopulate it — only iOS clearing the bond can.
            // Distinguish it from a genuinely CCv2-less camera so the message is truthful
            // and actionable, and stop the reconnect churn on a peripheral that cannot
            // recover until the operator acts.
            let serviceSeen = (peripheral.services ?? []).contains { $0.uuid == Self.ccv2Service }
            if serviceSeen {
                staleCacheStrikes += 1
                let guidance = "This camera's Bluetooth data is stale — the connection succeeds but "
                    + "carries no working commands, and only iOS can refresh it.\n\n"
                    + "Open Settings → Bluetooth, tap the ⓘ next to the camera, choose Forget This "
                    + "Device, then pair it again from Add Camera. (Wi-Fi capture still works in the "
                    + "meantime.)"
                onLog?(guidance)
                actionRequired = guidance
                failLink("stale BLE cache — the CCv2 service returned no characteristics")
                // A corrupt cache does not fix itself; a reconnect just re-reads the same
                // bad cache. After two strikes, stop auto-retrying and drop the link fully
                // so the operator is not stuck in a silent connect/fail loop.
                if staleCacheStrikes >= 2 {
                    onLog?("Bluetooth auto-retry stopped — re-pair to continue (Wi-Fi capture still works).")
                    teardown()
                }
            } else {
                failLink("this camera doesn't expose Camera Control v2 over Bluetooth")
            }
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

    /// Subscribe to the NotifyState push channel, ONCE, after all characteristic
    /// discovery has completed. Kept out of the per-service discovery callback on purpose
    /// — issuing a CoreBluetooth operation while sibling discoveries are still in flight
    /// is what crashed the app (see didDiscoverCharacteristicsFor).
    private func subscribeNotifyState(_ peripheral: CBPeripheral) {
        guard let notify = liveCharacteristic(Self.ccv2NotifyStateChar) else { return }
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard isTracked(peripheral) else { return }
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
        guard isTracked(peripheral) else { return }
        guard let pending = writePending.removeValue(forKey: characteristic.uuid) else { return }
        clearWatchdog(characteristic.uuid.uuidString)
        if let error {
            // Classify, don't stringify. An ATT refusal of a control write is a different
            // disease from a link that went away: iOS escalates security and retries on
            // 0x05/0x0F/0x0C, but on 0x03 (write-not-permitted) it does nothing at all —
            // no passkey dialog, no retry, and the refusal repeats for the life of the
            // bond. Only an operator re-pair clears it, so it must not be swallowed as a
            // generic write failure or answered with a reconnect loop.
            let attCodes: Set<CBATTError.Code> = [.writeNotPermitted, .insufficientAuthentication,
                                                  .insufficientEncryption, .insufficientAuthorization,
                                                  .invalidHandle]
            let nsError = error as NSError
            if nsError.domain == CBATTErrorDomain,
               let code = CBATTError.Code(rawValue: nsError.code), attCodes.contains(code) {
                Self.log.notice("control write REFUSED on \(characteristic.uuid.uuidString, privacy: .public): ATT 0x\(String(nsError.code, radix: 16), privacy: .public) \(error.localizedDescription, privacy: .public)")
                controlVerifiedForLink = false
                pending.resume(throwing: BLEError.controlRefused(code))
            } else {
                pending.resume(throwing: BLEError.writeFailed(error.localizedDescription))
            }
        } else {
            pending.resume()
        }
    }
}
