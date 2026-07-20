import Foundation
import ARKit
import UIKit
import AudioToolbox
import Observation
import os

/// Captures RGB frames, depth maps, and camera poses during an AR recording session.
@Observable
// swiftlint:disable type_body_length function_body_length cyclomatic_complexity function_parameter_count identifier_name
class FrameCaptureSession {
    private(set) var frameCount = 0
    private(set) var captureDir: URL?
    private var timer: Timer?
    private var imagesDir: URL?
    private var proxyImagesDir: URL?
    private var depthDir: URL?
    private var camerasDir: URL?
    private var confidenceDir: URL?
    private var masksDir: URL?
    private var frames: [FrameData] = []
    private var globalIntrinsics: CameraIntrinsics?
    private var imageWidth: Int = 0
    private var imageHeight: Int = 0
    private var lastCaptureTransform: simd_float4x4?
    private var overlapMax: Double = 80.0 // percentage
    private var rejectBlur: Bool = true
    private var privacyFilter: Bool = false
    private var lastCaptureTime: TimeInterval = 0

    // Test modes
    private var isMockingIMU: Bool = false
    private var isMockingImages: Bool = false
    private var isMockingDepth: Bool = false
    private var testSequenceIndex: Int = 0

    // Wearables proxy
    private var proxyFrameCount: Int = 0
    private var lastProxyCaptureTime: TimeInterval = 0

    // Capture warning logic — split by cause so the on-screen prompt matches the actual problem
    // (tracking dropped vs. genuinely moving too fast). Detection is a pose-velocity + tracking-state
    // heuristic, NOT a pixel-sharpness measurement (so blur_score in metadata is assumed, not measured).
    enum CaptureWarning: Equatable { case fastMotion, trackingLost }
    private(set) var blurWarningReason: CaptureWarning?
    /// Convenience for call sites that only care whether any capture warning is showing.
    var isBlurWarningActive: Bool { blurWarningReason != nil }
    private var blurWarningTimer: Timer?
    private var consecutiveBlurredFrames: Int = 0

    // ── Stillness detection & capture quality ──
    // Tracks device motion state to identify "sharp" frames (device stationary) vs
    // "sweep" frames (device in motion). Sharp frames get audio feedback (shutter click)
    // and are counted separately for the quality bar UI.
    private var stillnessStartTime: TimeInterval?
    private(set) var isCurrentlyStill: Bool = false
    /// Ring-fill progress for the stillness reticle: 0 while moving, climbing to 1 over the
    /// confirmation window once the device settles, held at 1 while confirmed still.
    private(set) var stillnessProgress: Double = 0
    /// Whether a keyframe has already been saved for the current stillness period.
    /// Prevents hundreds of near-identical frames from piling up when the camera is
    /// stationary (sensor jitter crosses the tiny overlap threshold at 30fps).
    private var hasStillnessKeyframe: Bool = false
    /// Number of frames captured while device was confirmed still (high confidence sharp).
    private(set) var sharpFrameCount: Int = 0
    /// Total frames captured this session (sharp + sweep).
    private(set) var totalCapturedFrameCount: Int = 0
    /// Time of last sharp frame capture (for ScanCoach "pause for photo" guidance).
    private(set) var lastSharpFrameTime: Date?

    // ── High-resolution keyframe capture ──
    // While the AR video stream runs a standard mesh-friendly format (1920×1440),
    // confirmed stillness triggers ARSession.captureHighResolutionFrame — a single
    // still at the camera's native photo resolution (up to ~12MP) with its own pose
    // and intrinsics. This sidesteps the hiRes-video-format-breaks-mesh problem:
    // sweep frames feed depth/mesh, hi-res stills feed splat texture detail.
    /// A hi-res capture request is pending; ARKit rejects overlapping requests.
    private var hiResCaptureInFlight = false
    /// AR-session timestamp of the pending hi-res request, for the watchdog that
    /// recovers when a completion is dropped (e.g. by a session interruption).
    private var hiResRequestTime: TimeInterval?
    /// Consecutive hi-res failures; transient errors get retried before latching.
    private var hiResFailureCount = 0
    /// Hi-res capture failed repeatedly (unsupported format/device) — fall back to
    /// saving stream frames as stillness keyframes for the rest of the session.
    private var hiResUnavailable = false
    /// Set when capture stops (pause/stop/discard); a hi-res completion landing after
    /// this must not save — the metadata writers have already run.
    private var captureEnded = false
    /// Blurred-still retries consumed in the current stillness period. Pose velocity says
    /// the DEVICE is still, but dim rooms force long exposures where hand tremor still
    /// blurs the photo — the sharpness gate rejects those and retries (bounded), and after
    /// the budget we accept the best we got with its measured quality recorded.
    private var keyframeRetryCount = 0
    /// A saved sharp keyframe (hi-res still or stream fallback), as delivered to the
    /// coverage overlay via `onKeyframeCaptured`.
    struct KeyframeStill {
        let transform: simd_float4x4
        let intrinsics: simd_float3x3
        let width: Int
        let height: Int
        /// Scene depth at capture time, when available. Consumers must use it
        /// synchronously inside the callback and not retain it — it's an ARKit
        /// pool buffer, and holding it starves the frame pool (VIO loss).
        let depthMap: CVPixelBuffer?
    }

    /// Called on the main thread after a sharp keyframe is saved. The AR coverage
    /// overlay stamps the photo-coverage voxel grid from the keyframe's depth map and
    /// updates mesh anchors' photo-covered state (amber → clear).
    @ObservationIgnored var onKeyframeCaptured: ((KeyframeStill) -> Void)?

    // Privacy logic
    /// Accumulating person anchor with an observation count, which acts as a confidence weight:
    /// a real person merges in across many frames (high weight) while a one-frame segmentation
    /// false positive stays at weight 1 and is dropped at finalize. Mirrors the live indicator's
    /// confidence gate, in 3D.
    private struct AnchorAccumulator {
        var position: SIMD3<Float>
        var weight: Float
    }
    private var faceAnchors: [AnchorAccumulator] = []

    /// Semantic display classes detected during this session (e.g. "wall", "floor", "fixture").
    /// Set by the AR coordinator before stop() so metadata includes the detected classes.
    var semanticClassesDetected: Set<String> = []

    /// Final photo-coverage voxel stats (covered = voxels stamped by keyframe depth,
    /// occupied = voxels containing mesh, plus the multi-view aggregates: mean
    /// still-to-still overlap and the fraction of covered voxels seen from ≥2
    /// standpoints). Set from ScanStats before stop() so metadata records how much of
    /// the scanned geometry got photo-grade coverage — and how well the stills overlap,
    /// the offline hook for correlating capture properties with splat quality.
    struct PhotoCoverageSummary {
        let covered: Int
        let occupied: Int
        let meanStillOverlap: Double
        let standpointDiversity: Double
    }
    var photoCoverageStats: PhotoCoverageSummary?

    /// Drop low-confidence anchors (seen in too few frames → likely transient segmentation noise)
    /// then coalesce any survivors still within the merge radius, so the saved `face_anchors` are
    /// few and representative of the live view — the persist-and-coalesce analog of the live gate.
    private static func finalizeAnchors(_ anchors: [AnchorAccumulator]) -> [SIMD3<Float>] {
        let confident = anchors.filter { $0.weight >= AppConstants.faceAnchorMinObservations }
        var merged: [AnchorAccumulator] = []
        for a in confident {
            if let i = merged.firstIndex(where: { simd_distance($0.position, a.position) < AppConstants.faceClusterThresholdMeters }) {
                let w = merged[i].weight
                merged[i].position = (merged[i].position * w + a.position * a.weight) / (w + a.weight)
                merged[i].weight = w + a.weight
            } else {
                merged.append(a)
            }
        }
        return merged.map { $0.position }
    }

    // Boundary Anchor (Pivot-Point)
    private(set) var boundaryAnchorTransform: simd_float4x4?
    private(set) var boundaryAnchorId: UUID?
    private var boundaryAnchorCompassHeading: Double?

