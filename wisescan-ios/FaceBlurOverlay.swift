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
    /// Retained confidence-grid state that temporally smooths the raw per-tick segmentation so the
    /// markers stop popping/skating. `@State` keeps the one instance alive across struct re-creation;
    /// only the (serialized) seg tick touches it, so no locking is needed.
    @State private var tracker = PrivacyEyeTracker()

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
        let seg = arSession?.currentFrame?.segmentationBuffer
        if seg == nil && tracker.isEmpty {
            if !regions.isEmpty { regions = [] } // nothing present and nothing fading → clear markers
            return
        }
        isProcessing = true
        // The stencil is small (~256×192) so the scan is cheap, but keep it off the main thread
        // to leave the capture timer + VIO untouched, then publish portrait-mapped rects.
        DispatchQueue.global(qos: .userInitiated).async {
            // Feed the stencil (or a nil frame) through the confidence grid: occupied cells build
            // toward 1, empty cells decay toward 0, and only cells above threshold emit a region —
            // so a brief blip can't pop a marker in and a brief dropout can't pop one out.
            let sensorRects = tracker.update(mask: seg)
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

/// Retained temporal-coherence state for the live red-eye indicator. The raw `personRegions` scan
/// recomputed occupancy fresh every ~10 Hz tick with no memory, so markers skated and popped as
/// cells flipped near person boundaries. This holds a persistent per-cell **confidence** grid:
/// each tick, person-occupied cells build their confidence toward 1 and empty cells decay toward 0,
/// and only cells above a threshold are rendered. A single threshold on the ramped value gives both
/// behaviors — a cell must be occupied for a few ticks before it locks on (debounces pop-in) and
/// stays lit for a few ticks after the person leaves (debounces pop-out). Per cluster we emit a
/// confidence-WEIGHTED centroid so the marker glides sub-cell as edge confidences ramp, instead of
/// snapping to whole-cell grid boundaries.
///
/// Single-threaded by contract: only the serialized seg tick (`PrivacyEyeOverlay.tick`, gated by
/// `isProcessing`) calls `update`, so the mutable grid needs no synchronization.
final class PrivacyEyeTracker {
    private let cols = 6, rows = 8
    private var confidence: [Float]

    // Tuned for the 0.1 s (10 Hz) tick. Build is faster than decay so a real person locks on
    // quickly (~2 ticks to cross threshold) while a momentary dropout lingers (~5 ticks to fade),
    // which is what kills the flicker. Adjust together if the tick rate changes.
    private let buildRate: Float = 0.35
    private let decayRate: Float = 0.15
    private let onThreshold: Float = 0.5
    private let minCount = 8 // person pixels per cell to count it occupied this tick (ignore specks)
    private let step = 4     // sample every 4th pixel for speed

    init() {
        confidence = [Float](repeating: 0, count: cols * rows)
    }

    /// True once every cell's confidence has decayed back to ~0 — i.e. nothing left to fade out.
    /// Lets the caller stop ticking the grid when there's neither a person nor a lingering marker.
    var isEmpty: Bool {
        !confidence.contains { $0 > 0.01 }
    }

    /// Decay/build the grid from the current stencil (nil = no person this tick → pure decay) and
    /// return merged person regions (normalized sensor coords, top-left origin) for confident cells.
    func update(mask: CVPixelBuffer?) -> [CGRect] {
        let occupiedNow = mask.map { countOccupiedCells(in: $0) } ?? [Bool](repeating: false, count: cols * rows)
        for i in 0..<(cols * rows) {
            if occupiedNow[i] {
                confidence[i] += (1 - confidence[i]) * buildRate
            } else {
                confidence[i] *= (1 - decayRate)
            }
        }
        return regions()
    }

    /// One strided pass over the stencil → which grid cells hold enough person pixels this tick.
    private func countOccupiedCells(in mask: CVPixelBuffer) -> [Bool] {
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        var occupied = [Bool](repeating: false, count: cols * rows)
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return occupied }
        let w = CVPixelBufferGetWidth(mask)
        let h = CVPixelBufferGetHeight(mask)
        guard w > 0, h > 0 else { return occupied }
        let stride = CVPixelBufferGetBytesPerRow(mask)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var cnt = [Int](repeating: 0, count: cols * rows)
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
        for i in 0..<(cols * rows) { occupied[i] = cnt[i] >= minCount }
        return occupied
    }

    /// Merge cells above the confidence threshold (4-connectivity union-find) into one region per
    /// person, each placed at its confidence-weighted centroid for smooth, gliding motion.
    private func regions() -> [CGRect] {
        let on = (0..<(cols * rows)).map { confidence[$0] >= onThreshold }

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
                guard on[i] else { continue }
                if cx + 1 < cols, on[i + 1] { union(i, i + 1) }
                if cy + 1 < rows, on[i + cols] { union(i, i + cols) }
            }
        }

        // Per cluster: grid-space bounding box (→ region size) + confidence-weighted center (→ glide).
        struct Accum { var minCX = Int.max, minCY = Int.max, maxCX = Int.min, maxCY = Int.min
                       var wX: Float = 0, wY: Float = 0, w: Float = 0 }
        var clusters = [Int: Accum]()
        for cy in 0..<rows {
            for cx in 0..<cols {
                let i = cy * cols + cx
                guard on[i] else { continue }
                let r = find(i)
                var a = clusters[r] ?? Accum()
                a.minCX = min(a.minCX, cx); a.maxCX = max(a.maxCX, cx)
                a.minCY = min(a.minCY, cy); a.maxCY = max(a.maxCY, cy)
                let wt = confidence[i]
                a.wX += wt * (Float(cx) + 0.5); a.wY += wt * (Float(cy) + 0.5); a.w += wt
                clusters[r] = a
            }
        }

        return clusters.values.map { a in
            let width = CGFloat(a.maxCX - a.minCX + 1) / CGFloat(cols)
            let height = CGFloat(a.maxCY - a.minCY + 1) / CGFloat(rows)
            // Confidence-weighted center (normalized); the rect is centered on it so the view's
            // midX/midY tracks the smooth centroid while width/height drive marker scaling.
            let cxNorm = CGFloat(a.wX / a.w) / CGFloat(cols)
            let cyNorm = CGFloat(a.wY / a.w) / CGFloat(rows)
            return CGRect(x: cxNorm - width / 2, y: cyNorm - height / 2, width: width, height: height)
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

    /// ONE normalized centroid (top-left origin) per person in a segmentation stencil — the 3D
    /// anchoring counterpart to the live indicator's `PrivacyEyeTracker`. Bins person pixels into
    /// the same coarse grid, then **union-finds adjacent occupied cells** so a person spanning
    /// several cells (head→torso→legs) collapses to a single body-center centroid instead of a
    /// vertical stack of per-cell points. Emitting one centroid per person — rather than per cell —
    /// is what keeps the saved `face_anchors` from fragmenting into widely-spaced anchors that the
    /// 3D merge radius (~body width) can't rejoin once they've unprojected onto separate body parts.
    /// Cheap: one strided pass + a tiny connected-components merge over the ≤48-cell grid.
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

        let minCount = 8 // ignore tiny specks / noise
        let occupied = (0..<(cols * rows)).map { cnt[$0] >= minCount }

        // Union-find over occupied cells (4-connectivity) so one person = one cluster.
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

        // Pixel-weighted centroid per cluster (summed pixel positions, not cell centers, for accuracy).
        var clX = [Int: Float](), clY = [Int: Float](), clN = [Int: Float]()
        for i in 0..<(cols * rows) where occupied[i] {
            let r = find(i)
            clX[r, default: 0] += sumX[i]; clY[r, default: 0] += sumY[i]; clN[r, default: 0] += Float(cnt[i])
        }
        return clN.keys.map { r in
            CGPoint(x: CGFloat(clX[r]! / clN[r]!) / CGFloat(w),
                    y: CGFloat(clY[r]! / clN[r]!) / CGFloat(h))
        }
    }

}
