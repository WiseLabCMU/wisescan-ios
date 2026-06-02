import SwiftUI
import ARKit
import Vision
import CoreImage.CIFilterBuiltins

/// Cheap live privacy indicator: draws a red "eye" marker over each detected person region.
/// Driven entirely by ARKit's already-computed `.personSegmentationWithDepth` stencil
/// (`ARFrame.segmentationBuffer`) — NO Vision pass and NO CoreImage render (the old overlay
/// ran a per-tick `.fast` `VNGeneratePersonSegmentationRequest` + pixelate/blend, which competed
/// with VIO). The privacy *guarantee* is the saved-frame blur; this only signals, live, that a
/// person is being detected and masked. AR-only — VR shows person-shaped point-cloud holes.
///
/// # Orientation Architecture
///
/// Getting the privacy overlay to align correctly is non-trivial because THREE independent
/// rendering layers must agree on orientation, and each has its own coordinate system:
///
/// 1. **RealityKit scene** — In AR mode, this is the camera passthrough feed; in VR mode,
///    it's a black background with a live depth point cloud. In both cases, RealityKit
///    internally handles rotation to match the device's interface orientation via
///    `ARCamera.viewMatrix(for:)`.
///
/// 2. **Privacy segmentation overlay** (this view) — Built from the raw `capturedImage`
///    pixel buffer, which is ALWAYS in landscape-right sensor coordinates regardless of
///    device orientation or capture mode (AR/VR). We must rotate the composited mask to
///    match what RealityKit displays.
///
/// 3. **Scene geometry overlays** — In AR mode, these are the mesh wireframe entities;
///    in VR mode, these are the point cloud entities rendered by `PointCloudManager`.
///    Both are world-space RealityKit entities that auto-rotate with the scene.
///
/// The key insight: layers 1 and 3 are handled by RealityKit and auto-rotate in both
/// AR and VR modes. Layer 2 is a SwiftUI overlay on top, so WE must rotate it to match.
/// Getting this wrong causes the pixelation mask to appear offset by 90°/180° from the
/// actual person position.
///
/// ## Current approach (portrait-locked)
///
/// We lock the capture view to portrait via `AppDelegate.orientationLocked` and restrict
/// supported orientations to portrait-only in Info.plist. This means:
/// - Vision processes the raw sensor buffer with `.up` orientation (no reinterpretation)
/// - The mask is composited in sensor-native landscape-right coordinates
/// - `UIImage(orientation: .right)` handles the rotation to portrait for display
///
/// This is the same proven approach used for thumbnail generation in CaptureView.
///
/// ## Important: CIImage.oriented() vs UIImage orientation
///
/// `CIImage.oriented(.right)` physically rotates the pixel data, but its semantics are
/// "correct FROM .right TO .up" — which is 90° CCW, NOT 90° CW. This caused the mask
/// to appear 90° off. Using `UIImage(cgImage:, orientation: .right)` instead lets
/// UIKit/SwiftUI handle the rotation via EXIF metadata, which is more reliable and matches
/// how the rest of the app (thumbnails, exports) handles the sensor→display rotation.
///
/// ## TODO: Apple is deprecating portrait-only on iPad
///
/// iPadOS logs warn:
///   1. "UIRequiresFullScreen will soon be ignored"
///   2. "Support for all orientations will soon be required"
///
/// When Apple enforces this, we will need to:
///   - Re-add runtime orientation detection (UIWindowScene.interfaceOrientation)
///   - Map device orientation → UIImage.Orientation for the overlay rotation
///   - Map device orientation → CGImagePropertyOrientation for Vision (if detection
///     accuracy is affected) and for frame export privacy blurring
///   - Test all four orientations × all rendering layers × both capture modes (AR + VR)
///
/// Additionally, iPadOS Stage Manager allows users to window the app even with
/// UIRequiresFullScreen = YES. This can cause the app to run in a non-standard
/// aspect ratio. The current `.scaledToFill().clipped()` approach handles this
/// gracefully by filling and cropping, but if Apple forces all-orientation support,
/// the overlay rotation will need to adapt dynamically.
///
/// The capture view is locked to portrait, so the sensor image is always landscape-right
/// and we use `UIImage(orientation: .right)` to rotate it for portrait display.
struct PrivacyEyeOverlay: View {
    var arSession: ARSession?
    /// Detected person regions as normalized PORTRAIT-screen rects (top-left origin), refreshed ~10 Hz.
    @State private var regions: [CGRect] = []
    @State private var timer: Timer?
    @State private var isProcessing = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(Array(regions.enumerated()), id: \.offset) { _, r in
                    // Scale the marker to the region, clamped so a tiny speck still reads and a
                    // close-up person doesn't fill the screen.
                    let dim = max(30, min(72, r.width * geo.size.width))
                    Image(systemName: "eye.fill")
                        .font(.system(size: dim * 0.7, weight: .bold))
                        .foregroundStyle(.red)
                        .shadow(color: .black.opacity(0.7), radius: 2)
                        .position(x: r.midX * geo.size.width,
                                  y: r.midY * geo.size.height)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in tick() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !isProcessing else { return } // drop a tick rather than pile up
        // Grab ARKit's existing person stencil and release the ARFrame immediately — only the
        // CVPixelBuffer is retained across the scan (avoids "retaining N ARFrames").
        guard let seg = arSession?.currentFrame?.segmentationBuffer else {
            if !regions.isEmpty { regions = [] } // no person / privacy off → clear markers
            return
        }
        isProcessing = true
        // The stencil is small (~256×192) so the scan is cheap, but keep it off the main thread
        // to leave the capture timer + VIO untouched, then publish portrait-mapped rects.
        DispatchQueue.global(qos: .userInitiated).async {
            let sensorRects = PrivacyBlurUtil.personRegions(in: seg)
            // Map sensor (landscape-right) → portrait (.right, i.e. 90° CW): (u, v) → (1 - v, u).
            // Same rotation the camera passthrough uses (see orientation notes above), so markers
            // land over the person as displayed. Aspect-fill crop is ignored — fine for a coarse
            // indicator, and the actual privacy guarantee is the saved-frame blur.
            let mapped = sensorRects.map { s -> CGRect in
                CGRect(x: 1 - (s.origin.y + s.height),
                       y: s.origin.x,
                       width: s.height,
                       height: s.width)
            }
            DispatchQueue.main.async {
                self.regions = mapped
                self.isProcessing = false
            }
        }
    }
}

