import Foundation
import Observation
import Combine
import MWDATCore
import MWDATCamera

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
    
    // Inject this from CaptureView or proxy handler
    var activeCaptureSession: FrameCaptureSession?

    private init() {
        setupDeviceObservation()
        checkPermissions()
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
        isScanning.toggle()
        if isScanning {
            setupDeviceObservation()
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

    private func setupStreamSession(for deviceId: String) {
        Task { [weak self] in
            guard let self = self else { return }
            guard self.streamSession == nil else { return }
            
            // Safely bypass compiler mismatch if String doesn't implement DeviceSelector directly
            guard let selector = deviceId as? DeviceSelector else {
                print("Error: deviceId does not conform to DeviceSelector in this SDK version.")
                return
            }
            
            // MWDAT initializer doesn't throw, and .start() is an async but NON-throwing function
            let session = StreamSession(deviceSelector: selector)
            self.streamSession = session
            
            // --- MWDAT ANNOUNCER SUBSCRIPTION ---
            // Depending on the exact iteration of the MWDAT headers, `any Announcer` exposes 
            // block-based observers natively (e.g. .subscribe, .addListener, .observe).
            // Once identified, uncomment the below blocks to map the Shutter button logic:
            /*
            self.stateToken = session.statePublisher.subscribe { state in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let stateStr = String(describing: state).lowercased()
                    if stateStr.contains("captur") || stateStr.contains("stream") {
                        self.isStreaming = true
                    } else {
                        self.isStreaming = false
                        self.activeCaptureSession?.stop()
                    }
                }
            }

            // Subscribe to actual camera frame output (e.g. session.frameAnnouncer / session.cameraPublisher)
            self.frameToken = session.videoFramePublisher?.subscribe { frame in
                // hook.captureProxyFrame(pixelBuffer: frame.pixelBuffer)
            }
            */
            
            await session.start()
        }
    }
}
