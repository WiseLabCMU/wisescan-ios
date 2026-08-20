import Foundation

// OSC (Open Spherical Camera) Web API v2.1 transport for ThetaCameraManager. Extracted
// from the manager so it stays under the file/type-body length limits and keeps a clean
// seam: these methods return primitives / manager types, so no OSC wire model leaks into
// the state/action layer. See ThetaCameraManager.swift.
extension ThetaCameraManager {

    // MARK: - Commands (manager-facing surface)

    /// GET `/osc/info` → model, firmware, serial.
    func fetchInfo() async throws -> ThetaDeviceInfo {
        let info = try await getJSON("/osc/info", as: OSCInfo.self)
        return ThetaDeviceInfo(model: info.model, firmware: info.firmwareVersion, serial: info.serialNumber)
    }

    /// POST `/osc/state` (empty body) → battery charge 0…1.
    func fetchBatteryLevel() async throws -> Double? {
        try await postJSON("/osc/state", body: [:], as: OSCStateResponse.self).state.batteryLevel
    }

    /// Reads the current still resolution from the `fileFormat` option.
    func fetchStillResolution() async throws -> StillFormat? {
        let body: [String: Any] = ["name": "camera.getOptions",
                                   "parameters": ["optionNames": ["fileFormat"]]]
        let response = try await postJSON("/osc/commands/execute", body: body, as: OSCOptionsResponse.self)
        if let error = response.error { throw ThetaError.osc(error.message ?? error.code ?? "getOptions failed") }
        guard let format = response.results?.options.fileFormat,
              let width = format.width, let height = format.height else { return nil }
        return StillFormat(width: width, height: height)
    }

    /// Applies a still resolution via `camera.setOptions`.
    func applyStillResolution(_ format: StillFormat) async throws {
        let body: [String: Any] = ["name": "camera.setOptions",
            "parameters": ["options": ["fileFormat": [
                "type": "jpeg", "width": format.width, "height": format.height
            ]]]]
        let response = try await postJSON("/osc/commands/execute", body: body, as: OSCCommandResponse.self)
        if let error = response.error { throw ThetaError.osc(error.message ?? error.code ?? "setOptions failed") }
    }

    /// Sets the camera's auto-sleep delay (OSC `sleepDelay`; 65535 = never). Keep-awake
    /// matters during active capture — a sleep/wake cycle re-derives the equirect
    /// yaw-reference (run14: 103° jump, rig untouched) and adds wake latency to still
    /// triggers — but an idle camera should be allowed to nap (battery kindness), so
    /// the capture tab's lifecycle drives this both ways.
    func setSleepDelaySeconds(_ seconds: Int) async throws {
        let body: [String: Any] = ["name": "camera.setOptions",
                                   "parameters": ["options": ["sleepDelay": seconds]]]
        let response = try await postJSON("/osc/commands/execute", body: body, as: OSCCommandResponse.self)
        if let error = response.error { throw ThetaError.osc(error.message ?? error.code ?? "setOptions failed for sleepDelay") }
    }

    /// Sets the `_topBottomCorrection` option (e.g. "Apply" or "Disapply").
    func setTopBottomCorrection(to mode: String) async throws {
        let body: [String: Any] = ["name": "camera.setOptions",
                                   "parameters": ["options": ["_topBottomCorrection": mode]]]
        let response = try await postJSON("/osc/commands/execute", body: body, as: OSCCommandResponse.self)
        if let error = response.error { throw ThetaError.osc(error.message ?? error.code ?? "setOptions failed for _topBottomCorrection") }
    }

    /// Reads the JPEG still resolutions the camera reports as supported via the
    /// `fileFormatSupport` option (a RICOH extension). Empty when the camera/firmware
    /// doesn't report it — callers fall back to a model table. Non-JPEG entries
    /// (e.g. RAW) are ignored.
    func fetchSupportedStillFormats() async throws -> [StillFormat] {
        let body: [String: Any] = ["name": "camera.getOptions",
                                   "parameters": ["optionNames": ["fileFormatSupport"]]]
        let response = try await postJSON("/osc/commands/execute", body: body, as: OSCOptionsResponse.self)
        if let error = response.error { throw ThetaError.osc(error.message ?? error.code ?? "getOptions failed") }
        guard let list = response.results?.options.fileFormatSupport else { return [] }
        return list.compactMap { format in
            guard format.type == "jpeg", let width = format.width, let height = format.height else { return nil }
            return StillFormat(width: width, height: height)
        }
    }

