import Foundation
import Observation

/// Connection + shutter-trigger manager for a Ricoh Theta 360° camera, driving the
/// **still-source spike** on `feat/still-source-360` (see docs/design/still-source-360.md).
///
/// SPIKE SCOPE — deliberately minimal:
/// - Transport is **Wi‑Fi + raw OSC HTTP** (the Open Spherical Camera Web API v2.1, a
///   published spec). This validates the P2 viability questions (connection + trigger
///   round-trip latency) with **no external dependencies**.
/// - The user joins the camera's Wi‑Fi AP **manually** (iOS Settings). We confirm the
///   link by probing the fixed OSC endpoint.
/// - No BLE trigger, no `NEHotspotConfiguration` auto-join, no `theta-client` SDK, no
///   image download / rig calibration / cube-map export. Those are the design doc's
///   P3/P4 work and are intentionally out of scope here.
///
/// Theta X speaks OSC API level 2.1, so still capture needs **no explicit session**
/// (`camera.startSession` was an API-2.0 requirement) — `camera.takePicture` is issued
/// directly, then polled to completion.
@Observable
@MainActor
final class ThetaCameraManager {
    static let shared = ThetaCameraManager()

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected(model: String, firmware: String)
        case failed(String)
    }

    /// Result of one successful shutter trigger — the file URL the camera assigned and the
    /// wall-clock round trip (trigger → "done"), the number the P2 spike is measuring.
    struct CaptureOutcome: Equatable {
        let fileURL: String
        let roundTripMs: Int
    }

    private(set) var state: ConnectionState = .disconnected
    /// Battery charge 0…1 from `/osc/state`, when known.
    private(set) var batteryLevel: Double?
    private(set) var isCapturing = false
    private(set) var lastCapture: CaptureOutcome?
    private(set) var lastError: String?

    /// Theta **direct (AP) mode** default host. Client/LAN mode uses a different address;
    /// left mutable so the spike can point at either without a rebuild.
    var host = "192.168.1.1"
    private var baseURL: URL { URL(string: "http://\(host)")! }

    /// Ephemeral, Wi‑Fi-only session: the camera is a local AP with no internet, so we
    /// forbid cellular (and keep no cookie/cache state between spike runs).
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 20
        cfg.waitsForConnectivity = false
        cfg.allowsCellularAccess = false
        return URLSession(configuration: cfg)
    }()

    private init() {}

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    // MARK: - Connection

    /// Probes `/osc/info` (and `/osc/state`) to confirm the phone is on the camera's
    /// network. Triggered by an explicit Dashboard tap — NOT on appear — so iOS's
    /// Local Network permission prompt only surfaces on a deliberate user action.
    func refreshConnection() {
        guard state != .connecting else { return }
        state = .connecting
        lastError = nil
        Task { await probe() }
    }

    private func probe() async {
        do {
            let info = try await getInfo()
            state = .connected(model: info.model, firmware: info.firmwareVersion)
            batteryLevel = try? await getBatteryLevel()
        } catch {
            batteryLevel = nil
            state = .failed(Self.describe(error))
        }
    }

    // MARK: - Trigger

    /// Fires the shutter and polls to completion, recording the file URL + round-trip time.
    /// No-op unless connected and no capture is already in flight.
    func takePicture() {
        guard isConnected, !isCapturing else { return }
        isCapturing = true
        lastError = nil
        Task {
            let start = Date()
            do {
                let fileURL: String
                switch try await execute(name: "camera.takePicture") {
                case .done(let url): fileURL = url                       // completed synchronously
                case .inProgress(let id): fileURL = try await pollUntilDone(commandID: id)
                }
                let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
                lastCapture = CaptureOutcome(fileURL: fileURL, roundTripMs: elapsedMs)
                batteryLevel = try? await getBatteryLevel()
            } catch {
                lastError = Self.describe(error)
                // A capture failure often means the AP dropped — reflect that in the badge.
                if case .urlError = Self.classify(error) { state = .failed(Self.describe(error)) }
            }
            isCapturing = false
        }
    }

    // MARK: - OSC Web API (v2.1)

    private func getInfo() async throws -> OSCInfo {
        try await getJSON("/osc/info", as: OSCInfo.self)
    }

    private func getBatteryLevel() async throws -> Double? {
        // /osc/state is a POST with an empty body per the OSC spec.
        try await postJSON("/osc/state", body: [:], as: OSCStateResponse.self).state.batteryLevel
    }

    private enum ExecuteResult {
        case inProgress(String)   // command id to poll via /osc/commands/status
        case done(String)         // fileUrl returned synchronously
    }

    /// POST `/osc/commands/execute`.
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

    /// Polls `/osc/commands/status` until the command finishes; returns its file URL.
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

    private enum ErrorClass { case urlError, other }
    private static func classify(_ error: Error) -> ErrorClass {
        error is URLError ? .urlError : .other
    }

    /// User-facing one-liners; the Wi‑Fi hint is the common first-run failure.
    private static func describe(_ error: Error) -> String {
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

private struct OSCCommandResponse: Decodable {
    struct Results: Decodable { let fileUrl: String? }
    struct OSCErrorBody: Decodable { let code: String?; let message: String? }
    let id: String?
    let state: String
    let results: Results?
    let error: OSCErrorBody?
}
