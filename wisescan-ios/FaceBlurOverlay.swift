import SwiftUI
import ARKit
import Vision
import CoreImage.CIFilterBuiltins

extension UIInterfaceOrientation {
    var visionPropertyOrientation: CGImagePropertyOrientation {
        switch self {
        case .portrait: return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft: return .down
        case .landscapeRight: return .up
        default: return .right
        }
    }
}

extension UIApplication {
    var currentInterfaceOrientation: UIInterfaceOrientation {
        return (connectedScenes.first as? UIWindowScene)?.interfaceOrientation ?? .portrait
    }
}

/// Privacy overlay using UIImageView (which correctly handles aspect-fill
struct PrivacyBlurOverlay: UIViewRepresentable {
    var arSession: ARSession?

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        return imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        context.coordinator.arSession = arSession
        context.coordinator.imageView = uiView
        if context.coordinator.timer == nil {
            context.coordinator.startDetection()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ uiView: UIImageView, coordinator: Coordinator) {
        coordinator.stopDetection()
    }

    class Coordinator {
        var arSession: ARSession?
        weak var imageView: UIImageView?
        var timer: Timer?

        func startDetection() {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.detectAndPixelatePersons()
            }
        }

        func stopDetection() {
            timer?.invalidate()
            timer = nil
        }

        private func detectAndPixelatePersons() {
            guard let frame = arSession?.currentFrame else { return }
            let pixelBuffer = frame.capturedImage
            let orientation = UIApplication.shared.currentInterfaceOrientation

            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .fast
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8

            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: orientation.visionPropertyOrientation,
                options: [:]
            )

            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                do {
                    try handler.perform([request])
                    guard let maskObs = request.results?.first as? VNPixelBufferObservation else { return }

                    let originalCI = CIImage(cvPixelBuffer: pixelBuffer)
                    let maskCI = CIImage(cvPixelBuffer: maskObs.pixelBuffer)

                    let scaleX = originalCI.extent.width / maskCI.extent.width
                    let scaleY = originalCI.extent.height / maskCI.extent.height
                    let scaledMask = maskCI.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

                    guard let pixelateFilter = CIFilter(name: "CIPixellate") else { return }
                    pixelateFilter.setValue(originalCI, forKey: kCIInputImageKey)
                    pixelateFilter.setValue(30.0, forKey: kCIInputScaleKey)
                    guard let pixelatedCI = pixelateFilter.outputImage else { return }

                    let clearBg = CIImage(color: .clear).cropped(to: originalCI.extent)
                    guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return }
                    blendFilter.setValue(pixelatedCI, forKey: kCIInputImageKey)
                    blendFilter.setValue(clearBg, forKey: kCIInputBackgroundImageKey)
                    blendFilter.setValue(scaledMask, forKey: kCIInputMaskImageKey)
                    guard let outputCI = blendFilter.outputImage else { return }

                    let ciCtx = CIContext(options: [.useSoftwareRenderer: false])
                    guard let cgImage = ciCtx.createCGImage(outputCI, from: originalCI.extent) else { return }

                    // CaptureView is portrait-locked, so the UIImageView frame
                    // is always portrait. The raw landscape buffer with .scaleAspectFill
                    // aligns correctly with the ARView's camera background.
                    let uiImage = UIImage(cgImage: cgImage)

                    DispatchQueue.main.async {
                        self?.imageView?.image = uiImage
                    }
                } catch {
                    print("Person segmentation failed: \(error)")
                }
            }
        }
    }
}

// MARK: - Privacy Blurring Utility for Image Export

enum PrivacyBlurUtil {
    /// Applies pixelation to person regions and returns their normalized face center coordinates.
    static func pixelatePersonsAndGetFaceCenters(in imageData: Data, orientation: UIInterfaceOrientation = .portrait) -> (Data?, [CGPoint]) {
        guard let uiImage = UIImage(data: imageData),
              let ciImage = CIImage(image: uiImage) else { return (imageData, []) }

        let handler = VNImageRequestHandler(ciImage: ciImage, orientation: orientation.visionPropertyOrientation, options: [:])
        
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

        // Pixelate original image
        guard let pixelateFilter = CIFilter(name: "CIPixellate") else { return (imageData, faceCenters) }
        pixelateFilter.setValue(ciImage, forKey: kCIInputImageKey)
        pixelateFilter.setValue(40.0, forKey: kCIInputScaleKey) 
        guard let pixelatedCI = pixelateFilter.outputImage else { return (imageData, faceCenters) }

        // Blend pixelated image over original using the person mask
        guard let blendFilter = CIFilter(name: "CIBlendWithMask") else { return (imageData, faceCenters) }
        blendFilter.setValue(pixelatedCI, forKey: kCIInputImageKey)
        blendFilter.setValue(ciImage, forKey: kCIInputBackgroundImageKey)
        blendFilter.setValue(scaledMask, forKey: kCIInputMaskImageKey)
        
        guard let outputCI = blendFilter.outputImage else { return (imageData, faceCenters) }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(outputCI, from: imageSize) else { return (imageData, faceCenters) }
        
        // The exported JPEG remains strictly .up (physical LandscapeRight)
        return (UIImage(cgImage: cgImage).jpegData(compressionQuality: AppConstants.jpegCompressionQuality), faceCenters)
    }
}