    /// Z1/V only: register this app's BLE identity over Wi-Fi
    /// (`camera._setBluetoothDevice`) — the prerequisite for BLE auth on those models.
    /// The X does not support this command (its v1 BLE family is vestigial; bonding
    /// replaced it). Returns the camera's BLE advertised deviceName (= serial digits).
    func registerBluetoothDevice(uuid: String) async throws -> String? {
        let body: [String: Any] = ["name": "camera._setBluetoothDevice",
                                   "parameters": ["uuid": uuid]]
        let response = try await postJSON("/osc/commands/execute", body: body, as: OSCBluetoothDeviceResponse.self)
        if let error = response.error { throw ThetaError.osc(error.message ?? error.code ?? "setBluetoothDevice failed") }
        return response.results?.deviceName
    }

    /// Z1/V: switch the camera's Bluetooth module (option `_bluetoothPower`).
    func setBluetoothPower(on enabled: Bool) async throws {
        let body: [String: Any] = ["name": "camera.setOptions",
                                   "parameters": ["options": ["_bluetoothPower": enabled ? "ON" : "OFF"]]]
        let response = try await postJSON("/osc/commands/execute", body: body, as: OSCCommandResponse.self)
        if let error = response.error { throw ThetaError.osc(error.message ?? error.code ?? "setOptions failed for _bluetoothPower") }
    }

    /// Normalize the camera's shooting state for scan stills. Two settings left on
    /// the camera would quietly corrupt a scan:
    ///   • `exposureDelay` (self-timer) — `camera.takePicture` honours it, so the
    ///     shutter would fire seconds AFTER we stamped the phone pose and measured the
    ///     trigger window; every still would carry a pose that isn't where it was shot.
    ///   • `captureMode: "video"` — stills aren't possible at all.
    /// Interval shooting itself does NOT hijack takePicture (that needs
    /// `camera.startCapture` with `_mode: "interval"`), but a capture already RUNNING
    /// does — see `stopRunningCapture`.
    /// Returns a description of what had to change (nil = nothing).
    func normalizeShootingState() async throws -> String? {
        let body: [String: Any] = ["name": "camera.getOptions",
                                   "parameters": ["optionNames": ["captureMode", "exposureDelay"]]]
        let current = try await postJSON("/osc/commands/execute", body: body, as: OSCOptionsResponse.self)
        let mode = current.results?.options.captureMode
        let delay = current.results?.options.exposureDelay ?? 0
        var options: [String: Any] = [:]
        var changed: [String] = []
        if let mode, mode != "image" {
            options["captureMode"] = "image"
            changed.append("captureMode \(mode)→image")
        }
        if delay != 0 {
            options["exposureDelay"] = 0
            changed.append("self-timer \(delay)s→off")
        }
        guard !options.isEmpty else { return nil }
        let setBody: [String: Any] = ["name": "camera.setOptions", "parameters": ["options": options]]
        let response = try await postJSON("/osc/commands/execute", body: setBody, as: OSCCommandResponse.self)
        if let error = response.error { throw ThetaError.osc(error.message ?? error.code ?? "setOptions failed") }
        return changed.joined(separator: ", ")
    }

    /// Current capture status from `/osc/state` ("idle" when the camera is free).
    func fetchCaptureStatus() async throws -> String? {
        try await postJSON("/osc/state", body: [:], as: OSCStateResponse.self).state._captureStatus
    }

    /// If the camera is mid-capture (interval/continuous/bracket/self-timer countdown),
    /// stop it — otherwise our shutter requests collide with a sequence the operator
    /// probably forgot was running. Returns the status it interrupted, if any.
    @discardableResult
    func stopRunningCapture() async throws -> String? {
        guard let status = try await fetchCaptureStatus(), status != "idle" else { return nil }
        // "converting" is the camera finishing a file — transient, not ours to stop.
        guard status != "converting" else { return status }
        let body: [String: Any] = ["name": "camera.stopCapture"]
        _ = try? await postJSON("/osc/commands/execute", body: body, as: OSCCommandResponse.self)
        return status
    }

