import Foundation
import os

// MARK: - The URLSession for the control plane and the uploads it hands out

/// With Settings → Control plane → Allow untrusted certificates on, a server certificate iOS
/// cannot verify (a lab's self-signed or locally-signed one) is accepted, but only from the
/// control plane's own host and the hosts it hands out upload grants for. Every other host, and
/// every host while the switch is off, gets the system's evaluation.
///
/// App Transport Security still applies first: an https host whose certificate is not trusted
/// needs to be an IP address, a `.local` or bare host name (`NSAllowsLocalNetworking`), or under an
/// `NSExceptionDomains` entry in Custom-Info.plist (the lab's `lan.cmu.edu` is).
nonisolated enum ControlPlaneSession {
    private static let trust = TrustDelegate()

    static let session = URLSession(configuration: .default, delegate: trust, delegateQueue: nil)

    /// A host the control plane named (its own, or an upload grant's): eligible for the override.
    static func allow(host: String?) {
        trust.allow(host)
    }

    static func isAllowed(host: String) -> Bool {
        trust.contains(host)
    }
}

nonisolated final class TrustDelegate: NSObject, URLSessionDelegate, Sendable {
    private let hosts = OSAllocatedUnfairLock(initialState: Set<String>())

    func allow(_ host: String?) {
        guard let host = host?.lowercased(), !host.isEmpty else { return }
        hosts.withLock { _ = $0.insert(host) }
    }

    func contains(_ host: String) -> Bool {
        let key = host.lowercased()
        return hosts.withLock { $0.contains(key) }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust,
              UserDefaults.standard.bool(forKey: AppConstants.Key.controlPlaneAllowUntrusted),
              contains(space.host) else {
            return (.performDefaultHandling, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
