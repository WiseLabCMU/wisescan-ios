import AVFoundation
import CoreMotion
import Foundation
import ImageIO
import Synchronization
import os
import simd

// swiftlint:disable file_length type_body_length function_body_length identifier_name

/// EXPERIMENT: ARKit-free capture. One `AVCaptureSession` on the LiDAR camera records three
/// streams into a directory, every record stamped on the same clock, then zips the directory.
///
/// What it tests (the premise behind a splat-quality focal scan, see the raw-capture branch
/// discussion): can the photo pipeline deliver full-sensor stills continuously while LiDAR depth
/// keeps streaming beside them, and can both be aligned to the IMU by timestamp alone.
///
///   - **Stills** from `AVCapturePhotoOutput` at the format's largest photo dimensions, fired
///     back-to-back with one capture in flight, each with depth delivery requested so the per-photo
///     depth answers "do 48MP and depth combine" directly. A gyro gate (same threshold as the AR
///     path's blur gate) skips the request while the device is turning fast.
///   - **Depth** from `AVCaptureDepthDataOutput`, synchronized with the video stream. Every depth
///     frame is logged (timestamp, dropped flag, video intrinsics); a rate-capped subset is written
///     as 16-bit millimetre PNGs. Video frames themselves are not saved — the stream is there for
///     the synchronizer and its intrinsics attachment.
///   - **IMU** from CoreMotion: fused device motion plus raw gyro and accelerometer.
///
/// **Clock.** Every `host_ts` is seconds on the host clock (`CMClockGetHostTimeClock`, i.e. time
/// since boot). Capture timestamps are converted from the session's synchronization clock
/// explicitly; CoreMotion reports on the same clock natively. `manifest.json` records the wall
/// time and uptime at start so a consumer can relate the two.
///
/// **Not here on purpose.** No pose. No ARKit. No exposure lock (one optional cap on the
/// auto-exposure duration, off by default). Zip and share, nothing persisted in the scan store.
///
/// Threading: `start`/`stop` from main. Capture delegates land on `dataQueue`; every file write
/// goes through `ioQueue`; the UI reads `liveStats()` from a lock-guarded mirror. Nothing here
/// is `@MainActor`.
nonisolated final class RawCaptureSession: NSObject, @unchecked Sendable {

    // MARK: Types

    /// What the session was configured with, written into `manifest.json` and shown on screen.
    nonisolated struct Setup: Codable, Equatable, Sendable {
        var deviceModel = ""
        var cameraName = ""
        var videoFormat = ""
        var maxPhotoDimensions = ""
        var depthFormat = ""
        var photoCodec = ""
        var jpegQuality = 0.0
        /// Bayer RAW pixel formats the photo output offers (four-character codes), empty when
        /// the device cannot capture DNG. Reported so the dump says whether raw is an option.
        var rawPhotoPixelFormats = ""
        var qualityPrioritization = ""
        var depthDeliverySupported = false
        var depthDeliveryEnabled = false
        var responsiveCaptureSupported = false
        var responsiveCaptureEnabled = false
        var intrinsicsDeliveryEnabled = false
        /// Effective cap on auto-exposure duration after clamping to the format's range (0 = none).
        var maxExposureCapSeconds = 0.0
        /// Hard ceiling on gyro rate, independent of exposure.
        var motionGateRadPerSec = 0.0
        /// Blur budget: a still is requested only while rate x exposure x focal predicts at most this.
        var blurBudgetPx = 0.0
        /// Focal length in photo pixels used by the gate: from the format's field of view until the
        /// first photo's calibration data refines it.
        var photoFocalPxEstimate = 0.0
        /// Still spacing thresholds in force (see `spacingDecision`).
        var stillSpacingRotationDeg = 0.0
        var stillSpacingShiftFraction = 0.0
        var stillMinIntervalSeconds = 0.0
        var stillMaxIntervalSeconds = 0.0
        var flowHz = 0.0
        var depthSaveMaxHz = 0.0
        /// Requested CoreMotion interval. CoreMotion clamps to the sensor's minimum, so the
        /// achieved rate is a measurement (`totals.*_hz`), not this.
        var imuRequestedIntervalSeconds = 0.0
        var startWallTime = ""
        var startUptimeSeconds = 0.0
        var clock = "host (seconds since boot; CMClockGetHostTimeClock == CoreMotion timestamp)"
    }

    /// Sample count and achieved rate of one sensor stream, from its own timestamps.
    nonisolated struct StreamRate: Equatable, Sendable {
        var count = 0
        var firstTimestamp = -1.0
        var lastTimestamp = 0.0
        /// Achieved rate over the samples seen so far (0 until two samples exist).
        var hz: Double {
            count > 1 && lastTimestamp > firstTimestamp ? Double(count - 1) / (lastTimestamp - firstTimestamp) : 0
        }
        mutating func sample(at timestamp: Double) {
            if firstTimestamp < 0 { firstTimestamp = timestamp }
            lastTimestamp = timestamp
            count += 1
        }
    }

    /// Counters mirrored for the UI, published from the capture queues.
    nonisolated struct LiveStats: Equatable, Sendable {
        var photosRequested = 0
        var photosSaved = 0
        var photosFailed = 0
        var photosGated = 0
        var photosWithDepth = 0
        var photoInFlight = false
        var lastPhotoLatencySeconds = 0.0
        var lastPhotoDimensions = ""
        var lastExposureSeconds = 0.0
        var lastISO = 0
        /// Live auto-exposure reading at the last gate check, and the smear it predicts.
        var aeExposureSeconds = 0.0
        var aeISO = 0.0
        var predictedSmearPx = 0.0
        /// Viewpoint change accumulated since the previous still, for the spacing gate.
        var rotationSinceStillDeg = 0.0
        var shiftSinceStillFraction = 0.0
        /// Image motion on the video stream, fraction of frame width per second.
        var flowSpeedFractionPerSecond = 0.0
        /// Gate checks held for spacing (checks, not stills: one every `rawCaptureGateRetrySeconds`).
        var spacingHolds = 0
        var lastSpacingReason = ""
        var depthFramesReceived = 0
        var depthFramesDropped = 0
        var depthFramesSaved = 0
        var videoFramesDropped = 0
        var lastDepthDimensions = ""
        var deviceMotion = StreamRate()
        var gyro = StreamRate()
        var accel = StreamRate()
        var magnetometer = StreamRate()
        var rotationRateRadPerSec = 0.0
        var interruptions = 0
        var runtimeErrors = 0
        var lastError = ""
        var bytesWritten: Int64 = 0
        var elapsedSeconds = 0.0
    }

    nonisolated enum Failure: Error, CustomStringConvertible {
        case noLiDARCamera
        case noDepthFormat
        case cannotAddInput
        case cannotAddOutput(String)
        case directory(String)

        var description: String {
            switch self {
            case .noLiDARCamera: return "No LiDAR depth camera on this device"
            case .noDepthFormat: return "The LiDAR camera has no format with depth"
            case .cannotAddInput: return "Could not add the camera input"
            case .cannotAddOutput(let name): return "Could not add the \(name) output"
            case .directory(let reason): return "Could not create the capture directory: \(reason)"
            }
        }
    }

    // MARK: State

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "org.arenaxr.scan4d.rawcapture.session", qos: .userInitiated)
    private let dataQueue = DispatchQueue(label: "org.arenaxr.scan4d.rawcapture.data", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "org.arenaxr.scan4d.rawcapture.io", qos: .utility)
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        queue.name = "org.arenaxr.scan4d.rawcapture.motion"
        return queue
    }()

    private var device: AVCaptureDevice?
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var synchronizer: AVCaptureDataOutputSynchronizer?
    private let motion = CMMotionManager()
    private var observers: [NSObjectProtocol] = []

    private let running = Atomic<Bool>(false)
    private let live = OSAllocatedUnfairLock(initialState: LiveStats())
    /// Latest fused rotation-rate magnitude, for the photo gate. Written on `motionQueue`.
    private let rotationRate = OSAllocatedUnfairLock(initialState: 0.0)

    private(set) var setup = Setup()
    private(set) var captureDirectory: URL?
    private var startUptime: TimeInterval = 0

    // dataQueue-owned
    /// Codec the stills are encoded with: the configured one when the output offers it, else JPEG.
    private var photoCodec: AVVideoCodecType = .jpeg
    private var depthIndex = 0
    private var lastDepthSaveHostTime: TimeInterval = -1
    private var photoIndex = 0
    /// What the gate saw when it issued each still, keyed by the settings' unique ID.
    private struct RequestContext {
        var hostTime: TimeInterval
        var omega: Double
        var exposure: Double
        var smearPx: Double
        var interval: Double
        var rotationDeg: Double
        var shiftFraction: Double
        var flowSpeed: Double
        var reason: String
    }
    private var photoRequests: [Int64: RequestContext] = [:]
    /// Focal length in photo pixels for the smear prediction. dataQueue-owned after configure.
    private var photoFocalPx = 0.0
    /// Latest fused attitude, written on `motionQueue`, read by the spacing gate.
    private let attitude = OSAllocatedUnfairLock<simd_quatd?>(initialState: nil)
    // Spacing state, dataQueue-owned.
    private var attitudeAtLastStill: simd_quatd?
    private var lastStillHostTime: TimeInterval = -1
    private var flowSinceStill = SIMD2<Float>(0, 0)
    private var flowSpeed = 0.0
    private var lastFlowHostTime: TimeInterval = -1
    private var shiftEstimator = ImageShiftEstimator()
    private var photoInFlight = false

    // ioQueue-owned
    private var writers: [String: CSVWriter] = [:]
    private var eventsHandle: FileHandle?

    /// The preview layer's session. Read-only; the view attaches an `AVCaptureVideoPreviewLayer`.
    var captureSession: AVCaptureSession { session }

    // MARK: Lifecycle

    /// Configures the camera, opens the capture directory, starts the three streams and the
    /// photo loop. Completion on main with the setup, or the reason it could not start.
    func start(label: String, completion: @escaping @Sendable (Result<Setup, Error>) -> Void) {
        sessionQueue.async { [self] in
            do {
                let directory = try makeDirectory(label: label)
                captureDirectory = directory
                try configure()
                startUptime = ProcessInfo.processInfo.systemUptime
                setup.startWallTime = ISO8601DateFormatter().string(from: Date())
                setup.startUptimeSeconds = startUptime
                ioQueue.sync { openWriters(in: directory) }
                installObservers()
                running.store(true, ordering: .releasing)
                live.withLock { $0 = LiveStats() }
                startMotion()
                session.startRunning()
                event("session started \(setup.videoFormat) photo=\(setup.maxPhotoDimensions) depth=\(setup.depthFormat)")
                dataQueue.async { [self] in requestPhotoIfIdle() }
                let setup = self.setup
                DispatchQueue.main.async { completion(.success(setup)) }
            } catch {
                event("start failed: \(error)")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// Stops every stream, flushes the logs, writes `manifest.json`, zips the directory and
    /// removes it. Completion on main with the zip, or nil when the zip failed (the directory is
    /// then left in place so nothing is lost).
    func stop(completion: @escaping @Sendable (URL?) -> Void) {
        sessionQueue.async { [self] in
            running.store(false, ordering: .releasing)
            motion.stopDeviceMotionUpdates()
            motion.stopGyroUpdates()
            motion.stopAccelerometerUpdates()
            motion.stopMagnetometerUpdates()
            if session.isRunning { session.stopRunning() }
            removeObservers()
            event("session stopped")
            let stats = liveStats()
            ioQueue.async { [self] in
                writeManifest(stats: stats)
                closeWriters()
                guard let directory = captureDirectory else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                let zip = Self.zip(directory: directory)
                if zip != nil { try? FileManager.default.removeItem(at: directory) }
                DispatchQueue.main.async { completion(zip) }
            }
        }
    }

    /// The counters so far. Cheap; the view polls it a few times a second.
    func liveStats() -> LiveStats {
        var stats = live.withLock { $0 }
        stats.rotationRateRadPerSec = rotationRate.withLock { $0 }
        if startUptime > 0 { stats.elapsedSeconds = ProcessInfo.processInfo.systemUptime - startUptime }
        return stats
    }

    // MARK: Configuration

    private func makeDirectory(label: String) throws -> URL {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let safeLabel = label.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression)
        let name = "raw_capture_\(safeLabel)_\(formatter.string(from: Date()))"
        let directory = documents.appendingPathComponent(AppConstants.rawCaptureFolder).appendingPathComponent(name)
        do {
            try fm.createDirectory(at: directory.appendingPathComponent("photos"), withIntermediateDirectories: true)
            try fm.createDirectory(at: directory.appendingPathComponent("photo_depth"), withIntermediateDirectories: true)
            try fm.createDirectory(at: directory.appendingPathComponent("depth"), withIntermediateDirectories: true)
        } catch {
            throw Failure.directory(error.localizedDescription)
        }
        return directory
    }

    private func configure() throws {
        guard let device = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) else {
            throw Failure.noLiDARCamera
        }
        self.device = device
        guard let chosen = Self.chooseFormats(for: device) else { throw Failure.noDepthFormat }
        let (format, depthFormat) = chosen

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            throw Failure.cannotAddInput
        }
        session.addInput(input)

        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeDepthDataFormat = depthFormat
        let frameDuration = CMTime(value: 1, timescale: Int32(AppConstants.rawCaptureVideoFPS))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        // Shutter ceiling for AE: it keeps metering but trades ISO for duration above this. The
        // first dump ran uncapped and AE sat at 1/30 s indoors, which blurred at walking pace.
        // Clamped to the format's range because an out-of-range value raises.
        var effectiveCap = 0.0
        if AppConstants.rawCaptureMaxExposureSeconds > 0 {
            let wanted = CMTime(seconds: AppConstants.rawCaptureMaxExposureSeconds, preferredTimescale: 1_000_000)
            let range = CMTimeRange(start: format.minExposureDuration, end: format.maxExposureDuration)
            let clamped = CMTimeClampToRange(wanted, range: range)
            device.activeMaxExposureDuration = clamped
            effectiveCap = CMTimeGetSeconds(clamped)
        }
        device.unlockForConfiguration()

        // Photo output. Added first: maxPhotoDimensions and depth delivery are only settable once
        // the output is in a session with a configured device.
        guard session.canAddOutput(photoOutput) else { throw Failure.cannotAddOutput("photo") }
        session.addOutput(photoOutput)
        let largest = format.supportedMaxPhotoDimensions.max { $0.width * $0.height < $1.width * $1.height }
        if let largest { photoOutput.maxPhotoDimensions = largest }
        photoOutput.maxPhotoQualityPrioritization = AppConstants.rawCapturePhotoQuality
        photoOutput.isDepthDataDeliveryEnabled = photoOutput.isDepthDataDeliverySupported
        if photoOutput.isResponsiveCaptureSupported {
            photoOutput.isResponsiveCaptureEnabled = AppConstants.rawCaptureResponsiveCapture
        }

        // Video stream: never saved, but it carries the intrinsics attachment and anchors the
        // synchronizer. Late frames are dropped so it can never backlog the depth stream.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        guard session.canAddOutput(videoOutput) else { throw Failure.cannotAddOutput("video") }
        session.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video), connection.isCameraIntrinsicMatrixDeliverySupported {
            connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            setup.intrinsicsDeliveryEnabled = true
        }

        // Depth stream, unfiltered: the raw LiDAR estimate, not the temporally smoothed one.
        depthOutput.isFilteringEnabled = false
        depthOutput.alwaysDiscardsLateDepthData = true
        guard session.canAddOutput(depthOutput) else { throw Failure.cannotAddOutput("depth") }
        session.addOutput(depthOutput)

        let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
        synchronizer.setDelegate(self, queue: dataQueue)
        self.synchronizer = synchronizer

        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let depthDims = CMVideoFormatDescriptionGetDimensions(depthFormat.formatDescription)
        setup.deviceModel = Self.hardwareModel()
        setup.cameraName = device.localizedName
        setup.videoFormat = "\(dims.width)x\(dims.height)@\(AppConstants.rawCaptureVideoFPS)"
        setup.maxPhotoDimensions = largest.map { "\($0.width)x\($0.height)" } ?? "unknown"
        setup.depthFormat = "\(depthDims.width)x\(depthDims.height) " + Self.fourCC(CMFormatDescriptionGetMediaSubType(depthFormat.formatDescription))
        let wanted = AppConstants.rawCapturePhotoCodec
        photoCodec = photoOutput.availablePhotoCodecTypes.contains(wanted) ? wanted : .jpeg
        setup.photoCodec = photoCodec == .hevc ? "hevc" : "jpeg"
        setup.jpegQuality = photoCodec == .jpeg ? AppConstants.rawCaptureJPEGQuality : 0
        setup.rawPhotoPixelFormats = photoOutput.availableRawPhotoPixelFormatTypes.map(Self.fourCC).joined(separator: " ")
        setup.qualityPrioritization = Self.name(of: AppConstants.rawCapturePhotoQuality)
        setup.depthDeliverySupported = photoOutput.isDepthDataDeliverySupported
        setup.depthDeliveryEnabled = photoOutput.isDepthDataDeliveryEnabled
        setup.responsiveCaptureSupported = photoOutput.isResponsiveCaptureSupported
        setup.responsiveCaptureEnabled = photoOutput.isResponsiveCaptureEnabled
        setup.maxExposureCapSeconds = effectiveCap
        setup.motionGateRadPerSec = Double(AppConstants.motionBlurAngularVelocity)
        setup.blurBudgetPx = AppConstants.rawCaptureBlurBudgetPx
        // Focal length in photo pixels from the format's horizontal field of view; the first
        // photo's calibration data replaces it. Both rasters are 4:3 so the FOV carries over.
        let fovDegrees = Double(format.videoFieldOfView)
        if fovDegrees > 0, let largest {
            photoFocalPx = Double(largest.width) / 2 / tan(fovDegrees / 2 * .pi / 180)
        }
        setup.photoFocalPxEstimate = photoFocalPx
        setup.stillSpacingRotationDeg = AppConstants.rawCaptureStillSpacingRotationDeg
        setup.stillSpacingShiftFraction = AppConstants.rawCaptureStillSpacingShiftFraction
        setup.stillMinIntervalSeconds = AppConstants.rawCaptureStillMinIntervalSeconds
        setup.stillMaxIntervalSeconds = AppConstants.rawCaptureStillMaxIntervalSeconds
        setup.flowHz = AppConstants.rawCaptureFlowHz
        setup.depthSaveMaxHz = AppConstants.rawCaptureDepthSaveMaxHz
        setup.imuRequestedIntervalSeconds = AppConstants.rawCaptureIMUUpdateInterval
    }

    /// The 4:3 video format whose photo dimensions are largest among those that stream depth,
    /// and that format's highest-resolution depth format. Among ties on photo size the SMALLEST
    /// video raster wins: the stream is only there for sync and intrinsics.
    private static func chooseFormats(for device: AVCaptureDevice) -> (AVCaptureDevice.Format, AVCaptureDevice.Format)? {
        let fps = Double(AppConstants.rawCaptureVideoFPS)
        let candidates = device.formats.filter { format in
            guard !format.supportedDepthDataFormats.isEmpty else { return false }
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard abs(Double(dims.width) / Double(dims.height) - 4.0 / 3.0) < 0.01 else { return false }
            return format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
        }
        func photoPixels(_ f: AVCaptureDevice.Format) -> Int32 {
            f.supportedMaxPhotoDimensions.map { $0.width * $0.height }.max() ?? 0
        }
        func videoPixels(_ f: AVCaptureDevice.Format) -> Int32 {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width * d.height
        }
        guard let best = candidates.max(by: { a, b in
            if photoPixels(a) != photoPixels(b) { return photoPixels(a) < photoPixels(b) }
            return videoPixels(a) > videoPixels(b)
        }) else { return nil }
        let depthFormats = best.supportedDepthDataFormats.filter {
            let sub = CMFormatDescriptionGetMediaSubType($0.formatDescription)
            return sub == kCVPixelFormatType_DepthFloat32 || sub == kCVPixelFormatType_DepthFloat16
        }
        guard let depth = (depthFormats.isEmpty ? best.supportedDepthDataFormats : depthFormats).max(by: { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return da.width * da.height < db.width * db.height
        }) else { return nil }
        return (best, depth)
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int).map(String.init) ?? "?"
            self?.live.withLock { $0.interruptions += 1 }
            self?.event("session interrupted reason=\(reason)")
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.event("session interruption ended")
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let text = error?.localizedDescription ?? "unknown"
            self?.live.withLock { $0.runtimeErrors += 1; $0.lastError = text }
            self?.event("session runtime error: \(text)")
        })
    }

    private func removeObservers() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    // MARK: IMU

    /// Every CoreMotion stream, each at its sensor's own maximum rate and each to its own CSV.
    /// The requested interval is far below any hardware minimum, so CoreMotion clamps to the
    /// fastest the sensor delivers; the achieved rate is measured from the sample timestamps
    /// (`LiveStats.StreamRate`) rather than assumed. Raw gyro and accelerometer are the streams
    /// a motion reconstruction integrates; device motion is Apple's fused estimate beside them
    /// for comparison; the magnetometer is uncalibrated and recorded only because it is free.
    private func startMotion() {
        let interval = AppConstants.rawCaptureIMUUpdateInterval
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = interval
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) { [weak self] data, error in
                guard let self else { return }
                if let error { event("device motion error: \(error.localizedDescription)"); return }
                guard let d = data else { return }
                let r = d.rotationRate
                let magnitude = sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
                rotationRate.withLock { $0 = magnitude }
                let q = d.attitude.quaternion
                attitude.withLock { $0 = simd_quatd(ix: q.x, iy: q.y, iz: q.z, r: q.w) }
                let a = d.userAcceleration
                let g = d.gravity
                let line = [d.timestamp, q.w, q.x, q.y, q.z, r.x, r.y, r.z, a.x, a.y, a.z, g.x, g.y, g.z]
                    .map { String(format: "%.6f", $0) }.joined(separator: ",")
                append("imu_devicemotion.csv", line)
                live.withLock { $0.deviceMotion.sample(at: d.timestamp) }
            }
        } else {
            event("device motion unavailable")
        }
        if motion.isGyroAvailable {
            motion.gyroUpdateInterval = interval
            motion.startGyroUpdates(to: motionQueue) { [weak self] data, _ in
                guard let self, let d = data else { return }
                let r = d.rotationRate
                append("imu_gyro.csv", [d.timestamp, r.x, r.y, r.z].map { String(format: "%.6f", $0) }.joined(separator: ","))
                live.withLock { $0.gyro.sample(at: d.timestamp) }
            }
        } else {
            event("gyroscope unavailable")
        }
        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = interval
            motion.startAccelerometerUpdates(to: motionQueue) { [weak self] data, _ in
                guard let self, let d = data else { return }
                let a = d.acceleration
                append("imu_accel.csv", [d.timestamp, a.x, a.y, a.z].map { String(format: "%.6f", $0) }.joined(separator: ","))
                live.withLock { $0.accel.sample(at: d.timestamp) }
            }
        } else {
            event("accelerometer unavailable")
        }
        if motion.isMagnetometerAvailable {
            motion.magnetometerUpdateInterval = interval
            motion.startMagnetometerUpdates(to: motionQueue) { [weak self] data, _ in
                guard let self, let d = data else { return }
                let m = d.magneticField
                append("imu_magnetometer.csv", [d.timestamp, m.x, m.y, m.z].map { String(format: "%.6f", $0) }.joined(separator: ","))
                live.withLock { $0.magnetometer.sample(at: d.timestamp) }
            }
        }
        event("imu requested interval=\(interval)s; achieved rates are measured into manifest.json")
    }

    // MARK: Photo loop (dataQueue)

    /// Issues the next still unless one is in flight, the session is stopping, or the device is
    /// turning faster than the blur gate allows (then it re-checks shortly).
    private func requestPhotoIfIdle() {
        guard running.load(ordering: .acquiring), !photoInFlight else { return }
        // Blur budget: gyro rate x the exposure AE is about to use x focal length, in photo
        // pixels. A fixed angular threshold cannot be right across lighting: 0.5 rad/s is a
        // 50 px smear at 1/30 s on a 4032 px frame and a 3 px smear at 1/500 s. The rate
        // ceiling stays as a backstop for when the exposure reading is unavailable. Rotation
        // only: translational blur needs a pose, which this path does not have.
        let omega = rotationRate.withLock { $0 }
        var exposure = 0.0
        var iso = 0.0
        if let device {
            let seconds = CMTimeGetSeconds(device.exposureDuration)
            if seconds.isFinite, seconds > 0 { exposure = seconds }
            iso = Double(device.iso)
        }
        let smearPx = omega * exposure * photoFocalPx
        live.withLock { $0.aeExposureSeconds = exposure; $0.aeISO = iso; $0.predictedSmearPx = smearPx }
        let overBudget = exposure > 0 && photoFocalPx > 0 && smearPx > AppConstants.rawCaptureBlurBudgetPx
        if omega > Double(AppConstants.motionBlurAngularVelocity) || overBudget {
            live.withLock { $0.photosGated += 1 }
            dataQueue.asyncAfter(deadline: .now() + AppConstants.rawCaptureGateRetrySeconds) { [self] in requestPhotoIfIdle() }
            return
        }
        // Spacing: hold the next still until the viewpoint has changed enough since the previous
        // one. Without it the loop runs at the photo pipeline's latency, which over-samples slow
        // movement. Rotation comes from the fused attitude; translation only shows up as image
        // shift on the video stream (rotation does too, so the two thresholds should agree: a
        // shift of one frame width is one horizontal field of view).
        let now = ProcessInfo.processInfo.systemUptime
        let sinceLast = lastStillHostTime < 0 ? Double.infinity : now - lastStillHostTime
        let rotationDeg = rotationSinceLastStillDeg()
        let shiftFraction = Double(simd_length(flowSinceStill))
        live.withLock { $0.rotationSinceStillDeg = rotationDeg }
        guard let reason = Self.spacingDecision(
            sinceLast: sinceLast, rotationDeg: rotationDeg, shiftFraction: shiftFraction,
            minInterval: AppConstants.rawCaptureStillMinIntervalSeconds,
            rotationThresholdDeg: AppConstants.rawCaptureStillSpacingRotationDeg,
            shiftThreshold: AppConstants.rawCaptureStillSpacingShiftFraction,
            maxInterval: AppConstants.rawCaptureStillMaxIntervalSeconds
        ) else {
            live.withLock { $0.spacingHolds += 1 }
            dataQueue.asyncAfter(deadline: .now() + AppConstants.rawCaptureGateRetrySeconds) { [self] in requestPhotoIfIdle() }
            return
        }
        // Container only: the ISP processing (quality prioritization) is the same for JPEG and
        // HEVC. AVVideoQualityKey is the one compression property photo settings honour.
        var format: [String: Any] = [AVVideoCodecKey: photoCodec]
        if photoCodec == .jpeg {
            format[AVVideoCompressionPropertiesKey] = [AVVideoQualityKey: AppConstants.rawCaptureJPEGQuality]
        }
        let settings = AVCapturePhotoSettings(format: format)
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.photoQualityPrioritization = AppConstants.rawCapturePhotoQuality
        if photoOutput.isDepthDataDeliveryEnabled {
            settings.isDepthDataDeliveryEnabled = true
            settings.embedsDepthDataInPhoto = false
        }
        photoInFlight = true
        photoRequests[settings.uniqueID] = RequestContext(
            hostTime: now, omega: omega, exposure: exposure, smearPx: smearPx, interval: sinceLast,
            rotationDeg: rotationDeg, shiftFraction: shiftFraction, flowSpeed: flowSpeed, reason: reason)
        lastStillHostTime = now
        attitudeAtLastStill = attitude.withLock { $0 }
        flowSinceStill = SIMD2(0, 0)
        live.withLock {
            $0.photosRequested += 1
            $0.photoInFlight = true
            $0.lastSpacingReason = reason
            $0.rotationSinceStillDeg = 0
            $0.shiftSinceStillFraction = 0
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    /// Spacing verdict: the reason the next still may fire now, or nil to hold. Pure, for tests.
    /// `sinceLast` is `.infinity` before the first still. Thresholds at or below 0 are off; with
    /// both motion thresholds off the loop is unspaced (the pipeline's latency sets the rate).
    static func spacingDecision(sinceLast: Double, rotationDeg: Double, shiftFraction: Double,
                                minInterval: Double, rotationThresholdDeg: Double, shiftThreshold: Double,
                                maxInterval: Double) -> String? {
        if sinceLast < minInterval { return nil }
        if rotationThresholdDeg <= 0 && shiftThreshold <= 0 { return "unspaced" }
        if sinceLast == .infinity { return "first" }
        if rotationThresholdDeg > 0 && rotationDeg >= rotationThresholdDeg { return "rotation" }
        if shiftThreshold > 0 && shiftFraction >= shiftThreshold { return "shift" }
        if maxInterval > 0 && sinceLast >= maxInterval { return "time" }
        return nil
    }

    /// Angle between the fused attitude now and at the previous still, degrees. 0 before the
    /// first still or without device motion.
    private func rotationSinceLastStillDeg() -> Double {
        guard let previous = attitudeAtLastStill, let current = attitude.withLock({ $0 }) else { return 0 }
        let dot = min(1, abs(simd_dot(previous.vector, current.vector)))
        return 2 * acos(dot) * 180 / .pi
    }

    /// Image motion on the video stream: a block-matched global shift between consecutive luma
    /// thumbnails, at most `rawCaptureFlowHz` times a second. Accumulated as a vector since the
    /// previous still (hand oscillation cancels, a real move does not) for the spacing gate, and
    /// kept as a speed for the per-still log. dataQueue-only.
    private func updateFlow(_ sampleBuffer: CMSampleBuffer, hostTime: TimeInterval) {
        let minInterval = 1.0 / max(1, AppConstants.rawCaptureFlowHz)
        guard lastFlowHostTime < 0 || hostTime - lastFlowHostTime >= minInterval,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let thumbnail = ImageShiftEstimator.lumaThumbnail(pixelBuffer) else { return }
        let dt = lastFlowHostTime < 0 ? 0 : hostTime - lastFlowHostTime
        lastFlowHostTime = hostTime
        guard let shift = shiftEstimator.update(thumbnail) else { return }
        let fraction = shift / Float(ImageShiftEstimator.width)
        flowSinceStill += fraction
        flowSpeed = dt > 0 ? Double(simd_length(fraction)) / dt : 0
        live.withLock {
            $0.flowSpeedFractionPerSecond = flowSpeed
            $0.shiftSinceStillFraction = Double(simd_length(flowSinceStill))
        }
    }

    private func photoFinished() {
        photoInFlight = false
        live.withLock { $0.photoInFlight = false }
        requestPhotoIfIdle()
    }

    // MARK: Depth frames (dataQueue)

    private func handle(depth: AVCaptureSynchronizedDepthData?, video: AVCaptureSynchronizedSampleBufferData?) {
        guard running.load(ordering: .acquiring) else { return }
        let index = depthIndex
        depthIndex += 1

        var fields: [String] = [String(index)]
        var depthHost = -1.0
        if let depth {
            depthHost = hostSeconds(depth.timestamp)
            fields.append(String(format: "%.6f", depthHost))
            fields.append(depth.depthDataWasDropped ? "1" : "0")
        } else {
            fields.append(contentsOf: ["", ""])
        }
        if let video {
            let videoHost = hostSeconds(video.timestamp)
            fields.append(String(format: "%.6f", videoHost))
            fields.append(video.sampleBufferWasDropped ? "1" : "0")
            if !video.sampleBufferWasDropped { updateFlow(video.sampleBuffer, hostTime: videoHost) }
            if let desc = CMSampleBufferGetFormatDescription(video.sampleBuffer) {
                let dims = CMVideoFormatDescriptionGetDimensions(desc)
                fields.append(contentsOf: [String(dims.width), String(dims.height)])
            } else {
                fields.append(contentsOf: ["", ""])
            }
            if let k = Self.intrinsics(of: video.sampleBuffer) {
                fields.append(contentsOf: [k[0][0], k[1][1], k[2][0], k[2][1]].map { String(format: "%.3f", $0) })
            } else {
                fields.append(contentsOf: ["", "", "", ""])
            }
        } else {
            fields.append(contentsOf: ["", "", "", "", "", "", "", ""])
        }

        var saved = ""
        if let depth, !depth.depthDataWasDropped {
            let minInterval = 1.0 / AppConstants.rawCaptureDepthSaveMaxHz
            if lastDepthSaveHostTime < 0 || depthHost - lastDepthSaveHostTime >= minInterval {
                lastDepthSaveHostTime = depthHost
                // Convert on the delegate queue: the pixel buffer belongs to the capture pool and
                // must not be retained; the UInt16 copy is what goes to the IO queue.
                if let mm = Self.millimetres(from: depth.depthData) {
                    saved = String(format: "depth/depth_%06d.png", index)
                    let name = saved
                    live.withLock { $0.lastDepthDimensions = "\(mm.width)x\(mm.height)" }
                    ioQueue.async { [self] in
                        if let png = DepthPNG.encode(mm.values, width: mm.width, height: mm.height) {
                            write(png, to: name)
                            live.withLock { $0.depthFramesSaved += 1 }
                        } else {
                            event("depth png encode failed index=\(index)")
                        }
                    }
                }
            }
        }
        fields.append(saved)
        append("depth_frames.csv", fields.joined(separator: ","))
        live.withLock {
            $0.depthFramesReceived += 1
            if depth?.depthDataWasDropped == true { $0.depthFramesDropped += 1 }
            if video?.sampleBufferWasDropped == true { $0.videoFramesDropped += 1 }
        }
    }

    // MARK: Files (ioQueue)

    private func openWriters(in directory: URL) {
        eventsHandle = Self.openAppend(directory.appendingPathComponent("events.log"))
        writers = [
            "photos.csv": CSVWriter(url: directory.appendingPathComponent("photos.csv"),
                                    header: "index,file,host_ts,request_host_ts,latency_s,width,height,exposure_s,iso,depth_file,depth_width,depth_height,fx,fy,cx,cy,ref_width,ref_height,request_omega_rad_s,request_exposure_s,predicted_smear_px,interval_since_prev_s,rotation_since_prev_deg,shift_since_prev_frac,flow_speed_frac_s,spacing_reason"),
            "depth_frames.csv": CSVWriter(url: directory.appendingPathComponent("depth_frames.csv"),
                                          header: "index,host_ts,depth_dropped,video_host_ts,video_dropped,video_width,video_height,fx,fy,cx,cy,saved_file"),
            "imu_devicemotion.csv": CSVWriter(url: directory.appendingPathComponent("imu_devicemotion.csv"),
                                              header: "host_ts,qw,qx,qy,qz,rot_x,rot_y,rot_z,user_acc_x,user_acc_y,user_acc_z,gravity_x,gravity_y,gravity_z"),
            "imu_gyro.csv": CSVWriter(url: directory.appendingPathComponent("imu_gyro.csv"), header: "host_ts,rot_x,rot_y,rot_z"),
            "imu_accel.csv": CSVWriter(url: directory.appendingPathComponent("imu_accel.csv"), header: "host_ts,acc_x,acc_y,acc_z"),
            "imu_magnetometer.csv": CSVWriter(url: directory.appendingPathComponent("imu_magnetometer.csv"), header: "host_ts,mag_x,mag_y,mag_z")
        ]
    }

    private func closeWriters() {
        writers.values.forEach { $0.close() }
        writers.removeAll()
        try? eventsHandle?.close()
        eventsHandle = nil
    }

    private func append(_ file: String, _ line: String) {
        ioQueue.async { [self] in writers[file]?.append(line) }
    }

    private func write(_ data: Data, to relativePath: String) {
        guard let directory = captureDirectory else { return }
        let url = directory.appendingPathComponent(relativePath)
        do {
            try data.write(to: url, options: .atomic)
            live.withLock { $0.bytesWritten += Int64(data.count) }
        } catch {
            live.withLock { $0.lastError = error.localizedDescription }
            event("write failed \(relativePath): \(error.localizedDescription)")
        }
    }

    private func event(_ message: String) {
        let line = "t=" + String(format: "%.6f", ProcessInfo.processInfo.systemUptime) + " " + message + "\n"
        print("[RawCapture] \(message)")
        ioQueue.async { [self] in
            if let data = line.data(using: .utf8) { try? eventsHandle?.write(contentsOf: data) }
        }
    }

    private func writeManifest(stats: LiveStats) {
        guard let directory = captureDirectory else { return }
        var manifest: [String: Any] = [
            "format": "scan4d-raw-capture",
            "version": 1,
            "files": [
                "photos/photo_NNNNN.jpg|heic": "full-sensor processed still (container per setup.photoCodec); row in photos.csv",
                "photo_depth/photo_NNNNN.png": "16-bit mm depth delivered WITH that photo (absent when the pipeline attached none)",
                "depth/depth_NNNNNN.png": "16-bit mm streamed LiDAR depth, rate-capped subset; every frame is a row in depth_frames.csv",
                "photos.csv": "per still: host_ts, request time, latency, dims, exposure, iso, attached-depth dims, intrinsics, and what the blur gate saw at request (gyro rate, AE exposure, predicted smear px)",
                "depth_frames.csv": "per streamed depth frame: host_ts, dropped flags, synchronized video dims + intrinsics, saved file",
                "imu_devicemotion.csv": "CoreMotion fused attitude (quaternion), rotation rate, user acceleration, gravity; sensor max rate",
                "imu_gyro.csv": "raw gyroscope rad/s; sensor max rate (achieved rate in totals.gyro_hz)",
                "imu_accel.csv": "raw accelerometer g; sensor max rate (achieved rate in totals.accel_hz)",
                "imu_magnetometer.csv": "raw, uncalibrated magnetometer microtesla; sensor max rate",
                "events.log": "session lifecycle, interruptions, errors"
            ]
        ]
        if let setupData = try? JSONEncoder().encode(setup),
           let setupJSON = try? JSONSerialization.jsonObject(with: setupData) {
            manifest["setup"] = setupJSON
        }
        let totals: [String: Any] = [
            "photos_requested": stats.photosRequested, "photos_saved": stats.photosSaved,
            "photos_failed": stats.photosFailed, "photos_gated": stats.photosGated,
            "photos_with_depth": stats.photosWithDepth,
            "depth_frames_received": stats.depthFramesReceived, "depth_frames_dropped": stats.depthFramesDropped,
            "depth_frames_saved": stats.depthFramesSaved, "video_frames_dropped": stats.videoFramesDropped,
            "devicemotion_samples": stats.deviceMotion.count, "devicemotion_hz": stats.deviceMotion.hz,
            "gyro_samples": stats.gyro.count, "gyro_hz": stats.gyro.hz,
            "accel_samples": stats.accel.count, "accel_hz": stats.accel.hz,
            "magnetometer_samples": stats.magnetometer.count, "magnetometer_hz": stats.magnetometer.hz,
            "interruptions": stats.interruptions,
            "runtime_errors": stats.runtimeErrors, "elapsed_seconds": stats.elapsedSeconds
        ]
        manifest["totals"] = totals
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: directory.appendingPathComponent("manifest.json"))
        }
    }

    /// Zips the directory beside itself with the system's upload-zip, same as `ScanExportManager`.
    private static func zip(directory: URL) -> URL? {
        let fm = FileManager.default
        let zipURL = directory.deletingPathExtension().appendingPathExtension("zip")
        try? fm.removeItem(at: zipURL)
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &error) { tempURL in
            try? fm.copyItem(at: tempURL, to: zipURL)
        }
        if let error {
            print("[RawCapture] zip failed: \(error.localizedDescription)")
            return nil
        }
        return fm.fileExists(atPath: zipURL.path) ? zipURL : nil
    }

    // MARK: Helpers

    /// Capture timestamps live on the session's synchronization clock; CoreMotion is on the host
    /// clock. Convert explicitly so the two columns are comparable by subtraction.
    private func hostSeconds(_ time: CMTime) -> TimeInterval {
        let host = CMClockGetHostTimeClock()
        let converted = session.synchronizationClock.map { CMSyncConvertTime(time, from: $0, to: host) } ?? time
        return CMTimeGetSeconds(converted)
    }

    private static func intrinsics(of sampleBuffer: CMSampleBuffer) -> matrix_float3x3? {
        guard let attachment = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil),
              let data = attachment as? Data, data.count >= MemoryLayout<matrix_float3x3>.size else { return nil }
        return data.withUnsafeBytes { $0.loadUnaligned(as: matrix_float3x3.self) }
    }

    /// Float depth to UInt16 millimetres (0 = no data), on a copy. Disparity and Float16 inputs
    /// are converted by AVFoundation first.
    private static func millimetres(from depth: AVDepthData) -> (values: [UInt16], width: Int, height: Int)? {
        let converted = depth.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depth : depth.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let buffer = converted.depthDataMap
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let floatsPerRow = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float32>.stride
        var values = [UInt16](repeating: 0, count: width * height)
        let floats = base.assumingMemoryBound(to: Float32.self)
        for y in 0..<height {
            for x in 0..<width {
                let metres = floats[y * floatsPerRow + x]
                values[y * width + x] = metres.isFinite ? UInt16(min(max(metres * 1000, 0), 65535)) : 0
            }
        }
        return (values, width, height)
    }

    private static func openAppend(_ url: URL) -> FileHandle? {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }

    private static func hardwareModel() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? String(code)
    }

    private static func name(of prioritization: AVCapturePhotoOutput.QualityPrioritization) -> String {
        switch prioritization {
        case .speed: return "speed"
        case .balanced: return "balanced"
        case .quality: return "quality"
        @unknown default: return "unknown"
        }
    }

    /// Buffered line writer; flushes every few hundred lines and on close. ioQueue-only.
    private nonisolated final class CSVWriter {
        private let handle: FileHandle?
        private var pending = ""
        private var pendingLines = 0

        init(url: URL, header: String) {
            handle = RawCaptureSession.openAppend(url)
            pending = header + "\n"
            pendingLines = 1
        }

        func append(_ line: String) {
            pending += line + "\n"
            pendingLines += 1
            if pendingLines >= 256 { flush() }
        }

        func flush() {
            guard pendingLines > 0, let data = pending.data(using: .utf8) else { return }
            try? handle?.write(contentsOf: data)
            pending = ""
            pendingLines = 0
        }

        func close() {
            flush()
            try? handle?.close()
        }
    }
}

