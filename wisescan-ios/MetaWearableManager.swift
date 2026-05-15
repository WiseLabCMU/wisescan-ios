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
    var deviceUpdateRequired = false
    var permissionGranted = false {
        didSet {
            guard permissionGranted, isStreamingRequested, let firstDevice = connectedDevices.first else { return }
            if streamSession != nil {
                // Tear down stale session created before we had permission
                print("[MetaWearable] Permissions granted late — tearing down stale session")
                Task {
                    await self.streamSession?.stop()
                    self.streamSession = nil
                    self.setupStreamSession(for: firstDevice.id)
                }
            } else {
                print("[MetaWearable] Permissions granted late, starting stream")
                setupStreamSession(for: firstDevice.id)
            }
        }
    }
    /// Whether the capture screen has requested streaming — prevents auto-start from device discovery
    private var isStreamingRequested = false

    struct WearableDevice: Identifiable {
        let id: String
        let name: String
        let model: String
        var isConnected: Bool
        var underlyingDevice: String // Device identifier
    }

    private var cancellables = Set<AnyCancellable>()
    private var deviceSession: DeviceSession?
    private var streamSession: MWDATCamera.Stream?

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
    private var hasLoggedNoDevices = false

    // Inject this from CaptureView or proxy handler
    var activeCaptureSession: FrameCaptureSession?

    // Published image for UI overlays
    var latestProxyImage: UIImage?

    private init() {
        setupRegistrationObservation()
        setupDeviceObservation()
        checkPermissions()
        syncMockWearable()

        // Refresh devices and permissions when returning to foreground (e.g., after granting permission in Meta AI)
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScanning = false
                self?.checkPermissions()
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
            MockDeviceKit.shared.enable()
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
            MockDeviceKit.shared.disable()
            self.setupDeviceObservation()
        }
        #endif
    }

    func checkPermissions() {
        Task {
            do {
                let status = try await Wearables.shared.checkPermissionStatus(.camera)
                let statusStr = String(describing: status).lowercased()
                let granted = statusStr.contains("grant") || statusStr.contains("authoriz")
                print("[MetaWearable] Permission check result: '\(statusStr)' → granted=\(granted)")
                self.permissionGranted = granted
            } catch {
                print("[MetaWearable] Permission check failed: \(error) — will retry on next foreground")
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
                    if !deviceIds.isEmpty {
                        print("[MetaWearable] setupDeviceObservation stream — found \(deviceIds.count) devices: \(deviceIds)")
                    }
                    self.updateConnectedDevices(deviceIds)
                }
            }
        }

        // Initial fetch
        let deviceIds = Wearables.shared.devices
        if !deviceIds.isEmpty {
            print("[MetaWearable] setupDeviceObservation initial — found \(deviceIds.count) devices: \(deviceIds)")
        }
        self.updateConnectedDevices(deviceIds)
    }

    private func updateConnectedDevices(_ deviceIds: [String]) {
        self.connectedDevices = deviceIds.map { deviceId in
            let device = Wearables.shared.deviceForIdentifier(deviceId)
            let name = device?.nameOrId() ?? "Meta Ray-Ban (\(deviceId.prefix(4)))"
            return WearableDevice(
                id: deviceId,
                name: name,
                model: "Meta Ray-Ban",
                isConnected: true,
                underlyingDevice: deviceId
            )
        }

        // Check compatibility for all connected devices
        for deviceId in deviceIds {
            if let device = Wearables.shared.deviceForIdentifier(deviceId) {
                let compat = device.compatibility()
                if compat == .deviceUpdateRequired {
                    self.deviceUpdateRequired = true
                } else if compat == .compatible {
                    self.deviceUpdateRequired = false
                }
            }
        }

        if let firstConnected = deviceIds.first {
            // Only auto-start stream if the capture screen has requested it AND we have permission
            if self.streamSession == nil && self.isStreamingRequested && self.permissionGranted {
                print("[MetaWearable] Setting up stream session for device: \(firstConnected)")
                self.setupStreamSession(for: firstConnected)
            } else if self.streamSession == nil && self.isStreamingRequested && !self.permissionGranted {
                print("[MetaWearable] Device found but camera permission not yet granted — deferring stream setup")
            }
        } else {
            if !hasLoggedNoDevices {
                print("[MetaWearable] No devices found")
                hasLoggedNoDevices = true
            }
            if !self.isMockWearableEnabled {
                // Device went away, stop stream and clear session
                Task {
                    await self.streamSession?.stop()
                    self.streamSession = nil
                    self.deviceSession?.stop()
                    self.deviceSession = nil
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

    /// Called by CaptureView.onAppear — starts the camera stream if a device is connected.
    func startStreaming() {
        isStreamingRequested = true
        // If a device is already connected but stream not started, start it now
        if let firstDevice = connectedDevices.first, streamSession == nil {
            print("[MetaWearable] CaptureView requested stream start")
            setupStreamSession(for: firstDevice.id)
        }
    }

    /// Called by CaptureView.onDisappear — stops the camera stream to save resources.
    func stopStreaming() {
        isStreamingRequested = false
        Task {
            if let stream = self.streamSession {
                print("[MetaWearable] CaptureView dismissed — stopping stream")
                await stream.stop()
            }
            self.streamSession = nil
            self.isStreaming = false
            self.latestProxyImage = nil
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
            self.deviceSession?.stop()
            self.deviceSession = nil
        }
    }

    func unregister() {
        Task {
            // Drop stream and clear local devices list to ensure SDK fully releases
            await self.streamSession?.stop()
            self.streamSession = nil
            self.deviceSession?.stop()
            self.deviceSession = nil

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

            // Get the device object and log its full state
            guard let device = Wearables.shared.deviceForIdentifier(deviceId) else {
                print("[MetaWearable] deviceForIdentifier returned nil for \(deviceId)")
                return
            }
            print("[MetaWearable] Device: \(device.nameOrId())")
            print("[MetaWearable] Device linkState: \(device.linkState)")
            print("[MetaWearable] Device compatibility: \(device.compatibility())")
            print("[MetaWearable] Device type: \(device.deviceType())")

            // Check firmware compatibility — surface to UI but still attempt streaming
            // (SDK 0.7.0 may report deviceUpdateRequired even when glasses firmware is current)
            let compat = device.compatibility()
            if compat == .deviceUpdateRequired {
                self.deviceUpdateRequired = true
                print("[MetaWearable] ⚠️ Device reports compatibility: deviceUpdateRequired — will still attempt session")
            } else if compat == .sdkUpdateRequired {
                self.deviceUpdateRequired = true
                print("[MetaWearable] ⚠️ Device reports compatibility: sdkUpdateRequired — will still attempt session")
            } else {
                self.deviceUpdateRequired = false
            }

            // Wait for device to be connected if not already
            if device.linkState != .connected {
                print("[MetaWearable] Device not connected (linkState: \(device.linkState)), waiting...")
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    var token: (any AnyListenerToken)?
                    token = device.addLinkStateListener { state in
                        print("[MetaWearable] Device linkState changed: \(state)")
                        if state == .connected {
                            Task { await token?.cancel() }
                            continuation.resume()
                        }
                    }
                    // Check again in case it changed during setup
                    if device.linkState == .connected {
                        Task { await token?.cancel() }
                        continuation.resume()
                    }
                }
                print("[MetaWearable] Device connected!")
            }

            // Use SpecificDeviceSelector (AutoDeviceSelector.activeDevice is always nil for this device)
            let selector = SpecificDeviceSelector(device: deviceId)

            // Create the DeviceSession
            let devSession: DeviceSession
            do {
                devSession = try Wearables.shared.createSession(deviceSelector: selector)
                print("[MetaWearable] DeviceSession created")
            } catch {
                print("[MetaWearable] Failed to create device session: \(error)")
                return
            }
            self.deviceSession = devSession

            // Start the session and wait for it to reach .started state
            let stateStream = devSession.stateStream()
            let errorStream = devSession.errorStream()
            do {
                try devSession.start()
                print("[MetaWearable] DeviceSession.start() called, state: \(devSession.state)")
            } catch let error as DeviceSessionError {
                if error == .datAppOnTheGlassesUpdateRequired {
                    self.deviceUpdateRequired = true
                    print("[MetaWearable] Failed to start device session: datAppOnTheGlassesUpdateRequired")
                } else if error == .noEligibleDevice {
                    print("[MetaWearable] Failed to start device session: noEligibleDevice (Glasses likely need firmware update)")
                    self.deviceUpdateRequired = true // Treat noEligibleDevice as an update required in 0.7.0 if compatibility is already flagging it
                } else if error == .dwaUnavailable {
                    print("[MetaWearable] Failed to start device session: WiFi Direct (DWA) unavailable")
                } else {
                    print("[MetaWearable] Failed to start device session: \(error)")
                }
                self.deviceSession = nil
                return
            } catch {
                print("[MetaWearable] Failed to start device session (Unknown): \(error)")
                self.deviceSession = nil
                return
            }

            // Wait for .started state (may have already transitioned)
            if devSession.state != .started {
                print("[MetaWearable] Waiting for DeviceSession to reach .started state...")
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for await state in stateStream {
                                print("[MetaWearable] DeviceSession state: \(state)")
                                if state == .started { return }
                                if state == .stopped {
                                    throw DeviceSessionError.unexpectedError(description: "Session stopped before starting")
                                }
                            }
                        }
                        group.addTask {
                            for await error in errorStream {
                                print("[MetaWearable] DeviceSession error: \(error)")
                                throw error
                            }
                        }
                        _ = try await group.next()
                        group.cancelAll()
                    }
                } catch let error as DeviceSessionError {
                    if error == .datAppOnTheGlassesUpdateRequired {
                        self.deviceUpdateRequired = true
                        print("[MetaWearable] DeviceSession failed to start async: datAppOnTheGlassesUpdateRequired")
                    } else if error == .noEligibleDevice {
                        print("[MetaWearable] DeviceSession failed to start async: noEligibleDevice")
                        self.deviceUpdateRequired = true
                    } else {
                        print("[MetaWearable] DeviceSession failed to start async: \(error)")
                    }
                    devSession.stop()
                    self.deviceSession = nil
                    return
                } catch {
                    print("[MetaWearable] DeviceSession failed to reach .started: \(error)")
                    devSession.stop()
                    self.deviceSession = nil
                    return
                }
            }
            print("[MetaWearable] DeviceSession is .started — adding stream")

            // Add a camera stream (matching the official sample: low res, 24fps)
            let config = StreamConfiguration(
                videoCodec: .raw,
                resolution: .low,
                frameRate: 24
            )
            guard let stream = try? devSession.addStream(config: config) else {
                print("[MetaWearable] addStream returned nil")
                print("[MetaWearable] DeviceSession state: \(devSession.state)")
                devSession.stop()
                self.deviceSession = nil
                return
            }
            self.streamSession = stream
            print("[MetaWearable] Stream created, subscribing to publishers...")

            // --- MWDAT ANNOUNCER SUBSCRIPTION ---
            self.stateToken = stream.statePublisher.listen { state in
                print("[MetaWearable] Stream state changed: \(state)")
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    switch state {
                    case .streaming:
                        self.isStreaming = true
                    case .paused:
                        print("[MetaWearable] Stream PAUSED — keeping connection alive")
                        self.isStreaming = false
                    case .stopped:
                        print("[MetaWearable] Stream STOPPED — releasing resources")
                        self.isStreaming = false
                        self.latestProxyImage = nil
                        _ = self.activeCaptureSession?.stop()
                        self.streamSession = nil
                    case .waitingForDevice, .starting, .stopping:
                        self.isStreaming = false
                    @unknown default:
                        self.isStreaming = false
                    }
                }
            }

            // Subscribe to actual camera frame output
            self.frameToken = stream.videoFramePublisher.listen { [weak self] frame in
                print("[MetaWearable] Received video frame")

                // TODO(Hardware Test): The DAT SDK 0.6.0 does not explicitly expose camera intrinsics.
                // However, AVFoundation sometimes silently injects metadata (like kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix)
                // directly into the sample buffer. When testing on physical glasses, check these logs.
                // If intrinsics exist, extract them to package with the Scan4D/Polycam export proxy data.
                // If empty, we may need to hardcode a fallback FOV matrix.
                if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: frame.sampleBuffer, attachmentMode: kCMAttachmentMode_ShouldPropagate) {
                    print("[MetaWearable] Sample buffer attachments (propagate): \(attachments)")
                }
                if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: frame.sampleBuffer, attachmentMode: kCMAttachmentMode_ShouldNotPropagate) {
                    print("[MetaWearable] Sample buffer attachments (non-propagate): \(attachments)")
                }

                if let pixelBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) {

                    // Wrap the non-Sendable CVPixelBuffer to safely cross the boundary to the MainActor
                    struct SendableBuffer: @unchecked Sendable {
                        let buffer: CVPixelBuffer
                    }
                    let sendableBuf = SendableBuffer(buffer: pixelBuffer)

                    var finalUIImage = frame.makeUIImage()
                    var finalJpegData: Data? = nil

                    // Capture MainActor properties safely without capturing self in the outer task
                    Task {
                        let isPrivacyEnabled = await MainActor.run { UserDefaults.standard.bool(forKey: AppConstants.Key.privacyFilter) }
                        let compression = await MainActor.run { AppConstants.jpegCompressionQuality }

                        if let img = finalUIImage, let rawJpeg = img.jpegData(compressionQuality: compression) {
                            finalJpegData = rawJpeg

                            if isPrivacyEnabled {
                                // Wearables stream is natively landscape right, which corresponds to vision orientation .up
                                let (blurredData, _) = PrivacyBlurUtil.pixelatePersonsAndGetFaceCenters(in: rawJpeg, orientation: .up)
                                if let bData = blurredData {
                                    finalJpegData = bData
                                    finalUIImage = UIImage(data: bData)
                                }
                            }
                        }

                        let safeJpegData = finalJpegData
                        let safeUIImage = finalUIImage

                        Task { @MainActor [weak self] in
                            self?.isStreaming = true
                            if let uiImage = safeUIImage {
                                self?.latestProxyImage = uiImage
                                print("[MetaWearable] PiP image updated")
                            } else {
                                print("[MetaWearable] Failed to create UIImage from frame")
                            }

                            if let jpeg = safeJpegData {
                                self?.activeCaptureSession?.captureProxyFrameData(jpeg)
                            } else {
                                self?.activeCaptureSession?.captureProxyFrame(pixelBuffer: sendableBuf.buffer)
                            }
                        }
                    }
                } else {
                    print("[MetaWearable] Frame had no pixel buffer")
                }
            }

            // Start the camera stream
            print("[MetaWearable] Starting stream...")
            await stream.start()
            print("[MetaWearable] Stream started")
        }
    }
}

