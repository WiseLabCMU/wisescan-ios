import ARKit
import Foundation
import Security

// MARK: - This phone's identity for the control plane (scan4d-server README, "Concepts")

/// A UUID made the first time it is asked for and kept in the Keychain, so it survives a
/// reinstall. iOS gives apps no serial number, and `identifierForVendor` resets once every app
/// from the vendor is deleted. `ThisDeviceOnly`: a backup restored onto another phone does not
/// carry it, so two phones never share an identity. Mirrored in the app's defaults in case the
/// Keychain write fails.
nonisolated enum DeviceIdentity {
    private static let service = "edu.cmu.wiselab.scan4d.control-plane"
    private static let account = "device_id"

    static let id: UUID = {
        if let stored = readKeychain() { return stored }
        if let text = UserDefaults.standard.string(forKey: AppConstants.Key.controlPlaneDeviceId),
           let fallback = UUID(uuidString: text) {
            writeKeychain(fallback)
            return fallback
        }
        let fresh = UUID()
        writeKeychain(fresh)
        UserDefaults.standard.set(fresh.uuidString, forKey: AppConstants.Key.controlPlaneDeviceId)
        return fresh
    }()

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

    private static func writeKeychain(_ id: UUID) {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(id.uuidString.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess && status != errSecDuplicateItem {
            print("[ControlPlane] Keychain write failed (\(status)); the device id lives in defaults only")
        }
    }
}
