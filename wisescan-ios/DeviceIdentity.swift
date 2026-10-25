import ARKit
import Foundation
import Security

// MARK: - This phone's identity for the control plane (scan4d-server README, "Concepts")

/// A UUID made the first time it is asked for and kept in the Keychain, so it survives a
/// reinstall. iOS gives apps no serial number, and `identifierForVendor` resets once every app
/// from the vendor is deleted. `ThisDeviceOnly`: a backup restored onto another phone does not
/// carry it, so two phones never share an identity.
///
/// The fallback, for a Keychain write that fails, is a file excluded from backups, for the same
/// reason. Never the app's defaults: those ride every backup, and a phone restored from another's
/// would sync as it, each marking the other's scans gone.
nonisolated enum DeviceIdentity {
    private static let service = "edu.cmu.wiselab.scan4d.control-plane"
    private static let account = "device_id"

    static let id: UUID = {
        if let stored = readKeychain() { return stored }
        if let fallback = readFallback() {
            writeKeychain(fallback)
            return fallback
        }
        let fresh = UUID()
        if !writeKeychain(fresh) {
            writeFallback(fresh)
        }
        return fresh
    }()

    private static var fallbackURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("control-plane-device-id")
    }

    private static func readFallback() -> UUID? {
        guard let url = fallbackURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func writeFallback(_ id: UUID) {
        guard var url = fallbackURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try id.uuidString.write(to: url, atomically: true, encoding: .utf8)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            print("[ControlPlane] device id fallback not written: \(error.localizedDescription)")
        }
    }

    /// The hardware model, e.g. "iPhone16,2" (the simulator reports the one it simulates).
    static var model: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)"
            : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    static var hasLiDAR: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    static func manifestDevice(label: String) -> ControlPlaneManifest.Device {
        ControlPlaneManifest.Device(deviceId: id, label: label, model: model, systemVersion: systemVersion,
                                    appVersion: appVersion, appBuild: appBuild, lidar: hasLiDAR)
    }

    private static func readKeychain() -> UUID? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: text)
    }

    @discardableResult
    private static func writeKeychain(_ id: UUID) -> Bool {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(id.uuidString.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            print("[ControlPlane] Keychain write failed (\(status)); the device id falls back to a file")
            return false
        }
        return true
    }
}
