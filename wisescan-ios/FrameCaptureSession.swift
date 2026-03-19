import Foundation
import ARKit
import UIKit
import Observation

/// Captures RGB frames, depth maps, and camera poses during an AR recording session.
@Observable
class FrameCaptureSession {
    private(set) var frameCount = 0
    private(set) var captureDir: URL?
    private var timer: Timer?
    private var imagesDir: URL?
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

    // Blur Warning logic
    private(set) var isBlurWarningActive: Bool = false
    private var blurWarningTimer: Timer?
    private var consecutiveBlurredFrames: Int = 0

    // Privacy logic
    private(set) var faceAnchors: [SIMD3<Float>] = []

    // Metadata dependencies
    private var locationManager: LocationManager?
    private var activeLocationId: UUID?

    private let ioQueue = DispatchQueue(label: "com.wisescan.capture.io", qos: .userInitiated)

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
    func start(session: ARSession, overlapMax: Double = 60.0, rejectBlur: Bool = true, privacyFilter: Bool = false, locationManager: LocationManager? = nil, activeLocationId: UUID? = nil) {
        // Create temp directory for this capture
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan4d_raw_\(UUID().uuidString)", isDirectory: true)
        let imagesPath = tempDir.appendingPathComponent("images", isDirectory: true)
        let depthPath = tempDir.appendingPathComponent("depth", isDirectory: true)
        let camerasPath = tempDir.appendingPathComponent("cameras", isDirectory: true)
        let confidencePath = tempDir.appendingPathComponent("confidence", isDirectory: true)

        try? FileManager.default.createDirectory(at: imagesPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: depthPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: camerasPath, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: confidencePath, withIntermediateDirectories: true)

        self.captureDir = tempDir
        self.imagesDir = imagesPath
        self.depthDir = depthPath
        self.camerasDir = camerasPath
        self.confidenceDir = confidencePath
        self.frames = []
        self.frameCount = 0
        self.globalIntrinsics = nil
        self.lastCaptureTransform = nil
        self.isBlurWarningActive = false
        self.consecutiveBlurredFrames = 0
        self.blurWarningTimer?.invalidate()
        self.blurWarningTimer = nil
        self.overlapMax = overlapMax
        self.rejectBlur = rejectBlur
        self.privacyFilter = privacyFilter
        self.faceAnchors = []
        self.lastCaptureTime = 0
        self.locationManager = locationManager
        self.activeLocationId = activeLocationId

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
            // Write Nerfstudio transforms.json
            self.writeTransformsJSON(to: captureDir)

            // Write Polycam per-frame camera JSONs
            self.writePolycamCameras(to: captureDir)

            // Write Scan4D ground-truth metadata
            self.writeScan4DMetadata(to: captureDir)
        }

