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
    private var mockTimer: Timer?
    private var mockFrameIndex = 0
    #endif
    
    private var deviceObservationTask: Task<Void, Never>?
    private var registrationObservationTask: Task<Void, Never>?
    
    // Inject this from CaptureView or proxy handler
    var activeCaptureSession: FrameCaptureSession?
    
    // CoreImage context for real-time PiP conversion
    private let ciContext = CIContext()
    
    // Published image for UI overlays
    var latestProxyImage: UIImage?

    private init() {
        setupRegistrationObservation()
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
        let isEnabled = UserDefaults.standard.bool(forKey: AppConstants.Key.mockWearable)
        guard isEnabled != isMockWearableEnabled else { return }
        isMockWearableEnabled = isEnabled
        
        if isEnabled {
            print("[MockWearable] Enabling mock wearable...")
            let device = MockDeviceKit.shared.pairRaybanMeta()
            self.mockDevice = device
            print("[MockWearable] Paired mock device: \(device.deviceIdentifier)")
            
            device.powerOn()
            device.unfold()
            device.don()
            print("[MockWearable] Device lifecycle: powerOn → unfold → don")
            
            self.setupDeviceObservation()
            self.isStreaming = true
            
            // Directly feed synthetic frames to PiP at ~2 FPS (SDK setCameraFeed requires HEVC video)
            self.mockFrameIndex = 0
            self.mockTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let idx = self.mockFrameIndex % TestDataGenerator.totalFrames
                    let (transform, intrinsics) = TestDataGenerator.generatePoseAndIntrinsics(for: idx)
                    let jpegData = TestDataGenerator.generateImage(for: idx, transform: transform, intrinsics: intrinsics)
                    if let uiImage = UIImage(data: jpegData) {
                        self.latestProxyImage = uiImage
                    }
                    // Persist mock proxy frames to disk
                    self.activeCaptureSession?.captureProxyFrameData(jpegData)
                    self.mockFrameIndex += 1
                }
            }
            print("[MockWearable] Started mock frame timer")
        } else {
            print("[MockWearable] Disabling mock wearable...")
            self.mockTimer?.invalidate()
            self.mockTimer = nil
            self.latestProxyImage = nil
            self.isStreaming = false
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

    private func setupRegistrationObservation() {
        registrationObservationTask?.cancel()
        registrationObservationTask = Task { [weak self] in
            for await state in Wearables.shared.registrationStateStream() {
                let stateStr = String(describing: state).lowercased()
                print("[MetaWearable] Registration state: \(stateStr)")
                await MainActor.run {
                    if stateStr.contains("registered") && !stateStr.contains("unregistered") {
                        self?.permissionGranted = true
                    } else if stateStr.contains("unregistered") {
                        self?.permissionGranted = false
                    }
                }
            }
        }
    }

    private func setupDeviceObservation() {
        deviceObservationTask?.cancel()
        deviceObservationTask = Task { [weak self] in
            for await deviceIds in Wearables.shared.devicesStream() {
                await MainActor.run {
                    guard let self = self else { return }
                    print("[MetaWearable] setupDeviceObservation stream — found \(deviceIds.count) devices: \(deviceIds)")
                    self.updateConnectedDevices(deviceIds)
                }
            }
        }
        
        // Initial fetch
        let deviceIds = Wearables.shared.devices
        print("[MetaWearable] setupDeviceObservation initial — found \(deviceIds.count) devices: \(deviceIds)")
        self.updateConnectedDevices(deviceIds)
    }
    
    private func updateConnectedDevices(_ deviceIds: [String]) {
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
            if self.streamSession == nil {
                print("[MetaWearable] Setting up stream session for device: \(firstConnected)")
                self.setupStreamSession(for: firstConnected)
            }
        } else {
            print("[MetaWearable] No devices found")
            if !self.isMockWearableEnabled {
                // Device went away, stop stream and clear session
                Task {
                    await self.streamSession?.stop()
                    self.streamSession = nil
                }
            }
        }
    }

    /// Public entry point for views to refresh wearable state (e.g., on tab switch).
    func refreshDevices() {
        syncMockWearable()
        // Our deviceObservationTask will automatically handle changes, 
        // but we can manually trigger an update just in case.
        self.updateConnectedDevices(Wearables.shared.devices)
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
            guard self.streamSession == nil else {
                print("[MetaWearable] Stream session already exists, skipping setup")
                return
            }
            
            let selector = AutoDeviceSelector(wearables: Wearables.shared)
            
            let config = StreamSessionConfig(
                videoCodec: .raw,
                resolution: .medium,
                frameRate: 15
            )
            
            // MWDAT initializer doesn't throw, and .start() is an async but NON-throwing function
            let session = StreamSession(streamSessionConfig: config, deviceSelector: selector)
            self.streamSession = session
            print("[MetaWearable] StreamSession created (medium res, 15fps), subscribing to publishers...")
            
            // --- MWDAT ANNOUNCER SUBSCRIPTION ---
            self.stateToken = session.statePublisher.listen { state in
                let stateStr = String(describing: state)
                print("[MetaWearable] State changed: \(stateStr)")
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let lower = stateStr.lowercased()
                    if lower.contains("captur") || lower.contains("stream") {
                        self.isStreaming = true
                    } else if lower.contains("paused") {
                        print("[MetaWearable] Session PAUSED — keeping connection alive, holding work")
                        self.isStreaming = false
                        // DO NOT teardown capture session or session object here, wait for resume or stop
                    } else if lower.contains("stop") {
                        print("[MetaWearable] Session STOPPED — releasing resources")
                        self.isStreaming = false
                        self.latestProxyImage = nil
                        _ = self.activeCaptureSession?.stop()
                        self.streamSession = nil // Allow a new session to be created when device is ready
                    } else {
                        // starting, waitingForDevice, etc.
                        self.isStreaming = false
                    }
                }
            }

            // Subscribe to actual camera frame output
            self.frameToken = session.videoFramePublisher.listen { [weak self] frame in
                print("[MetaWearable] Received video frame")
                if let pixelBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) {
                    
                    // Wrap the non-Sendable CVPixelBuffer to safely cross the boundary to the MainActor
                    struct SendableBuffer: @unchecked Sendable {
                        let buffer: CVPixelBuffer
                    }
                    let sendableBuf = SendableBuffer(buffer: pixelBuffer)
                    
                    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                    let cgImage = self?.ciContext.createCGImage(ciImage, from: ciImage.extent)
                    
                    Task { @MainActor [weak self] in
                        self?.isStreaming = true
                        if let cgImage = cgImage {
                            self?.latestProxyImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
                            print("[MetaWearable] PiP image updated: \(cgImage.width)x\(cgImage.height)")
                        } else {
                            print("[MetaWearable] Failed to create CGImage from pixel buffer")
                        }
                        self?.activeCaptureSession?.captureProxyFrame(pixelBuffer: sendableBuf.buffer)
                    }
                } else {
                    print("[MetaWearable] Frame had no pixel buffer")
                }
            }
            
            print("[MetaWearable] Starting stream session...")
            await session.start()
            print("[MetaWearable] Stream session started")
        }
    }
}
