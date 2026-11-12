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

    /// What the device is called when nobody named it: the model's marketing name where it is in
    /// `marketingNames`, else the hardware model. The server's paths are ids, so the name is only
    /// what people see; a name set later replaces it and moves nothing.
    static var defaultLabel: String { marketingName(model) ?? model }

    /// The LiDAR iPhones and iPads Scan4D runs on, by hardware model. One missing here just shows
    /// its hardware model.
    static func marketingName(_ model: String) -> String? {
        let names: [String: String] = [
            "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPad8,9": "iPad Pro 11-inch (2nd generation)", "iPad8,10": "iPad Pro 11-inch (2nd generation)",
            "iPad8,11": "iPad Pro 12.9-inch (4th generation)", "iPad8,12": "iPad Pro 12.9-inch (4th generation)",
            "iPad13,4": "iPad Pro 11-inch (M1)", "iPad13,5": "iPad Pro 11-inch (M1)",
            "iPad13,6": "iPad Pro 11-inch (M1)", "iPad13,7": "iPad Pro 11-inch (M1)",
            "iPad13,8": "iPad Pro 12.9-inch (M1)", "iPad13,9": "iPad Pro 12.9-inch (M1)",
            "iPad13,10": "iPad Pro 12.9-inch (M1)", "iPad13,11": "iPad Pro 12.9-inch (M1)",
            "iPad14,3": "iPad Pro 11-inch (M2)", "iPad14,4": "iPad Pro 11-inch (M2)",
            "iPad14,5": "iPad Pro 12.9-inch (M2)", "iPad14,6": "iPad Pro 12.9-inch (M2)",
            "iPad16,3": "iPad Pro 11-inch (M4)", "iPad16,4": "iPad Pro 11-inch (M4)",
            "iPad16,5": "iPad Pro 13-inch (M4)", "iPad16,6": "iPad Pro 13-inch (M4)"
        ]
        return names[model]
    }

    /// This device as the sync manifest reports it. A blank `label` (the user never named it)
    /// sends `defaultLabel`, so a new device arrives with a name people can tell apart.
    static func manifestDevice(label: String) -> ControlPlaneManifest.Device {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return ControlPlaneManifest.Device(deviceId: id, label: name.isEmpty ? defaultLabel : name, model: model,
                                           systemVersion: systemVersion, appVersion: appVersion,
                                           appBuild: appBuild, lidar: hasLiDAR)
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
