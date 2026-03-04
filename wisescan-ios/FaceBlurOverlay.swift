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

    /// Convert Vision's normalized rect (origin bottom-left) to screen coordinates.
    private func visionRectToScreen(_ rect: CGRect, in size: CGSize) -> CGRect {
        let x = rect.origin.x * size.width
        let y = (1.0 - rect.origin.y - rect.height) * size.height
        let w = rect.width * size.width
        let h = rect.height * size.height
        // Pad the rectangle slightly for better coverage
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
    /// Applies Gaussian blur to detected face regions in the image.
    static func blurFaces(in imageData: Data) -> Data? {
        guard let uiImage = UIImage(data: imageData),
              let ciImage = CIImage(image: uiImage) else { return imageData }

        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        let request = VNDetectFaceRectanglesRequest()

        do {
            try handler.perform([request])
        } catch {
            return imageData
        }

        guard let results = request.results, !results.isEmpty else {
            return imageData // no faces found, return original
        }

        let context = CIContext()
        var outputImage = ciImage
        let imageSize = ciImage.extent

        for face in results {
            let box = face.boundingBox
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

        guard let cgImage = context.createCGImage(outputImage, from: imageSize) else { return imageData }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
    }
}
