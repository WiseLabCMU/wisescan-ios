import CoreGraphics
import Metal
import simd
import UIKit

/// GPU-accelerated vertex projection for the colorization pipeline.
/// Dispatches `VertexColorProject.metal` to project all mesh vertices through
/// a camera frame in parallel, replacing the CPU O(N) inner loop.
///
/// Usage (per frame inside `colorizeFromSavedFrames`):
/// 1. Call `uploadVertices(_:normals:)` once before the frame loop.
/// 2. For each frame, call `projectFrame(...)` which returns per-vertex
///    `(R, G, B, weight)` observations. The caller accumulates into top-K.
enum VertexColorGPU {

    // MARK: - Availability

    /// Whether the Metal pipeline compiled successfully.
    static var isAvailable: Bool { pipeline != nil }

    // MARK: - Shared Metal state (process-lifetime)

    private static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    private static let queue: MTLCommandQueue? = device?.makeCommandQueue()
    private static let pipeline: MTLComputePipelineState? = {
        guard let device else { return nil }
        guard let lib = device.makeDefaultLibrary(),
              let fn = lib.makeFunction(name: "vertexColorProject") else { return nil }
        return try? device.makeComputePipelineState(function: fn)
    }()

    // MARK: - Per-colorize-session GPU buffers

    /// Persistent vertex + normal buffers (uploaded once per colorize call).
    private(set) static var vertexBuffer: MTLBuffer?
    private(set) static var normalBuffer: MTLBuffer?
    private(set) static var vertexCount: Int = 0

    // MARK: - Packed result struct (must match Metal VertexColorResult)

    struct VertexColorResult {
        var r: UInt8
        var g: UInt8
        var b: UInt8
        /// Frustum witness, not padding: 1 when the kernel had this vertex inside the
        /// frame's image, whether or not it then survived occlusion / mask / backface.
        /// Splits "no frame ever saw it" from "seen but always rejected".
        var a: UInt8
        var weight: Float
    }

    // MARK: - Params struct (must match Metal VertexColorParams)

    struct Params {
        var world2Cam: simd_float4x4
        var camX: Float
        var camY: Float
        var camZ: Float
        var fx: Float
        var fy: Float
        var cx: Float
        var cy: Float
        var imgW: Int32
        var imgH: Int32
        var depthW: Int32
        var depthH: Int32
        var maskW: Int32
        var maskH: Int32
        var distFloor: Float
        var occlusionMM: Float
        var frameWeight: Float
        var vertexCount: UInt32
        var downscaleFactor: Int32
        var hasDepth: UInt32
        var hasMask: UInt32
        var occlusionFrac: Float
        var edgeSpreadFrac: Float
        var backfaceDotMin: Float
        var depthIsRaster: UInt32
    }

    // MARK: - Upload (once per colorize call)

    /// Upload vertex positions and normals to GPU. Call once before the frame loop.
    static func uploadVertices(_ vertices: [SIMD3<Float>], normals: [SIMD3<Float>]) {
        guard let device else { return }
        vertexCount = vertices.count
        vertexBuffer = device.makeBuffer(
            bytes: vertices, length: vertices.count * MemoryLayout<SIMD3<Float>>.stride,
            options: .storageModeShared)
        normalBuffer = device.makeBuffer(
            bytes: normals, length: normals.count * MemoryLayout<SIMD3<Float>>.stride,
            options: .storageModeShared)
    }

    /// Release GPU buffers after the colorize session.
    static func releaseBuffers() {
        vertexBuffer = nil
        normalBuffer = nil
        vertexCount = 0
    }

    // MARK: - Per-frame projection

    /// Project all vertices through one camera frame on the GPU.
    /// Returns per-vertex (r, g, b, weight) observations. weight == 0 means not visible.
    static func projectFrame(
        world2Cam: simd_float4x4,
        camWorldPos: SIMD3<Float>,
        fx: Float, fy: Float, cx: Float, cy: Float,
        imgW: Int, imgH: Int,
        downscaleFactor: Int,
        frameWeight: Float,
        colorImage: CGImage,
        depthImage: CGImage?,
        maskImage: CGImage?,
        distFloor: Float,
        occlusionToleranceMM: Float,
        depthIsRaster: Bool = false
    ) -> [VertexColorResult]? {
        guard let device, let queue, let pipeline,
              let vBuf = vertexBuffer, let nBuf = normalBuffer,
              vertexCount > 0 else { return nil }

        // Create textures. FAIL CLOSED: when a depth/mask image is PROVIDED but its texture
        // can't be built, return nil so the caller's per-frame CPU fallback (which honors
        // occlusion + the person mask exactly) handles the frame — never silently proceed
        // without an exclusion the caller asked for (the mask path is privacy-relevant:
        // colors.bin ships in PLY/Scan4D exports).
        guard let colorTex = makeRGBATexture(from: colorImage, device: device) else { return nil }

        // Depth texture (R16Uint) — optional
        let depthTex: MTLTexture
        let hasDepth: Bool
        var depthW: Int32 = 0, depthH: Int32 = 0
        if let depthCG = depthImage {
            guard let dt = makeDepthTexture(from: depthCG, device: device) else { return nil }
            depthTex = dt
            hasDepth = true
            depthW = Int32(depthCG.width)
            depthH = Int32(depthCG.height)
        } else {
            // Dummy 1×1 texture (Metal requires a binding)
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Uint, width: 1, height: 1, mipmapped: false)
            desc.usage = .shaderRead
            guard let dummy = device.makeTexture(descriptor: desc) else { return nil }
            depthTex = dummy
            hasDepth = false
        }

