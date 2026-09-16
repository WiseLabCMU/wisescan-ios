import Foundation
import simd

enum StillSourceKind: String, CaseIterable {
    case thetaLive = "Ricoh Theta (Live)"
    case deferredExternal = "Deferred External Import"
}

@MainActor
protocol ScanStillSource: AnyObject {
    var kind: StillSourceKind { get }
    var isAvailableForCapture: Bool { get }
    var scanStillCount: Int { get }
    var scanStillPositions: [SIMD3<Float>] { get }
    var swayedStillCount: Int { get }
    var cameraUnresponsive: Bool { get }

    func beginScanStillSession(rawDataDir: URL?)
    func endScanStillSession()
    func verifyReadyForCapture() async -> Bool

    @discardableResult
    func captureStillForScan(phoneTransform: simd_float4x4,
                             timestamp: TimeInterval,
                             into rawDataDir: URL,
                             samplePose: (() -> simd_float4x4?)?) -> Bool
}

extension ThetaCameraManager: ScanStillSource {
    var kind: StillSourceKind { .thetaLive }
    var isAvailableForCapture: Bool { isConnected }
}