// MARK: - Privacy Blurring Utility for Image Export

enum PrivacyBlurUtil {
    /// Shared CoreImage context. Creating a `CIContext` builds the entire Metal render
    /// pipeline + shader cache, which is very expensive, so we create it once and reuse
    /// it across every privacy pass — the live overlay and frame export alike. `CIContext`
    /// is documented thread-safe, so sharing across the capture/export queues is safe.
    nonisolated(unsafe) static let sharedContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Applies pixelation to person regions of JPEG `imageData` and returns their normalized
    /// face center coordinates. On any failure, returns the original `imageData` unchanged.
    nonisolated static func pixelatePersonsAndGetFaceCenters(in imageData: Data, orientation: CGImagePropertyOrientation = .up) -> (Data?, [CGPoint]) {
        guard let uiImage = UIImage(data: imageData),
              let ciImage = CIImage(image: uiImage) else { return (imageData, []) }
        return pixelatePersonsAndGetFaceCenters(ciImage: ciImage, orientation: orientation, fallbackData: imageData)
    }

    /// Core pixelation: runs person segmentation + face detection on `ciImage`, pixelates
    /// detected persons, and JPEG-encodes the result once. Callers that already hold a
    /// CIImage (e.g. a camera/glasses frame) can use this to avoid an extra JPEG
    /// encode→decode round trip. On any failure returns `fallbackData` (nil if none).
    nonisolated static func pixelatePersonsAndGetFaceCenters(ciImage: CIImage, orientation: CGImagePropertyOrientation = .up, fallbackData: Data? = nil) -> (Data?, [CGPoint]) {
        let handler = VNImageRequestHandler(ciImage: ciImage, orientation: orientation, options: [:])

        // 1. Face detection for 3D anchors
        let faceRequest = VNDetectFaceRectanglesRequest()

        // 2. Person segmentation for pixelation
        let segRequest = VNGeneratePersonSegmentationRequest()
        segRequest.qualityLevel = .accurate
        segRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8

        do {
            try handler.perform([faceRequest, segRequest])
        } catch {
            return (fallbackData, [])
        }

        // Get face centers
        var faceCenters: [CGPoint] = []
        if let faceResults = faceRequest.results {
            for face in faceResults {
                let box = face.boundingBox
                // Vision origin is bottom-left, typically we want top-left UVs for depth map lookup
                let uv = CGPoint(x: box.midX, y: 1.0 - box.midY)
                faceCenters.append(uv)
            }
        }

        // Get person mask
        guard let maskObservation = segRequest.results?.first as? VNPixelBufferObservation else {
            return (fallbackData, faceCenters) // no mask found, return fallback
        }

        let maskCI = CIImage(cvPixelBuffer: maskObservation.pixelBuffer)
        let imageSize = ciImage.extent

        // Scale mask
        let scaleX = imageSize.width / maskCI.extent.width
        let scaleY = imageSize.height / maskCI.extent.height
        let scaledMask = maskCI.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Pixelate original image (typed builtin avoids per-call string-registry lookup)
        let pixelate = CIFilter.pixellate()
        pixelate.inputImage = ciImage
        pixelate.scale = 40.0
        guard let pixelatedCI = pixelate.outputImage else { return (fallbackData, faceCenters) }

        // Blend pixelated image over original using the person mask
        let blend = CIFilter.blendWithMask()
        blend.inputImage = pixelatedCI
        blend.backgroundImage = ciImage
        blend.maskImage = scaledMask
        guard let outputCI = blend.outputImage else { return (fallbackData, faceCenters) }

        guard let cgImage = sharedContext.createCGImage(outputCI, from: imageSize) else { return (fallbackData, faceCenters) }

        // The exported JPEG remains strictly .up (physical LandscapeRight)
        return (UIImage(cgImage: cgImage).jpegData(compressionQuality: AppConstants.jpegCompressionQuality), faceCenters)
    }