    /// Total files on the camera (`camera.listFiles` with entryCount 0 returns just
    /// the count — no entries, no thumbnails). fileType: "all" | "image" | "video".
    /// NOTE the short timeout. `camera.listFiles` makes the camera enumerate its
    /// storage, which grows with the number of files on it, and this runs at the END of
    /// an already serial connect chain (info → leveling → shooting state → battery →
    /// resolution → formats → this). It is the only purely informational call in that
    /// chain, so it gets the shortest leash: a missing file count is a blank row, while
    /// eight seconds of it is a card that feels hung.
    func fetchFileCount(fileType: String = "all") async throws -> Int {
        let body: [String: Any] = ["name": "camera.listFiles",
                                   "parameters": ["fileType": fileType, "entryCount": 0,
                                                  "maxThumbSize": 0, "startPosition": 0]]
        let started = Date()
        defer {
            PerfDiag.log(String(format: "[Theta] listFiles took %d ms",
                                Int(Date().timeIntervalSince(started) * 1000)))
        }
        let response = try await postJSON("/osc/commands/execute", body: body,
                                          as: OSCListFilesResponse.self, timeout: 4)
        if let error = response.error { throw ThetaError.osc(error.message ?? error.code ?? "listFiles failed") }
        return response.results?.totalEntries ?? 0
    }

    /// URL of the newest image on the camera, or nil if it has none. Used to recover a
    /// still whose BLE capture CONFIRMATION never arrived: the shutter write was accepted,
    /// so the picture almost certainly exists — only the NotifyState push was lost. One
    /// entry, no thumbnail, so the camera enumerates as little as it can.
    func latestImageURL() async throws -> String? {
        let body: [String: Any] = ["name": "camera.listFiles",
                                   "parameters": ["fileType": "image", "entryCount": 1,
                                                  "maxThumbSize": 0, "startPosition": 0]]
        let response = try await postJSON("/osc/commands/execute", body: body,
                                          as: OSCListFilesResponse.self, timeout: 5)
        if let error = response.error { throw ThetaError.osc(error.message ?? error.code ?? "listFiles failed") }
        return response.results?.entries?.first?.fileUrl
    }

    /// The camera's clock offset versus the phone, measured to poll-interval precision by
    /// catching a SECOND TICK: poll `dateTimeZone` back-to-back until the returned second
    /// increments — at that moment the camera's clock just crossed a whole-second
    /// boundary, so cameraTime − phoneTime is known to roughly the gap between the last
    /// two polls plus half the HTTP round trip.
    ///
    /// WHY IT EXISTS (measurement brief, 2026-08-19): the Theta stamps EXIF
    /// DateTimeOriginal at 1 s resolution with no sub-second field, and its clock drifts
    /// 1–7 s/day — so EXIF alone yields shutter-latency-plus-clock-offset, never latency.
    /// With the offset stamped per scan, the ack→shutter latency λ falls out of every
    /// scan's EXIF offline, for free, forever — replacing a bench session that the
    /// archive analysis showed could never work anyway.
    ///
    /// Positive offset = the camera's clock is AHEAD of the phone's.
    func measureCameraClockOffset() async -> (offsetMs: Int64, uncertaintyMs: Int)? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssZZZZZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        func readClock() async -> (value: String, at: Date, rttMs: Int)? {
            let sent = Date()
            let body: [String: Any] = ["name": "camera.getOptions",
                                       "parameters": ["optionNames": ["dateTimeZone"]]]
            guard let response = try? await postJSON("/osc/commands/execute", body: body,
                                                     as: OSCGetOptionsResponse.self, timeout: 3),
                  let value = response.results?.options?.dateTimeZone else { return nil }
            let now = Date()
            return (value, now, Int(now.timeIntervalSince(sent) * 1000))
        }
        guard var previous = await readClock() else { return nil }
        let deadline = Date().addingTimeInterval(2.6)   // a tick MUST land within ~1 s + margin
        while Date() < deadline {
            guard let current = await readClock() else { return nil }
            if current.value != previous.value {
                guard let cameraSecond = formatter.date(from: current.value) else { return nil }
                // The tick happened between the two responses; take the midpoint of the
                // window [previous response, current response] as the boundary estimate.
                let windowMs = Int(current.at.timeIntervalSince(previous.at) * 1000)
                let boundary = previous.at.addingTimeInterval(Double(windowMs) / 2000)
                let offsetMs = Int64((cameraSecond.timeIntervalSince1970
                                      - boundary.timeIntervalSince1970) * 1000)
                return (offsetMs, windowMs / 2 + current.rttMs / 2)
            }
            previous = current
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return nil
    }

