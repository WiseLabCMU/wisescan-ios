import Foundation

// MARK: - Control plane HTTP client (scan4d-server README, "API")

/// Talks to the lab's control plane server. No auth yet: the server lives on the internal
/// network and the app knows only its host (Settings → Control plane). Requests go through
/// `ControlPlaneSession`, which can accept the lab's own certificate.
nonisolated struct ControlPlaneClient: Sendable {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
        ControlPlaneSession.allow(host: baseURL.host())
    }

    nonisolated struct Health: Decodable, Sendable {
        let status: String
        let version: String
        let api: Int
    }

    nonisolated struct SyncReply: Decodable, Sendable {
        let maps: Int
        let scans: Int
        let links: Int
        let markedGone: Int
        /// Map-package files the server asks for (absent from servers before map packages).
        let wanted: [WantedFile]?
        /// Fine-tunes to apply: the web's edits, or the revision number of this device's own.
        let linkUpdates: [LinkUpdate]?
        let uploadTarget: UploadTarget?
    }

    nonisolated struct WantedFile: Decodable, Sendable {
        let scanId: String
        let name: String
        let size: Int64
        /// "eager" (the server's own logic reads it) or "requested: <why>" (someone needs it).
        let reason: String?
    }

    nonisolated struct StoredFile: Decodable, Sendable {
        let name: String
        let size: Int64
    }

    nonisolated struct Nudge: Decodable, Sendable, Equatable {
        let yawDeg: Double
        let dx: Double
        let dy: Double
        let dz: Double
    }

    nonisolated struct LinkUpdate: Decodable, Sendable {
        let linkId: String
        let revision: Int
        let manual: Nudge
    }

    /// Whether exports go through the server's grants (scan4d-server README, "Export uploads").
    nonisolated struct UploadTarget: Decodable, Sendable, Equatable {
        let available: Bool
        let revoked: Bool
        let bucket: String?
    }

    /// A presigned PUT for one export.
    nonisolated struct ExportGrant: Decodable, Sendable {
        let exportId: String
        let method: String
        let url: URL
        let headers: [String: String]
        let key: String
    }

    /// The server asking this device to scan a region (scan4d-server README, "Tasks").
    nonisolated struct ScanTask: Sendable, Identifiable, Equatable {
        let id: UUID
        let mapId: UUID
        let mapName: String
        let reason: String
        let status: String
        /// "high" alerts once; "normal" waits in the to-do list.
        let priority: String
        let region: FocusRegion

        var isUrgent: Bool { priority == "high" }
    }

    nonisolated struct SyncResult: Sendable {
        let reply: SyncReply
        let tasks: [ScanTask]
    }

    nonisolated enum Failure: LocalizedError, Equatable {
        case server(status: Int, detail: String)
        case unreadableReply
        case insecureHost(String)
        case untrustedCertificate(String)
        case unreachable(String)
        case unauthorized
        /// A large file held back on a metered (cellular) or Low Data network: not an error, it waits.
        case waitingForUnmeteredNetwork
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .server(let status, let detail):
                return detail.isEmpty ? "The server answered \(status)." : "The server answered \(status): \(detail)"
            case .unauthorized:
                return "The server wants its password: enter it in Settings → Control plane."
            case .waitingForUnmeteredNetwork:
                return "Waiting for Wi-Fi."
            case .unreadableReply:
                return "The server's answer could not be read. Is this a Scan4D control plane?"
            case .insecureHost(let host):
                return "iOS allows plain http only to an IP address, a .local name or a bare host name, not \(host). Use one of those, or https."
            case .untrustedCertificate(let host):
                return "\(host)'s certificate is not trusted. If it is the lab's own, turn on Allow untrusted certificates."
            case .unreachable(let host):
                return "Can't reach \(host). Check the host and port, and that this phone is on the lab network."
            case .transport(let message):
                return message
            }
        }
    }

    /// The server from what the user typed: "192.168.1.40:8000", "scan4d.local:8000",
    /// "https://wiselambda4.lan.cmu.edu/scan4d". No scheme means http; nil when unusable.
    static func baseURL(fromHost host: String) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let text = trimmed.contains("://") ? trimmed : "http://" + trimmed
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let name = url.host(), !name.isEmpty else { return nil }
        return url
    }

    func health() async throws -> Health {
        try await send(URLRequest(url: baseURL.appending(path: "v1/health")))
    }

    func sync(_ manifest: ControlPlaneManifest) async throws -> SyncResult {
        let path = "v1/devices/\(manifest.device.deviceId.uuidString)/sync"
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ControlPlaneManifest.encoder.encode(manifest)
        let data = try await perform(request)
        return SyncResult(reply: try Self.decode(SyncReply.self, from: data), tasks: Self.tasks(from: data))
    }

    /// One map-package file, streamed from disk. `modifiedAt` is the time the sync listed, so the
    /// server knows which version it now holds. `unmeteredOnly` holds a large file back on cellular
    /// or Low Data networks (`Failure.waitingForUnmeteredNetwork`).
    func upload(_ file: ControlPlaneManifest.LocalFile, scanId: String, name: String,
                unmeteredOnly: Bool) async throws -> StoredFile {
        var request = URLRequest(url: baseURL.appending(path: "v1/scans/\(scanId)/files/\(name)"))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(ISO8601DateFormatter().string(from: file.modifiedAt), forHTTPHeaderField: "X-Scan4D-Modified-At")
        request.allowsExpensiveNetworkAccess = !unmeteredOnly
        request.allowsConstrainedNetworkAccess = !unmeteredOnly
        return try await send(request, uploading: file.url)
    }

    /// The export's PUT succeeded: the server checks the bucket and tells its pipelines.
    func completeExport(_ exportId: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "v1/exports/\(exportId)/complete"))
        request.httpMethod = "POST"
        _ = try await perform(request)
    }

    /// A grant to upload one export: where to PUT it and with which headers. The grant's host is
    /// one the control plane named, so `ControlPlaneSession` may trust its certificate.
    func exportGrant(deviceId: UUID, scanId: UUID, filename: String, contentType: String,
                     format: String) async throws -> ExportGrant {
        var request = URLRequest(url: baseURL.appending(path: "v1/devices/\(deviceId.uuidString)/exports"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "scan_id": scanId.uuidString, "filename": filename, "content_type": contentType, "format": format
        ])
        let grant: ExportGrant = try await send(request)
        ControlPlaneSession.allow(host: grant.url.host())
        return grant
    }

    /// The device's answer to a task: "accepted" or "declined".
    func setTaskStatus(_ taskId: UUID, status: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "v1/tasks/\(taskId.uuidString.lowercased())/status"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["status": status])
        _ = try await perform(request)
    }

    private func send<Reply: Decodable>(_ request: URLRequest, uploading file: URL? = nil) async throws -> Reply {
        try Self.decode(Reply.self, from: try await perform(request, uploading: file))
    }

    private func perform(_ request: URLRequest, uploading file: URL? = nil) async throws -> Data {
        var request = request
        request.timeoutInterval = file == nil ? AppConstants.controlPlaneRequestTimeoutS
            : AppConstants.controlPlaneUploadTimeoutS
        let password = ControlPlaneSecret.password
        if !password.isEmpty {
            request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        }
        let session = ControlPlaneSession.session
        let data: Data
        let response: URLResponse
        do {
            if let file {
                (data, response) = try await session.upload(for: request, fromFile: file)
            } else {
                (data, response) = try await session.data(for: request)
            }
        } catch let error as URLError {
            throw Self.failure(for: error, host: request.url?.host() ?? baseURL.absoluteString)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadableReply }
        if http.statusCode == 401 { throw Failure.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.server(status: http.statusCode, detail: Self.detail(from: data))
        }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let value = try? decoder.decode(type, from: data) else { throw Failure.unreadableReply }
        return value
    }

    /// The sync response's tasks. Each region is a focus_region.json, decoded with its own keys
    /// (the snake_case strategy of the rest of the reply would not match them).
    static func tasks(from data: Data) -> [ScanTask] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["tasks"] as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = (item["task_id"] as? String).flatMap(UUID.init(uuidString:)),
                  let mapId = (item["map_id"] as? String).flatMap(UUID.init(uuidString:)),
                  let regionObject = item["region"],
                  let regionData = try? JSONSerialization.data(withJSONObject: regionObject),
                  let region = FocusRegion.decode(regionData), region.isValid else { return nil }
            return ScanTask(id: id, mapId: mapId, mapName: item["map_name"] as? String ?? "",
                            reason: item["reason"] as? String ?? "", status: item["status"] as? String ?? "",
                            priority: item["priority"] as? String ?? "normal", region: region)
        }
    }

    static func failure(for error: URLError, host: String) -> Failure {
        if error.networkUnavailableReason == .expensive || error.networkUnavailableReason == .constrained {
            return .waitingForUnmeteredNetwork
        }
        switch error.code {
        case .appTransportSecurityRequiresSecureConnection:
            return .insecureHost(host)
        case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .serverCertificateHasBadDate, .secureConnectionFailed:
            return .untrustedCertificate(host)
        case .cannotFindHost, .cannotConnectToHost, .timedOut, .notConnectedToInternet,
             .networkConnectionLost, .dnsLookupFailed:
            return .unreachable(host)
        default:
            return .transport(error.localizedDescription)
        }
    }

    /// FastAPI's error body is {"detail": "..."} (or a list of validation errors).
    static func detail(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        if let text = object["detail"] as? String { return text }
        if let list = object["detail"] as? [Any] { return "\(list.count) invalid field(s)" }
        return ""
    }
}
