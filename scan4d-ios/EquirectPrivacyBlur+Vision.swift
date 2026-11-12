import CoreImage
import CoreVideo
import Foundation
import Vision

// Per-face person segmentation for the equirect privacy pass.
//
// Split out of EquirectPrivacyBlur to keep that file within its length budget; this is
// the Vision half — one segmentation request per cube face, plus the confident-core
// verdict that separates a real subject from the model's no-subject failure mode.
extension EquirectPrivacyBlur {

    // MARK: - Vision per face

    struct FaceMask {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let hasPerson: Bool
    }

    /// Run person segmentation on one pinhole face. `.success(nil)` = clean face.
    static func personMask(for face: CGImage) -> Result<FaceMask?, StringError> {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cgImage: face, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .failure(StringError("Vision segmentation failed: \(error.localizedDescription)"))
        }
        guard let buffer = request.results?.first?.pixelBuffer else {
            return .failure(StringError("Vision returned no segmentation mask"))
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let baseAddr = CVPixelBufferGetBaseAddress(buffer) else {
            return .failure(StringError("segmentation mask has no base address"))
        }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var bytes = [UInt8](repeating: 0, count: width * height)
        var maskedPixels = 0, corePixels = 0
        let src = baseAddr.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for col in 0..<width {
                let value = src[row * stride + col]
                bytes[row * width + col] = value
                if value >= maskThreshold { maskedPixels += 1 }
                if value >= coreThreshold { corePixels += 1 }
            }
        }
        // TRUST THE MODEL. A confident-core requirement used to gate this, and it
        // leaked: field run 2026-08-17 logged a face at "0.1% over threshold, 0.00%
        // core → REJECTED" — a real person, small on that face because they straddled a
        // seam, discarded whole, leaving an unmasked hole in the operator's head.
        //
        // The asymmetry decides it. Over-masking costs ceiling texture in ONE still, and
        // other stills of the same room recover it (in the run that prompted the core
        // test, two of five stills were clean). Under-masking ships a person's face.
        // Those are not comparable costs, so the model's own answer stands even when it
        // is over-cautious.
        let hasPerson = maskedPixels > 0
        OperatorRigMask.logFaceMask(masked: maskedPixels, core: corePixels,
                                    total: width * height, accepted: hasPerson)
        return .success(hasPerson ? FaceMask(bytes: bytes, width: width, height: height, hasPerson: true) : nil)
    }

    struct StringError: Error { let message: String; init(_ msg: String) { message = msg } }
}