    /// Bulk erase. The spec's special values ("all" / "image" / "video") must be sent
    /// ALONE in fileUrls. Not permitted during video recording.
    /// Deletes ONE camera-side file by its URL — the single-file twin of the security
    /// sweep that runs after scan stills transfer. Failures are logged, never fatal: the
    /// bytes are already safe on the device, and a file we could not delete is a cleanup
    /// problem rather than a data-loss one.
    func deleteCameraFile(_ fileURL: String) async {
        do {
            _ = try await execute(name: "camera.delete", parameters: ["fileUrls": [fileURL]])
            log(.transfer, "Deleted the camera-side original after download")
        } catch {
            log(.transfer, "Could not delete the camera-side original (\(Self.describe(error)))")
        }
    }

    func deleteAllFiles(fileType: String = "all") async throws {
        let body: [String: Any] = ["name": "camera.delete",
                                   "parameters": ["fileUrls": [fileType]]]
        let response = try await postJSON("/osc/commands/execute", body: body, as: OSCCommandResponse.self)
        if let error = response.error { throw ThetaError.osc(error.message ?? error.code ?? "delete failed") }
    }

    /// Current WLAN mode as the camera reports it — "AP" (its own access point) or
    /// "CL" (joined someone else's network). CL is the field gotcha: the camera looks
    /// on and healthy but never advertises its SSID, so joining silently can't work.
        /// Fires `camera.takePicture` and resolves to the saved file URL (polls if async).
    func triggerStill(onAck: (() -> Void)? = nil) async throws -> String {
        let result = try await execute(name: "camera.takePicture")
        onAck?()   // command accepted — exposure starts about now (sway-window anchor)
        switch result {
        case .done(let url): return url
        case .inProgress(let id): return try await pollUntilDone(commandID: id)
        }
    }

    /// Downloads the bytes at a camera file URL.
    func downloadData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw ThetaError.badResponse(-1) }
        guard (200...299).contains(http.statusCode) else { throw ThetaError.badResponse(http.statusCode) }
        return data
    }

    // MARK: - execute / poll

    private enum ExecuteResult {
        case inProgress(String)   // command id to poll via /osc/commands/status
        case done(String)         // fileUrl returned synchronously
    }

    private func execute(name: String, parameters: [String: Any] = [:]) async throws -> ExecuteResult {
        var body: [String: Any] = ["name": name]
        if !parameters.isEmpty { body["parameters"] = parameters }
        let response = try await postJSON("/osc/commands/execute", body: body, as: OSCCommandResponse.self)
        if let error = response.error { throw ThetaError.osc(error.message ?? error.code ?? "unknown") }
        // Some commands return done immediately with a fileUrl and no id.
        if response.state == "done", let fileURL = response.results?.fileUrl { return .done(fileURL) }
        guard let id = response.id else { throw ThetaError.osc("no command id returned") }
        return .inProgress(id)
    }

    private func pollUntilDone(commandID: String) async throws -> String {
        let deadline = Date().addingTimeInterval(AppConstants.thetaCaptureTimeout)
        while Date() < deadline {
            let response = try await postJSON(
                "/osc/commands/status", body: ["id": commandID], as: OSCCommandResponse.self
            )
            switch response.state {
            case "done":
                guard let fileURL = response.results?.fileUrl else { throw ThetaError.noFileURL }
                return fileURL
            case "error":
                throw ThetaError.osc(response.error?.message ?? "camera reported an error")
            default:
                try await Task.sleep(nanoseconds: UInt64(AppConstants.thetaStatusPollInterval * 1_000_000_000))
            }
        }
        throw ThetaError.timeout
    }

    // MARK: - HTTP helpers

    private func getJSON<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        return try await send(request, as: type)
    }

    private func postJSON<T: Decodable>(_ path: String, body: [String: Any], as type: T.Type,
                                        timeout: TimeInterval? = nil) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        if let timeout { request.timeoutInterval = timeout }
        return try await send(request, as: type)
    }

    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ThetaError.badResponse(-1) }
        guard (200...299).contains(http.statusCode) else {
            // OSC errors arrive as JSON even on non-2xx; surface the message when present.
            if let osc = try? JSONDecoder().decode(OSCCommandResponse.self, from: data), let error = osc.error {
                throw ThetaError.osc(error.message ?? error.code ?? "HTTP \(http.statusCode)")
            }
            throw ThetaError.badResponse(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ThetaError.decode
        }
    }

    // MARK: - Errors

    enum ThetaError: Error {
        case badResponse(Int)
        case osc(String)
        case noFileURL
        case timeout
        case decode
    }

    /// True when the error indicates the camera link dropped (used to flip the badge).
    static func isConnectivityError(_ error: Error) -> Bool {
        error is URLError
    }

    /// User-facing one-liners; the Wi‑Fi hint is the common first-run failure.
    static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
                return "Can't reach the camera — join its Wi‑Fi in Settings, then retry."
            default:
                return "Network error: \(urlError.localizedDescription)"
            }
        }
        switch error {
        case ThetaError.badResponse(404):
            // A 404 from 192.168.1.1 means we reached a WEB SERVER that isn't the
            // camera — i.e. the phone is on some other network whose router answered
            // (field: home router, 360ble12). The camera join never happened.
            return "Reached a different device at the camera's address — you're on another "
                + "Wi-Fi network. Wake the camera and retry, or join its Wi-Fi in Settings."
        case ThetaError.badResponse(let code): return "Camera returned HTTP \(code)."
        case ThetaError.osc(let message): return "Camera error: \(message)."
        case ThetaError.noFileURL: return "Capture finished but no file URL was returned."
        case ThetaError.timeout: return "Capture timed out."
        case ThetaError.decode: return "Unexpected response from the camera."
        default: return error.localizedDescription
        }
    }
}

