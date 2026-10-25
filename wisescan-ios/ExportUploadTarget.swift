import Foundation

// MARK: - Where an export upload goes (scan4d-server README, "Export uploads")

/// With a control plane set, the server hands out each export's destination: a presigned PUT
/// into the lab's Versity bucket, under this device's `exports/<format>/` in the shared working
/// directory, so no bucket credentials live on the phone and uploads can be revoked per device.
/// When the PUT succeeds, `reportCompleted` tells the server, which checks the bucket and signals
/// its pipelines. The manual Upload URL (Settings) is the fallback: with no control plane, or one
/// with no upload target.
nonisolated struct ExportUploadTarget: Sendable {
    /// The PUT, its headers set; the caller streams the export file with it.
    let request: URLRequest
    let session: URLSession
    /// The control plane's grant, when it handed out the destination.
    var exportId: String? = nil
    var client: ControlPlaneClient? = nil

    /// After a successful PUT: the server checks the object and announces `export.completed`.
    /// Best-effort; a missed report leaves the export uploaded but unannounced.
    func reportCompleted() {
        guard let exportId, let client else { return }
        Task {
            do {
                try await client.completeExport(exportId)
            } catch {
                print("[ControlPlane] export \(exportId) completion not reported: \(error.localizedDescription)")
            }
        }
    }

    nonisolated enum Failure: LocalizedError, Equatable {
        case revoked
        case nowhere

        var errorDescription: String? {
            switch self {
            case .revoked: return "Uploads are turned off for this device on the control plane"
            case .nowhere: return "No upload server: set a control plane or an upload URL in Settings"
            }
        }
    }

    /// Whether the Upload buttons have anywhere to send to.
    static func isConfigured(manualURL: String, controlPlaneHost: String) -> Bool {
        !manualURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || ControlPlaneClient.baseURL(fromHost: controlPlaneHost) != nil
    }

    @MainActor
    static func resolve(scanId: UUID, filename: String, contentType: String, format: ExportFormat,
                        manualURL: String) async throws -> ExportUploadTarget {
        if let client = ControlPlaneSync.shared.client {
            do {
                let grant = try await client.exportGrant(deviceId: DeviceIdentity.id, scanId: scanId, filename: filename,
                                                         contentType: contentType, format: format.rawValue)
                var request = URLRequest(url: grant.url)
                request.httpMethod = grant.method
                for (field, value) in grant.headers {
                    request.setValue(value, forHTTPHeaderField: field)
                }
                return ExportUploadTarget(request: request, session: ControlPlaneSession.session,
                                          exportId: grant.exportId, client: client)
            } catch ControlPlaneClient.Failure.server(let status, _) where status == 403 {
                throw Failure.revoked
            } catch ControlPlaneClient.Failure.server(let status, _) where status == 503 && !manualURL.isEmpty {
                // The control plane has no upload target: the manual URL stands in.
            }
        }
        guard let target = manual(manualURL, filename: filename, contentType: contentType) else {
            throw Failure.nowhere
        }
        return target
    }

    /// The manual Upload URL: a plain PUT of the file under it.
    static func manual(_ uploadURL: String, filename: String, contentType: String) -> ExportUploadTarget? {
        let base = uploadURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, let url = URL(string: (base.hasSuffix("/") ? base : base + "/") + filename) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return ExportUploadTarget(request: request, session: URLSession.shared)
    }
}
