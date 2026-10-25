import Foundation

// MARK: - Control plane HTTP client (scan4d-server README, "API")

/// Talks to the lab's control plane server. No auth yet: the server lives on the internal
/// network and the app knows only its host (Settings → Control plane).
nonisolated struct ControlPlaneClient: Sendable {
    let baseURL: URL

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
    }

    nonisolated enum Failure: LocalizedError, Equatable {
        case server(status: Int, detail: String)
        case unreadableReply
        case insecureHost(String)
        case unreachable(String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .server(let status, let detail):
                return detail.isEmpty ? "The server answered \(status)." : "The server answered \(status): \(detail)"
            case .unreadableReply:
                return "The server's answer could not be read. Is this a Scan4D control plane?"
            case .insecureHost(let host):
                return "iOS allows plain http only to an IP address, a .local name or a bare host name, not \(host). Use one of those, or https."
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

    func sync(_ manifest: ControlPlaneManifest) async throws -> SyncReply {
        let path = "v1/devices/\(manifest.device.deviceId.uuidString)/sync"
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ControlPlaneManifest.encoder.encode(manifest)
        return try await send(request)
    }

    private func send<Reply: Decodable>(_ request: URLRequest) async throws -> Reply {
        var request = request
        request.timeoutInterval = AppConstants.controlPlaneRequestTimeoutS
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            throw Self.failure(for: error, host: baseURL.host() ?? baseURL.absoluteString)
        }
        guard let http = response as? HTTPURLResponse else { throw Failure.unreadableReply }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.server(status: http.statusCode, detail: Self.detail(from: data))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let reply = try? decoder.decode(Reply.self, from: data) else { throw Failure.unreadableReply }
        return reply
    }

    static func failure(for error: URLError, host: String) -> Failure {
        switch error.code {
        case .appTransportSecurityRequiresSecureConnection:
            return .insecureHost(host)
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
