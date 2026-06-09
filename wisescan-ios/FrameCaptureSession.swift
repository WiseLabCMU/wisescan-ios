import Foundation
import ARKit
import UIKit
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

    private let ioQueue = DispatchQueue(label: "com.scan4d.capture.io", qos: .userInitiated)
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
    }

    struct CameraIntrinsics {
        let fx: Float
        let fy: Float
        let cx: Float
        let cy: Float
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

        try? FileManager.default.createDirectory(at: imagesPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: proxyImagesPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: depthPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: camerasPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: confidencePath, withIntermediateDirectories: true)

        self.captureDir = tempDir
        self.imagesDir = imagesPath
        self.proxyImagesDir = proxyImagesPath
        self.depthDir = depthPath
        self.camerasDir = camerasPath
        self.confidenceDir = confidencePath
        self.frames = []
        self.frameCount = 0
        self.globalIntrinsics = nil
        self.lastCaptureTransform = nil
        self.blurWarningReason = nil
        self.consecutiveBlurredFrames = 0
        self.blurWarningTimer?.invalidate()
        self.blurWarningTimer = nil
        self.overlapMax = overlapMax
        self.rejectBlur = rejectBlur
        self.privacyFilter = privacyFilter
        self.faceAnchors = []
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
    }

    /// Abandon the in-progress capture without finalizing: stop the timer and delete the capture
    /// directory (queued on ioQueue so it runs after any in-flight frame saves drain).
    func discardCapture() {
        timer?.invalidate()
        timer = nil
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

        // Reject blurred frames based on camera tracking quality
        if rejectBlur && !isMockingIMU {
            var warning: CaptureWarning?

            // Tracking dropped out of .normal (limited / excessive motion / relocalizing): frames
            // here are unreliable. The fix is to hold steady & let tracking recover — NOT necessarily
            // to slow down — so this is reported as a distinct cause from genuine fast motion.
            if let state = trackingState, state != .normal {
                warning = .trackingLost
            }

            // Otherwise, the camera pose moved too fast since the last capture (motion blur likely).
            // Heuristic from pose velocity, not a pixel-sharpness measurement.
            if warning == nil, let lastTransform = lastCaptureTransform {
                let timeDelta = frameTimestamp - lastCaptureTime
                if timeDelta > 0 {
                    let movement = cameraMovement(from: lastTransform, to: transform)
                    let velocity = movement / Float(timeDelta)
                    if velocity > AppConstants.motionBlurVelocity {
                        warning = .fastMotion
                    }
                }
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

        lastCaptureTransform = transform
        lastCaptureTime = frameTimestamp

        let currentIndex = self.testSequenceIndex
        self.testSequenceIndex += 1 // Increment sequence index for synthetic progression

        processAndSaveFrame(
            pixelBuffer: pixelBuffer,
            camW: camW,
            camH: camH,
            transform: transform,
            intrinsics: intrinsics,
            depthMap: depthMap,
            confidenceMap: confidenceMap,
            segBuffer: segBuffer,
            currentIndex: currentIndex
        )
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

    private func processAndSaveFrame(
        pixelBuffer: CVPixelBuffer?,
        camW: Int,
        camH: Int,
        transform: simd_float4x4,
        intrinsics: simd_float3x3,
        depthMap: CVPixelBuffer?,
        confidenceMap: CVPixelBuffer?,
        segBuffer: CVPixelBuffer?,
        currentIndex: Int
    ) {
        // Backlog guard: if frame encodes are falling behind, DROP this frame instead of piling
        // up retained CVPixelBuffers. That pile-up is what starves ARKit's frame pool ("retaining
        // N ARFrames") and ultimately stalls/loses VIO tracking — and any data captured after VIO
        // loss is corrupt. Capture is movement-gated, so the next motion re-triggers a save.
        // Admit-and-increment atomically; the ioQueue closure decrements in its defer.
        let admittedDepth: Int? = inFlightSaves.withLock { count -> Int? in
            guard count < AppConstants.maxFramesInFlight else { return nil }
            count += 1
            return count
        }
        guard let depth = admittedDepth else {
            if PerfDiag.enabled { PerfDiag.log("capture frame DROPPED — backlog at cap (\(AppConstants.maxFramesInFlight))") }
            return
        }
        if PerfDiag.enabled && depth > 1 { PerfDiag.log("capture I/O backlog: \(depth) frames in flight") }
        ioQueue.async { [weak self] in
            defer { self?.inFlightSaves.withLock { $0 -= 1 } }
            guard let self = self, let imagesDir = self.imagesDir else { return }

            // Depth is optional — LiDAR devices get depth, others just capture images + poses
            var validDepthData: Data?
            if self.isMockingDepth {
                validDepthData = TestDataGenerator.generateDepthMap(for: currentIndex, w: camW, h: camH)
            } else if let dMap = depthMap {
                let depthFormat = CVPixelBufferGetPixelFormatType(dMap)
                guard depthFormat == kCVPixelFormatType_DepthFloat32 else {
                    print("[FrameCapture] Unexpected depth format: \(depthFormat), skipping depth")
                    return
                }
                validDepthData = PerfDiag.timed("depth_png16", warnOverMs: 50) { self.depthMapToPNG16(dMap, personMask: segBuffer) }
            }

            var finalJpegData: Data
            if self.isMockingImages {
                finalJpegData = TestDataGenerator.generateImage(for: currentIndex, w: camW, h: camH, transform: transform, intrinsics: intrinsics)
            } else {
                guard let pBuf = pixelBuffer else { return }
                if self.privacyFilter, let segBuffer = segBuffer {
                    // Blur directly from the camera buffer and encode the JPEG ONCE (no plain
                    // encode → decode → re-encode), using ARKit's existing person-segmentation
                    // stencil — the same buffer behind the depth cutout + live point-cloud holes.
                    // The redundant .accurate Vision pass (180–360ms/frame) is gone; it was the
                    // dominant capture-side cause of ioQueue backlog + ARFrame-pool starvation.
                    // Also yields person-region centroids for 3D anchoring.
                    let (blurredData, centers) = PerfDiag.timed("privacy_blur_mask", warnOverMs: 50) {
                        PrivacyBlurUtil.pixelatePersonsWithMask(pixelBuffer: pBuf, mask: segBuffer)
                    }
                    guard let bData = blurredData else { return }
                    finalJpegData = bData

                    // Unproject person-region centers to 3D using depth map (only if depth available)
                    if !centers.isEmpty, let dMap = depthMap {
                        let depthWidth = CVPixelBufferGetWidth(dMap)
                        let depthHeight = CVPixelBufferGetHeight(dMap)
                        let imgWidth = Float(camW)
                        let imgHeight = Float(camH)

                        CVPixelBufferLockBaseAddress(dMap, .readOnly)
                        if let base = CVPixelBufferGetBaseAddress(dMap)?.assumingMemoryBound(to: Float32.self) {
                            // Accumulate into a local copy to avoid data race with main thread
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

                                // Cluster merging — weighted by observation count so the merged
                                // position converges on the true centroid (not biased toward the
                                // most recent point, as a flat 0.5 blend was), and the weight
                                // records how many frames saw this person (its confidence).
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
                            // Publish updated anchors on main thread
                            let updatedAnchors = localAnchors
                            DispatchQueue.main.async {
                                self.faceAnchors = updatedAnchors
                            }
                        }
                        CVPixelBufferUnlockBaseAddress(dMap, .readOnly)
                    }
                } else if self.privacyFilter {
                    // Privacy is ON but ARKit's person stencil was unavailable for this frame —
                    // either the device doesn't support .personSegmentationWithDepth, or it's a
                    // momentary gap right after the session (re)starts. Fall back to the (slower)
                    // Vision person-segmentation blur so we never leave a detected person unblurred.
                    // The plain encode is passed as the fallback: a frame with no person (or a
                    // failed Vision pass) still saves, but any detected person is pixelated.
                    let plain = PerfDiag.timed("jpeg_encode", warnOverMs: 50) { self.pixelBufferToJPEG(pBuf) }
                    let (blurredData, _) = PerfDiag.timed("privacy_blur_vision_fallback", warnOverMs: 100) {
                        PrivacyBlurUtil.pixelatePersonsAndGetFaceCenters(ciImage: CIImage(cvPixelBuffer: pBuf), fallbackData: plain)
                    }
                    guard let bData = blurredData else { return }
                    finalJpegData = bData
                } else {
                    // No privacy filter: plain single JPEG encode.
                    guard let jpegData = PerfDiag.timed("jpeg_encode", warnOverMs: 50, { self.pixelBufferToJPEG(pBuf) }) else { return }
                    finalJpegData = jpegData
                }
            }

        let index = self.frames.count
            let paddedIndex = String(format: "%05d", index)
            let rgbPath = imagesDir.appendingPathComponent("frame_\(paddedIndex).jpg")

            do {
                try finalJpegData.write(to: rgbPath, options: .atomic)
                if let depthData = validDepthData, let depthDir = self.depthDir {
                    let depthPath = depthDir.appendingPathComponent("frame_\(paddedIndex).png")
                    try depthData.write(to: depthPath, options: .atomic)
                }

                if let confMap = confidenceMap, let confData = PerfDiag.timed("confidence_png", warnOverMs: 40, { self.confidenceMapToPNG(confMap) }), let confDir = self.confidenceDir {
                    let confPath = confDir.appendingPathComponent("frame_\(paddedIndex).png")
                    try confData.write(to: confPath, options: .atomic)
                }

                if self.globalIntrinsics == nil {
                    self.imageWidth = camW
                    self.imageHeight = camH
                    self.globalIntrinsics = CameraIntrinsics(
                        fx: intrinsics[0][0],
                        fy: intrinsics[1][1],
                        cx: intrinsics[2][0],
                        cy: intrinsics[2][1]
                    )
                }

                self.frames.append(FrameData(index: index, transform: transform))
                let newlyAddedCount = self.frames.count

                DispatchQueue.main.async {
                    self.frameCount = newlyAddedCount
                }
            } catch {
                try? FileManager.default.removeItem(at: rgbPath)
            }
        }
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
            let entry: [String: Any] = [
                "file_path": "images/frame_\(paddedIndex).jpg",
                "depth_file_path": "depth/frame_\(paddedIndex).png",
                "confidence_file_path": "confidence/frame_\(paddedIndex).png",
                "transform_matrix": [
                    [mat.columns.0.x, mat.columns.0.y, mat.columns.0.z, mat.columns.0.w],
                    [mat.columns.1.x, mat.columns.1.y, mat.columns.1.z, mat.columns.1.w],
                    [mat.columns.2.x, mat.columns.2.y, mat.columns.2.z, mat.columns.2.w],
                    [mat.columns.3.x, mat.columns.3.y, mat.columns.3.z, mat.columns.3.w]
                ]
            ]
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
        guard let intrinsics = globalIntrinsics,
              let camerasDir = camerasDir else { return }

        for frame in frames {
            let mat = frame.transform
            let paddedIndex = String(format: "%05d", frame.index)

            // Polycam uses t_00..t_23 (3×4 flattened, row-major, omitting last row [0,0,0,1])
            // ARKit transform is column-major, so we transpose
            let cameraJSON: [String: Any] = [
                "t_00": mat.columns.0.x, "t_01": mat.columns.1.x, "t_02": mat.columns.2.x, "t_03": mat.columns.3.x,
                "t_10": mat.columns.0.y, "t_11": mat.columns.1.y, "t_12": mat.columns.2.y, "t_13": mat.columns.3.y,
                "t_20": mat.columns.0.z, "t_21": mat.columns.1.z, "t_22": mat.columns.2.z, "t_23": mat.columns.3.z,
                "fx": intrinsics.fx,
                "fy": intrinsics.fy,
                "cx": intrinsics.cx,
                "cy": intrinsics.cy,
                "width": imageWidth,
                "height": imageHeight,
                "blur_score": 1.0, // frames passed blur rejection are assumed sharp
                "image_path": "images/frame_\(paddedIndex).jpg",
                "depth_path": "depth/frame_\(paddedIndex).png",
                "confidence_path": "confidence/frame_\(paddedIndex).png"
            ]

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

        // Semantic labeling: record whether classification was enabled for this session
        let semanticEnabled = UserDefaults.standard.bool(forKey: AppConstants.Key.semanticLabeling)
        metadata["semantic_labeling"] = semanticEnabled

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

    private func depthMapToPNG16(_ depthBuffer: CVPixelBuffer, personMask: CVPixelBuffer? = nil) -> Data? {
        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(depthBuffer)
        let height = CVPixelBufferGetHeight(depthBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthBuffer) else { return nil }

        let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)

        // Read person segmentation mask if provided
        var maskBase: UnsafeMutableRawPointer?
        var maskWidth = 0, maskHeight = 0, maskStride = 0
        if let mask = personMask {
            CVPixelBufferLockBaseAddress(mask, .readOnly)
            maskBase = CVPixelBufferGetBaseAddress(mask)
            maskWidth = CVPixelBufferGetWidth(mask)
            maskHeight = CVPixelBufferGetHeight(mask)
            maskStride = CVPixelBufferGetBytesPerRow(mask)
        }

        // Convert float meters to UInt16 millimeters, zeroing person regions.
        // Reuse a session-scoped buffer to avoid a per-frame allocation. Every pixel is
        // written exactly once below, so stale contents from the previous frame don't leak.
        // (Kept scalar: vDSP float→uint16 mishandles NaN/inf/negative depth, and the
        // per-pixel person mask isn't vectorizable; the PNG encode dominates this function.)
        let count = width * height
        if depthScratch.count != count {
            depthScratch = [UInt16](repeating: 0, count: count)
        }
        depthScratch.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x

                    // Check person mask (scale coordinates if sizes differ)
                    if let mBase = maskBase {
                        let mx = x * maskWidth / max(width, 1)
                        let my = y * maskHeight / max(height, 1)
                        if mx < maskWidth && my < maskHeight {
                            let pixel = mBase.advanced(by: my * maskStride + mx).assumingMemoryBound(to: UInt8.self).pointee
                            if pixel > 128 {
                                out[i] = 0 // zero out person region
                                continue
                            }
                        }
                    }

                    let meters = floatBuffer[i]
                    out[i] = meters.isFinite ? UInt16(min(max(meters * 1000.0, 0), 65535)) : 0
                }
            }
        }

        if personMask != nil {
            CVPixelBufferUnlockBaseAddress(personMask!, .readOnly)
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
}
