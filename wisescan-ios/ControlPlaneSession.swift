import Foundation
import Security
import os

// MARK: - The URLSession for the control plane

/// With Settings → Control plane → Allow untrusted certificates on, a server certificate iOS
/// cannot verify (a lab's self-signed or locally-signed one) is accepted, but only from the
/// control plane's own host, for its API and for the bundles sent to it. Every other host, and
/// every host while the switch is off, gets the system's evaluation.
///
/// This is for hosts on the lab's local network or VLAN, reached by IP address or a `.local` or
/// bare host name, which `NSAllowsLocalNetworking` exempts from App Transport Security. A host
/// exposed under a public name gets a real certificate (Let's Encrypt) and needs none of this; the
/// app deliberately carries no ATS exception domains.
nonisolated enum ControlPlaneSession {
    private static let trust = TrustDelegate()

    static let session = URLSession(configuration: .default, delegate: trust, delegateQueue: nil)

    /// The control plane's host: eligible for the override.
    static func allow(host: String?) {
        trust.allow(host)
    }

    static func isAllowed(host: String) -> Bool {
        trust.contains(host)
    }

    /// The same rule for another session's challenges: the background session that sends scans'
    /// bundles to the control plane (`BundleUploadSession`).
    static func disposition(for challenge: URLAuthenticationChallenge)
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        trust.disposition(for: challenge)
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
        disposition(for: challenge)
    }

    func disposition(for challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
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

// MARK: - The server password

/// The control plane's shared password (scan4d-server README, "Auth"), sent as a bearer token on
/// every request to it. Kept in the Keychain, this device only: it is a credential, so neither the
/// app's defaults nor a backup restored elsewhere should carry it.
nonisolated enum ControlPlaneSecret {
    private static let service = "edu.cmu.wiselab.scan4d.control-plane"
    private static let account = "api_token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static var password: String {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Stores it, or removes it when empty.
    static func setPassword(_ value: String) {
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            print("[ControlPlane] server password not stored (\(status))")
        }
    }

    // MARK: Whether the server wants one

    /// What a request sent without a password learned (`ControlPlaneClient`): a 401 means this
    /// server wants one, a success that it runs open (a development server, its master password
    /// unset). Other answers, requests sent with a password and routes open either way teach nothing.
    static func noteReply(from server: URL, refused: Bool) {
        let defaults = UserDefaults.standard
        let key = AppConstants.Key.controlPlanePasswordWanted
        if refused {
            defaults.set(server.absoluteString, forKey: key)
        } else if defaults.string(forKey: key) == server.absoluteString {
            defaults.removeObject(forKey: key)
        }
    }

    /// Whether this server has refused a request for want of a password.
    static func isWanted(by server: URL) -> Bool {
        UserDefaults.standard.string(forKey: AppConstants.Key.controlPlanePasswordWanted) == server.absoluteString
    }

    /// A control plane is set, it wants a password, and none is stored: a tapped Sync
    /// asks for it before going (`ControlPlanePasswordPrompt`).
    static func isMissing(forHost host: String, password: String = ControlPlaneSecret.password) -> Bool {
        guard password.isEmpty, let server = ControlPlaneClient.baseURL(fromHost: host) else { return false }
        return isWanted(by: server)
    }
}