    // Metadata dependencies
    private var locationManager: LocationManager?
    private var activeLocationId: UUID?
    private var hardwareDeviceModel: String = "Native iOS"

    // Cached for export on background queue
    private var cachedDeviceName: String = "Unknown"
    private var cachedOSName: String = "iOS"
    private var cachedOSVersion: String = "Unknown"

    // Haptic generators are held for the session and re-prepared after each use so the
    // keyframe feedback lands without Taptic Engine spin-up latency (mirrors the
    // prepared `hapticGenerator` pattern in CaptureView). Main-thread only.
    @ObservationIgnored private let shutterHaptic = UIImpactFeedbackGenerator(style: .rigid)
    @ObservationIgnored private let stillnessHaptic = UIImpactFeedbackGenerator(style: .light)

    private let ioQueue = DispatchQueue(label: "com.scan4d.capture.io", qos: .userInitiated)
    /// Dedicated queue for the expensive ~12MP hi-res keyframe JPEG encode, kept OFF the
    /// shared ioQueue so a >1s native-res encode can't head-of-line-block stream saves and
    /// starve ARKit's frame pool. Only one hi-res request is in flight at a time, so serial.
    private let keyframeEncodeQueue = DispatchQueue(label: "com.scan4d.capture.keyframe", qos: .utility)
    private let ciContext = CIContext()  // Reuse across frames to avoid GPU pipeline re-init
    /// Reusable 16-bit depth conversion buffer (depth resolution is fixed per session).
    /// Only touched inside depthMapToPNG16 on ioQueue, so no synchronization needed.
    private var depthScratch: [UInt16] = []

    /// Perf diagnostics: number of frame-save closures queued/running on ioQueue. Growth means
    /// retained CVPixelBuffers are piling up faster than encodes finish — the capture-side cause
    /// of ARFrame-pool starvation. Incremented on the capture (main) timer, decremented on ioQueue.
    private let inFlightSaves = OSAllocatedUnfairLock(initialState: 0)

    struct FrameData {
        let index: Int
        let transform: simd_float4x4
        // Whether a depth/confidence PNG was actually written for this frame. The per-frame metadata
        // (transforms.json / Polycam cameras) references these paths only when true, so the export
        // never points at files that don't exist (depth is unavailable on some frames, e.g. while
        // RoomPlan owns the session or on non-LiDAR devices).
        let hasDepth: Bool
        let hasConfidence: Bool
        // Per-frame dimensions and intrinsics: hi-res keyframes are captured at native photo
        // resolution, so they differ from the video-stream frames. Writers emit per-frame
        // overrides when these differ from the session-global values.
        let width: Int
        let height: Int
        let intrinsics: CameraIntrinsics
        /// True for hi-res stills captured at a stillness point (splat-priority frames).
        let isKeyframe: Bool
        // Measured keyframe quality (nil for sweep frames): Laplacian-variance sharpness
        // (higher = sharper) and the camera exposure duration at capture. Persisted so
        // downstream pipelines can weight stills by actual quality, not just is_keyframe.
        let sharpness: Float?
        let exposureDuration: Double?
    }

    struct CameraIntrinsics {
        let fx: Float
        let fy: Float
        let cx: Float
        let cy: Float
    }

    /// Returns the last `count` camera-to-world transforms from captured frames.
    /// Lightweight — copies only the simd_float4x4 values, no pixel data.
    /// Called by ScanCoach at ~1Hz for spatial pattern analysis.
    func recentTransforms(count: Int = 30) -> [simd_float4x4] {
        let slice = frames.suffix(count)
        return slice.map { $0.transform }
    }

    /// Start capturing frames from the given AR session.
    /// - Parameters:
    ///   - overlapMax: Maximum overlap percentage (10-100). Higher = more frames.
    ///   - rejectBlur: If true, skip frames with motion blur.
    ///   - privacyFilter: If true, blur faces in images and zero person regions in depth.
    func start(
        session: ARSession,
        overlapMax: Double = 60.0,
        rejectBlur: Bool = true,
        privacyFilter: Bool = false,
        locationManager: LocationManager? = nil,
        activeLocationId: UUID? = nil,
        hardwareDeviceModel: String = "Native iOS",
        mockIMU: Bool = false,
        mockCameraImages: Bool = false,
        mockDepthMaps: Bool = false
    ) {
        // Create temp directory for this capture
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan4d_raw_\(UUID().uuidString)", isDirectory: true)
        let imagesPath = tempDir.appendingPathComponent("images", isDirectory: true)
        let proxyImagesPath = tempDir.appendingPathComponent("proxy_images", isDirectory: true)
        let depthPath = tempDir.appendingPathComponent("depth", isDirectory: true)
        let camerasPath = tempDir.appendingPathComponent("cameras", isDirectory: true)
        let confidencePath = tempDir.appendingPathComponent("confidence", isDirectory: true)
        let masksPath = tempDir.appendingPathComponent("masks", isDirectory: true)

        try? FileManager.default.createDirectory(at: imagesPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: proxyImagesPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: depthPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: camerasPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: confidencePath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: masksPath, withIntermediateDirectories: true)

        self.captureDir = tempDir
        self.imagesDir = imagesPath
        self.proxyImagesDir = proxyImagesPath
        self.depthDir = depthPath
        self.camerasDir = camerasPath
        self.confidenceDir = confidencePath
        self.masksDir = masksPath
        self.frames = []
        self.frameCount = 0
        self.globalIntrinsics = nil
        self.lastCaptureTransform = nil
        self.blurWarningReason = nil
        self.consecutiveBlurredFrames = 0
        self.blurWarningTimer?.invalidate()
        self.blurWarningTimer = nil
        self.stillnessStartTime = nil
        self.isCurrentlyStill = false
        self.stillnessProgress = 0
        self.hasStillnessKeyframe = false
        self.sharpFrameCount = 0
        self.totalCapturedFrameCount = 0
        self.lastSharpFrameTime = nil
        self.hiResCaptureInFlight = false
        self.hiResRequestTime = nil
        self.hiResFailureCount = 0
        self.hiResUnavailable = false
        self.captureEnded = false
        self.keyframeRetryCount = 0
        self.photoCoverageStats = nil
        self.overlapMax = overlapMax
        self.rejectBlur = rejectBlur
        self.privacyFilter = privacyFilter
        ioQueue.async { self.faceAnchors = [] } // ioQueue owns faceAnchors (see frame loop); ordered before frame work
        self.boundaryAnchorTransform = nil
        self.boundaryAnchorId = nil
        self.boundaryAnchorCompassHeading = nil
        self.lastCaptureTime = 0
        self.locationManager = locationManager
        self.activeLocationId = activeLocationId
        self.hardwareDeviceModel = hardwareDeviceModel

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.cachedDeviceName = UIDevice.current.name
            self.cachedOSName = UIDevice.current.systemName
            self.cachedOSVersion = UIDevice.current.systemVersion
            self.shutterHaptic.prepare()
            self.stillnessHaptic.prepare()
        }

        self.isMockingIMU = mockIMU
        self.isMockingImages = mockCameraImages
        self.isMockingDepth = mockDepthMaps
        self.testSequenceIndex = 0

