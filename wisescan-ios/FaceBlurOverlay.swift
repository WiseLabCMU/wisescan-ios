import SwiftUI
import ARKit
import Vision
import CoreImage.CIFilterBuiltins

/// Overlay that detects persons in the AR camera feed and draws a pixelated overlay over them.
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
struct PrivacyBlurOverlay: View {
    var arSession: ARSession?
    @State private var overlayImage: UIImage? = nil
    @State private var timer: Timer?
    // Owns the reused Vision request + serializes work so overlapping timer ticks
    // never share request state and never pile up. Retained for the view's lifetime.
    @State private var processor = PrivacyOverlayProcessor()

    var body: some View {
        GeometryReader { geo in
            if let img = overlayImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        }
        .onAppear { startDetection() }
        .onDisappear { stopDetection() }
    }

    private func startDetection() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            detectAndPixelatePersons()
        }
    }

    private func stopDetection() {
        timer?.invalidate()
        timer = nil
    }

    private func detectAndPixelatePersons() {
        // Extract the pixel buffer immediately and release the ARFrame reference.
        // This prevents ARKit's "retaining N ARFrames" warning caused by holding
        // strong refs while Vision segmentation runs on a background queue.
        guard let pixelBuffer = arSession?.currentFrame?.capturedImage else { return }
        // ARFrame is now released — only the CVPixelBuffer is retained
        processor.process(pixelBuffer: pixelBuffer) { uiImage in
            self.overlayImage = uiImage
        }
    }
}

/// Drives the live privacy overlay segmentation off the main thread.
///
/// Reuses a single `VNGeneratePersonSegmentationRequest` and the shared
/// `PrivacyBlurUtil.sharedContext` across ticks. A re-entrancy guard drops a tick
/// if the previous segmentation is still running, which (a) prevents work from
/// piling up faster than it completes and (b) guarantees only one thread touches
/// the reused request at a time, making the reuse race-free.
private final class PrivacyOverlayProcessor: @unchecked Sendable {
    private let request: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .fast
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    private let lock = NSLock()
    private var isProcessing = false

    func process(pixelBuffer: CVPixelBuffer, completion: @escaping (UIImage?) -> Void) {
        lock.lock()
        if isProcessing { lock.unlock(); return }
        isProcessing = true
        lock.unlock()

        DispatchQueue.global(qos: .userInteractive).async { [self] in
            defer { lock.lock(); isProcessing = false; lock.unlock() }

            // Pass .up so Vision processes in the raw sensor coordinate space.
            // The mask will be in the same coordinate system as the source pixel buffer,
            // ensuring correct alignment during compositing.
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
            do {
                try handler.perform([request])
                guard let maskObservation = request.results?.first as? VNPixelBufferObservation else { return }

                // Everything operates in the original sensor landscape-right coordinates
                let originalCI = CIImage(cvPixelBuffer: pixelBuffer)
                let maskCI = CIImage(cvPixelBuffer: maskObservation.pixelBuffer)

                // Scale mask to original image size
                let scaleX = originalCI.extent.width / maskCI.extent.width
                let scaleY = originalCI.extent.height / maskCI.extent.height
                let scaledMask = maskCI.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

                // Apply pixelation (typed builtin avoids per-call string-registry lookup)
                let pixelate = CIFilter.pixellate()
                pixelate.inputImage = originalCI
                pixelate.scale = 30.0
                guard let pixelatedCI = pixelate.outputImage else { return }

                // Blend with clear background
                let clearBg = CIImage(color: .clear).cropped(to: originalCI.extent)

                let blend = CIFilter.blendWithMask()
                blend.inputImage = pixelatedCI
                blend.backgroundImage = clearBg
                blend.maskImage = scaledMask
                guard let outputCI = blend.outputImage else { return }

                // Render the composite in sensor-native (landscape-right) coordinates,
                // then use UIImage orientation metadata to rotate for portrait display.
                // This is the same proven approach used for thumbnail generation.
                guard let cgImage = PrivacyBlurUtil.sharedContext.createCGImage(outputCI, from: outputCI.extent) else { return }

                // .right orientation tells UIKit/SwiftUI to rotate the landscape-right
                // pixels 90° for correct portrait display
                let uiImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)

                DispatchQueue.main.async { completion(uiImage) }
            } catch {
                print("Person segmentation failed: \(error)")
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

    /// Applies pixelation to person regions and returns their normalized face center coordinates.
    nonisolated static func pixelatePersonsAndGetFaceCenters(in imageData: Data, orientation: CGImagePropertyOrientation = .up) -> (Data?, [CGPoint]) {
        guard let uiImage = UIImage(data: imageData),
              let ciImage = CIImage(image: uiImage) else { return (imageData, []) }

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
            return (imageData, [])
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
            return (imageData, faceCenters) // no mask found, return original
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
        guard let pixelatedCI = pixelate.outputImage else { return (imageData, faceCenters) }

        // Blend pixelated image over original using the person mask
        let blend = CIFilter.blendWithMask()
        blend.inputImage = pixelatedCI
        blend.backgroundImage = ciImage
        blend.maskImage = scaledMask
        guard let outputCI = blend.outputImage else { return (imageData, faceCenters) }

        guard let cgImage = sharedContext.createCGImage(outputCI, from: imageSize) else { return (imageData, faceCenters) }
        
        // The exported JPEG remains strictly .up (physical LandscapeRight)
        return (UIImage(cgImage: cgImage).jpegData(compressionQuality: AppConstants.jpegCompressionQuality), faceCenters)
    }
}