    /// Pixelates person regions in a camera `pixelBuffer` using a PRE-COMPUTED segmentation
    /// stencil (ARKit's `.personSegmentationWithDepth` buffer) instead of running a second,
    /// expensive `.accurate` `VNGeneratePersonSegmentationRequest`. ARKit already produced this
    /// mask for the live point-cloud exclusion and the saved depth-map cutout, so reusing it
    /// here is effectively free and keeps coverage consistent across all three outputs.
    ///
    /// Returns the blurred JPEG plus a sparse set of normalized person-region centroids
    /// (top-left origin) for 3D anchoring — the caller unprojects + clusters these into
    /// per-person anchors (see `AppConstants.faceClusterThresholdMeters`, now body-sized).
    ///
    /// The saved JPEG and the stencil are both in sensor-native (landscape-right) coordinates,
    /// so no orientation transform is needed; display rotation is handled downstream.
    nonisolated static func pixelatePersonsWithMask(pixelBuffer: CVPixelBuffer, mask: CVPixelBuffer) -> (Data?, [CGPoint]) {
        // Blur directly from the camera buffer and encode the JPEG ONCE — the capture path no
        // longer does a plain-encode → decode → re-encode round trip when privacy is on.
        return pixelatePersonsWithMask(ciImage: CIImage(cvPixelBuffer: pixelBuffer), mask: mask)
    }

    private nonisolated static func pixelatePersonsWithMask(ciImage: CIImage, mask: CVPixelBuffer) -> (Data?, [CGPoint]) {
        let imageSize = ciImage.extent
        let maskCI = CIImage(cvPixelBuffer: mask)

        // Scale the (lower-res) stencil up to the image size.
        let scaleX = imageSize.width / maskCI.extent.width
        let scaleY = imageSize.height / maskCI.extent.height
        var scaledMask = maskCI.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Dilate slightly so we never UNDER-cover a person versus the old Vision mask. The
        // region is pixelated anyway, so over-covering by a few px is harmless, and this guards
        // against the stencil's coarser edges.
        let dilate = CIFilter.morphologyMaximum()
        dilate.inputImage = scaledMask
        dilate.radius = 12
        if let dilated = dilate.outputImage {
            scaledMask = dilated.cropped(to: imageSize)
        }

        let pixelate = CIFilter.pixellate()
        pixelate.inputImage = ciImage
        pixelate.scale = 40.0
        guard let pixelatedCI = pixelate.outputImage else { return (nil, []) }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = pixelatedCI
        blend.backgroundImage = ciImage
        blend.maskImage = scaledMask
        guard let outputCI = blend.outputImage,
              let cgImage = sharedContext.createCGImage(outputCI, from: imageSize) else { return (nil, []) }

        let centers = personCentroids(in: mask)
        return (UIImage(cgImage: cgImage).jpegData(compressionQuality: AppConstants.jpegCompressionQuality), centers)
    }

