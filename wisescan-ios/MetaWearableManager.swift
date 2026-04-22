import Foundation
import Observation
import Combine
import MWDATCore
import MWDATCamera
#if canImport(MWDATMockDevice)
import MWDATMockDevice
#endif
import CoreMedia
import UIKit

/// Manages background Bluetooth connections and data streaming for Meta Ray-Ban proxy devices
/// using the Meta Wearables Device Access Toolkit (DAT) SDK.
@Observable
@MainActor
class MetaWearableManager {
    static let shared = MetaWearableManager()

    var isScanning = false
    var connectedDevices: [WearableDevice] = []
    var isStreaming = false
    var permissionGranted = false

    struct WearableDevice: Identifiable {
        let id: String
        let name: String
        let model: String
        var isConnected: Bool
        var underlyingDevice: String // Device identifier
    }

    private var cancellables = Set<AnyCancellable>()
    private var streamSession: StreamSession?
    
    // Store SDK Announcer subscription tokens if required by the interface
    private var stateToken: Any?
    private var frameToken: Any?
    
    #if canImport(MWDATMockDevice)
    private var mockDevice: MockRaybanMeta?
    private var isMockWearableEnabled = false
    #endif
    
    // Inject this from CaptureView or proxy handler
    var activeCaptureSession: FrameCaptureSession?

    private init() {
        setupDeviceObservation()
        checkPermissions()
        syncMockWearable()
        
        // Refresh devices when returning to foreground in case the deep-link failed to bounce back
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScanning = false
                self?.setupDeviceObservation()
            }
        }
        
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncMockWearable()
            }
        }
    }
    
    private func syncMockWearable() {
        #if canImport(MWDATMockDevice)
        let isEnabled = UserDefaults.standard.bool(forKey: AppDefaults.Key.mockWearable)
        guard isEnabled != isMockWearableEnabled else { return }
        isMockWearableEnabled = isEnabled
        
        if isEnabled {
            let device = MockDeviceKit.shared.pairRaybanMeta()
            self.mockDevice = device
            Task {
                await device.powerOn()
                await device.unfold()
                await device.don()
                await MainActor.run {
                    self.setupDeviceObservation()
                }
            }
        } else {
            if let device = self.mockDevice {
                MockDeviceKit.shared.unpairDevice(device)
            }
            self.mockDevice = nil
            self.setupDeviceObservation()
        }
        #endif
    }

    func checkPermissions() {
        Task {
            do {
                let status = try await Wearables.shared.checkPermissionStatus(.camera)
                let statusStr = String(describing: status).lowercased()
                self.permissionGranted = statusStr.contains("grant") || statusStr.contains("authoriz")
            } catch {
                print("DAT Permission check failed: \(error)")
            }
        }
    }
    
    func requestPermissions() {
        Task {
            do {
                let status = try await Wearables.shared.requestPermission(.camera)
                let statusStr = String(describing: status).lowercased()
                self.permissionGranted = statusStr.contains("grant") || statusStr.contains("authoriz")
            } catch {
                print("DAT Permission request failed: \(error)")
            }
        }
    }

    private func setupDeviceObservation() {
        // Wearables.shared.devices exposes an array of identifiers
        let deviceIds = Wearables.shared.devices
        self.connectedDevices = deviceIds.map { deviceId in
            WearableDevice(
                id: deviceId,
                name: "Meta Ray-Ban (\(deviceId.prefix(4)))",
                model: "Meta Ray-Ban",
                isConnected: true,
                underlyingDevice: deviceId
            )
        }
        
        if let firstConnected = deviceIds.first {
            self.setupStreamSession(for: firstConnected)
        }
    }

    func toggleScanning() {
        if isScanning { return }
        isScanning = true
        Task {
            do {
                // Deep-link to the Meta AI App for registration pairing
                try await Wearables.shared.startRegistration()
            } catch {
                print("Registration error: \(error)")
            }
            Task { @MainActor [weak self] in
                self?.isScanning = false
                self?.setupDeviceObservation()
            }
        }
    }

    func connect(to deviceId: String) {
        guard permissionGranted else {
            requestPermissions()
            return
        }
        setupDeviceObservation()
    }

    func disconnect(deviceId: String) {
        Task {
            // SDK handles disconnect implicitly; simply teardown our active stream
            await self.streamSession?.stop()
            self.streamSession = nil
        }
    }
    
    func unregister() {
        Task {
            // Drop stream and clear local devices list to ensure SDK fully releases
            await self.streamSession?.stop()
            self.streamSession = nil
            
            Task { @MainActor in
                self.connectedDevices = []
            }
            
            do {
                try await Wearables.shared.startUnregistration()
            } catch {
                print("Failed to unregister: \(error)")
            }
        }
    }

    private func setupStreamSession(for deviceId: String) {
        Task { [weak self] in
            guard let self = self else { return }
            guard self.streamSession == nil else { return }
            
            let selector = AutoDeviceSelector(wearables: Wearables.shared)
            
            // MWDAT initializer doesn't throw, and .start() is an async but NON-throwing function
            let session = StreamSession(deviceSelector: selector)
            self.streamSession = session
            
            // --- MWDAT ANNOUNCER SUBSCRIPTION ---
            self.stateToken = session.statePublisher.listen { state in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let stateStr = String(describing: state).lowercased()
                    if stateStr.contains("captur") || stateStr.contains("stream") {
                        self.isStreaming = true
                    } else {
                        self.isStreaming = false
                        _ = self.activeCaptureSession?.stop()
                    }
                }
            }

            // Subscribe to actual camera frame output
            self.frameToken = session.videoFramePublisher.listen { [weak self] frame in
                if let pixelBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) {
                    
                    // Wrap the non-Sendable CVPixelBuffer to safely cross the boundary to the MainActor
                    struct SendableBuffer: @unchecked Sendable {
                        let buffer: CVPixelBuffer
                    }
                    let sendableBuf = SendableBuffer(buffer: pixelBuffer)
                    
                    Task { @MainActor [weak self] in
                        self?.activeCaptureSession?.captureProxyFrame(pixelBuffer: sendableBuf.buffer)
                    }
                }
            }
            
            await session.start()
        }
    }
}