/// Global image shift between consecutive luma thumbnails by exhaustive block matching, for the
/// raw-capture spacing gate. Coarse on purpose: a `width`-pixel thumbnail resolves about 1.5% of
/// the frame, enough to notice a viewpoint change and nothing like enough to measure blur.
/// Thumbnails are mean-subtracted so an exposure step between frames does not read as motion.
nonisolated struct ImageShiftEstimator {
    static let width = 64
    static let height = 48
    static let search = 8
    /// The best match must beat the no-motion match by this factor, else the frame is called
    /// still: on a blank wall every shift scores alike and the minimum would be noise.
    static let decisiveness: Float = 0.8

    private var previous: [Float]?

    /// Shift of the scene in thumbnail pixels from the previous thumbnail to this one: content at
    /// (x, y) before is at (x + dx, y + dy) now. nil until two thumbnails exist; (0, 0) when the
    /// match is not decisive.
    mutating func update(_ thumbnail: [Float]) -> SIMD2<Float>? {
        defer { previous = thumbnail }
        guard let prev = previous, prev.count == thumbnail.count,
              thumbnail.count == Self.width * Self.height else { return nil }
        let w = Self.width, h = Self.height, r = Self.search
        var best = Float.infinity, bestDx = 0, bestDy = 0, zero: Float = 0
        prev.withUnsafeBufferPointer { p in
            thumbnail.withUnsafeBufferPointer { c in
                for dy in -r...r {
                    let y0 = max(0, -dy), y1 = min(h, h - dy)
                    for dx in -r...r {
                        let x0 = max(0, -dx), x1 = min(w, w - dx)
                        var sum: Float = 0
                        for y in y0..<y1 {
                            let rowPrev = y * w, rowCur = (y + dy) * w + dx
                            for x in x0..<x1 { sum += abs(p[rowPrev + x] - c[rowCur + x]) }
                        }
                        let sad = sum / Float((x1 - x0) * (y1 - y0))
                        if dx == 0 && dy == 0 { zero = sad }
                        if sad < best { best = sad; bestDx = dx; bestDy = dy }
                    }
                }
            }
        }
        if bestDx == 0 && bestDy == 0 { return SIMD2(0, 0) }
        return best < zero * Self.decisiveness ? SIMD2(Float(bestDx), Float(bestDy)) : SIMD2(0, 0)
    }

    /// Mean-subtracted luma thumbnail of a bi-planar 4:2:0 pixel buffer (plane 0), each sample the
    /// 4x4 average at the centre of its block. nil for a buffer too small to sample.
    static func lumaThumbnail(_ buffer: CVPixelBuffer) -> [Float]? {
        guard CVPixelBufferGetPlaneCount(buffer) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let sx = w / width, sy = h / height
        guard sx >= 4, sy >= 4, let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out = [Float](repeating: 0, count: width * height)
        var mean: Float = 0
        for ty in 0..<height {
            let cy = ty * sy + sy / 2 - 2
            for tx in 0..<width {
                let cx = tx * sx + sx / 2 - 2
                var acc = 0
                for j in 0..<4 {
                    let row = (cy + j) * rowBytes + cx
                    for i in 0..<4 { acc += Int(p[row + i]) }
                }
                let v = Float(acc) / 16
                out[ty * width + tx] = v
                mean += v
            }
        }
        mean /= Float(width * height)
        for i in out.indices { out[i] -= mean }
        return out
    }
}

