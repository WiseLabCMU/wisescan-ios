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
        /// The link is up and the control characteristic is present, but the camera
        /// REFUSED the write at the ATT layer. Distinguished from `.writeFailed` because
        /// the remedy is an operator action, not a retry: on 0x03 (write-not-permitted)
        /// iOS does not escalate security, does not show a passkey prompt and does not
        /// retry — it is deterministic in milliseconds and permanent for the life of the
        /// bond. Observed 4/4 on 2026-08-18 across three connect cycles over 6.5 minutes,
        /// on the same firmware that had fired the BLE shutter cold the day before, so it
        /// is a stale iOS GATT cache or a camera-side authorization state — either way,
        /// cured only by forgetting the device and re-pairing.
        case controlRefused(CBATTError.Code)
        var errorDescription: String? {
            switch self {
            case .bluetoothOff: return "Bluetooth is off"
            case .timeout(let what): return "Timed out: \(what)"
            case .writeFailed(let what): return "Write failed: \(what)"
            case .linkNotReady: return "BLE link not ready"
            case .unsupportedCamera(let why): return why
            case .needsWiFiSetup(let model, _): return "\(model) needs Wi-Fi setup first"
            case .controlRefused:
                return "The camera refused Bluetooth control. In Settings → Bluetooth, "
                    + "tap the ⓘ next to the camera and Forget This Device, then pair it "
                    + "again from Add Camera."
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

    // X-native v2 service + characteristics (see ThetaBLEProbe for the full discovery map).
    // The manager needs ONLY this one service: every characteristic below lives in it.
    static let ccv2Service = CBUUID(string: "B6AC7A7E-8C01-4A52-B188-68D53DF53EA2")
    static let ccv2GetInfoChar = CBUUID(string: "A0452E2D-C7D8-4314-8CD6-7B8BBAB4D523")
    static let ccv2GetStateChar = CBUUID(string: "083D92B0-21E0-4FB2-9503-7D8B2C2BB1D1")
    static let ccv2NotifyStateChar = CBUUID(string: "D32CE140-B0C2-4C07-AF15-2301B5057B8C")
    /// Stamped whenever a GetState value lands — the liveness probe watches it change.
    var lastStateReadAt: Date?
    /// Latest `_captureStatus` seen on a GetState read. NotifyState never pushes this
    /// (probe rounds 4-8 — it only pushes _latestFileUrl, battery and temps), so it is
    /// only current if something is polling.
    /// Latest `_captureStatus` / `_capturedPictures` seen on a GetState read. NOTE: on
    /// the X these do NOT move for a single still — a probe polling at 40 Hz through
    /// four captures saw only "idle/0" (2026-08-17), so the shutter instant is not
    /// observable over BLE and ack + allowance remains the only estimate.
    var lastCaptureStatus: String?
    var lastCapturedPictures: Int?

    /// Polls GetState until `_captureStatus` leaves idle and returns again, timing both
    /// edges from `origin`. This is the ONLY direct measurement of when the shutter
    /// actually fires: the write-ack proves the camera ACCEPTED the command, and the
    /// sway window and the "you can move" release are both anchored on that assumption
    /// plus a fixed latency allowance. Field reports of the camera's own audible shutter
    /// landing later than our release are what this exists to settle.
    ///
    static let ccv2SetOptionsChar = CBUUID(string: "F0BCD2F9-5862-4653-B50D-80DC51E8CB82")
    static let ccv2ShutterChar = CBUUID(string: "6E2DEEBE-88B0-42A5-829D-1B2C6ABCE750")
    static let ccv2GetOptionsChar = CBUUID(string: "7CFFAAE3-8467-4D0C-A9DD-7F70B4F52863")
    /// The exact characteristics the manager consumes — passed to discoverCharacteristics
    /// so CoreBluetooth reconciles only these, never the full cached attribute table.
    static let ccv2Characteristics = [ccv2GetInfoChar, ccv2GetStateChar, ccv2NotifyStateChar,
                                      ccv2SetOptionsChar, ccv2ShutterChar, ccv2GetOptionsChar]

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
    /// Readiness is a write ACK coming back clean, not a characteristic existing. On
    /// 2026-08-18 the shutter characteristic was present and `isLinkReady` was true for
    /// the whole session while every control write was refused at the ATT layer, so the
    /// record-start gate never fired and six stills silently fell back to OSC. See
    /// `verifyControlWritable`.
    var canShutterOverBLE: Bool {
        isLinkReady && chars[Self.ccv2ShutterChar] != nil && controlVerifiedForLink
    }
    /// Scoped to the PHYSICAL LINK, never the app session: cleared on disconnect and at
    /// the top of `establishLink`, because a fresh connection is the only thing that can
    /// re-trigger encryption or re-read a moved attribute table.
    var controlVerifiedForLink = false
    /// When this link reached `.ready`, and how many times in a row a link has reached
    /// ready and then died without a single successful control operation. See
    /// `noteUnproductiveLink` — that pattern is the half-cleared-pairing signature.
    var linkReadyAt: Date?
    var unproductiveLinkCycles = 0
    /// Consecutive connects where the CCv2 service was present but returned no
    /// characteristics — the corrupt-cache signature. Two ⇒ stop auto-retrying; the cache
    /// cannot self-heal and only an operator re-pair fixes it. Reset on a clean link and
    /// on establishLink.
    var staleCacheStrikes = 0
    /// Mirrors key events into ThetaCameraManager's card log (wired at its init).
    var onLog: ((String) -> Void)?
    /// A blocking condition the operator must resolve OUTSIDE the app — currently only the
    /// corrupt iOS GATT cache (Forget This Device in iOS Settings). Observable so the UI
    /// can raise a prominent alert rather than leaving the fix buried in the event log.
    /// nil = nothing to act on. Cleared automatically on the next clean link.
    var actionRequired: String?

    var central: CBCentralManager?
    var peripheral: CBPeripheral?
    var chars: [CBUUID: CBCharacteristic] = [:]
    /// Outstanding per-service characteristic discoveries — lets us tell "still
    /// enumerating" from "enumeration finished and the working set never appeared",
    /// so an unsupported camera fails with the TRUTH instead of eating the link
    /// watchdog and reporting "camera did not answer" (which it plainly did).
    var pendingCharDiscoveries = 0

    /// A stored characteristic, but ONLY if it still belongs to the peripheral we are
    /// driving. Belt to `establishLink`'s braces: any path that reaches a stale
    /// characteristic and hands it to CoreBluetooth crashes the process from inside
    /// CoreBluetooth, where nothing in Swift can intervene — so every use goes through
    /// here rather than subscripting `chars` directly.
    func liveCharacteristic(_ uuid: CBUUID) -> CBCharacteristic? {
        guard let char = chars[uuid], let peripheral else { return nil }
        guard char.service?.peripheral?.identifier == peripheral.identifier else {
            Self.log.notice("dropped a stale characteristic \(uuid.uuidString, privacy: .public) from a previous link")
            chars.removeValue(forKey: uuid)
            return nil
        }
        return char
    }

    /// Is this the peripheral this manager is currently driving?
    ///
    /// Every delegate callback checks it. CoreBluetooth keeps delivering callbacks for a
    /// peripheral after we have moved on — a superseded connect attempt, a camera switch,
    /// a teardown that raced an in-flight discovery — and acting on those means driving
    /// discovery against objects from a connection that no longer exists. On 2026-08-21
    /// that produced a hard crash:
    /// `-[CBCharacteristic handleCharacteristicsDiscovered:]: unrecognized selector`,
    /// CoreBluetooth's own internals dispatching a service callback onto a reused object,
    /// after a day of reconnect churn and a stale GATT cache. An NSException from inside
    /// CoreBluetooth cannot be caught in Swift, so the only defence is not provoking it.
    func isTracked(_ candidate: CBPeripheral) -> Bool {
        candidate.identifier == peripheral?.identifier
    }
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
        } catch ThetaBLEManager.BLEError.controlRefused {
            // This is where 2026-08-18 first announced the problem — six minutes and one
            // wasted still before anyone acted on it. Say what fixes it, right here.
            onLog?("The camera refused Bluetooth control — Settings → Bluetooth → ⓘ next to the "
                   + "camera → Forget This Device, then pair it again from Add Camera. "
                   + "Trying Wi-Fi directly.")
            Self.log.notice("BLE wake refused at the ATT layer — bond needs to be rebuilt")
            return false
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
        guard isLinkReady, let peripheral, let shutter = liveCharacteristic(Self.ccv2ShutterChar) else {
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
        guard isLinkReady, let peripheral, let char = liveCharacteristic(Self.ccv2GetStateChar) else { return false }
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
              let peripheral, let char = liveCharacteristic(Self.ccv2GetOptionsChar) else { return nil }
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

    /// Prove the control plane actually accepts writes on THIS link, without taking a
    /// picture.
    ///
    /// PROBE WITH THE WAKE WRITE, on SetOptions. The first version of this probed
    /// GetOptions instead, and on 2026-08-19 that produced a false negative that cost a
    /// whole scan's worth of BLE shutters: the wake write to SetOptions succeeded at
    /// 10:14:09, and the GetOptions probe was refused at 10:15:47 — two DIFFERENT
    /// characteristics, and neither of them the shutter. A refusal on GetOptions says
    /// nothing about whether the shutter would fire, so gating on it was gating on
    /// unrelated evidence. `cameraPower: on` is the exact write the wake path already
    /// performs, it is proven to work on this hardware, and it is idempotent — the camera
    /// is awake by the time this runs, so it does nothing at all.
    @discardableResult
    func verifyControlWritable(timeout: TimeInterval = 4) async -> Bool {
        guard isLinkReady, chars[Self.ccv2SetOptionsChar] != nil else {
            controlVerifiedForLink = false
            return false
        }
        if controlVerifiedForLink { return true }
        do {
            try await writeJSON("{\"cameraPower\":\"on\"}",
                                to: Self.ccv2SetOptionsChar, timeout: timeout)
            controlVerifiedForLink = true
            return true
        } catch {
            controlVerifiedForLink = false
            let refused = (error as? BLEError).map { if case .controlRefused = $0 { return true } else { return false } } ?? false
            onLog?(refused
                   ? "BLE control REFUSED by the camera — forget it in Settings → Bluetooth and re-pair"
                   : "BLE control probe failed: \(error.localizedDescription)")
            Self.log.notice("control writability probe failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Ready, then dead again inside the ATT transaction timeout, with nothing to show
    /// for it — twice in a row. That is not a flaky radio, it is a PAIRING THAT ONLY ONE
    /// SIDE FORGOT: the open CCv2 subset (GetInfo, NotifyState presence) enumerates on an
    /// unencrypted link, so the link goes ready; then the NotifyState subscribe — a CCCD
    /// write on an attribute the camera still believes is bonded — stalls for 30 s and
    /// CoreBluetooth drops the connection. Clearing the bond on the phone alone produces
    /// exactly this, because the camera keeps its half.
    ///
    /// Nothing in software can re-pair from here: iOS will not raise the passkey dialog
    /// while the camera thinks it is already bonded. Say so, once, instead of looping.
    func noteUnproductiveLink(_ error: Error?) {
        guard let readyAt = linkReadyAt, !controlVerifiedForLink,
              Date().timeIntervalSince(readyAt) < 45 else {
            if controlVerifiedForLink { unproductiveLinkCycles = 0 }
            linkReadyAt = nil
            return
        }
        linkReadyAt = nil
        unproductiveLinkCycles += 1
        let paired = (error as? CBError).map {
            $0.code == .peerRemovedPairingInformation || $0.code == .encryptionTimedOut
        } ?? false
        guard paired || unproductiveLinkCycles == 2 else { return }
        // Order matters and was established the hard way (2026-08-18): clearing the pairing
        // on the CAMERA alone does not free it, and neither does Forget This Camera in the
        // app — the decisive step is iOS's own bond record in Settings → Bluetooth. Lead
        // with that one.
        let advice = "The camera's Bluetooth pairing is out of sync — it connects, then drops "
            + "after about 30 s without ever accepting a command. Fix it in this order: "
            + "1) iOS Settings → Bluetooth → ⓘ next to the camera → Forget This Device (this "
            + "is the step that actually releases it). 2) Clear the pairing on the camera's "
            + "own screen. 3) Forget This Camera here, then Add Camera → Find Camera via "
            + "Bluetooth and enter the passkey."
        onLog?(advice)
        Self.log.notice("unproductive link cycle \(self.unproductiveLinkCycles, privacy: .public) — pairing out of sync (camera still bonded, phone is not)")
        unproductiveLinkCycles = 0
    }

    /// One real recovery attempt for a refused control plane: a fresh connection is the
    /// only thing that can re-trigger encryption or re-read a moved attribute table.
    /// A second refusal is conclusive — do not loop.
    func recoverControlPlane() async -> Bool {
        teardown()
        guard (try? await ensureLinkReady()) != nil else { return false }
        return await verifyControlWritable()
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
    /// Peripherals whose disconnect we have REQUESTED but which CoreBluetooth has not
    /// finished with yet.
    ///
    /// `cancelPeripheralConnection` is asynchronous. CoreBluetooth does NOT retain the
    /// CBPeripheral for you — if the last strong reference goes away while it still has
    /// operations in flight, its internal attribute bookkeeping is left pointing at freed
    /// memory. That is the 2026-08-21/25 launch crash: `-[CBCharacteristic
    /// handleCharacteristicsDiscovered:]: unrecognized selector` — an internal SERVICE
    /// callback dispatched onto whatever object now occupies the reused allocation. It
    /// reproduced immediately after "Camera forgotten", the one path that runs disconnect()
    /// and teardown() back to back, and it throws from inside CoreBluetooth where no Swift
    /// guard or catch can reach it.
    ///
    /// So the peripheral stays alive here until `didDisconnectPeripheral` confirms
    /// CoreBluetooth is done with it, or the backstop expires.
    private var retiring: [CBPeripheral] = []

    func teardown() {
        failAllPending(BLEError.linkNotReady)
        central?.stopScan()
        if let peripheral {
            // Hold a strong reference across the async cancel — see `retiring`.
            retiring.append(peripheral)
            central?.cancelPeripheralConnection(peripheral)
            // Backstop: if the disconnect callback never arrives (peripheral already gone,
            // Bluetooth toggled), release after a grace period rather than leaking. Long
            // enough that a real disconnect callback always wins the race.
            let identifier = peripheral.identifier
            armWatchdog("retire-\(identifier.uuidString)", 10) { [weak self] in
                self?.releaseRetired(identifier)
            }
        }
        peripheral = nil
        chars.removeAll()
        pendingCharDiscoveries = 0
        linkState = .idle
    }

    /// Drop the strong reference held across a requested disconnect.
    func releaseRetired(_ identifier: UUID) {
        guard retiring.contains(where: { $0.identifier == identifier }) else { return }
        // Stop delegate traffic before the object goes: CoreBluetooth's `delegate` is an
        // unsafe-unretained reference, so a callback arriving after we are gone is its own
        // hazard, separate from the peripheral's lifetime.
        for peripheral in retiring where peripheral.identifier == identifier {
            peripheral.delegate = nil
        }
        retiring.removeAll { $0.identifier == identifier }
        clearWatchdog("retire-\(identifier.uuidString)")
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