    /// Sparse normalized centroids (top-left origin) of person-labeled regions in a
    /// segmentation stencil. Bins person pixels into a coarse grid and emits one centroid per
    /// occupied cell; the caller's 3D clustering then merges cells of the same person into a
    /// single anchor at the body-sized threshold. Cheap — one strided pass over the stencil.
    private nonisolated static func personCentroids(in mask: CVPixelBuffer) -> [CGPoint] {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return [] }
        let w = CVPixelBufferGetWidth(mask)
        let h = CVPixelBufferGetHeight(mask)
        guard w > 0, h > 0 else { return [] }
        let stride = CVPixelBufferGetBytesPerRow(mask)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let cols = 6, rows = 8
        var sumX = [Float](repeating: 0, count: cols * rows)
        var sumY = [Float](repeating: 0, count: cols * rows)
        var cnt = [Int](repeating: 0, count: cols * rows)
        let step = 4 // sample every 4th pixel for speed
        var y = 0
        while y < h {
            let row = ptr + y * stride
            var x = 0
            while x < w {
                if row[x] > 128 {
                    let cx = min(cols - 1, x * cols / w)
                    let cy = min(rows - 1, y * rows / h)
                    let idx = cy * cols + cx
                    sumX[idx] += Float(x); sumY[idx] += Float(y); cnt[idx] += 1
                }
                x += step
            }
            y += step
        }

        var centers: [CGPoint] = []
        let minCount = 8 // ignore tiny specks / noise
        for i in 0..<(cols * rows) where cnt[i] >= minCount {
            let ux = (sumX[i] / Float(cnt[i])) / Float(w)
            let uy = (sumY[i] / Float(cnt[i])) / Float(h)
            centers.append(CGPoint(x: CGFloat(ux), y: CGFloat(uy)))
        }
        return centers
    }

    /// Merged person regions (normalized sensor coords, top-left origin) from a segmentation
    /// stencil — drives the live red-eye indicator. Bins person pixels into the same coarse grid
    /// as `personCentroids`, then unions adjacent occupied cells (4-connectivity) so each physical
    /// person yields roughly one region rather than a swarm of per-cell markers. Cheap: one strided
    /// pass + a tiny connected-components merge over the ≤48-cell grid. No Vision, no render.
    nonisolated static func personRegions(in mask: CVPixelBuffer) -> [CGRect] {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return [] }
        let w = CVPixelBufferGetWidth(mask)
        let h = CVPixelBufferGetHeight(mask)
        guard w > 0, h > 0 else { return [] }
        let stride = CVPixelBufferGetBytesPerRow(mask)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let cols = 6, rows = 8
        var cnt = [Int](repeating: 0, count: cols * rows)
        let step = 4 // sample every 4th pixel for speed
        var y = 0
        while y < h {
            let row = ptr + y * stride
            var x = 0
            while x < w {
                if row[x] > 128 {
                    let cx = min(cols - 1, x * cols / w)
                    let cy = min(rows - 1, y * rows / h)
                    cnt[cy * cols + cx] += 1
                }
                x += step
            }
            y += step
        }

        let minCount = 8 // ignore tiny specks / noise
        let occupied = (0..<(cols * rows)).map { cnt[$0] >= minCount }

        // Union-find over occupied cells (4-connectivity) so one person = one region.
        var parent = Array(0..<(cols * rows))
        func find(_ a: Int) -> Int {
            var r = a
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for cy in 0..<rows {
            for cx in 0..<cols {
                let i = cy * cols + cx
                guard occupied[i] else { continue }
                if cx + 1 < cols, occupied[i + 1] { union(i, i + 1) }
                if cy + 1 < rows, occupied[i + cols] { union(i, i + cols) }
            }
        }

        // Bounding box (in grid space) per cluster.
        var minCX = [Int: Int](), minCY = [Int: Int](), maxCX = [Int: Int](), maxCY = [Int: Int]()
        for cy in 0..<rows {
            for cx in 0..<cols {
                let i = cy * cols + cx
                guard occupied[i] else { continue }
                let r = find(i)
                minCX[r] = min(minCX[r] ?? cx, cx); maxCX[r] = max(maxCX[r] ?? cx, cx)
                minCY[r] = min(minCY[r] ?? cy, cy); maxCY[r] = max(maxCY[r] ?? cy, cy)
            }
        }

        return minCX.keys.map { r in
            let x0 = CGFloat(minCX[r]!) / CGFloat(cols)
            let y0 = CGFloat(minCY[r]!) / CGFloat(rows)
            let x1 = CGFloat(maxCX[r]! + 1) / CGFloat(cols)
            let y1 = CGFloat(maxCY[r]! + 1) / CGFloat(rows)
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
    }
}