/// Camera identity returned by `fetchInfo()` (a struct rather than a tuple so the seam
/// stays lint-clean and self-documenting).
struct ThetaDeviceInfo {
    let model: String
    let firmware: String
    let serial: String?
}

// MARK: - OSC response models

private struct OSCInfo: Decodable {
    let model: String
    let firmwareVersion: String
    let serialNumber: String?
}

private struct OSCStateResponse: Decodable {
    struct State: Decodable {
        let batteryLevel: Double?
        let _captureStatus: String?   // swiftlint:disable:this identifier_name
    }
    let state: State
}

private struct OSCErrorBody: Decodable {
    let code: String?
    let message: String?
}

private struct OSCBluetoothDeviceResponse: Decodable {
    struct Results: Decodable { let deviceName: String? }
    let results: Results?
    let error: OSCErrorBody?
}

private struct OSCCommandResponse: Decodable {
    struct Results: Decodable { let fileUrl: String? }
    let id: String?
    let state: String
    let results: Results?
    let error: OSCErrorBody?
}

private struct OSCGetOptionsResponse: Decodable {
    struct Options: Decodable {
        let dateTimeZone: String?
    }
    struct Results: Decodable { let options: Options? }
    let results: Results?
    let error: OSCErrorBody?
}

private struct OSCListFilesResponse: Decodable {
    struct Entry: Decodable { let fileUrl: String? }
    struct Results: Decodable {
        let totalEntries: Int?
        let entries: [Entry]?
    }
    let results: Results?
    let error: OSCErrorBody?
}

private struct OSCOptionsResponse: Decodable {
    struct Results: Decodable { let options: Options }
    struct Options: Decodable {
        let fileFormat: FileFormat?
        let fileFormatSupport: [FileFormat]?
        let topBottomCorrection: String?
        let networkType: String?
        let captureMode: String?
        let exposureDelay: Int?
        // RICOH's extension options are underscore-prefixed on the wire.
        enum CodingKeys: String, CodingKey {
            case fileFormat, fileFormatSupport, captureMode, exposureDelay
            case topBottomCorrection = "_topBottomCorrection"
            case networkType = "_networkType"
        }
    }
    struct FileFormat: Decodable { let type: String?; let width: Int?; let height: Int? }
    let results: Results?
    let error: OSCErrorBody?
}
