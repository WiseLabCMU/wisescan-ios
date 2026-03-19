import SwiftUI
import ARKit
import Vision

/// Overlay that detects faces in the AR camera feed and draws blur rectangles over them.
struct FaceBlurOverlay: View {
    var arSession: ARSession?
    @State private var faceRects: [CGRect] = []
    @State private var timer: Timer?

    var body: some View {
        GeometryReader { geo in
            ForEach(Array(faceRects.enumerated()), id: \.offset) { _, rect in
                // Convert normalized Vision rect to screen coordinates
                let screenRect = visionRectToScreen(rect, in: geo.size)
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.red.opacity(0.6), lineWidth: 2)
                    )
                    .overlay(
                        Image(systemName: "eye.slash.fill")
                            .foregroundColor(.red.opacity(0.7))
                            .font(.system(size: min(screenRect.width, screenRect.height) * 0.4))
                    )
                    .frame(width: screenRect.width, height: screenRect.height)
                    .position(x: screenRect.midX, y: screenRect.midY)
            }
        }
        .onAppear { startDetection() }
        .onDisappear { stopDetection() }
    }

    /// Convert Vision's normalized rect (origin bottom-left, corrected for .right orientation)
    /// to screen coordinates, accounting for AR camera aspect-fill cropping.
    private func visionRectToScreen(_ rect: CGRect, in size: CGSize) -> CGRect {
        // The AR camera feed (4:3 landscape) is aspect-filled into the view.
        // Vision's normalized coords span the full camera image, but the view
        // may crop top/bottom or left/right. Compute the visible offset.
        let cameraAspect: CGFloat = 4.0 / 3.0 // standard iPhone LiDAR camera
        let viewAspect = size.width / size.height

        var scaleX: CGFloat = 1.0
        var scaleY: CGFloat = 1.0
        var offsetX: CGFloat = 0.0
        var offsetY: CGFloat = 0.0

        if viewAspect < cameraAspect {
            // View is taller than camera → height fills, width is cropped
            scaleY = size.height
            scaleX = size.height * cameraAspect
            offsetX = (scaleX - size.width) / 2.0
        } else {
            // View is wider than camera → width fills, height is cropped
            scaleX = size.width
            scaleY = size.width / cameraAspect
            offsetY = (scaleY - size.height) / 2.0
        }

        let x = rect.origin.x * scaleX - offsetX
        let y = (1.0 - rect.origin.y - rect.height) * scaleY - offsetY
        let w = rect.width * scaleX
        let h = rect.height * scaleY

        let padding: CGFloat = 8
        return CGRect(x: x - padding, y: y - padding, width: w + padding * 2, height: h + padding * 2)
    }

    private func startDetection() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            detectFaces()
        }
    }

    private func stopDetection() {
        timer?.invalidate()
        timer = nil
    }

    private func detectFaces() {
        guard let frame = arSession?.currentFrame else { return }
        let pixelBuffer = frame.capturedImage

        let request = VNDetectFaceRectanglesRequest { request, error in
            guard let results = request.results as? [VNFaceObservation] else { return }
            DispatchQueue.main.async {
                self.faceRects = results.map { $0.boundingBox }
            }
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        DispatchQueue.global(qos: .userInteractive).async {
            try? handler.perform([request])
        }
    }
}

// MARK: - Face Blurring Utility for Image Export

enum FaceBlurUtil {
    /// Applies Gaussian blur to detected face regions in the image and returns their normalized center coordinates.
    static func blurFacesAndGetCenters(in imageData: Data) -> (Data?, [CGPoint]) {
        guard let uiImage = UIImage(data: imageData),
              let ciImage = CIImage(image: uiImage) else { return (imageData, []) }

        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        let request = VNDetectFaceRectanglesRequest()

        do {
            try handler.perform([request])
        } catch {
            return (imageData, [])
        }

        guard let results = request.results, !results.isEmpty else {
            return (imageData, []) // no faces found, return original
        }

        let context = CIContext()
        var outputImage = ciImage
        let imageSize = ciImage.extent
        var faceCenters: [CGPoint] = []

        for face in results {
            let box = face.boundingBox
            // Vision origin is bottom-left, typically we want top-left UVs for depth map lookup
            let uv = CGPoint(x: box.midX, y: 1.0 - box.midY)
            faceCenters.append(uv)

            // Convert normalized rect to pixel coordinates
            let faceRect = CGRect(
                x: box.origin.x * imageSize.width,
                y: box.origin.y * imageSize.height,
                width: box.width * imageSize.width,
                height: box.height * imageSize.height
            ).insetBy(dx: -20, dy: -20) // pad for better coverage

            // Create a heavily blurred version
            guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: [
                kCIInputImageKey: outputImage,
                kCIInputRadiusKey: 30.0
            ])?.outputImage else { continue }

            // Create a mask for the face region
            let maskImage = CIImage(color: CIColor.white).cropped(to: faceRect)
            let background = CIImage(color: CIColor.black).cropped(to: outputImage.extent)
            guard let mask = CIFilter(name: "CISourceOverCompositing", parameters: [
                kCIInputImageKey: maskImage,
                kCIInputBackgroundImageKey: background
            ])?.outputImage else { continue }

            // Blend: blurred face region over original
            guard let blended = CIFilter(name: "CIBlendWithMask", parameters: [
                kCIInputImageKey: blurred.cropped(to: outputImage.extent),
                kCIInputBackgroundImageKey: outputImage,
                kCIInputMaskImageKey: mask
            ])?.outputImage else { continue }

            outputImage = blended
        }

        guard let cgImage = context.createCGImage(outputImage, from: imageSize) else { return (imageData, faceCenters) }
        return (UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85), faceCenters)
    }
}
