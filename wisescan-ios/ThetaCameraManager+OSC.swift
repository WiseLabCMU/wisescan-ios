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

    /// Fires `camera.takePicture` and resolves to the saved file URL (polls if async).
    func triggerStill() async throws -> String {
        switch try await execute(name: "camera.takePicture") {
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

    private func postJSON<T: Decodable>(_ path: String, body: [String: Any], as type: T.Type) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
    struct State: Decodable { let batteryLevel: Double? }
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

private struct OSCOptionsResponse: Decodable {
    struct Results: Decodable { let options: Options }
    struct Options: Decodable {
        let fileFormat: FileFormat?
        let fileFormatSupport: [FileFormat]?
        let _topBottomCorrection: String?
    }
    struct FileFormat: Decodable { let type: String?; let width: Int?; let height: Int? }
    let results: Results?
    let error: OSCErrorBody?
}
