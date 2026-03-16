import Foundation

/// Central source of truth for all @AppStorage keys and default values.
/// Usage: `@AppStorage(AppDefaults.Key.uploadURL) private var uploadURL = AppDefaults.uploadURL`
enum AppDefaults {
    // MARK: - Keys
    enum Key {
        static let uploadURL = "uploadURL"
        static let rawOverlapMax = "rawOverlapMax"
        static let rawRejectBlur = "rawRejectBlur"
        static let developerMode = "developerMode"
        static let flipCameraEnabled = "flipCameraEnabled"
        static let privacyFilter = "privacyFilter"
        static let selectedExportFormat = "selectedExportFormat"
    }

    // MARK: - Default Values
    static let uploadURL = "https://wiselambda4.lan.cmu.edu/wisescan-uploads/"
    static let rawOverlapMax: Double = 60.0
    static let rawRejectBlur: Bool = true
    static let developerMode: Bool = false
    static let flipCameraEnabled: Bool = false
    static let privacyFilter: Bool = true
    static let selectedExportFormat = "PLYCM" // ExportFormat.polycam.rawValue
}