        return captureDir
    }

    private func captureFrame(from session: ARSession) {
        guard let currentFrame = session.currentFrame else { return }

        // Capture on background thread to avoid blocking AR
        let pixelBuffer = currentFrame.capturedImage
        let transform = currentFrame.camera.transform
        let intrinsics = currentFrame.camera.intrinsics
        let depthMap = currentFrame.sceneDepth?.depthMap

        // Reject blurred frames based on camera tracking quality
        if rejectBlur {
            var isBlurred = false
            
            // Skip if tracking is not normal (e.g. limited, excessive motion)
            if currentFrame.camera.trackingState != .normal {
                isBlurred = true
            }
            
            // Skip if camera moved too fast since last capture (motion blur likely)
            if !isBlurred, let lastTransform = lastCaptureTransform {
                let timeDelta = currentFrame.timestamp - lastCaptureTime
                if timeDelta > 0 {
                    let movement = cameraMovement(from: lastTransform, to: transform)
                    let velocity = movement / Float(timeDelta)
                    // If moving faster than ~0.5m/s, likely blurred
                    if velocity > 0.5 {
                        isBlurred = true
                    }
                }
            }
            
            if isBlurred {
                // Increment blurred frame counter
                consecutiveBlurredFrames += 1
                
                // If we get several blurred frames in a row, trigger the warning
                if consecutiveBlurredFrames >= 5 && !isBlurWarningActive {
                    DispatchQueue.main.async {
                        self.isBlurWarningActive = true
                        self.resetBlurWarningTimer()
                    }
                }
                return
            } else {
                // Valid frame, reset blur counter
                consecutiveBlurredFrames = 0
            }
        }

        // Skip frame if camera hasn't moved enough (based on overlap setting)
        if let lastTransform = lastCaptureTransform {
            let movement = cameraMovement(from: lastTransform, to: transform)
            // Higher overlap = smaller movement threshold = more frames
            // overlapMax 100% → threshold ~0.01m (capture almost everything)
            // overlapMax 10%  → threshold ~0.15m (only distinct views)
            let threshold = Float(0.15 * (1.0 - overlapMax / 100.0)) + 0.01
            if movement < threshold {
                return // skip — too much overlap with previous frame
            }
        }

        lastCaptureTransform = transform
        lastCaptureTime = currentFrame.timestamp
        let segBuffer = self.privacyFilter ? currentFrame.segmentationBuffer : nil

        ioQueue.async { [weak self] in
            guard let self = self, let imagesDir = self.imagesDir, let depthDir = self.depthDir else { return }

            guard let dMap = depthMap,
                  let jpegData = self.pixelBufferToJPEG(pixelBuffer),
                  let depthData = self.depthMapToPNG16(dMap, personMask: segBuffer) else {
                return
            }
            
            var finalJpegData = jpegData
            if self.privacyFilter {
                let (blurredData, centers) = FaceBlurUtil.blurFacesAndGetCenters(in: jpegData)
                if let bData = blurredData {
                    finalJpegData = bData
                }
                
                // Unproject face centers to 3D using depth map
                if !centers.isEmpty {
                    let depthWidth = CVPixelBufferGetWidth(dMap)
                    let depthHeight = CVPixelBufferGetHeight(dMap)
                    let imgWidth = Float(CVPixelBufferGetWidth(pixelBuffer))
                    let imgHeight = Float(CVPixelBufferGetHeight(pixelBuffer))
                    
                    CVPixelBufferLockBaseAddress(dMap, .readOnly)
                    if let base = CVPixelBufferGetBaseAddress(dMap)?.assumingMemoryBound(to: Float32.self) {
                        for uv in centers {
                            let px = Int(uv.x * CGFloat(depthWidth))
                            let py = Int(uv.y * CGFloat(depthHeight))
                            let clampedX = min(max(px, 0), depthWidth - 1)
                            let clampedY = min(max(py, 0), depthHeight - 1)
                            
                            let z = base[clampedY * depthWidth + clampedX]
                            if z > 0 && z < 10.0 { // reasonable face distance limit
                                let fx = intrinsics[0][0]
                                let fy = intrinsics[1][1]
                                let cx = intrinsics[2][0]
                                let cy = intrinsics[2][1]
                                
                                let x_cam = (Float(uv.x) * imgWidth - cx) * z / fx
                                let y_cam = (Float(uv.y) * imgHeight - cy) * z / fy
                                let z_cam = -z
                                
                                let localPoint = SIMD4<Float>(x_cam, y_cam, z_cam, 1.0)
                                let worldPoint = transform * localPoint
                                let point3D = SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)
                                
                                // Simple cluster merging
                                var found = false
                                for i in 0..<self.faceAnchors.count {
                                    if simd_distance(self.faceAnchors[i], point3D) < 0.3 {
                                        self.faceAnchors[i] = (self.faceAnchors[i] + point3D) * 0.5
                                        found = true
                                        break
                                    }
                                }
                                if !found {
                                    self.faceAnchors.append(point3D)
                                }
                            }
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(dMap, .readOnly)
                }
            }
            
            let index = self.frames.count
            let paddedIndex = String(format: "%05d", index)
            let rgbPath = imagesDir.appendingPathComponent("frame_\(paddedIndex).jpg")
            let depthPath = depthDir.appendingPathComponent("frame_\(paddedIndex).png")
            
            do {
                try finalJpegData.write(to: rgbPath, options: .atomic)
                try depthData.write(to: depthPath, options: .atomic)
                
                let imgWidth = CVPixelBufferGetWidth(pixelBuffer)
                let imgHeight = CVPixelBufferGetHeight(pixelBuffer)
                
                if self.globalIntrinsics == nil {
                    self.imageWidth = imgWidth
                    self.imageHeight = imgHeight
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
                try? FileManager.default.removeItem(at: depthPath)
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
                "depth_path": "depth/frame_\(paddedIndex).png"
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
            "device": UIDevice.current.name,
            "os_name": UIDevice.current.systemName,
            "os_version": UIDevice.current.systemVersion,
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

        if let heading = locationManager?.currentHeading {
            metadata["compass_heading"] = heading.trueHeading > 0 ? heading.trueHeading : heading.magneticHeading
        }

        if !faceAnchors.isEmpty {
            metadata["face_anchors"] = faceAnchors.map { [$0.x, $0.y, $0.z] }
        }

        let jsonPath = directory.appendingPathComponent("scan4d_metadata.json")
        if let jsonData = try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted) {
            try? jsonData.write(to: jsonPath)
        }
    }

    // MARK: - Image Conversion

    private func pixelBufferToJPEG(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: 0.85)
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

        // Convert float meters to UInt16 millimeters, zeroing person regions
        var uint16Buffer = [UInt16](repeating: 0, count: width * height)
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
                            uint16Buffer[i] = 0 // zero out person region
                            continue
                        }
                    }
                }

                let meters = floatBuffer[i]
                uint16Buffer[i] = meters.isFinite ? UInt16(min(max(meters * 1000.0, 0), 65535)) : 0
            }
        }

        if personMask != nil {
            CVPixelBufferUnlockBaseAddress(personMask!, .readOnly)
        }

        // Create 16-bit grayscale CGImage
        let data = Data(bytes: uint16Buffer, count: uint16Buffer.count * 2)
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

    /// Cleanup temp files.
    func cleanup() {
        if let dir = captureDir {
            try? FileManager.default.removeItem(at: dir)
        }
        captureDir = nil
    }

    /// Compute how far the camera moved between two transforms (translation distance + rotation).
    private func cameraMovement(from a: simd_float4x4, to b: simd_float4x4) -> Float {
        let posA = SIMD3<Float>(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let posB = SIMD3<Float>(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        let translationDist = simd_length(posB - posA)

        // Also account for rotation (dot product of forward vectors)
        let fwdA = SIMD3<Float>(a.columns.2.x, a.columns.2.y, a.columns.2.z)
        let fwdB = SIMD3<Float>(b.columns.2.x, b.columns.2.y, b.columns.2.z)
        let rotationChange = 1.0 - abs(simd_dot(simd_normalize(fwdA), simd_normalize(fwdB)))

        return translationDist + rotationChange * 0.3
    }
    
    private func resetBlurWarningTimer() {
        blurWarningTimer?.invalidate()
        blurWarningTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.isBlurWarningActive = false
            }
        }
    }
}