// MARK: - AVCaptureDataOutputSynchronizerDelegate

extension RawCaptureSession: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        let depth = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData
        let video = synchronizedDataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData
        guard depth != nil else { return }   // video-only collections carry nothing we log
        handle(depth: depth, video: video)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension RawCaptureSession: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        dataQueue.async { [self] in
            let request = photoRequests.removeValue(forKey: photo.resolvedSettings.uniqueID)
            let requested = request?.hostTime ?? -1
            if let error {
                live.withLock { $0.photosFailed += 1; $0.lastError = error.localizedDescription }
                event("photo failed: \(error.localizedDescription)")
                return
            }
            guard let data = photo.fileDataRepresentation() else {
                live.withLock { $0.photosFailed += 1; $0.lastError = "no file representation" }
                event("photo had no file representation")
                return
            }
            let index = photoIndex
            photoIndex += 1
            let host = hostSeconds(photo.timestamp)
            let latency = requested >= 0 ? host - requested : -1
            let dims = photo.resolvedSettings.photoDimensions
            let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
            let exposure = exif?[kCGImagePropertyExifExposureTime as String] as? Double ?? 0
            let iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Int])?.first ?? 0
            let file = "photos/photo_" + String(format: "%05d", index) + (setup.photoCodec == "hevc" ? ".heic" : ".jpg")

            var depthFile = "", depthDims = ("", "")
            var depthCopy: (values: [UInt16], width: Int, height: Int)?
            if let attached = photo.depthData, let mm = Self.millimetres(from: attached) {
                depthCopy = mm
                depthFile = String(format: "photo_depth/photo_%05d.png", index)
                depthDims = (String(mm.width), String(mm.height))
            }
            var calibration = ["", "", "", "", "", ""]
            if let cal = photo.cameraCalibrationData ?? photo.depthData?.cameraCalibrationData {
                let k = cal.intrinsicMatrix
                let ref = cal.intrinsicMatrixReferenceDimensions
                calibration = [k[0][0], k[1][1], k[2][0], k[2][1]].map { String(format: "%.3f", $0) }
                    + [String(Int(ref.width)), String(Int(ref.height))]
                // Replace the field-of-view estimate the gate started with: fx at the calibration's
                // reference width, scaled to the photo's width. Same queue as the gate, no race.
                if ref.width > 0, k[0][0] > 0 {
                    photoFocalPx = Double(k[0][0]) * Double(dims.width) / Double(ref.width)
                }
            }
            let gate = [request?.omega ?? -1, request?.exposure ?? -1, request?.smearPx ?? -1]
                .map { String(format: "%.4f", $0) }
            let spacing = [request?.interval ?? -1, request?.rotationDeg ?? -1, request?.shiftFraction ?? -1, request?.flowSpeed ?? -1]
                .map { $0.isFinite ? String(format: "%.4f", $0) : "inf" } + [request?.reason ?? ""]
            let row = [String(index), file, String(format: "%.6f", host), String(format: "%.6f", requested),
                       String(format: "%.3f", latency), String(dims.width), String(dims.height),
                       String(format: "%.6f", exposure), String(iso), depthFile, depthDims.0, depthDims.1]
                + calibration + gate + spacing
            append("photos.csv", row.joined(separator: ","))

            ioQueue.async { [self] in
                write(data, to: file)
                if let depthCopy, let png = DepthPNG.encode(depthCopy.values, width: depthCopy.width, height: depthCopy.height) {
                    write(png, to: depthFile)
                }
            }
            live.withLock {
                $0.photosSaved += 1
                if depthCopy != nil { $0.photosWithDepth += 1 }
                $0.lastPhotoLatencySeconds = latency
                $0.lastPhotoDimensions = "\(dims.width)x\(dims.height)"
                $0.lastExposureSeconds = exposure
                $0.lastISO = iso
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        dataQueue.async { [self] in
            if let error, photoRequests.removeValue(forKey: resolvedSettings.uniqueID) != nil {
                // Failed before processing delivered anything; didFinishProcessingPhoto never ran.
                live.withLock { $0.photosFailed += 1; $0.lastError = error.localizedDescription }
                event("capture failed: \(error.localizedDescription)")
            }
            photoFinished()
        }
    }
}