        // Check for new frames at 10fps, but only capture when sufficient movement
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.captureFrame(from: session)
        }
    }

    /// Stop capturing and write export metadata.
    func stop() -> URL? {
        timer?.invalidate()
        timer = nil

        guard let captureDir = captureDir else { return nil }

        // Block to ensure ongoing frame captures complete and write their JSONs
        ioQueue.sync {
            print("[FrameCapture] Stopping — \(self.frames.count) frames captured (mockIMU=\(self.isMockingIMU) mockImages=\(self.isMockingImages) mockDepth=\(self.isMockingDepth))")

            // Write Nerfstudio transforms.json
            self.writeTransformsJSON(to: captureDir)

            // Write Polycam per-frame camera JSONs
            self.writePolycamCameras(to: captureDir)

            // Write Scan4D ground-truth metadata
            self.writeScan4DMetadata(to: captureDir)
        }

        return captureDir
    }

    /// Immediately stop capturing new frames (cheap, main-thread safe). Call this on the main
    /// thread before invoking `stop()` off-main, so no frames are saved after the scan ends and
    /// the run-loop timer is invalidated on the thread it was scheduled on.
    func pauseCapture() {
        timer?.invalidate()
        timer = nil
        captureEnded = true // a late hi-res completion must not save past this point
    }

    /// Abandon the in-progress capture without finalizing: stop the timer and delete the capture
    /// directory (queued on ioQueue so it runs after any in-flight frame saves drain).
    func discardCapture() {
        timer?.invalidate()
        timer = nil
        captureEnded = true
        let dir = captureDir
        ioQueue.async {
            if let dir = dir { try? FileManager.default.removeItem(at: dir) }
        }
    }

    private func captureFrame(from session: ARSession) {
        let fullyTest = isMockingIMU && isMockingImages && isMockingDepth

        // Grab the frame and extract everything we need in one shot.
        // Releasing the ARFrame reference ASAP prevents ARKit's
        // "retaining N ARFrames" warning caused by holding strong refs
        // while heavy IO / Vision work runs asynchronously.
        let frame = session.currentFrame

        // On Simulator, currentFrame is always nil. Allow fully-synthetic capture to proceed.
        guard frame != nil || fullyTest else { return }

        // Cap test captures at one full 360° loop — no redundant duplicate poses
        if isMockingIMU && testSequenceIndex >= TestDataGenerator.totalFrames { return }

        // Extract all needed data from the frame immediately
        let pixelBuffer = frame?.capturedImage
        let camW = pixelBuffer.map { CVPixelBufferGetWidth($0) } ?? TestDataGenerator.defaultW
        let camH = pixelBuffer.map { CVPixelBufferGetHeight($0) } ?? TestDataGenerator.defaultH
        var transform = frame?.camera.transform ?? matrix_identity_float4x4
        var intrinsics = frame?.camera.intrinsics ?? simd_float3x3(1)
        let depthMap = frame?.sceneDepth?.depthMap
        let confidenceMap = frame?.sceneDepth?.confidenceMap
        let trackingState = frame?.camera.trackingState
        let frameTimestamp = frame?.timestamp ?? 0
        let segBuffer = self.privacyFilter ? frame?.segmentationBuffer : nil

        // ⚡ ARFrame reference is now released — only extracted values are retained
        // (The local `frame` will be released when this scope exits, but we avoid
        // passing it to any async closures or storing it longer than necessary.)

        if isMockingIMU {
            let (testTransform, testIntrinsics) = TestDataGenerator.generatePoseAndIntrinsics(for: testSequenceIndex, w: camW, h: camH)
            transform = testTransform
            intrinsics = testIntrinsics
        }

        // ── Motion state ──
        // Pose velocities since the last saved frame. Computed regardless of the
        // rejectBlur setting: stillness detection drives the keyframe pipeline,
        // reticle, and coverage overlay — not just blur rejection.
        // Checks both translational velocity (fast walking) AND rotational velocity
        // (panning in place) — the rotational check catches the common indoor scanning
        // pattern where users stand still but rotate quickly.
        var velocity: Float = 0
        var angularVelocity: Float = 0
        var hasMotionBaseline = false
        if !isMockingIMU, let lastTransform = lastCaptureTransform {
            let timeDelta = frameTimestamp - lastCaptureTime
            if timeDelta > 0 {
                velocity = cameraMovement(from: lastTransform, to: transform) / Float(timeDelta)
                angularVelocity = extractRotationAngle(from: lastTransform, to: transform) / Float(timeDelta)
                hasMotionBaseline = true
            }
        }
        let trackingNormal = trackingState == nil || trackingState == .normal

        // ── Stillness detection ──
        // Still only when we have a motion baseline, tracking is reliable, and both
        // velocities are under the stillness thresholds. Tracking loss or fast motion
        // resets the state machine so the reticle never shows a stale locked-green ring.
        let isStill = hasMotionBaseline && trackingNormal &&
                      velocity < AppConstants.stillnessTranslationalThreshold &&
                      angularVelocity < AppConstants.stillnessAngularThreshold
        let confirmedStill = updateStillness(isStill: isStill, frameTimestamp: frameTimestamp)

        // Reject blurred frames based on camera tracking quality
        if rejectBlur && !isMockingIMU {
            var warning: CaptureWarning?

            // Tracking dropped out of .normal (limited / excessive motion / relocalizing): frames
            // here are unreliable. The fix is to hold steady & let tracking recover — NOT necessarily
            // to slow down — so this is reported as a distinct cause from genuine fast motion.
            if !trackingNormal {
                warning = .trackingLost
            } else if velocity > AppConstants.motionBlurVelocity ||
                      angularVelocity > AppConstants.motionBlurAngularVelocity {
                // The camera pose moved too fast since the last capture (motion blur likely).
                warning = .fastMotion
            }

            if let warning = warning {
                // Increment the bad-frame counter; surface the warning once several land in a row.
                consecutiveBlurredFrames += 1
                if consecutiveBlurredFrames >= AppConstants.consecutiveBlurThreshold && blurWarningReason != warning {
                    DispatchQueue.main.async {
                        self.blurWarningReason = warning
                        self.resetBlurWarningTimer()
                    }
                }
                return
            } else {
                // Valid frame, reset the counter
                consecutiveBlurredFrames = 0
            }
        }

        // Skip frame if camera hasn't moved enough (based on overlap setting)
        if let lastTransform = lastCaptureTransform {
            let movement = cameraMovement(from: lastTransform, to: transform)
            // Higher overlap = smaller movement threshold = more frames
            // overlapMax 100% → threshold ~0.01m (capture almost everything)
            // overlapMax 10%  → threshold ~0.15m (only distinct views)
            let threshold = Float(Double(AppConstants.overlapBaseThreshold) * (1.0 - overlapMax / 100.0)) + AppConstants.overlapMinThreshold
            if !isMockingIMU && movement < threshold {
                return // skip — too much overlap with previous frame
            }
        }

        // ── Stillness keyframe ──
        // When the device is confirmed still, capture exactly one keyframe at the
        // start of the stillness period, then suppress further saves until the camera
        // moves again. Without this gate, sensor noise jitter crosses the tiny overlap
        // threshold (0.01-0.04m) at 30fps, producing hundreds of near-identical frames
        // of the same spot.
        //
        // The keyframe itself is a native-resolution still (captureHighResolutionFrame)
        // when the device supports it, so the sharp pause-shot carries far more texture
        // detail than the video stream. After repeated hi-res failures, keyframes fall
        // back to saving the stream frame (pre-hi-res behavior).
        var isStillnessKeyframe = false
        if confirmedStill && !isMockingIMU {
            if hasStillnessKeyframe {
                return // already captured a keyframe for this stillness period
            }
            // Mock-image capture stays on the stream path — a real hi-res photo would be
            // inconsistent with the synthetic frame sequence.
            if !hiResUnavailable && !isMockingImages {
                // Anchor the overlap gate at this pose so stream saves don't sneak
                // through on sensor jitter while the hi-res request is in flight.
                lastCaptureTransform = transform
                lastCaptureTime = frameTimestamp
                if !hiResCaptureInFlight {
                    hasStillnessKeyframe = true
                    hiResRequestTime = frameTimestamp
                    requestHighResolutionKeyframe(from: session)
                } else if let requested = hiResRequestTime,
                          frameTimestamp - requested > AppConstants.hiResCaptureTimeoutSeconds {
                    // Watchdog: the completion never arrived (a session interruption can
                    // drop it). Issue a fresh request; a zombie completion landing later
                    // costs at most one extra saved frame.
                    print("[FrameCapture] Hi-res capture timed out after \(Int(AppConstants.hiResCaptureTimeoutSeconds))s — re-requesting")
                    hasStillnessKeyframe = true
                    hiResRequestTime = frameTimestamp
                    requestHighResolutionKeyframe(from: session)
                }
                // A previous request still in flight (not timed out): leave the keyframe
                // budget unconsumed so the next tick retries once the completion lands.
                return // the hi-res completion saves the keyframe (or re-arms the gate on failure)
            }
            // Hi-res unavailable — fall through and save the stream frame as the keyframe.
            hasStillnessKeyframe = true
            isStillnessKeyframe = true
        }

        lastCaptureTransform = transform
        lastCaptureTime = frameTimestamp

        let currentIndex = self.testSequenceIndex
        self.testSequenceIndex += 1 // Increment sequence index for synthetic progression

        let admitted = processAndSaveFrame(
            pixelBuffer: pixelBuffer,
            camW: camW,
            camH: camH,
            transform: transform,
            intrinsics: intrinsics,
            depthMap: depthMap,
            confidenceMap: confidenceMap,
            segBuffer: segBuffer,
            currentIndex: currentIndex,
            isKeyframe: isStillnessKeyframe
        )

        // ── Counters & feedback (post-admission) ──
        // Bookkeeping only runs for frames that actually entered the save pipeline, so
        // the UI counts, shutter feedback, and coverage overlay never report a frame the
        // backlog guard dropped.
        if admitted {
            if isStillnessKeyframe {
                noteKeyframeSaved(transform: transform, intrinsics: intrinsics, width: camW, height: camH, depthMap: depthMap)
            } else {
                DispatchQueue.main.async { self.totalCapturedFrameCount += 1 }
            }
        } else if isStillnessKeyframe {
            hasStillnessKeyframe = false // backlog drop — let this stillness period retry
        }
    }

    /// Advances the stillness state machine: entry/exit tracking, the confirmed-still
    /// flag, reticle ring progress, and the entering-stillness chime/haptic.
    /// Returns whether the device is confirmed still as of this frame (fresher than the
    /// async-published `isCurrentlyStill`). Runs on the capture timer (main thread).
    @discardableResult
    private func updateStillness(isStill: Bool, frameTimestamp: TimeInterval) -> Bool {
        if isStill && stillnessStartTime == nil {
            stillnessStartTime = frameTimestamp
        } else if !isStill {
            stillnessStartTime = nil
            hasStillnessKeyframe = false // reset so next stillness period gets a fresh keyframe
            keyframeRetryCount = 0       // fresh blurred-still retry budget for the next period
        }
        let wasStill = isCurrentlyStill
        let confirmedStill = isStill && (frameTimestamp - (stillnessStartTime ?? frameTimestamp)) >= AppConstants.stillnessDurationRequired
        if confirmedStill != isCurrentlyStill {
            DispatchQueue.main.async { self.isCurrentlyStill = confirmedStill }
        }
        // Publish ring-fill progress for the stillness reticle.
        let progress: Double
        if confirmedStill {
            progress = 1.0
        } else if isStill, let start = stillnessStartTime {
            progress = min((frameTimestamp - start) / AppConstants.stillnessDurationRequired, 1.0)
        } else {
            progress = 0.0
        }
        if progress != stillnessProgress {
            DispatchQueue.main.async { self.stillnessProgress = progress }
        }
        // Play audio + haptic feedback on stillness transitions
        if confirmedStill && !wasStill {
            playStillnessChime()
        }
        return confirmedStill
    }

    /// Shared bookkeeping for a saved stillness keyframe (hi-res still or stream
    /// fallback): counters, coach timestamp, shutter feedback, and the coverage-overlay
    /// callback. Must be called on the main thread.
    private func noteKeyframeSaved(
        transform: simd_float4x4,
        intrinsics: simd_float3x3,
        width: Int,
        height: Int,
        depthMap: CVPixelBuffer?
    ) {
        sharpFrameCount += 1
        totalCapturedFrameCount += 1
        lastSharpFrameTime = Date()
        playShutterClick()
        onKeyframeCaptured?(KeyframeStill(
            transform: transform, intrinsics: intrinsics,
            width: width, height: height, depthMap: depthMap
        ))
    }

    /// Requests a single still at the camera's native photo resolution and saves it as the
    /// keyframe for the current stillness period. The AR video stream is unaffected — this
    /// is how we get 4K+ sharp frames without switching to a hiRes video format (which
    /// breaks Recon3D mesh integration on iPads).
    private func requestHighResolutionKeyframe(from session: ARSession) {
        hiResCaptureInFlight = true
        session.captureHighResolutionFrame { [weak self] frame, error in
            guard let self = self else { return }

            guard let frame = frame, error == nil else {
                DispatchQueue.main.async {
                    self.hiResCaptureInFlight = false
                    self.hiResFailureCount += 1
                    print("[FrameCapture] Hi-res capture failed (\(error?.localizedDescription ?? "nil frame")) — attempt \(self.hiResFailureCount)/\(AppConstants.hiResMaxFailures)")
                    // Transient failures happen (session interruptions, RoomPlan
                    // reconfiguration windows) — only latch the stream-frame fallback
                    // after repeated failures.
                    if self.hiResFailureCount >= AppConstants.hiResMaxFailures {
                        self.hiResUnavailable = true
                        print("[FrameCapture] Hi-res capture disabled for this session — falling back to stream keyframes")
                    }
                    // Re-arm the keyframe budget AND drop the overlap anchor: the anchor
                    // was pinned at the stillness pose, so without this the jitter-gated
                    // overlap check could starve the retry for the rest of the pause.
                    self.hasStillnessKeyframe = false
                    self.lastCaptureTransform = nil
                }
                return
            }

            // Completion arrives on an arbitrary queue. Extract everything needed from the
            // ARFrame here so the reference releases when this scope exits (same ARFrame
            // retention discipline as the stream path).
            let pixelBuffer = frame.capturedImage
            let camW = CVPixelBufferGetWidth(pixelBuffer)
            let camH = CVPixelBufferGetHeight(pixelBuffer)
            let transform = frame.camera.transform
            let intrinsics = frame.camera.intrinsics
            let exposureDuration = frame.camera.exposureDuration
            let depthMap = frame.sceneDepth?.depthMap
            let confidenceMap = frame.sceneDepth?.confidenceMap
            let segBuffer = self.privacyFilter ? frame.segmentationBuffer : nil

            // Measure + encode on a DEDICATED background queue — off both the main thread
            // AND the shared ioQueue. A native-resolution encode can exceed a second; running
            // it on the ioQueue head-of-line-blocks queued stream saves, pinning their live
            // ARFrame pool buffers and starving ARKit (observed on device: a 1668ms encode →
            // 1.5s frame gap → tracking loss → RoomPlan drift). We dispatch explicitly rather
            // than run on the completion's own queue because ARKit doesn't document which queue
            // that is (it may be main). The ioQueue closure later then only does the fast
            // depth-PNG + file writes. The hi-res pixel buffer is not a live-pool ARFrame
            // buffer, so retaining it across these hops doesn't affect ARKit's pool.
            keyframeEncodeQueue.async {
                // ── Sharpness gate ──
                // Pose velocity confirmed the DEVICE was still, but in dim light the long
                // exposure can still blur the photo from hand tremor. Measure actual image
                // sharpness BEFORE the expensive encode; the gate decision runs on main,
                // which owns the retry budget. Exposure is recorded, not gated: a dim room
                // makes EVERY still long-exposure, so gating on it would starve keyframes.
                let sharpness = Self.laplacianSharpness(of: pixelBuffer)
                let exposureLabel = exposureDuration > 0 ? String(format: "1/%.0fs", 1.0 / exposureDuration) : "n/a"
                print("[FrameCapture] Hi-res keyframe captured: \(camW)×\(camH) (depth: \(depthMap != nil), sharpness: \(String(format: "%.0f", sharpness)), exposure: \(exposureLabel))")

                DispatchQueue.main.async {
                    guard !self.captureEnded else {
                        self.hiResCaptureInFlight = false
                        return
                    }
                    if sharpness < AppConstants.keyframeSharpnessFloor,
                       self.keyframeRetryCount < AppConstants.keyframeMaxRetries {
                        // Too blurred — re-arm the stillness period for another attempt
                        // (bounded). No shutter feedback for a rejected still.
                        self.keyframeRetryCount += 1
                        self.hiResCaptureInFlight = false
                        self.hasStillnessKeyframe = false
                        print("[FrameCapture] Keyframe below sharpness floor (\(String(format: "%.0f", sharpness)) < \(String(format: "%.0f", AppConstants.keyframeSharpnessFloor))) — retry \(self.keyframeRetryCount)/\(AppConstants.keyframeMaxRetries)")
                        return
                    }

                    // Accepted (sharp enough, or retry budget exhausted — keep the best we
                    // got, with its measured quality recorded for downstream weighting).
                    self.keyframeEncodeQueue.async {
                        guard let keyframeJPEG = PerfDiag.timed("jpeg_encode_hires", warnOverMs: 250, { self.pixelBufferToJPEG(pixelBuffer) }) else {
                            print("[FrameCapture] Hi-res keyframe JPEG encode failed — dropping")
                            DispatchQueue.main.async {
                                self.hiResCaptureInFlight = false
                                self.hasStillnessKeyframe = false // let the stillness period retry
                            }
                            return
                        }

                        DispatchQueue.main.async {
                            self.hiResCaptureInFlight = false
                            self.hiResFailureCount = 0
                            // Recording may have stopped while the encode ran — the metadata
                            // writers have already run, so a late save would write an orphan
                            // frame into the exported capture directory.
                            guard !self.captureEnded else { return }
                            // pixelBuffer: nil — the JPEG is pre-encoded, so the 12MP buffer isn't
                            // retained across the ioQueue hop (depth/seg are separate small buffers).
                            let admitted = self.processAndSaveFrame(
                                pixelBuffer: nil,
                                camW: camW,
                                camH: camH,
                                transform: transform,
                                intrinsics: intrinsics,
                                depthMap: depthMap,
                                confidenceMap: confidenceMap,
                                segBuffer: segBuffer,
                                currentIndex: 0,
                                isKeyframe: true,
                                preEncodedJPEG: keyframeJPEG,
                                keyframeQuality: (sharpness: sharpness, exposureDuration: exposureDuration)
                            )
                            // Feedback and coverage marking only for frames that actually entered
                            // the save pipeline — a backlog drop re-arms the stillness period instead.
                            if admitted {
                                self.noteKeyframeSaved(transform: transform, intrinsics: intrinsics, width: camW, height: camH, depthMap: depthMap)
                            } else {
                                self.hasStillnessKeyframe = false
                            }
                        }
                    }
                }
            }
        }
    }

    /// Injects a pixel buffer from a proxy capture device (e.g., Meta Ray-Ban stream).
    func captureProxyFrame(pixelBuffer: CVPixelBuffer) {
        guard let proxyDir = self.proxyImagesDir else { return }

        let now = Date().timeIntervalSince1970
        // Limit to ~15 FPS to prevent massive proxy image bloat
        guard now - lastProxyCaptureTime >= (1.0 / 15.0) else { return }
        lastProxyCaptureTime = now

        ioQueue.async { [weak self] in
            guard let self = self else { return }
            guard let jpegData = self.pixelBufferToJPEG(pixelBuffer) else { return }

            let index = self.proxyFrameCount
            self.proxyFrameCount += 1

            let paddedIndex = String(format: "%05d", index)
            let rgbPath = proxyDir.appendingPathComponent("frame_\(paddedIndex).jpg")

            do {
                try jpegData.write(to: rgbPath, options: .atomic)
            } catch {
                print("[FrameCapture] Failed to save proxy frame: \(error)")
            }
        }
    }

    /// Injects pre-encoded JPEG data as a proxy frame (used by mock wearable mode).
    func captureProxyFrameData(_ jpegData: Data) {
        guard let proxyDir = self.proxyImagesDir else { return }

        let now = Date().timeIntervalSince1970
        guard now - lastProxyCaptureTime >= (1.0 / 15.0) else { return }
        lastProxyCaptureTime = now

        ioQueue.async { [weak self] in
            guard let self = self else { return }

            let index = self.proxyFrameCount
            self.proxyFrameCount += 1

            let paddedIndex = String(format: "%05d", index)
            let rgbPath = proxyDir.appendingPathComponent("frame_\(paddedIndex).jpg")

            do {
                try jpegData.write(to: rgbPath, options: .atomic)
            } catch {
                print("[FrameCapture] Failed to save mock proxy frame: \(error)")
            }
        }
    }

    /// Returns whether the frame was admitted to the save pipeline (false = dropped at
    /// the in-flight backlog cap). Admission does not guarantee the encode/write
    /// succeeds, but callers use it to keep UI counters honest under backpressure.
    @discardableResult
    private func processAndSaveFrame(
        pixelBuffer: CVPixelBuffer?,
        camW: Int,
        camH: Int,
        transform: simd_float4x4,
        intrinsics: simd_float3x3,
        depthMap: CVPixelBuffer?,
        confidenceMap: CVPixelBuffer?,
        segBuffer: CVPixelBuffer?,
        currentIndex: Int,
        isKeyframe: Bool = false,
        preEncodedJPEG: Data? = nil,
        keyframeQuality: (sharpness: Float, exposureDuration: Double)? = nil
    ) -> Bool {
        // Backlog guard: if frame encodes are falling behind, DROP this frame instead of piling
        // up retained CVPixelBuffers. That pile-up is what starves ARKit's frame pool ("retaining
        // N ARFrames") and ultimately stalls/loses VIO tracking — and any data captured after VIO
        // loss is corrupt. Capture is movement-gated, so the next motion re-triggers a save.
        // Admit-and-increment atomically; the ioQueue closure decrements in its defer.
        //
        // Keyframes are EXEMPT from the cap: they arrive pre-encoded (the expensive ~12MP JPEG
        // encode already ran off-queue in the hi-res completion), carry no live-pool pixel buffer
        // into the ioQueue closure, and are rare + high-value — so they can't contribute to pool
        // starvation and must not be dropped by transient stream backlog.
        let admittedDepth: Int? = inFlightSaves.withLock { count -> Int? in
            guard isKeyframe || count < AppConstants.maxFramesInFlight else { return nil }
            count += 1
            return count
        }
        guard let depth = admittedDepth else {
            if PerfDiag.enabled { PerfDiag.log("capture frame DROPPED — backlog at cap (\(AppConstants.maxFramesInFlight))") }
            return false
        }
        if PerfDiag.enabled && depth > 1 { PerfDiag.log("capture I/O backlog: \(depth) frames in flight") }
        ioQueue.async { [weak self] in
            defer { self?.inFlightSaves.withLock { $0 -= 1 } }
            guard let self = self, let imagesDir = self.imagesDir else { return }

            // Depth is optional — LiDAR devices get depth, others just capture images + poses.
            // Depth is saved RAW (no person masking) — privacy masking is deferred to export.
            var validDepthData: Data?
            if self.isMockingDepth {
                validDepthData = TestDataGenerator.generateDepthMap(for: currentIndex, w: camW, h: camH)
            } else if let dMap = depthMap {
                let depthFormat = CVPixelBufferGetPixelFormatType(dMap)
                guard depthFormat == kCVPixelFormatType_DepthFloat32 else {
                    print("[FrameCapture] Unexpected depth format: \(depthFormat), skipping depth")
                    return
                }
                validDepthData = PerfDiag.timed("depth_png16", warnOverMs: 50) { self.depthMapToPNG16(dMap) }
            }

            // ── Image encode ──
            // Always save the RAW (unblurred) JPEG. Privacy blur is deferred to the export
            // pipeline (ScanExportManager) where it runs off the critical capture path. This
            // eliminates 50-200ms/frame of privacy encode from the ioQueue, preventing ARFrame
            // retention backpressure and VIO tracking loss on low-end devices.
            var finalJpegData: Data
            if self.isMockingImages {
                finalJpegData = TestDataGenerator.generateImage(for: currentIndex, w: camW, h: camH, transform: transform, intrinsics: intrinsics)
            } else if let preEncodedJPEG = preEncodedJPEG {
                // Keyframe path: the ~12MP encode already ran off-queue (hi-res completion),
                // so the ioQueue only does the fast depth-PNG + file writes here.
                finalJpegData = preEncodedJPEG
            } else {
                guard let pBuf = pixelBuffer else { return }
                guard let jpegData = PerfDiag.timed("jpeg_encode", warnOverMs: 50, { self.pixelBufferToJPEG(pBuf) }) else { return }
                finalJpegData = jpegData
            }

            // ── Segmentation mask save ──
            // When privacy filter is ON and ARKit provides a person stencil, save it as a
            // lightweight grayscale PNG alongside the frame. The export pipeline uses these
            // masks to apply blur to images and zero person regions in depth maps.
            if self.privacyFilter, let seg = segBuffer, let masksDir = self.masksDir {
                if let maskData = self.segmentationMaskToPNG(seg) {
                    let paddedIdx = String(format: "%05d", self.frames.count)
                    let maskPath = masksDir.appendingPathComponent("frame_\(paddedIdx).png")
                    do {
                        try maskData.write(to: maskPath, options: .atomic)
                    } catch {
                        print("[FrameCapture] Failed to save mask: \(error.localizedDescription)")
                    }
                }
            }

            // ── Face anchor accumulation (kept at capture time — cheap) ──
            // Extract person-region centroids from the seg buffer and unproject to 3D
            // using the depth map. This runs regardless of whether images are blurred,
            // since it only reads a few depth pixels per detected person centroid.
            if self.privacyFilter, let seg = segBuffer, let dMap = depthMap {
                let centers = PrivacyBlurUtil.personCentroids(in: seg)
                if !centers.isEmpty {
                    let depthWidth = CVPixelBufferGetWidth(dMap)
                    let depthHeight = CVPixelBufferGetHeight(dMap)
                    let imgWidth = Float(camW)
                    let imgHeight = Float(camH)

                    CVPixelBufferLockBaseAddress(dMap, .readOnly)
                    if let base = CVPixelBufferGetBaseAddress(dMap)?.assumingMemoryBound(to: Float32.self) {
                        var localAnchors = self.faceAnchors
                        for uv in centers {
                            let px = Int(uv.x * CGFloat(depthWidth))
                            let py = Int(uv.y * CGFloat(depthHeight))

                            // 3x3 kernel median for stable depth reading
                            var samples: [Float] = []
                            for dy in -1...1 {
                                for dx in -1...1 {
                                    let sx = min(max(px + dx, 0), depthWidth - 1)
                                    let sy = min(max(py + dy, 0), depthHeight - 1)
                                    let d = base[sy * depthWidth + sx]
                                    if d > 0 && d < 10.0 {
                                        samples.append(d)
                                    }
                                }
                            }
                            samples.sort()
                            guard !samples.isEmpty else { continue }
                            let z = samples[samples.count / 2] // median

                            let fx = intrinsics[0][0]
                            let fy = intrinsics[1][1]
                            let cx = intrinsics[2][0]
                            let cy = intrinsics[2][1]

                            let x_cam = (Float(uv.x) * imgWidth - cx) * z / fx
                            let y_cam = (cy - Float(uv.y) * imgHeight) * z / fy
                            let z_cam = -z

                            let localPoint = SIMD4<Float>(x_cam, y_cam, z_cam, 1.0)
                            let worldPoint = transform * localPoint
                            let point3D = SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)

                            var found = false
                            for i in 0..<localAnchors.count {
                                if simd_distance(localAnchors[i].position, point3D) < AppConstants.faceClusterThresholdMeters {
                                    let w = localAnchors[i].weight
                                    localAnchors[i].position = (localAnchors[i].position * w + point3D) / (w + 1)
                                    localAnchors[i].weight = w + 1
                                    found = true
                                    break
                                }
                            }
                            if !found {
                                localAnchors.append(AnchorAccumulator(position: point3D, weight: 1))
                            }
                        }
                        self.faceAnchors = localAnchors
                    }
                    CVPixelBufferUnlockBaseAddress(dMap, .readOnly)
                }
            }

        let index = self.frames.count
            let paddedIndex = String(format: "%05d", index)
            let rgbPath = imagesDir.appendingPathComponent("frame_\(paddedIndex).jpg")

            do {
                try finalJpegData.write(to: rgbPath, options: .atomic)
                var wroteDepth = false
                if let depthData = validDepthData, let depthDir = self.depthDir {
                    let depthPath = depthDir.appendingPathComponent("frame_\(paddedIndex).png")
                    try depthData.write(to: depthPath, options: .atomic)
                    wroteDepth = true
                }

                var wroteConfidence = false
                if let confMap = confidenceMap, let confData = PerfDiag.timed("confidence_png", warnOverMs: 40, { self.confidenceMapToPNG(confMap) }), let confDir = self.confidenceDir {
                    let confPath = confDir.appendingPathComponent("frame_\(paddedIndex).png")
                    try confData.write(to: confPath, options: .atomic)
                    wroteConfidence = true
                }

                let frameIntrinsics = CameraIntrinsics(
                    fx: intrinsics[0][0],
                    fy: intrinsics[1][1],
                    cx: intrinsics[2][0],
                    cy: intrinsics[2][1]
                )

                // Session-global intrinsics describe the video stream. Hi-res keyframes have
                // different dimensions/intrinsics, so never let one seed the globals — writers
                // emit per-frame overrides for frames that differ from the globals.
                if self.globalIntrinsics == nil && !isKeyframe {
                    self.imageWidth = camW
                    self.imageHeight = camH
                    self.globalIntrinsics = frameIntrinsics
                }

                self.frames.append(FrameData(
                    index: index,
                    transform: transform,
                    hasDepth: wroteDepth,
                    hasConfidence: wroteConfidence,
                    width: camW,
                    height: camH,
                    intrinsics: frameIntrinsics,
                    isKeyframe: isKeyframe,
                    sharpness: keyframeQuality?.sharpness,
                    exposureDuration: keyframeQuality?.exposureDuration
                ))
                let newlyAddedCount = self.frames.count

                DispatchQueue.main.async {
                    self.frameCount = newlyAddedCount
                }
            } catch {
                try? FileManager.default.removeItem(at: rgbPath)
            }
        }
        return true
    }

    // MARK: - transforms.json

    private func writeTransformsJSON(to directory: URL) {
        guard let intrinsics = globalIntrinsics else { return }

        // Convert ARKit camera poses to Nerfstudio convention (OpenGL: +X right, +Y up, +Z back)
        // ARKit: +X right, +Y up, -Z forward (same as OpenGL)
        var frameEntries: [[String: Any]] = []
        for frame in frames {
            let mat = frame.transform
            // ARKit uses the same convention as OpenGL for camera space,
            // but we need to ensure the transform_matrix is camera-to-world
            let paddedIndex = String(format: "%05d", frame.index)
            var entry: [String: Any] = [
                "file_path": "images/frame_\(paddedIndex).jpg",
                "transform_matrix": [
                    [mat.columns.0.x, mat.columns.0.y, mat.columns.0.z, mat.columns.0.w],
                    [mat.columns.1.x, mat.columns.1.y, mat.columns.1.z, mat.columns.1.w],
                    [mat.columns.2.x, mat.columns.2.y, mat.columns.2.z, mat.columns.2.w],
                    [mat.columns.3.x, mat.columns.3.y, mat.columns.3.z, mat.columns.3.w]
                ]
            ]
            // Reference depth/confidence only when the file was actually written for this frame.
            if frame.hasDepth { entry["depth_file_path"] = "depth/frame_\(paddedIndex).png" }
            if frame.hasConfidence { entry["confidence_file_path"] = "confidence/frame_\(paddedIndex).png" }
            // Hi-res keyframes differ from the session-global (video stream) resolution:
            // emit per-frame intrinsics/dimensions, which Nerfstudio reads as overrides.
            if frame.width != imageWidth || frame.height != imageHeight {
                entry["fl_x"] = frame.intrinsics.fx
                entry["fl_y"] = frame.intrinsics.fy
                entry["cx"] = frame.intrinsics.cx
                entry["cy"] = frame.intrinsics.cy
                entry["w"] = frame.width
                entry["h"] = frame.height
            }
            // Mark sharp stillness keyframes so the splat pipeline can weight them higher,
            // with measured quality when available (sharpness = Laplacian variance of luma,
            // higher = sharper; exposure in seconds).
            if frame.isKeyframe { entry["is_keyframe"] = true }
            if let sharpness = frame.sharpness { entry["sharpness"] = sharpness }
            if let exposure = frame.exposureDuration { entry["exposure_duration_s"] = exposure }
            frameEntries.append(entry)
        }

        let transforms: [String: Any] = [
            "camera_model": "OPENCV",
            "fl_x": intrinsics.fx,
            "fl_y": intrinsics.fy,
            "cx": intrinsics.cx,
            "cy": intrinsics.cy,
            "w": imageWidth,
            "h": imageHeight,
            "frames": frameEntries
        ]

        let jsonPath = directory.appendingPathComponent("transforms.json")
        if let jsonData = try? JSONSerialization.data(withJSONObject: transforms, options: .prettyPrinted) {
            try? jsonData.write(to: jsonPath)
        }
    }

    // MARK: - Polycam Camera JSONs

    private func writePolycamCameras(to directory: URL) {
        guard globalIntrinsics != nil,
              let camerasDir = camerasDir else { return }

        for frame in frames {
            let mat = frame.transform
            let paddedIndex = String(format: "%05d", frame.index)

            // Polycam uses t_00..t_23 (3×4 flattened, row-major, omitting last row [0,0,0,1])
            // ARKit transform is column-major, so we transpose.
            // Intrinsics/dimensions are per-frame: hi-res keyframes are captured at native
            // photo resolution, larger than the video-stream frames.
            var cameraJSON: [String: Any] = [
                "t_00": mat.columns.0.x, "t_01": mat.columns.1.x, "t_02": mat.columns.2.x, "t_03": mat.columns.3.x,
                "t_10": mat.columns.0.y, "t_11": mat.columns.1.y, "t_12": mat.columns.2.y, "t_13": mat.columns.3.y,
                "t_20": mat.columns.0.z, "t_21": mat.columns.1.z, "t_22": mat.columns.2.z, "t_23": mat.columns.3.z,
                "fx": frame.intrinsics.fx,
                "fy": frame.intrinsics.fy,
                "cx": frame.intrinsics.cx,
                "cy": frame.intrinsics.cy,
                "width": frame.width,
                "height": frame.height,
                "blur_score": 1.0, // frames passed blur rejection are assumed sharp
                "image_path": "images/frame_\(paddedIndex).jpg"
            ]
            if frame.isKeyframe { cameraJSON["is_keyframe"] = true }
            // Measured keyframe quality (blur_score's semantics are left untouched for
            // compatibility; these are additive keys).
            if let sharpness = frame.sharpness { cameraJSON["sharpness"] = sharpness }
            if let exposure = frame.exposureDuration { cameraJSON["exposure_duration_s"] = exposure }
            // Reference depth/confidence only when the file was actually written for this frame.
            if frame.hasDepth { cameraJSON["depth_path"] = "depth/frame_\(paddedIndex).png" }
            if frame.hasConfidence { cameraJSON["confidence_path"] = "confidence/frame_\(paddedIndex).png" }

            let jsonPath = camerasDir.appendingPathComponent("frame_\(paddedIndex).json")
            if let jsonData = try? JSONSerialization.data(withJSONObject: cameraJSON, options: .prettyPrinted) {
                try? jsonData.write(to: jsonPath)
            }
        }

        // Write mesh_info.json with basic metadata
        let meshInfo: [String: Any] = [
            "num_frames": frames.count,
            "image_width": imageWidth,
            "image_height": imageHeight,
            "coordinate_system": "arkit"
        ]
        let meshInfoPath = directory.appendingPathComponent("mesh_info.json")
        if let jsonData = try? JSONSerialization.data(withJSONObject: meshInfo, options: .prettyPrinted) {
            try? jsonData.write(to: meshInfoPath)
        }
    }

    // MARK: - Scan4D Metadata

    private func writeScan4DMetadata(to directory: URL) {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        #if DEBUG
        let buildType = "debug"
        #else
        let buildType = "release"
        #endif

        var metadata: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "device": self.cachedDeviceName,
            "hardware_device_model": hardwareDeviceModel,
            "os_name": self.cachedOSName,
            "os_version": self.cachedOSVersion,
            "app_version": appVersion,
            "build_type": buildType
        ]

        if let locId = activeLocationId {
            metadata["location_id"] = locId.uuidString
        }

        if let location = locationManager?.currentLocation {
            metadata["gps_latitude"] = location.coordinate.latitude
            metadata["gps_longitude"] = location.coordinate.longitude
            metadata["gps_altitude"] = location.altitude
            metadata["gps_accuracy"] = location.horizontalAccuracy
        }

        if let heading = locationManager?.bestHeading {
            metadata["compass_heading"] = heading
        }

        let finalAnchors = Self.finalizeAnchors(faceAnchors)
        if !finalAnchors.isEmpty {
            metadata["face_anchors"] = finalAnchors.map { ["x": $0.x, "y": $0.y, "z": $0.z] }
        }

        // Boundary Anchor (Pivot-Point) for spatial stitching
        // Only emit when both transform and ID are present — a random fallback UUID
        // would break downstream stitching/debugging.
        if let anchorTransform = boundaryAnchorTransform,
           let anchorId = boundaryAnchorId {
            var boundaryDict: [String: Any] = [
                "id": anchorId.uuidString,
                // Column-major layout: each inner array is one column of the 4×4 matrix.
                // This matches the transform export convention used by the app.
                "transform": [
                    [anchorTransform.columns.0.x, anchorTransform.columns.0.y, anchorTransform.columns.0.z, anchorTransform.columns.0.w],
                    [anchorTransform.columns.1.x, anchorTransform.columns.1.y, anchorTransform.columns.1.z, anchorTransform.columns.1.w],
                    [anchorTransform.columns.2.x, anchorTransform.columns.2.y, anchorTransform.columns.2.z, anchorTransform.columns.2.w],
                    [anchorTransform.columns.3.x, anchorTransform.columns.3.y, anchorTransform.columns.3.z, anchorTransform.columns.3.w]
                ]
            ]
            if let heading = boundaryAnchorCompassHeading {
                boundaryDict["compass_heading"] = heading
            }
            metadata["boundary_anchor"] = boundaryDict
        }

        // Sharp stillness keyframes (hi-res stills when supported) — counted from the frames
        // array (ioQueue-owned) rather than the main-thread UI counter to avoid a data race.
        metadata["keyframe_count"] = frames.filter { $0.isKeyframe }.count

        // Photo-coverage voxel stats: how much of the depth-scanned geometry was covered
        // by sharp keyframes. Lets the backend triage datasets (low fraction = splat
        // texture quality will be sweep-frame limited).
        if let stats = photoCoverageStats, stats.occupied > 0 {
            metadata["photo_coverage"] = [
                "covered_voxels": stats.covered,
                "occupied_voxels": stats.occupied,
                "fraction": Double(stats.covered) / Double(stats.occupied),
                "voxel_size_m": Double(AppConstants.photoCoverageVoxelSize),
                "mean_still_overlap": stats.meanStillOverlap,
                "standpoint_diversity": stats.standpointDiversity
            ]
        }

        // Privacy filter: lets the export pipeline apply its privacy passes even when zero
        // segmentation masks were saved (e.g. the stencil never became available), instead
        // of inferring the setting from the masks/ directory alone.
        metadata["privacy_filter"] = privacyFilter

        // Semantic labeling: record whether classification was enabled for this session
        let semanticEnabled = UserDefaults.standard.bool(forKey: AppConstants.Key.semanticLabeling)
        metadata["semantic_labeling"] = semanticEnabled
        if semanticEnabled && !semanticClassesDetected.isEmpty {
            metadata["semantic_classes_detected"] = Array(semanticClassesDetected).sorted()
        }

        let jsonPath = directory.appendingPathComponent("scan4d_metadata.json")
        if let jsonData = try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted) {
            try? jsonData.write(to: jsonPath)
        }
    }

    // MARK: - Image Conversion

    private func pixelBufferToJPEG(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: AppConstants.jpegCompressionQuality)
    }

    private func confidenceMapToPNG(_ confidenceBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: confidenceBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.pngData()
    }

    /// Converts a Float32 depth buffer to a 16-bit grayscale PNG (millimeters).
    /// Person masking is deferred to the export pipeline — this saves raw depth only.
    private func depthMapToPNG16(_ depthBuffer: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(depthBuffer)
        let height = CVPixelBufferGetHeight(depthBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthBuffer) else { return nil }

        // Convert float meters to UInt16 millimeters.
        // Reuse a session-scoped buffer to avoid a per-frame allocation. Every pixel is
        // written exactly once below, so stale contents from the previous frame don't leak.
        // Access rows via bytesPerRow stride — CVPixelBuffer may pad rows beyond width*4.
        let count = width * height
        if depthScratch.count != count {
            depthScratch = [UInt16](repeating: 0, count: count)
        }
        let floatsPerRow = bytesPerRow / MemoryLayout<Float32>.stride
        depthScratch.withUnsafeMutableBufferPointer { out in
            let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)
            for y in 0..<height {
                let rowStart = y * floatsPerRow
                let outStart = y * width
                for x in 0..<width {
                    let meters = floatBuffer[rowStart + x]
                    out[outStart + x] = meters.isFinite ? UInt16(min(max(meters * 1000.0, 0), 65535)) : 0
                }
            }
        }

        // Create 16-bit grayscale CGImage
        let data = Data(bytes: depthScratch, count: count * 2)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 16,
                  bitsPerPixel: 16,
                  bytesPerRow: width * 2,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: 0),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }

        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.pngData()
    }

    /// Encodes the ARKit person segmentation stencil as a lightweight grayscale PNG.
    /// The mask is typically 256×192 (matching depth resolution), so the resulting
    /// PNG is ~5-15KB — negligible storage cost. Used by the export pipeline to
    /// apply privacy blur to images and zero person regions in depth maps.
    private func segmentationMaskToPNG(_ mask: CVPixelBuffer) -> Data? {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }

        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        guard let baseAddress = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)

        guard let provider = CGDataProvider(data: Data(bytes: baseAddress, count: bytesPerRow * height) as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 8,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: 0),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }

        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.pngData()
    }

    // MARK: - Boundary Anchor

    /// Records a boundary anchor's transform along with the compass heading at pin-drop time.
    /// Called when the user drops a boundary pin during recording.
    /// GPS is intentionally omitted — indoor accuracy (~5-15m) is useless for
    /// doorway-level alignment. The recorded camera pose provides sub-cm precision,
    /// and session-level GPS already covers coarse "which building" context.
    ///
    /// - Parameters:
    ///   - transform: The camera's world transform at the moment the boundary pin is dropped.
    ///   - id: The ARAnchor identifier.
    ///   - compassHeading: Best available compass heading (true north preferred) at pin-drop time.
    func recordBoundaryAnchor(transform: simd_float4x4, id: UUID, compassHeading: Double?) {
        self.boundaryAnchorTransform = transform
        self.boundaryAnchorId = id
        self.boundaryAnchorCompassHeading = compassHeading

        print("[FrameCapture] Recorded boundary anchor \(id.uuidString) with heading=\(compassHeading ?? -1)")
    }

    /// Cleanup temp files.
    func cleanup() {
        if let dir = captureDir {
            try? FileManager.default.removeItem(at: dir)
        }
        captureDir = nil
    }

    /// Compute how far the camera moved between two transforms (translation distance + rotation).
    private func cameraMovement(from fromTransform: simd_float4x4, to toTransform: simd_float4x4) -> Float {
        let posA = SIMD3<Float>(fromTransform.columns.3.x, fromTransform.columns.3.y, fromTransform.columns.3.z)
        let posB = SIMD3<Float>(toTransform.columns.3.x, toTransform.columns.3.y, toTransform.columns.3.z)
        let translationDist = simd_length(posB - posA)

        // Also account for rotation (dot product of forward vectors)
        let fwdA = SIMD3<Float>(fromTransform.columns.2.x, fromTransform.columns.2.y, fromTransform.columns.2.z)
        let fwdB = SIMD3<Float>(toTransform.columns.2.x, toTransform.columns.2.y, toTransform.columns.2.z)
        let rotationChange = 1.0 - abs(simd_dot(simd_normalize(fwdA), simd_normalize(fwdB)))

        return translationDist + rotationChange * 0.3
    }

    private func resetBlurWarningTimer() {
        blurWarningTimer?.invalidate()
        blurWarningTimer = Timer.scheduledTimer(withTimeInterval: AppConstants.blurWarningTimeout, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.blurWarningReason = nil
            }
        }
    }

    // MARK: - Capture Quality Helpers

    /// Variance of the 3×3 Laplacian over the luma plane — the standard cheap focus/blur
    /// metric (higher = sharper). Samples every `keyframeSharpnessStride`-th pixel (~760K
    /// samples on a 12MP still, a few ms on a background queue); each sample's Laplacian
    /// uses immediate ±1 neighbors so the measure reflects true pixel-level edge energy.
    /// Returns 0 when the buffer isn't the expected bi-planar YCbCr camera format.
    private static func laplacianSharpness(of pixelBuffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        // Luma is plane 0 of the bi-planar YCbCr formats ARKit delivers.
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return 0 }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard width > 2, height > 2 else { return 0 }
        let luma = base.assumingMemoryBound(to: UInt8.self)

        let step = max(1, AppConstants.keyframeSharpnessStride)
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0
        var row = step
        while row < height - 1 {
            let rowStart = row * rowBytes
            var col = step
            while col < width - 1 {
                let center = Int(luma[rowStart + col])
                let lap = 4 * center
                    - Int(luma[rowStart + col - 1]) - Int(luma[rowStart + col + 1])
                    - Int(luma[rowStart - rowBytes + col]) - Int(luma[rowStart + rowBytes + col])
                sum += Double(lap)
                sumSquares += Double(lap * lap)
                count += 1
                col += step
            }
            row += step
        }
        guard count > 0 else { return 0 }
        let mean = sum / Double(count)
        return Float(sumSquares / Double(count) - mean * mean)
    }

    /// Compute the total rotation angle (radians) between two 4×4 pose transforms.
    /// Uses quaternion dot product for a robust, gimbal-lock-free angular delta.
    private func extractRotationAngle(from a: simd_float4x4, to b: simd_float4x4) -> Float {
        let qa = simd_quaternion(a)
        let qb = simd_quaternion(b)
        let dot = abs(simd_dot(qa, qb))
        return 2.0 * acos(min(dot, 1.0))
    }

    /// Whether capture audio (shutter click + chime) is enabled. Defaults to on when unset.
    private var captureAudioOn: Bool {
        (UserDefaults.standard.object(forKey: AppConstants.Key.captureAudioEnabled) as? Bool) ?? true
    }

    /// Shutter click + crisp haptic when a keyframe is captured at a stillness point.
    /// The haptic always fires (people scan with the ringer off); only audio is gated.
    private func playShutterClick() {
        let audioOn = captureAudioOn
        DispatchQueue.main.async {
            self.shutterHaptic.impactOccurred()
            self.shutterHaptic.prepare() // keep the Taptic Engine warm for the next keyframe
            if audioOn { AudioServicesPlaySystemSound(1108) }
        }
    }

    /// Gentle chime + soft haptic when the device enters confirmed stillness.
    private func playStillnessChime() {
        let audioOn = captureAudioOn
        DispatchQueue.main.async {
            self.stillnessHaptic.impactOccurred(intensity: AppConstants.stillnessHapticIntensity)
            self.stillnessHaptic.prepare()
            if audioOn { AudioServicesPlaySystemSound(1057) }
        }
    }
}
