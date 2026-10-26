import Foundation
import Security
import os

// MARK: - The URLSession for the control plane and the uploads it hands out

/// With Settings → Control plane → Allow untrusted certificates on, a server certificate iOS
/// cannot verify (a lab's self-signed or locally-signed one) is accepted, but only from the
/// control plane's own host and the hosts it hands out upload grants for. Every other host, and
/// every host while the switch is off, gets the system's evaluation.
///
/// This is for hosts on the lab's local network or VLAN, reached by IP address or a `.local` or
/// bare host name, which `NSAllowsLocalNetworking` exempts from App Transport Security. A host
/// exposed under a public name gets a real certificate (Let's Encrypt) and needs none of this; the
/// app deliberately carries no ATS exception domains.
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
}
