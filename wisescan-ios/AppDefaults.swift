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
        static let debugVertexMapping = "debugVertexMapping"
        static let testIMU = "testIMU"
        static let testCameraImages = "testCameraImages"
        static let testDepthMaps = "testDepthMaps"
        static let privacyFilter = "privacyFilter"
        static let selectedExportFormat = "selectedExportFormat"
    }

    // MARK: - Default Values
    static let uploadURL = "https://wiselambda4.lan.cmu.edu/wisescan-uploads/"
    static let overlapMax: Double = 60.0
    static let rejectBlur: Bool = true
    static let developerMode: Bool = false
    static let flipCameraEnabled: Bool = false
    static let debugVertexMapping: Bool = false
    static let testIMU: Bool = false
    static let testCameraImages: Bool = false
    static let testDepthMaps: Bool = false
    static let privacyFilter: Bool = true
    static let selectedExportFormat = "Scan4D" // ExportFormat.scan4d.rawValue

    // MARK: - Pipeline Constants
    static let faceClusterThresholdMeters: Float = 0.5      // merge distance for face anchors (~head diameter)
    static let overlapBaseThreshold: Float = 0.15            // movement threshold base for frame capture
    static let overlapMinThreshold: Float = 0.01             // minimum movement threshold
    static let maxColorizationFrames: Int = 150              // max sampled frames for vertex coloring
    static let jpegCompressionQuality: CGFloat = 0.85        // JPEG quality for captured frames
    static let blurWarningTimeout: TimeInterval = 1.5        // seconds before blur warning auto-dismisses
    static let consecutiveBlurThreshold: Int = 5             // blurred frames before warning triggers
    static let motionBlurVelocity: Float = 0.5               // m/s threshold for motion blur detection
    static let depthOcclusionToleranceMM: Float = 150.0      // mm tolerance for depth occlusion test
    static let thumbnailMaxWidth: CGFloat = 800              // max width for scan thumbnails
    static let thumbnailJpegQuality: CGFloat = 0.6           // JPEG quality for thumbnails
}
