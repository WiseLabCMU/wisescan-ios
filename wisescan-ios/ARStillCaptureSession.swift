import ARKit
import AVFoundation
import CoreImage
import CoreMotion
import ImageIO
import Foundation
import Synchronization
import os
import simd

// swiftlint:disable file_length type_body_length function_body_length identifier_name

/// EXPERIMENT: the capture-only branch of the Rescan flow. AR Capture enters the ordinary rescan
/// (same gates, relocalization against the latest scan's world map, ghost, alignment, nudge);
/// at Start, instead of recording a scan, the AR view re-runs the session with LiDAR scene depth
/// and nothing else (no mesh, planes, RoomPlan, frame capture), applies the SAME record-start
/// bakes into the world origin (dev ICP correction, manual ghost nudge), removes the ghost, and
/// feeds every frame to this engine. Coordinate space is therefore the rescan's by construction:
/// the latest scan's raw frame, nudged exactly as a rescan would be. A copy of that scan's
/// `registration.json` (raw -> canonical, the original scan's frame) ships in the dump.
///
///   - **Stills** from `captureHighResolutionFrame`, one in flight, requested from a tracked frame
///     once the gates allow. Each comes back as its own ARFrame: pose, intrinsics, exposure, and
///     the depth + confidence of that instant. The image arrives unencoded and is encoded to JPEG
///     here, on a dedicated queue, with a bounded backlog.
///   - **Gates** (`ARStillCaptureGates`), per tracked frame: predicted smear from gyro rotation
///     AND sideways translation (ARKit velocity over the near scene depth); viewpoint spacing as
///     rotation or parallax since the previous still.
///   - **Exposure cap**: `arStillMaxExposureSeconds` on ARKit's own camera via
///     `configurableCaptureDeviceForPrimaryCamera`; auto exposure keeps metering and raises ISO.
///   - **Logs**: every stream frame's pose; stream depth + confidence at a capped rate; raw gyro
///     and accelerometer. One clock: `ARFrame.timestamp` and CoreMotion are seconds since boot.
///
/// Threading: `begin`/`stop`/`liveStats` from main. `offer` on the AR session's delegate queue
/// (one serial queue), where all gate state lives; it does nothing unless recording, and `begin`
/// resets that state before turning recording on. Still requests hop to main; completions land
/// on an undocumented queue and hop to `encodeQueue`. File writes go through `ioQueue`.
nonisolated final class ARStillCaptureSession: @unchecked Sendable {

    // MARK: Types

    nonisolated struct Setup: Codable, Equatable, Sendable {
        var deviceModel = ""
        var streamFormat = ""
        var frameSemantics = "sceneDepth"
        var worldMapScan = ""
        var worldMapScanId = ""
        var originalScanId = ""
        var registrationIncluded = false
        var manualNudgeBake: [Float]?
        var icpBake: [Float]?
        var exposureCapRequestedSeconds = 0.0
        var exposureCapAppliedSeconds = 0.0
        var exposureCapNote = ""
        /// What the primary camera's active format offers, and what ARKit's still settings ask for:
        /// the evidence for whether ARKit stills are capped below the sensor (48MP iPhones).
        var deviceSupportedPhotoDimensions = ""
        var arkitDefaultPhotoDimensions = ""
        /// ARKit reports each still with the VIDEO's intrinsics scaled to the still size, but the
        /// still has a narrower field of view: on an M1 iPad Pro a multi-view refit put its focal
        /// length at 1.0476x the reported value, matching the photo pipeline's own calibration.
        /// The likely cause is geometric distortion correction (a crop) on the photo path. These
        /// fields record the format's two fields of view so every dump carries the expected ratio;
        /// `photos.csv` keeps the reported intrinsics, which ARE right for the LiDAR maps.
        var videoFieldOfViewDeg = 0.0
        var distortionCorrectedFieldOfViewDeg = 0.0
        var geometricDistortionCorrectionEnabled = false
        /// tan(videoFOV/2) / tan(correctedFOV/2): the still focal over the reported focal, if the
        /// still is the distortion-corrected crop. 0 when either field of view is unavailable.
        var expectedStillFocalScale = 0.0
        var blurBudgetRad = 0.0
        var shortExposureISOCeiling = 0.0
        var shortExposureFloorSeconds = 0.0
        var viewpointThresholdDeg = 0.0
        var stillMinIntervalSeconds = 0.0
        var stillMaxIntervalSeconds = 0.0
        var gateDepthPercentile = 0.0
        var gateMinConfidence = 0
        var startWallTime = ""
        var startUptimeSeconds = 0.0
        var thermalStateAtStart = ""
        var clock = "ARFrame.timestamp and CoreMotion: seconds since boot (same clock)"
        var frame = "world = the latest scan's raw capture frame (its world map), with the rescan record-start bakes applied (icpBake, then manualNudgeBake, both column-major, as setWorldOrigin relative transforms). world_map_registration.json maps that raw frame to the original scan's canonical frame."
        var poseConvention = "c2w_* = ARKit camera-to-world, row-major 3x4; camera looks down -Z, +Y up in the image; world +Y up (gravity), metres. Images, depth and intrinsics are in the sensor's landscape orientation."
    }

    /// What the capture flow knows about the frame at Start.
    nonisolated struct FrameContext: Sendable {
        var worldMapScan = ""
        var worldMapScanId = ""
        var originalScanId = ""
        var registrationFile: URL?
        var manualNudgeBake: simd_float4x4?
    }

    nonisolated struct LiveStats: Equatable, Sendable {
        var tracking = "-"
        var recording = false
        var stillsRequested = 0
        var stillsSaved = 0
        var stillsFailed = 0
        var stillsWithDepth = 0
        var heldBlurFrames = 0
        var heldSpacingFrames = 0
        var heldBackpressureFrames = 0
        var pendingEncodes = 0
        var inFlight = false
        var lastStillDimensions = ""
        var lastLatencySeconds = 0.0
        var lastStillExposureSeconds = 0.0
        var lastStillISO = 0.0
        var lastReason = ""
        var streamDimensions = ""
        var streamExposureSeconds = 0.0
        var exposureCapAppliedSeconds = 0.0
        var exposureCapNote = ""
        var angularRate = 0.0
        var lateralSpeed = 0.0
        var gateDepth = 0.0
        var smearRotationPx = 0.0
        var smearTranslationPx = 0.0
        /// Predicted image-motion smear in still pixels, and the angular budget in the same pixels.
        var smearImageMotionPx = 0.0
        var blurBudgetPx = 0.0
        var shortExposure = false
        var stillsShortExposure = 0
        var sceneDepthPresent = false
        var depthDropouts = 0
        var framesWithoutDepth = 0
        var trackingChanges = 0
        var thermalState = ""
        var rotationSinceStillDeg = 0.0
        var parallaxSinceStillDeg = 0.0
        var framesLogged = 0
        var gyroSamples = 0
        var accelSamples = 0
        var bytesWritten: Int64 = 0
        var elapsedSeconds = 0.0
        var lastError = ""
    }

    // MARK: State

    private weak var session: ARSession?
    private let encodeQueue = DispatchQueue(label: "org.arenaxr.scan4d.arstill.encode", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "org.arenaxr.scan4d.arstill.io", qos: .utility)
    private let motionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        queue.name = "org.arenaxr.scan4d.arstill.motion"
        return queue
    }()
    private let motion = CMMotionManager()
    private let ciContext = CIContext()

    private let recording = Atomic<Bool>(false)
    private let live = OSAllocatedUnfairLock(initialState: LiveStats())
    private let gyroRate = OSAllocatedUnfairLock(initialState: 0.0)
    /// In-flight still and queued encodes, shared by the frame path and the completion path.
    private let pipeline = OSAllocatedUnfairLock(initialState: (inFlight: false, pending: 0))
    /// Still width / stream width, learned from the first still (completion queue) and read per
    /// frame (delegate queue).
    private let stillScale = OSAllocatedUnfairLock(initialState: 4032.0 / 1920.0)
    /// The dev ICP correction, when the AR view baked one at Start (any queue).
    private let icpBakeNoted = OSAllocatedUnfairLock<[Float]?>(initialState: nil)
    /// Short-exposure experiment: set from main by the toggle, read per frame on the delegate queue.
    private let shortExposure = Atomic<Bool>(false)
    /// Raised when the toggle flips so the next tracked frame re-applies the cap.
    private let exposureModeChanged = Atomic<Bool>(false)

    private(set) var setup = Setup()
    private(set) var captureDirectory: URL?
    private var startUptime: TimeInterval = 0
    private var stopUptime: TimeInterval = 0

    // Delegate-queue-owned (reset by `begin` while not recording).
    private var poseHistory: [(t: TimeInterval, m: simd_float4x4)] = []
    private var lastStillTransform: simd_float4x4?
    private var lastStillTime: TimeInterval = -1
    private var frameIndex = 0
    private var exposureCapApplied = false
    private var lastExposureUpdate: TimeInterval = -1
    // Session health: tracking and depth transitions for the events log, the depth watchdog, and
    // the last good near depth the gates hold through a short dropout.
    private var lastTrackingLabel = ""
    private var hadDepth: Bool?
    private var everHadDepth = false
    private var firstHealthFrame: TimeInterval = -1
    private var lastDepthRequest: TimeInterval = -1
    private var lastGoodDepth = 0.0
    private var lastGoodDepthTime: TimeInterval = -1
    /// Set once "depth requested but not delivered" has been logged for the current dropout.
    private let depthNotDeliveredLogged = Atomic<Bool>(false)
    private var thermalObserver: NSObjectProtocol?

    // encodeQueue-owned
    private var photoIndex = 0

    // ioQueue-owned
    private var writers: [String: ARStillCSVWriter] = [:]
    private var eventsHandle: FileHandle?

    // MARK: Lifecycle (main)

    /// Opens the dump and starts accepting frames. Call after the AR view has re-run the session
    /// for capture and applied the bakes (it does both on the same Start transition).
    func begin(session: ARSession, label: String, context: FrameContext) throws {
        precondition(!recording.load(ordering: .acquiring), "begin while recording")
        self.session = session
        let directory = try makeDirectory(label: label)
        captureDirectory = directory
        startUptime = ProcessInfo.processInfo.systemUptime
        stopUptime = 0

        var s = Setup()
        s.deviceModel = Self.hardwareModel()
        s.startWallTime = ISO8601DateFormatter().string(from: Date())
        s.startUptimeSeconds = startUptime
        s.worldMapScan = context.worldMapScan
        s.worldMapScanId = context.worldMapScanId
        s.originalScanId = context.originalScanId
        s.manualNudgeBake = context.manualNudgeBake.map(Self.columnMajor)
        s.blurBudgetRad = AppConstants.arStillBlurBudgetRad
        s.shortExposureISOCeiling = AppConstants.arStillShortExposureISOCeiling
        s.shortExposureFloorSeconds = AppConstants.arStillShortExposureFloorSeconds
        s.viewpointThresholdDeg = AppConstants.arStillViewpointThresholdDeg
        s.stillMinIntervalSeconds = AppConstants.arStillMinIntervalSeconds
        s.stillMaxIntervalSeconds = AppConstants.arStillMaxIntervalSeconds
        s.gateDepthPercentile = AppConstants.arStillGateDepthPercentile
        s.gateMinConfidence = Int(AppConstants.arStillGateMinConfidence)
        if let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera {
            s.deviceSupportedPhotoDimensions = device.activeFormat.supportedMaxPhotoDimensions
                .map { "\($0.width)x\($0.height)" }.joined(separator: " ")
            let video = Double(device.activeFormat.videoFieldOfView)
            let corrected = Double(device.activeFormat.geometricDistortionCorrectedVideoFieldOfView)
            s.videoFieldOfViewDeg = video
            s.distortionCorrectedFieldOfViewDeg = corrected
            s.geometricDistortionCorrectionEnabled = device.isGeometricDistortionCorrectionEnabled
            if video > 0, corrected > 0 {
                s.expectedStillFocalScale = tan(video / 2 * .pi / 180) / tan(corrected / 2 * .pi / 180)
            }
        }
        if let format = session.configuration?.videoFormat {
            s.streamFormat = "\(Int(format.imageResolution.width))x\(Int(format.imageResolution.height))@\(format.framesPerSecond)"
            if #available(iOS 26.0, *) {
                let dims = format.defaultPhotoSettings.maxPhotoDimensions
                s.arkitDefaultPhotoDimensions = "\(dims.width)x\(dims.height)"
            }
        }
        if let registration = context.registrationFile,
           (try? FileManager.default.copyItem(at: registration, to: directory.appendingPathComponent("world_map_registration.json"))) != nil {
            s.registrationIncluded = true
        }
        setup = s

        // Gate state. `offer` returns at once while recording is off, so nothing races this.
        poseHistory.removeAll()
        lastStillTransform = nil
        lastStillTime = -1
        frameIndex = 0
        exposureCapApplied = false
        lastTrackingLabel = ""
        hadDepth = nil
        everHadDepth = false
        firstHealthFrame = -1
        lastDepthRequest = -1
        lastGoodDepth = 0
        lastGoodDepthTime = -1
        depthNotDeliveredLogged.store(false, ordering: .releasing)
        encodeQueue.sync { photoIndex = 0 }
        pipeline.withLock { $0 = (false, 0) }
        icpBakeNoted.withLock { $0 = nil }
        let shortOn = shortExposure.load(ordering: .acquiring)
        let thermal = Self.thermalName(ProcessInfo.processInfo.thermalState)
        setup.thermalStateAtStart = thermal
        live.withLock { $0 = LiveStats(); $0.shortExposure = shortOn; $0.thermalState = thermal }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            let state = Self.thermalName(ProcessInfo.processInfo.thermalState)
            self?.live.withLock { $0.thermalState = state }
            self?.event("thermal state -> \(state)")
        }
        ioQueue.sync { openWriters(in: directory) }
        startMotion()
        live.withLock { $0.recording = true }
        event("capture opened stream=\(s.streamFormat) map=\(s.worldMapScan.isEmpty ? "none" : s.worldMapScan); waiting for the frame bakes")
    }

    /// Starts accepting frames. Called by the AR view right after it re-ran the session for capture
    /// and applied the record-start bakes, so no still can carry a pre-bake pose.
    func startAccepting() {
        guard captureDirectory != nil, live.withLock({ $0.recording }) else { return }
        recording.store(true, ordering: .releasing)
        event("accepting frames (bakes applied)")
    }

    /// Short-exposure experiment on or off (any time; it takes effect on the next tracked frame
    /// while capturing, and is recorded per still).
    func setShortExposure(_ on: Bool) {
        shortExposure.store(on, ordering: .releasing)
        exposureModeChanged.store(true, ordering: .releasing)
        live.withLock { $0.shortExposure = on }
    }

    /// The AR view applied the dev ICP correction at Start (before any manual nudge).
    func noteICPBake(_ bake: simd_float4x4) {
        let values = Self.columnMajor(bake)
        icpBakeNoted.withLock { $0 = values }
    }

    /// Stops accepting frames, waits for the in-flight still and queued encodes, writes the
    /// manifest, zips. Completion on main with the zip, or nil (directory kept) when zipping failed.
    func stop(completion: @escaping @Sendable (URL?) -> Void) {
        recording.store(false, ordering: .releasing)
        stopUptime = ProcessInfo.processInfo.systemUptime
        live.withLock { $0.recording = false }
        motion.stopGyroUpdates()
        motion.stopAccelerometerUpdates()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        // Hand the camera back with auto exposure's own limit (an invalid time restores the
        // default), so neither the 1/120 cap nor a short-exposure cap leaks into later scans.
        if let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
           (try? device.lockForConfiguration()) != nil {
            device.activeMaxExposureDuration = .invalid
            device.unlockForConfiguration()
        }
        event("capture stopped")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            // A requested still can complete after Stop; give it a bounded moment, then drain.
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let state = pipeline.withLock { $0 }
                if !state.inFlight && state.pending == 0 { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
            encodeQueue.sync {}
            let stats = liveStats()
            ioQueue.sync {
                writeManifest(stats: stats)
                closeWriters()
            }
            guard let directory = captureDirectory else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let zip = Self.zip(directory: directory)
            if zip != nil { try? FileManager.default.removeItem(at: directory) }
            DispatchQueue.main.async { completion(zip) }
        }
    }

    func liveStats() -> LiveStats {
        var stats = live.withLock { $0 }
        let state = pipeline.withLock { $0 }
        stats.inFlight = state.inFlight
        stats.pendingEncodes = state.pending
        if startUptime > 0 {
            let end = stats.recording || stopUptime <= startUptime ? ProcessInfo.processInfo.systemUptime : stopUptime
            stats.elapsedSeconds = end - startUptime
        }
        return stats
    }

    // MARK: Frames (AR delegate queue)

    /// One ARKit frame from the capture view's session delegate. Cheap and non-blocking; must not
    /// retain the frame (pool buffers).
    func offer(_ frame: ARFrame) {
        guard recording.load(ordering: .acquiring) else { return }
        let camera = frame.camera
        let t = frame.timestamp
        let transform = camera.transform
        let (trackingLabel, isNormal) = Self.describe(camera.trackingState)
        noteSessionHealth(hasDepth: frame.sceneDepth != nil, t: t, trackingLabel: trackingLabel)
        if isNormal { manageExposure(at: t) }

        // Motion from the pose over a short window (ARKit pose jitter dominates shorter ones).
        poseHistory.append((t, transform))
        while let first = poseHistory.first, t - first.t > AppConstants.arStillVelocityWindowSeconds * 2 { poseHistory.removeFirst() }
        let past = poseHistory.last(where: { t - $0.t >= AppConstants.arStillVelocityWindowSeconds })
        var velocity = SIMD3<Float>(0, 0, 0)
        if let past, t > past.t {
            velocity = (ARStillCaptureGates.position(transform) - ARStillCaptureGates.position(past.m)) / Float(t - past.t)
        }

        // Near-scene depth from a sparse sample of the LiDAR map (~800 reads). Through a short
        // dropout the last good value is held, so the gates keep their sidestep and parallax terms
        // instead of falling back to rotation only.
        var nearDepth = frame.sceneDepth.flatMap { Self.sampleDepth($0) } ?? 0
        var held = false
        if nearDepth > 0 {
            lastGoodDepth = nearDepth
            lastGoodDepthTime = t
        } else if lastGoodDepthTime >= 0, t - lastGoodDepthTime <= AppConstants.arStillDepthHoldSeconds {
            nearDepth = lastGoodDepth
            held = true
        }
        let gateDepth = nearDepth
        let depthHeld = held
        let exposure = camera.exposureDuration
        let omega = gyroRate.withLock { $0 }
        let lateral = ARStillCaptureGates.lateralSpeed(velocity: velocity, cameraToWorld: transform)
        let scale = stillScale.withLock { $0 }
        let fStream = Double(camera.intrinsics[0][0])
        let focalStill = fStream * scale
        // Reported for context (the old sum gate); the gate itself is the image-motion smear below.
        let smear = ARStillCaptureGates.smear(angularRate: omega, lateralSpeed: lateral, depth: gateDepth,
                                              exposure: exposure, focalPx: focalStill)
        // The blur gate: rigid camera motion from two poses, as image motion at the centre and
        // corners at the near depth. Pose only. Until a window of poses exists, fall back to the
        // gyro's rotation-only prediction.
        // Computed as an ANGLE (focal 1: normalized image plane), so the budget means the same real
        // sharpness at any still resolution; the pixel figure is for the panel and the log.
        // Sideways motion is in it: a sidestep at v m/s, Z m from the scene, sweeps v/Z rad/s.
        let angularSmear: Double
        if let past, t > past.t, gateDepth > 0, fStream > 0 {
            angularSmear = ARStillCaptureGates.imageMotionSmear(
                from: past.m, to: transform, dt: t - past.t, depth: gateDepth, exposure: exposure,
                focalPx: 1,
                halfWidthNorm: Double(camera.imageResolution.width) / 2 / fStream,
                halfHeightNorm: Double(camera.imageResolution.height) / 2 / Double(camera.intrinsics[1][1]))
        } else {
            angularSmear = omega * exposure
        }
        let imageSmear = angularSmear * focalStill
        let budgetPx = AppConstants.arStillBlurBudgetRad * focalStill
        let view = lastStillTransform.map {
            ARStillCaptureGates.viewpointChange(from: $0, to: transform, depth: gateDepth)
        } ?? (rotationDeg: 0.0, parallaxDeg: 0.0)
        let streamDims = "\(Int(camera.imageResolution.width))x\(Int(camera.imageResolution.height))"
        live.withLock {
            $0.tracking = trackingLabel
            $0.streamDimensions = streamDims
            $0.streamExposureSeconds = exposure
            $0.angularRate = omega
            $0.lateralSpeed = lateral
            $0.gateDepth = gateDepth
            $0.smearRotationPx = smear.rotationPx
            $0.smearTranslationPx = smear.translationPx
            $0.smearImageMotionPx = imageSmear
            $0.blurBudgetPx = budgetPx
            $0.rotationSinceStillDeg = view.rotationDeg
            $0.parallaxSinceStillDeg = view.parallaxDeg
        }

        logFrame(frame, trackingLabel: trackingLabel)
        guard isNormal else { return }

        // Gates: backpressure, blur, then spacing.
        let state = pipeline.withLock { $0 }
        if state.inFlight { return }
        if state.pending >= AppConstants.arStillMaxPendingEncodes {
            live.withLock { $0.heldBackpressureFrames += 1 }
            return
        }
        if exposure > 0, angularSmear > AppConstants.arStillBlurBudgetRad {
            live.withLock { $0.heldBlurFrames += 1 }
            return
        }
        let sinceLast = lastStillTime < 0 ? Double.infinity : t - lastStillTime
        guard let reason = ARStillCaptureGates.spacingDecision(
            sinceLast: sinceLast, rotationDeg: view.rotationDeg, parallaxDeg: view.parallaxDeg,
            minInterval: AppConstants.arStillMinIntervalSeconds,
            viewpointThresholdDeg: AppConstants.arStillViewpointThresholdDeg,
            maxInterval: AppConstants.arStillMaxIntervalSeconds
        ) else {
            live.withLock { $0.heldSpacingFrames += 1 }
            return
        }
        // The pose of the frame that passed the gates anchors the spacing for the next still.
        lastStillTransform = transform
        lastStillTime = t
        let request = StillRequest(hostTime: ProcessInfo.processInfo.systemUptime, reason: reason,
                                   angularRate: omega, lateralSpeed: lateral, gateDepth: gateDepth,
                                   streamExposure: exposure, smear: smear, imageSmear: imageSmear, sinceLast: sinceLast,
                                   rotationDeg: view.rotationDeg, parallaxDeg: view.parallaxDeg,
                                   angularSmear: angularSmear, shortExposure: shortExposure.load(ordering: .acquiring),
                                   exposureCap: live.withLock { $0.exposureCapAppliedSeconds },
                                   depthHeld: depthHeld,
                                   thermalState: Self.thermalName(ProcessInfo.processInfo.thermalState))
        requestStill(request)
    }

    // MARK: Stills

    private struct StillRequest {
        var hostTime: TimeInterval
        var reason: String
        var angularRate: Double
        var lateralSpeed: Double
        var gateDepth: Double
        var streamExposure: Double
        var smear: ARStillCaptureGates.Smear
        var imageSmear: Double
        var sinceLast: Double
        var rotationDeg: Double
        var parallaxDeg: Double
        var angularSmear: Double
        var shortExposure: Bool
        var exposureCap: Double
        var depthHeld: Bool
        var thermalState: String
    }

    private func requestStill(_ request: StillRequest) {
        pipeline.withLock { $0.inFlight = true }
        let reason = request.reason
        live.withLock { $0.stillsRequested += 1; $0.lastReason = reason }
        DispatchQueue.main.async { [self] in
            guard let session, recording.load(ordering: .acquiring) else {
                pipeline.withLock { $0.inFlight = false }
                return
            }
            session.captureHighResolutionFrame { [self] frame, error in
                handleStill(frame, error: error, request: request)
            }
        }
    }

    /// Completion of `captureHighResolutionFrame`, on an undocumented queue. Copies what it needs
    /// out of the ARFrame (depth and confidence are live-pool buffers; the still image is not) and
    /// hands the encode to `encodeQueue`.
    private func handleStill(_ frame: ARFrame?, error: Error?, request: StillRequest) {
        guard let frame, error == nil else {
            pipeline.withLock { $0.inFlight = false }
            let message = error?.localizedDescription ?? "nil frame"
            live.withLock { $0.stillsFailed += 1; $0.lastError = message }
            event("still failed: \(message)")
            return
        }
        let image = frame.capturedImage
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        let camera = frame.camera
        let transform = camera.transform
        let k = camera.intrinsics
        let exposure = camera.exposureDuration
        let t = frame.timestamp
        let depth = frame.sceneDepth.flatMap { Self.copyDepth($0) }
        let latency = ProcessInfo.processInfo.systemUptime - request.hostTime
        let (trackingLabel, _) = Self.describe(camera.trackingState)
        let iso = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera.map { Double($0.iso) } ?? -1
        // Learn the still-to-stream ratio for the smear prediction (stream width from the live
        // stats; `camera` here is the still's own).
        let streamDims = live.withLock { $0.streamDimensions }
        let streamWidth = streamDims.split(separator: "x").first.flatMap { Double(String($0)) } ?? 0
        if streamWidth > 0 { stillScale.withLock { $0 = Double(width) / streamWidth } }
        pipeline.withLock { $0.inFlight = false; $0.pending += 1 }
        encodeQueue.async { [self] in
            defer { pipeline.withLock { $0.pending -= 1 } }
            let index = photoIndex
            photoIndex += 1
            let stem = String(format: "photo_%05d", index)
            guard let jpeg = encodeJPEG(image, exposure: exposure, iso: iso) else {
                live.withLock { $0.stillsFailed += 1; $0.lastError = "jpeg encode failed" }
                event("jpeg encode failed \(stem)")
                return
            }
            let depthPNG = depth.flatMap { DepthPNG.encode($0.millimetres, width: $0.width, height: $0.height) }
            let confPNG = depth.flatMap { Self.encodeGray8($0.confidence, width: $0.width, height: $0.height) }
            let depthFile = depthPNG != nil ? "photo_depth/\(stem).png" : ""
            let confFile = confPNG != nil ? "photo_confidence/\(stem).png" : ""
            let depthW = depthPNG != nil ? String(depth?.width ?? 0) : ""
            let depthH = depthPNG != nil ? String(depth?.height ?? 0) : ""
            // Built in pieces: one long mixed concatenation is a type-checker time sink.
            var row: [String] = [String(index), "photos/\(stem).jpg", Fmt.f6(t), Fmt.f6(request.hostTime), Fmt.f3(latency)]
            row += [String(width), String(height), Fmt.f6(exposure), Fmt.f0(iso), trackingLabel]
            row += [depthFile, confFile, depthW, depthH]
            row += [Fmt.f3(Double(k[0][0])), Fmt.f3(Double(k[1][1])), Fmt.f3(Double(k[2][0])), Fmt.f3(Double(k[2][1]))]
            row += Self.rowMajor3x4(transform)
            row += [Fmt.f4(request.angularRate), Fmt.f4(request.lateralSpeed), Fmt.f4(request.gateDepth), Fmt.f6(request.streamExposure)]
            row += [Fmt.f3(request.smear.rotationPx), Fmt.f3(request.smear.translationPx)]
            row += [request.sinceLast.isFinite ? Fmt.f3(request.sinceLast) : "inf"]
            row += [Fmt.f3(request.rotationDeg), Fmt.f3(request.parallaxDeg), request.reason, Fmt.f3(request.imageSmear)]
            row += [Fmt.f6(request.angularSmear), request.shortExposure ? "1" : "0", Fmt.f6(request.exposureCap)]
            row += [request.depthHeld ? "1" : "0", request.thermalState]
            let line = row.joined(separator: ",")
            ioQueue.async { [self] in
                write(jpeg, to: "photos/\(stem).jpg")
                if let depthPNG { write(depthPNG, to: depthFile) }
                if let confPNG { write(confPNG, to: confFile) }
                writers["photos.csv"]?.append(line)
            }
            let hasDepth = depth != nil
            let wasShort = request.shortExposure
            live.withLock {
                $0.stillsSaved += 1
                if wasShort { $0.stillsShortExposure += 1 }
                if hasDepth { $0.stillsWithDepth += 1 }
                $0.lastStillDimensions = "\(width)x\(height)"
                $0.lastLatencySeconds = latency
                $0.lastStillExposureSeconds = exposure
                $0.lastStillISO = iso
            }
        }
    }

    /// JPEG with the still's exposure time and ISO in its EXIF, so photo tools and pipelines see
    /// them without photos.csv (ARKit hands the image over bare; CIContext's own JPEG path writes
    /// almost no EXIF).
    private func encodeJPEG(_ buffer: CVPixelBuffer, exposure: Double, iso: Double) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let cgImage = ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        var exif: [CFString: Any] = [:]
        if exposure > 0 { exif[kCGImagePropertyExifExposureTime] = exposure }
        if iso > 0 { exif[kCGImagePropertyExifISOSpeedRatings] = [Int(iso.rounded())] }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: AppConstants.arStillJPEGQuality,
            kCGImagePropertyExifDictionary: exif
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: Session health (delegate queue)

    /// Logs tracking and depth transitions, and keeps scene depth on. The first iPhone capture lost
    /// depth for good 107 s in: something re-ran the session (tracking went normal -> initializing
    /// -> relocalizing) with a configuration that did not request scene depth, and nothing logged
    /// it. Map reloads are now blocked during a capture; this is the safety net for any other
    /// re-run, and the record that says which case a dropout was.
    private func noteSessionHealth(hasDepth: Bool, t: TimeInterval, trackingLabel: String) {
        if trackingLabel != lastTrackingLabel {
            if !lastTrackingLabel.isEmpty {
                event("tracking \(lastTrackingLabel) -> \(trackingLabel)")
                live.withLock { $0.trackingChanges += 1 }
            }
            lastTrackingLabel = trackingLabel
        }
        if firstHealthFrame < 0 { firstHealthFrame = t }
        if hasDepth != hadDepth {
            let wasPresent = hadDepth == true
            // The first frames after the Start re-run can lack depth before ARKit delivers it:
            // only a loss after depth was seen counts (and a recovery only after a logged loss).
            if wasPresent && !hasDepth { event("scene depth LOST") }
            if hasDepth && everHadDepth { event("scene depth restored") }
            if hasDepth { everHadDepth = true; depthNotDeliveredLogged.store(false, ordering: .releasing) }
            hadDepth = hasDepth
            live.withLock {
                $0.sceneDepthPresent = hasDepth
                if wasPresent && !hasDepth { $0.depthDropouts += 1 }
            }
        }
        guard !hasDepth, everHadDepth || t - firstHealthFrame > 5 else { return }
        live.withLock { $0.framesWithoutDepth += 1 }
        if lastDepthRequest < 0 || t - lastDepthRequest >= AppConstants.arStillDepthRequestCooldownSeconds {
            lastDepthRequest = t
            requestSceneDepth()
        }
    }

    /// Re-requests scene depth on the LIVE configuration, with no run options: tracking, the
    /// loaded world map and the session's frame are kept (the app's proven live-config pattern).
    /// If the configuration still asks for depth, ARKit itself stopped delivering it; that is
    /// logged once per dropout with the thermal state, the likeliest cause.
    private func requestSceneDepth() {
        DispatchQueue.main.async { [self] in
            guard recording.load(ordering: .acquiring), let session,
                  ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
                  let config = session.configuration as? ARWorldTrackingConfiguration else { return }
            if config.frameSemantics.contains(.sceneDepth) {
                if !depthNotDeliveredLogged.exchange(true, ordering: .acquiringAndReleasing) {
                    event("scene depth requested by the configuration but not delivered (thermal \(Self.thermalName(ProcessInfo.processInfo.thermalState)))")
                }
                return
            }
            config.frameSemantics.insert(.sceneDepth)
            session.run(config)
            event("scene depth missing from the live configuration (the session was re-run elsewhere); re-requested without a tracking reset")
        }
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // MARK: Exposure

    /// Caps auto exposure on ARKit's camera. Applied on the first normally tracked frame after
    /// `begin` (the Start re-run can reconfigure the device). Results go through `live` (locked),
    /// not `setup`: this runs on the delegate queue; the manifest merges them at Stop.
    private func applyExposureCap() {
        exposureCapApplied = true
        let requested = AppConstants.arStillMaxExposureSeconds
        guard requested > 0 else { reportCap(0, "cap disabled"); return }
        setMaxExposure(requested, why: "fixed cap")
    }

    /// Per tracked frame (delegate queue). The fixed cap goes on once after `begin` and again
    /// whenever the experiment toggle flips; with the experiment on, the cap follows the light
    /// (`ARStillCaptureGates.shortExposureCap`), re-evaluated every few frames.
    private func manageExposure(at t: TimeInterval) {
        let toggled = exposureModeChanged.exchange(false, ordering: .acquiringAndReleasing)
        let short = shortExposure.load(ordering: .acquiring)
        if !exposureCapApplied || toggled {
            applyExposureCap()
            lastExposureUpdate = t
            if toggled { event("short-exposure experiment \(short ? "ON" : "OFF")") }
            return
        }
        guard short, AppConstants.arStillMaxExposureSeconds > 0,
              t - lastExposureUpdate >= AppConstants.arStillShortExposureUpdateSeconds,
              let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
        lastExposureUpdate = t
        let exposure = CMTimeGetSeconds(device.exposureDuration)
        let iso = Double(device.iso)
        let offset = Double(device.exposureTargetOffset)
        let ceiling = min(AppConstants.arStillShortExposureISOCeiling, Double(device.activeFormat.maxISO))
        let floor = max(AppConstants.arStillShortExposureFloorSeconds, CMTimeGetSeconds(device.activeFormat.minExposureDuration))
        let target = ARStillCaptureGates.shortExposureCap(
            exposure: exposure, iso: iso, targetOffsetEV: offset, isoCeiling: ceiling,
            floor: floor, cap: AppConstants.arStillMaxExposureSeconds)
        let current = live.withLock { $0.exposureCapAppliedSeconds }
        guard current <= 0 || abs(target - current) / current > 0.1 else { return }
        setMaxExposure(target, why: String(format: "short-exposure: light %.4f (%.6f s x ISO %.0f, AE offset %+.2f EV), ISO ceiling %.0f", exposure * iso, exposure, iso, offset, ceiling))
    }

    /// Sets the longest exposure auto exposure may use on ARKit's camera, clamped to the format.
    private func setMaxExposure(_ seconds: Double, why: String) {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else {
            reportCap(0, "no configurable capture device")
            return
        }
        do {
            try device.lockForConfiguration()
            let format = device.activeFormat
            let wanted = CMTime(seconds: seconds, preferredTimescale: 1_000_000)
            let range = CMTimeRange(start: format.minExposureDuration, end: format.maxExposureDuration)
            let clamped = CMTimeClampToRange(wanted, range: range)
            device.activeMaxExposureDuration = clamped
            let mode = device.exposureMode.rawValue
            device.unlockForConfiguration()
            let applied = CMTimeGetSeconds(clamped)
            let shutter = String(format: "%.0f", 1 / applied)
            reportCap(applied, "activeMaxExposureDuration 1/\(shutter) s (\(why); exposure mode \(mode))")
        } catch {
            reportCap(0, "lockForConfiguration failed: \(error.localizedDescription)")
        }
    }

    private func reportCap(_ applied: Double, _ note: String) {
        live.withLock { $0.exposureCapAppliedSeconds = applied; $0.exposureCapNote = note }
        event("exposure cap: \(note)")
    }

    // MARK: Stream logging (delegate queue)

    /// Text-only pose log of the tracking stream (the trajectory between stills). No stream
    /// images or stream depth are saved: the only images are the full-resolution stills.
    private func logFrame(_ frame: ARFrame, trackingLabel: String) {
        let index = frameIndex
        frameIndex += 1
        let camera = frame.camera
        let k = camera.intrinsics
        var row: [String] = [String(index), Fmt.f6(frame.timestamp), trackingLabel, Fmt.f6(camera.exposureDuration)]
        row += [String(Int(camera.imageResolution.width)), String(Int(camera.imageResolution.height))]
        row += [Fmt.f3(Double(k[0][0])), Fmt.f3(Double(k[1][1])), Fmt.f3(Double(k[2][0])), Fmt.f3(Double(k[2][1]))]
        row += Self.rowMajor3x4(camera.transform)
        append("frames.csv", row.joined(separator: ","))
        live.withLock { $0.framesLogged += 1 }
    }

    // MARK: IMU

    private func startMotion() {
        let interval = AppConstants.arStillIMUUpdateInterval
        if motion.isGyroAvailable {
            motion.gyroUpdateInterval = interval
            motion.startGyroUpdates(to: motionQueue) { [weak self] data, _ in
                guard let self, let d = data else { return }
                let r = d.rotationRate
                let rate = sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
                gyroRate.withLock { $0 = rate }
                append("imu_gyro.csv", [d.timestamp, r.x, r.y, r.z].map { String(format: "%.6f", $0) }.joined(separator: ","))
                live.withLock { $0.gyroSamples += 1 }
            }
        }
        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = interval
            motion.startAccelerometerUpdates(to: motionQueue) { [weak self] data, _ in
                guard let self, let d = data else { return }
                let a = d.acceleration
                append("imu_accel.csv", [d.timestamp, a.x, a.y, a.z].map { String(format: "%.6f", $0) }.joined(separator: ","))
                live.withLock { $0.accelSamples += 1 }
            }
        }
    }

    // MARK: Files

    private func makeDirectory(label: String) throws -> URL {
        let fm = FileManager.default
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let safe = label.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression)
        let directory = documents.appendingPathComponent(AppConstants.arStillFolder)
            .appendingPathComponent("ar_capture_\(safe)_\(formatter.string(from: Date()))")
        for sub in ["photos", "photo_depth", "photo_confidence"] {
            try fm.createDirectory(at: directory.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return directory
    }

    private func openWriters(in directory: URL) {
        eventsHandle = ARStillCSVWriter.openAppend(directory.appendingPathComponent("events.log"))
        let pose = "c2w_00,c2w_01,c2w_02,c2w_03,c2w_10,c2w_11,c2w_12,c2w_13,c2w_20,c2w_21,c2w_22,c2w_23"
        let photosHeader = "index,file,host_ts,request_host_ts,latency_s,width,height,exposure_s,iso,tracking,depth_file,confidence_file,depth_width,depth_height,fx,fy,cx,cy,"
            + pose
            + ",request_gyro_rad_s,request_lateral_speed_m_s,request_gate_depth_m,request_stream_exposure_s,predicted_rotation_smear_px,predicted_translation_smear_px,interval_since_prev_s,rotation_since_prev_deg,parallax_since_prev_deg,reason,predicted_image_motion_smear_px,predicted_image_motion_smear_rad,short_exposure,exposure_cap_s,gate_depth_held,thermal_state"
        writers = [
            "photos.csv": ARStillCSVWriter(url: directory.appendingPathComponent("photos.csv"), header: photosHeader),
            "frames.csv": ARStillCSVWriter(url: directory.appendingPathComponent("frames.csv"),
                                           header: "index,host_ts,tracking,exposure_s,width,height,fx,fy,cx,cy," + pose),
            "imu_gyro.csv": ARStillCSVWriter(url: directory.appendingPathComponent("imu_gyro.csv"), header: "host_ts,rot_x,rot_y,rot_z"),
            "imu_accel.csv": ARStillCSVWriter(url: directory.appendingPathComponent("imu_accel.csv"), header: "host_ts,acc_x,acc_y,acc_z")
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
        do {
            try data.write(to: directory.appendingPathComponent(relativePath), options: .atomic)
            let count = Int64(data.count)
            live.withLock { $0.bytesWritten += count }
        } catch {
            let message = error.localizedDescription
            live.withLock { $0.lastError = message }
            event("write failed \(relativePath): \(message)")
        }
    }

    private func event(_ message: String) {
        let line = "t=" + String(format: "%.6f", ProcessInfo.processInfo.systemUptime) + " " + message + "\n"
        print("[ARStill] \(message)")
        ioQueue.async { [self] in
            if let data = line.data(using: .utf8) { try? eventsHandle?.write(contentsOf: data) }
        }
    }

    private func writeManifest(stats: LiveStats) {
        guard let directory = captureDirectory else { return }
        var manifest: [String: Any] = [
            "format": "scan4d-ar-still-capture",
            "version": 1,
            "files": [
                "photos/photo_NNNNN.jpg": "high-resolution ARKit still, sensor orientation; row in photos.csv (pose, intrinsics, exposure, gate inputs)",
                "photo_depth/photo_NNNNN.png": "16-bit mm LiDAR depth of the same ARFrame (sceneDepth, unsmoothed)",
                "photo_confidence/photo_NNNNN.png": "8-bit ARKit depth confidence of the same ARFrame: 0 low, 1 medium, 2 high",
                "frames.csv": "pose log of every tracking-stream frame while capturing (text only: host_ts, tracking, exposure, intrinsics, pose); no stream images are saved",
                "imu_gyro.csv": "raw gyroscope rad/s (also the rotation input of the blur gate)",
                "imu_accel.csv": "raw accelerometer g",
                "world_map_registration.json": "copy of the world-map scan's registration.json (raw -> original scan's canonical frame), when it had one",
                "events.log": "capture lifecycle, exposure cap, failures"
            ]
        ]
        var setup = self.setup   // exposure and ICP results come from locked state (written off main)
        setup.exposureCapRequestedSeconds = AppConstants.arStillMaxExposureSeconds
        setup.exposureCapAppliedSeconds = stats.exposureCapAppliedSeconds
        setup.exposureCapNote = stats.exposureCapNote
        setup.icpBake = icpBakeNoted.withLock { $0 }
        if let data = try? JSONEncoder().encode(setup), let json = try? JSONSerialization.jsonObject(with: data) {
            manifest["setup"] = json
        }
        let totals: [String: Any] = [
            "stills_requested": stats.stillsRequested, "stills_saved": stats.stillsSaved,
            "stills_failed": stats.stillsFailed, "stills_with_depth": stats.stillsWithDepth,
            "frames_held_blur": stats.heldBlurFrames, "frames_held_spacing": stats.heldSpacingFrames,
            "frames_held_backpressure": stats.heldBackpressureFrames,
            "stills_short_exposure": stats.stillsShortExposure,
            "depth_dropouts": stats.depthDropouts, "frames_without_depth": stats.framesWithoutDepth,
            "tracking_changes": stats.trackingChanges, "thermal_state_at_stop": stats.thermalState,
            "frames_logged": stats.framesLogged,
            "gyro_samples": stats.gyroSamples, "accel_samples": stats.accelSamples,
            "last_still_dimensions": stats.lastStillDimensions,
            "elapsed_seconds": stats.elapsedSeconds
        ]
        manifest["totals"] = totals
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: directory.appendingPathComponent("manifest.json"))
        }
    }

    private static func zip(directory: URL) -> URL? {
        let fm = FileManager.default
        let zipURL = directory.deletingPathExtension().appendingPathExtension("zip")
        try? fm.removeItem(at: zipURL)
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: directory, options: .forUploading, error: &error) { temp in
            try? fm.copyItem(at: temp, to: zipURL)
        }
        if error != nil { return nil }
        return fm.fileExists(atPath: zipURL.path) ? zipURL : nil
    }

    // MARK: Helpers

    private static func describe(_ state: ARCamera.TrackingState) -> (String, Bool) {
        switch state {
        case .normal: return ("normal", true)
        case .notAvailable: return ("not available", false)
        case .limited(let reason):
            switch reason {
            case .initializing: return ("initializing", false)
            case .relocalizing: return ("relocalizing", false)
            case .excessiveMotion: return ("excessive motion", false)
            case .insufficientFeatures: return ("insufficient features", false)
            @unknown default: return ("limited", false)
            }
        }
    }

    private struct DepthCopy {
        var millimetres: [UInt16]
        var confidence: [UInt8]
        var width: Int
        var height: Int
    }

    /// Copies depth (metres -> mm) and confidence out of the pooled buffers.
    private static func copyDepth(_ depth: ARDepthData) -> DepthCopy? {
        let map = depth.depthMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<Float32>.stride
        let floats = base.assumingMemoryBound(to: Float32.self)
        var mm = [UInt16](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let m = floats[y * stride + x]
                mm[y * w + x] = m.isFinite ? UInt16(min(max(m * 1000, 0), 65535)) : 0
            }
        }
        var conf = [UInt8](repeating: 2, count: w * h)
        if let c = depth.confidenceMap, CVPixelBufferGetWidth(c) == w, CVPixelBufferGetHeight(c) == h {
            CVPixelBufferLockBaseAddress(c, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(c, .readOnly) }
            if let cb = CVPixelBufferGetBaseAddress(c) {
                let rowBytes = CVPixelBufferGetBytesPerRow(c)
                let bytes = cb.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h { for x in 0..<w { conf[y * w + x] = bytes[y * rowBytes + x] } }
            }
        }
        return DepthCopy(millimetres: mm, confidence: conf, width: w, height: h)
    }

    /// Near-scene depth for the gates: a low percentile of a sparse grid of confident samples.
    private static func sampleDepth(_ depth: ARDepthData) -> Double? {
        let map = depth.depthMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<Float32>.stride
        let floats = base.assumingMemoryBound(to: Float32.self)
        let cols = 32, rows = 24
        var depths: [Float] = [], confs: [UInt8] = []
        depths.reserveCapacity(cols * rows)
        confs.reserveCapacity(cols * rows)
        var confBase: UnsafeMutableRawPointer?
        var confRow = 0
        let confMap = depth.confidenceMap.flatMap { CVPixelBufferGetWidth($0) == w && CVPixelBufferGetHeight($0) == h ? $0 : nil }
        if let c = confMap {
            CVPixelBufferLockBaseAddress(c, .readOnly)
            confBase = CVPixelBufferGetBaseAddress(c)
            confRow = CVPixelBufferGetBytesPerRow(c)
        }
        defer { if let c = confMap { CVPixelBufferUnlockBaseAddress(c, .readOnly) } }
        let confBytes = confBase?.assumingMemoryBound(to: UInt8.self)
        for r in 0..<rows {
            let y = min(h - 1, (2 * r + 1) * h / (2 * rows))
            for c in 0..<cols {
                let x = min(w - 1, (2 * c + 1) * w / (2 * cols))
                depths.append(floats[y * stride + x])
                confs.append(confBytes?[y * confRow + x] ?? 2)
            }
        }
        return ARStillCaptureGates.depthPercentile(depths, confidences: confs,
                                                   minConfidence: AppConstants.arStillGateMinConfidence,
                                                   percentile: AppConstants.arStillGateDepthPercentile)
    }

    /// 8-bit greyscale PNG of raw values (confidence 0/1/2 stays 0/1/2).
    private static func encodeGray8(_ values: [UInt8], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, values.count == width * height else { return nil }
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: Data(values) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func rowMajor3x4(_ m: simd_float4x4) -> [String] {
        // simd is column-major: m[col][row].
        (0..<3).flatMap { row in (0..<4).map { col in String(format: "%.6f", m[col][row]) } }
    }

    private static func columnMajor(_ m: simd_float4x4) -> [Float] {
        (0..<4).flatMap { col in (0..<4).map { row in m[col][row] } }
    }

    private static func hardwareModel() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }
}

/// Fixed-precision CSV fields. A `nonisolated` enum so the helpers are callable from any queue
/// (the project defaults declarations to the main actor).
private nonisolated enum Fmt {
    static func f0(_ v: Double) -> String { String(format: "%.0f", v) }
    static func f3(_ v: Double) -> String { String(format: "%.3f", v) }
    static func f4(_ v: Double) -> String { String(format: "%.4f", v) }
    static func f6(_ v: Double) -> String { String(format: "%.6f", v) }
}

/// Buffered line writer for the AR still capture dump. ioQueue-only. (Same shape as the raw
/// capture's private writer; kept separate so the experiment does not touch that compiled file.)
nonisolated final class ARStillCSVWriter {
    private let handle: FileHandle?
    private var pending = ""
    private var pendingLines = 0

    init(url: URL, header: String) {
        handle = Self.openAppend(url)
        pending = header + "\n"
        pendingLines = 1
    }

    static func openAppend(_ url: URL) -> FileHandle? {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
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
