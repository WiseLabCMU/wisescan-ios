import CoreGraphics
import Metal
import simd
import UIKit

/// GPU-accelerated equirectangular → pinhole face reprojection using Metal compute shaders.
///
/// Replaces the CPU pixel-by-pixel bilinear sampler that was 94.5% of the 360° export time
/// (see docs/design/still-source-360.md → Performance Optimization Roadmap). Both
/// `EquirectPrivacyBlur.extractFace` (1024² detection faces) and
/// `EquirectFaceExport.renderFace` (~1680² export faces) delegate to this shared GPU path.
///
/// Memory: the equirect source texture lives in GPU memory for the duration of one still's
/// processing; face output textures are transient (created per dispatch, read back, released).
/// The Metal command queue is reused across calls within a process.
enum EquirectGPU {

    // MARK: - Shared GPU state (lazy, process-lifetime)

    private static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private static let commandQueue: MTLCommandQueue? = device?.makeCommandQueue()

    /// Pipeline for axis-aligned face bases (privacy blur).
    private static let facePipeline: MTLComputePipelineState? = {
        guard let device, let library = device.makeDefaultLibrary(),
              let fn = library.makeFunction(name: "equirectToFace")
        else { return nil }
        return try? device.makeComputePipelineState(function: fn)
    }()

    /// Pipeline for rotation-matrix faces (cube face export).
    private static let rotatedPipeline: MTLComputePipelineState? = {
        guard let device, let library = device.makeDefaultLibrary(),
              let fn = library.makeFunction(name: "equirectToFaceRotated")
        else { return nil }
        return try? device.makeComputePipelineState(function: fn)
    }()

    /// Whether the GPU path is available (device + pipeline compiled successfully).
    static var isAvailable: Bool { facePipeline != nil && rotatedPipeline != nil }

    // MARK: - Param structs (must match Metal)

    /// Matches `EquirectFaceParams` in EquirectReproject.metal.
    private struct FaceParams {
        var fwd: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var faceSize: UInt32
        var equirectWidth: UInt32
        var equirectHeight: UInt32
    }

    /// Matches `EquirectFaceRotatedParams` in EquirectReproject.metal.
    private struct RotatedParams {
        var rotCol0: SIMD3<Float>
        var rotCol1: SIMD3<Float>
        var rotCol2: SIMD3<Float>
        var faceSize: UInt32
        var equirectWidth: UInt32
        var equirectHeight: UInt32
        var vOffsetFrac: Float
    }

    // MARK: - Texture creation

    /// A GPU-visible RGBA8 buffer sized for `width`×`height`, plus the row stride to use.
    ///
    /// The stride is padded up to `minimumLinearTextureAlignment`, which a buffer-backed
    /// texture requires and which CGContext accepts without complaint — so a caller can
    /// decode an image DIRECTLY into this memory and then wrap it with `makeTexture(from:)`
    /// below, paying for the image once instead of decoding into a Swift array and copying
    /// that into a texture.
    static func makeSharedBuffer(width: Int, height: Int) -> (MTLBuffer, bytesPerRow: Int)? {
        guard let device, width > 0, height > 0 else { return nil }
        let alignment = max(1, device.minimumLinearTextureAlignment(for: .rgba8Unorm))
        let unpadded = width * 4
        let bytesPerRow = ((unpadded + alignment - 1) / alignment) * alignment
        guard let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared)
        else { return nil }
        return (buffer, bytesPerRow)
    }

    /// Wrap an already-populated shared buffer as a texture — a VIEW, not a copy.
    static func makeTexture(from buffer: MTLBuffer, width: Int, height: Int,
                            bytesPerRow: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        return buffer.makeTexture(descriptor: desc, offset: 0, bytesPerRow: bytesPerRow)
    }

    /// Create a Metal texture from RGBA8 bitmap data.
    static func makeTexture(from pixels: [UInt8], width: Int, height: Int) -> MTLTexture? {
        guard let device else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        let bytesPerRow = width * 4
        texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: pixels,
                        bytesPerRow: bytesPerRow)
        return texture
    }

    /// Create a Metal texture from a CGImage (decodes to RGBA8).
    static func makeTexture(from cgImage: CGImage) -> MTLTexture? {
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }
        return makeTexture(from: pixels, width: width, height: height)
    }

    // MARK: - Face extraction (privacy blur — axis-aligned bases)

    /// GPU gnomonic reprojection for one face. Returns a CGImage suitable for Vision.
    /// `fwd/right/up` are the face basis vectors (same as EquirectPrivacyBlur.FaceBasis).
    static func extractFace(from equirectTexture: MTLTexture,
                            fwd: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                            faceSize: Int) -> CGImage? {
        guard let device, let pipeline = facePipeline, let queue = commandQueue else { return nil }

        // Output texture
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: faceSize, height: faceSize, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .shared
        guard let outTexture = device.makeTexture(descriptor: desc) else { return nil }

        // Encode
        var params = FaceParams(
            fwd: fwd, right: right, up: up,
            faceSize: UInt32(faceSize),
            equirectWidth: UInt32(equirectTexture.width),
            equirectHeight: UInt32(equirectTexture.height))

        guard let cmdBuf = queue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(equirectTexture, index: 0)
        encoder.setTexture(outTexture, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<FaceParams>.stride, index: 0)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(width: faceSize, height: faceSize, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return readbackCGImage(from: outTexture)
    }

    // MARK: - Face rendering (cube face export — rotation matrix)

    /// GPU gnomonic reprojection for one export face. Returns JPEG Data.
    /// `rotation` is the face's 3×3 rotation matrix (same as EquirectFaceExport.Face.rotation).
    static func renderFace(from equirectTexture: MTLTexture,
                           rotation: simd_float3x3,
                           faceSize: Int,
                           jpegQuality: CGFloat = 0.9,
                           vOffsetFrac: Float = 0) -> Data? {
        guard let device, let pipeline = rotatedPipeline, let queue = commandQueue else { return nil }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: faceSize, height: faceSize, mipmapped: false)
        desc.usage = [.shaderWrite, .shaderRead]
        desc.storageMode = .shared
        guard let outTexture = device.makeTexture(descriptor: desc) else { return nil }

        var params = RotatedParams(
            rotCol0: rotation.columns.0,
            rotCol1: rotation.columns.1,
            rotCol2: rotation.columns.2,
            faceSize: UInt32(faceSize),
            equirectWidth: UInt32(equirectTexture.width),
            equirectHeight: UInt32(equirectTexture.height),
            vOffsetFrac: vOffsetFrac)

        guard let cmdBuf = queue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else { return nil }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(equirectTexture, index: 0)
        encoder.setTexture(outTexture, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<RotatedParams>.stride, index: 0)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let gridSize = MTLSize(width: faceSize, height: faceSize, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        guard let cgImage = readbackCGImage(from: outTexture) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: jpegQuality)
    }

    // MARK: - Readback

    /// Read GPU texture back to a CGImage (RGBA8 → CGContext → makeImage).
    private static func readbackCGImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&pixels, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixels.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }
}