        // Mask texture (R8Unorm) — optional
        let maskTex: MTLTexture
        let hasMask: Bool
        var maskW: Int32 = 0, maskH: Int32 = 0
        if let maskCG = maskImage {
            guard let mt = makeMaskTexture(from: maskCG, device: device) else { return nil }
            maskTex = mt
            hasMask = true
            maskW = Int32(maskCG.width)
            maskH = Int32(maskCG.height)
        } else {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
            desc.usage = .shaderRead
            guard let dummy = device.makeTexture(descriptor: desc) else { return nil }
            maskTex = dummy
            hasMask = false
        }

        // Params
        var params = Params(
            world2Cam: world2Cam,
            camX: camWorldPos.x, camY: camWorldPos.y, camZ: camWorldPos.z,
            fx: fx, fy: fy, cx: cx, cy: cy,
            imgW: Int32(imgW), imgH: Int32(imgH),
            depthW: depthW, depthH: depthH,
            maskW: maskW, maskH: maskH,
            distFloor: distFloor,
            occlusionMM: occlusionToleranceMM,
            frameWeight: frameWeight,
            vertexCount: UInt32(vertexCount),
            downscaleFactor: Int32(downscaleFactor),
            hasDepth: hasDepth ? 1 : 0,
            hasMask: hasMask ? 1 : 0,
            // Anti-bleed knobs read straight from AppConstants (compile-time constants;
            // keeps this already-long signature from growing further).
            occlusionFrac: AppConstants.colorizationOcclusionToleranceFrac,
            edgeSpreadFrac: AppConstants.colorizationDepthEdgeMaxSpreadFrac,
            backfaceDotMin: AppConstants.colorizationBackfaceDotMin,
            depthIsRaster: depthIsRaster ? 1 : 0
        )

        // Output buffer
        let resultSize = vertexCount * MemoryLayout<VertexColorResult>.stride
        guard let resultBuf = device.makeBuffer(length: resultSize, options: .storageModeShared) else { return nil }

        // Dispatch
        guard let cmdBuf = queue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(vBuf, offset: 0, index: 0)
        encoder.setBuffer(nBuf, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 2)
        encoder.setBuffer(resultBuf, offset: 0, index: 3)
        encoder.setTexture(colorTex, index: 0)
        encoder.setTexture(depthTex, index: 1)
        encoder.setTexture(maskTex, index: 2)

        let threadWidth = pipeline.threadExecutionWidth
        let threadsPerGroup = MTLSize(width: threadWidth, height: 1, depth: 1)
        let gridSize = MTLSize(width: vertexCount, height: 1, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Read back results
        let ptr = resultBuf.contents().bindMemory(to: VertexColorResult.self, capacity: vertexCount)
        return Array(UnsafeBufferPointer(start: ptr, count: vertexCount))
    }

    // MARK: - Texture helpers

    private static func makeRGBATexture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
        let w = image.width, h = image.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }

        // Render image into RGBA8 bitmap
        let bytesPerRow = w * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }

        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: bytesPerRow)
        return tex
    }

    private static func makeDepthTexture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
        guard image.bitsPerPixel == 16 else { return nil }
        let w = image.width, h = image.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Uint, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc),
              let dataProvider = image.dataProvider,
              let cfData = dataProvider.data,
              let srcPtr = CFDataGetBytePtr(cfData) else { return nil }

        // Byte order: Metal reads .r16Uint host-little-endian. The decoded buffer's real
        // byte order cannot be read off CGBitmapInfo — ImageIO stamps byteOrder16Little on
        // every 16-bit PNG it decodes, whatever the writer declared — so this took the raw
        // branch unconditionally and scrambled every capture depth (1000 mm as ~59k mm),
        // silently disabling occlusion on the GPU path. DepthPNG votes on the values instead.
        // Swap into a staging buffer when needed (~98KB at 256×192).
        let isLittleEndian = DepthPNG.needsLittleEndianByteStream(image)
        if isLittleEndian {
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: srcPtr, bytesPerRow: image.bytesPerRow)
        } else {
            let srcRow = image.bytesPerRow
            var swapped = [UInt8](repeating: 0, count: w * h * 2)
            for row in 0..<h {
                let rowBase = row * srcRow
                let dstBase = row * w * 2
                for col in 0..<w {
                    swapped[dstBase + col * 2] = srcPtr[rowBase + col * 2 + 1]
                    swapped[dstBase + col * 2 + 1] = srcPtr[rowBase + col * 2]
                }
            }
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: swapped, bytesPerRow: w * 2)
        }
        return tex
    }

    private static func makeMaskTexture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
        guard image.bitsPerPixel == 8 else { return nil }
        let w = image.width, h = image.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc),
              let dataProvider = image.dataProvider,
              let cfData = dataProvider.data else { return nil }
        let ptr = CFDataGetBytePtr(cfData)!
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: ptr, bytesPerRow: image.bytesPerRow)
        return tex
    }
}
