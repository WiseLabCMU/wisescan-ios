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
    var connectionFailed = false
    var deviceUpdateRequired = false
    var permissionGranted = false {
        didSet {
            // Cache for Dashboard UI banner (so it doesn't flash on cold launch)
            UserDefaults.standard.set(permissionGranted, forKey: AppConstants.Key.metaWearablesPermissionGranted)
            guard permissionGranted, isStreamingRequested, let firstDevice = connectedDevices.first else { return }
            if streamSession != nil {
                // Tear down stale session created before we had permission
                print("[MetaWearable] Permissions granted late — tearing down stale session")
                Task {
                    await self.streamSession?.stop()
                    self.streamSession = nil
                    self.deviceSession?.stop()
                    self.deviceSession = nil
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

    // Timestamp for frame throttling (thread-safe for background video publisher)
    private final class FrameThrottle: @unchecked Sendable {
        private var lock = os_unfair_lock()
        private var lastTime: CFAbsoluteTime = 0
        func shouldProcess() -> Bool {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }

            // Fast read of cached setting
            let defaultFps = UserDefaults.standard.object(forKey: AppConstants.Key.metaWearablesFPS) != nil
                ? UserDefaults.standard.double(forKey: AppConstants.Key.metaWearablesFPS)
                : AppConstants.metaWearablesFPS
            let targetFps = max(1.0, min(30.0, defaultFps))
            let interval = 1.0 / targetFps

            let now = CFAbsoluteTimeGetCurrent()
            if now - lastTime < interval { return false }
            lastTime = now
            return true
        }
    }
    private let throttle = FrameThrottle()

    private final class TokenBox: @unchecked Sendable {
        var token: (any AnyListenerToken)?
    }

    private final class ResumeFlag: @unchecked Sendable {
        private var lock = os_unfair_lock()
        private var resumed = false
        func tryResume() -> Bool {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    #if canImport(MWDATMockDevice)
    private var mockDevice: MockRaybanMeta?
    private var isMockWearableEnabled = false
    private var mockTimer: Timer?
    private var mockFrameIndex = 0
    #endif

    private var deviceObservationTask: Task<Void, Never>?
    private var registrationObservationTask: Task<Void, Never>?
    private var permissionCheckTask: Task<Void, Never>?
    private var hasLoggedNoDevices = false
    private var hasLoggedPermissionRetry = false
    private var lastKnownDeviceIds: [String] = []
    private var lastRegistrationState: String = ""
    private var isSettingUpStream = false

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
                // Staggered retry: SDK may not have emitted newly registered devices yet
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.setupDeviceObservation()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
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
        // print("[MockWearable] Mock wearables are disabled for SDK 0.5.0 compatibility testing.")
        #endif
    }

    func checkPermissions() {
        guard !permissionGranted else { return } // Already confirmed this session
        // Cancel any existing permission check loop to prevent concurrent retry storms
        permissionCheckTask?.cancel()
        hasLoggedPermissionRetry = false
        permissionCheckTask = Task { [weak self] in
            var retryCount = 0
            let maxRetries = 10
            while retryCount < maxRetries {
                guard !Task.isCancelled else { return }
                guard let self = self, !self.permissionGranted else { return }
                do {
                    let status = try await Wearables.shared.checkPermissionStatus(.camera)
                    let statusStr = String(describing: status).lowercased()
                    let granted = statusStr.contains("grant") || statusStr.contains("authoriz")
                    print("[MetaWearable] Permission check result: '\(statusStr)' → granted=\(granted)")
                    await MainActor.run { self.permissionGranted = granted }
                    return // Success — exit loop
                } catch {
                    if !self.hasLoggedPermissionRetry {
                        print("[MetaWearable] Permission check threw: \(error) — will retry (max \(maxRetries)x)")
                        await MainActor.run { self.hasLoggedPermissionRetry = true }
                    }
                    retryCount += 1
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
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
                await MainActor.run {
                    guard let self = self else { return }
                    // Only log when registration state actually changes
                    if stateStr != self.lastRegistrationState {
                        self.lastRegistrationState = stateStr
                        print("[MetaWearable] Registration state: \(stateStr)")
                    }
                    // Re-evaluate actual camera permissions when registration changes
                    self.checkPermissions()
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
                    // Only log when device list actually changes
                    if deviceIds != self.lastKnownDeviceIds {
                        self.lastKnownDeviceIds = deviceIds
                        if !deviceIds.isEmpty {
                            print("[MetaWearable] Devices changed: \(deviceIds.count) device(s)")
                        }
                        self.hasLoggedNoDevices = false // Reset so "No devices" logs once if they disconnect
                    }
                    self.updateConnectedDevices(deviceIds)
                }
            }
        }

        // Initial fetch
        let deviceIds = Wearables.shared.devices
        if deviceIds != lastKnownDeviceIds {
            lastKnownDeviceIds = deviceIds
            if !deviceIds.isEmpty {
                print("[MetaWearable] Initial devices: \(deviceIds.count) device(s)")
            }
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
            if permissionGranted {
                print("[MetaWearable] CaptureView requested stream start")
                setupStreamSession(for: firstDevice.id)
            } else {
                print("[MetaWearable] CaptureView requested stream start, but deferred due to missing permissions")
            }
        }
    }

    /// Called by CaptureView.onDisappear — stops the camera stream to save resources.
    /// Synchronously clears session state to prevent startStreaming() race conditions.
    func stopStreaming() {
        isStreamingRequested = false
        // Capture references before clearing — clear synchronously to prevent races
        let stream = self.streamSession
        let devSession = self.deviceSession
        self.streamSession = nil
        self.deviceSession = nil
        self.isStreaming = false
        self.latestProxyImage = nil
        self.isSettingUpStream = false
        // Async teardown of SDK resources
        if stream != nil || devSession != nil {
            print("[MetaWearable] CaptureView dismissed — stopping stream")
            Task {
                await stream?.stop()
                devSession?.stop()
            }
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

    func openFirmwareUpdate() {
        Task {
            do {
                // Try the specific DAT app update first to fix noEligibleDevice
                try await Wearables.shared.openDATGlassesAppUpdate()
            } catch {
                // Fallback to regular firmware update
                try? await Wearables.shared.openFirmwareUpdate()
            }
        }
    }

    private func setupStreamSession(for deviceId: String) {
        // Synchronous guard prevents concurrent setup attempts
        guard !isSettingUpStream else {
            print("[MetaWearable] Stream setup already in progress, skipping")
            return
        }
        guard streamSession == nil else {
            print("[MetaWearable] Stream session already exists, skipping setup")
            return
        }
        isSettingUpStream = true
        connectionFailed = false

        Task { [weak self] in
            guard let self = self else { return }
            defer { self.isSettingUpStream = false }
            guard self.permissionGranted else {
                print("[MetaWearable] Blocked stream setup: permissions not granted")
                return
            }
            guard self.streamSession == nil else {
                print("[MetaWearable] Stream session already exists, skipping setup")
                return
            }

            // Get the device object and log its full state
            guard let device = Wearables.shared.deviceForIdentifier(deviceId) else {
                print("[MetaWearable] deviceForIdentifier returned nil for \(deviceId)")
                return
            }
            print("[MetaWearable] Device: \(device.nameOrId()) linkState=\(device.linkState) compat=\(device.compatibility()) type=\(device.deviceType())")

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
                    let box = TokenBox()
                    let flag = ResumeFlag()
                    box.token = device.addLinkStateListener { state in
                        print("[MetaWearable] Device linkState changed: \(state)")
                        if state == .connected {
                            let t = box.token
                            Task { await t?.cancel() }
                            if flag.tryResume() {
                                continuation.resume()
                            }
                        }
                    }
                    // Check again in case it changed during setup
                    if device.linkState == .connected {
                        let t = box.token
                        Task { await t?.cancel() }
                        if flag.tryResume() {
                            continuation.resume()
                        }
                    }
                }
                print("[MetaWearable] Device connected!")
            }

            // Create DeviceSession via SpecificDeviceSelector to avoid race conditions
            let selector = SpecificDeviceSelector(device: deviceId)
            let devSession: DeviceSession
            do {
                devSession = try Wearables.shared.createSession(deviceSelector: selector)
            } catch {
                let errStr = String(describing: error).lowercased()
                if errStr.contains("sessionalreadyexists") || errStr.contains("inprogress") {
                    print("[MetaWearable] Session conflict (​\(error)) — waiting 2s for SDK cleanup")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    // Retry once
                    do {
                        devSession = try Wearables.shared.createSession(deviceSelector: selector)
                    } catch {
                        print("[MetaWearable] Retry failed: \(error)")
                        self.connectionFailed = true
                        return
                    }
                } else {
                    print("[MetaWearable] Failed to create DeviceSession: \(error)")
                    return
                }
            }

            let stateStream = devSession.stateStream()

            do {
                try devSession.start()
            } catch {
                print("[MetaWearable] Failed to start DeviceSession: \(error)")
                let errStr = String(describing: error).lowercased()
                if errStr.contains("sessionalreadyexists") || errStr.contains("inprogress") {
                    print("[MetaWearable] Orphaned session detected! Attempting to force-stop...")
                    Task { @MainActor [weak self] in
                        self?.deviceUpdateRequired = true // trigger UI warning
                    }
                } else if errStr.contains("noeligibledevice") || errStr.contains("datappontheglassesupdaterequired") {
                    Task { @MainActor [weak self] in
                        self?.deviceUpdateRequired = true
                    }
                }
                return
            }

            print("[MetaWearable] Waiting for DeviceSession to start...")
            if devSession.state == .started {
                print("[MetaWearable] DeviceSession started (synchronous check)!")
            } else {
                let started = await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        for await state in stateStream {
                            if state == .started { return true }
                            if state == .stopped { return false }
                        }
                        return false
                    }
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s timeout
                        return false
                    }
                    let result = await group.next() ?? false
                    group.cancelAll()
                    return result
                }

                guard started else {
                    print("[MetaWearable] DeviceSession failed to start within timeout — tearing down (possible bad hardware state)")
                    devSession.stop()
                    self.connectionFailed = true
                    return
                }
                print("[MetaWearable] DeviceSession started!")
            }

            self.deviceSession = devSession

            // Add camera stream to the DeviceSession
            let session: MWDATCamera.Stream
            do {
                guard let stream = try devSession.addStream() else {
                    print("[MetaWearable] addStream returned nil")
                    return
                }
                session = stream
            } catch {
                print("[MetaWearable] Failed to add stream: \(error)")
                return
            }
            self.streamSession = session
            print("[MetaWearable] DeviceSession + Stream created")

            // --- MWDAT ANNOUNCER SUBSCRIPTION ---
            self.stateToken = session.statePublisher.listen { state in
                print("[MetaWearable] Stream state changed: \(state)")
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let stateStr = String(describing: state).lowercased()
                    if stateStr.contains("captur") || stateStr.contains("stream") {
                        self.isStreaming = true
                    } else {
                        self.isStreaming = false
                        _ = self.activeCaptureSession?.stop()
                    }
                    if stateStr.contains("stop") {
                        self.latestProxyImage = nil
                        self.streamSession = nil
                        self.deviceSession?.stop()
                        self.deviceSession = nil
                    }
                }
            }

            // Subscribe to actual camera frame output
            let localThrottle = self.throttle
            self.frameToken = session.videoFramePublisher.listen { [weak self] frame in
                guard let self = self else { return }
                // Throttle to ~7 FPS
                guard localThrottle.shouldProcess() else { return }

                // print("[MetaWearable] Received video frame")

                // TODO(Hardware Test): The DAT SDK 0.6.0 does not explicitly expose camera intrinsics.
                // However, AVFoundation sometimes silently injects metadata (like kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix)
                // directly into the sample buffer. When testing on physical glasses, check these logs.
                // If intrinsics exist, extract them to package with the Scan4D/Polycam export proxy data.
                // If empty, we may need to hardcode a fallback FOV matrix.
                // if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: frame.sampleBuffer, attachmentMode: kCMAttachmentMode_ShouldPropagate) {
                //     print("[MetaWearable] Sample buffer attachments (propagate): \(attachments)")
                // }
                // if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: frame.sampleBuffer, attachmentMode: kCMAttachmentMode_ShouldNotPropagate) {
                //     print("[MetaWearable] Sample buffer attachments (non-propagate): \(attachments)")
                // }

                if let pixelBuffer = CMSampleBufferGetImageBuffer(frame.sampleBuffer) {

                    // Wrap the non-Sendable CVPixelBuffer to safely cross the boundary to the MainActor
                    struct SendableBuffer: @unchecked Sendable {
                        let buffer: CVPixelBuffer
                    }
                    let sendableBuf = SendableBuffer(buffer: pixelBuffer)

                    // Decode the frame here (the SDK `frame` is not Sendable, so don't capture
                    // it in the Task). Read settings directly — UserDefaults is thread-safe and
                    // AppConstants is a plain constant, so no MainActor hop is needed.
                    let rawImage = frame.makeUIImage()
                    let isPrivacyEnabled = UserDefaults.standard.bool(forKey: AppConstants.Key.privacyFilter)
                    let compression = AppConstants.jpegCompressionQuality

                    Task {
                        var finalJpegData: Data?
                        var finalUIImage: UIImage?

                        if isPrivacyEnabled, let img = rawImage, let ciImage = CIImage(image: img) {
                            // Run segmentation/pixelation on the decoded frame and encode JPEG
                            // once — avoids encoding a raw JPEG only to decode + re-encode it.
                            // The wearable stream is natively landscape-right → Vision .up.
                            let (blurredData, _) = PrivacyBlurUtil.pixelatePersonsAndGetFaceCenters(ciImage: ciImage, orientation: .up)
                            finalJpegData = blurredData
                            finalUIImage = blurredData.flatMap { UIImage(data: $0) }
                        } else {
                            finalJpegData = rawImage?.jpegData(compressionQuality: compression)
                            finalUIImage = rawImage
                        }

                        let safeJpegData = finalJpegData
                        let safeUIImage = finalUIImage

                        await MainActor.run { [weak self] in
                            guard let self = self else { return }
                            self.isStreaming = true
                            if let uiImage = safeUIImage {
                                self.latestProxyImage = uiImage
                            } else {
                                print("[MetaWearable] Failed to create UIImage from frame")
                            }

                            if let jpeg = safeJpegData {
                                self.activeCaptureSession?.captureProxyFrameData(jpeg)
                            } else {
                                self.activeCaptureSession?.captureProxyFrame(pixelBuffer: sendableBuf.buffer)
                            }
                        }
                    }
                } else {
                    print("[MetaWearable] Frame had no pixel buffer")
                }
            }

            // Start the camera stream
            print("[MetaWearable] Starting stream...")
            await session.start()
            print("[MetaWearable] Stream started")
        }
    }
}
