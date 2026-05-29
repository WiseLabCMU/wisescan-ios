import Foundation
import RealityKit
import ARKit
import Metal
import CoreGraphics

@MainActor
class PointCloudManager {
    private var pointCloudEntity: ModelEntity?
    private var skyboxEntity: ModelEntity?
    private var lowLevelMesh: LowLevelMesh?
    /// GPU-writable texture for per-pixel camera colors (256×192).
    /// The compute kernel writes RGB here; UnlitMaterial samples via UV.
    private var colorTexture: LowLevelTexture?
    private weak var arView: ARView?
    /// Standard iOS LiDAR sceneDepth resolution (256×192)
    private let depthWidth = 256
    private let depthHeight = 192
    private var depthPixels: Int { depthWidth * depthHeight }
    /// Each depth pixel → 4 vertices (billboard quad)
    private var maxVertices: Int { depthPixels * 4 }
    /// Each depth pixel → 2 triangles → 6 indices
    private var maxIndices: Int { depthPixels * 6 }

    // Metal device properties
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    /// Cached texture cache — creating one per frame retains old ARFrames
    private var textureCache: CVMetalTextureCache?
    /// Track in-flight GPU work so we don't queue faster than the GPU processes
    private var gpuBusy = false

    init?(arView: ARView) {
        self.arView = arView
        guard let mtlDevice = MTLCreateSystemDefaultDevice(),
              let queue = mtlDevice.makeCommandQueue() else {
            print("[PointCloudManager] Failed to get Metal device")
            return nil
        }
        self.device = mtlDevice
        self.commandQueue = queue

        // Load compute shader for fast point cloud projection
        guard let library = mtlDevice.makeDefaultLibrary(),
              let function = library.makeFunction(name: "projectPointCloud"),
              let pipeline = try? mtlDevice.makeComputePipelineState(function: function) else {
            print("[PointCloudManager] Failed to load point cloud compute shader")
            return nil
        }
        self.pipelineState = pipeline

        // Create CVMetalTextureCache once — reuse across frames
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, mtlDevice, nil, &cache)
        self.textureCache = cache
    }

    func setup(in parentEntity: Entity, activeMeshColor: String) {
        // 1. Skybox — procedural grid texture on an inverted sphere
        setupSkybox(in: parentEntity, activeMeshColor: activeMeshColor)

        // 2. Point Cloud — billboard quads (4 verts + 6 indices per depth pixel)
        setupPointCloud(in: parentEntity)
    }

    // MARK: - Skybox

    private func setupSkybox(in parentEntity: Entity, activeMeshColor: String) {
        // Generate a procedural grid texture (active mesh color lines on black)
        // High resolution (2048) to support dense grid lines without aliasing
        let texSize = 2048
        guard let gridTexture = generateGridTexture(size: texSize, colorString: activeMeshColor) else {
            print("[PointCloudManager] Failed to generate grid texture, using fallback")
            let fallback = UnlitMaterial(color: UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0))
            let skybox = ModelEntity(mesh: .generateSphere(radius: 50.0), materials: [fallback])
            skybox.scale = SIMD3<Float>(-1, 1, 1) // Invert to view from inside
            parentEntity.addChild(skybox)
            self.skyboxEntity = skybox
            return
        }

        do {
            let textureResource = try TextureResource(image: gridTexture, options: .init(semantic: .color))
            var material = UnlitMaterial()
            material.color = .init(tint: .white, texture: .init(textureResource))
            let skybox = ModelEntity(mesh: .generateSphere(radius: 50.0), materials: [material])
            skybox.scale = SIMD3<Float>(-1, 1, 1)
            parentEntity.addChild(skybox)
            self.skyboxEntity = skybox
        } catch {
            print("[PointCloudManager] Failed to create skybox texture resource: \(error)")
            let fallback = UnlitMaterial(color: UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0))
            let skybox = ModelEntity(mesh: .generateSphere(radius: 50.0), materials: [fallback])
            skybox.scale = SIMD3<Float>(-1, 1, 1)
            parentEntity.addChild(skybox)
            self.skyboxEntity = skybox
        }
    }

    /// Generates a CGImage with a repeating grid pattern: colored lines on black background.
    private func generateGridTexture(size: Int, colorString: String) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Background: black
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // Grid lines: active mesh color
        let simdColor = colorString.toSIMD4Color
        let strokeColor = UIColor(red: CGFloat(simdColor.x), green: CGFloat(simdColor.y), blue: CGFloat(simdColor.z), alpha: 0.4)

        context.setStrokeColor(strokeColor.cgColor)
        context.setLineWidth(2.0)

        // Draw grid: denser cells (320x320 - 10x smaller scale)
        let cellCount = 320
        let cellSize = CGFloat(size) / CGFloat(cellCount)
        for i in 0...cellCount {
            let pos = CGFloat(i) * cellSize
            context.move(to: CGPoint(x: pos, y: 0))
            context.addLine(to: CGPoint(x: pos, y: CGFloat(size)))
            context.move(to: CGPoint(x: 0, y: pos))
            context.addLine(to: CGPoint(x: CGFloat(size), y: pos))
        }
        context.strokePath()

        return context.makeImage()
    }

    // MARK: - Point Cloud

    private func setupPointCloud(in parentEntity: Entity) {
        // Vertex layout: [position: float3, uv: float2] = 5 floats = 20 bytes.
        // Colors go to a separate LowLevelTexture; vertices carry UV to sample it.
        // This avoids CustomMaterial, which crashes with AR video compositing.
        var desc = LowLevelMesh.Descriptor()
        desc.vertexCapacity = maxVertices
        desc.vertexAttributes = [
            LowLevelMesh.Attribute(semantic: .position, format: .float3, offset: 0),
            LowLevelMesh.Attribute(semantic: .uv0, format: .float2, offset: MemoryLayout<Float>.stride * 3)
        ]
        desc.vertexLayouts = [
            LowLevelMesh.Layout(bufferIndex: 0, bufferStride: MemoryLayout<Float>.stride * 5)
        ]
        desc.indexCapacity = maxIndices
        desc.indexType = .uint32

        do {
            let llm = try LowLevelMesh(descriptor: desc)

            // Pre-fill indices: each depth pixel → 2 triangles (billboard quad)
            // Quad vertices: 0=BL, 1=BR, 2=TL, 3=TR
            // Triangle 1: BL→BR→TL (0,1,2), Triangle 2: TL→BR→TR (2,1,3)
            llm.withUnsafeMutableIndices { buffer in
                let indices = buffer.bindMemory(to: UInt32.self)
                for i in 0..<depthPixels {
                    let base = UInt32(i * 4)
                    let idx = i * 6
                    indices[idx + 0] = base + 0
                    indices[idx + 1] = base + 1
                    indices[idx + 2] = base + 2
                    indices[idx + 3] = base + 2
                    indices[idx + 4] = base + 1
                    indices[idx + 5] = base + 3
                }
            }

            let meshBounds = BoundingBox(min: [-100, -100, -100], max: [100, 100, 100])
            llm.parts.replaceAll([
                LowLevelMesh.Part(
                    indexCount: maxIndices,
                    topology: .triangle,
                    materialIndex: 0,
                    bounds: meshBounds
                )
            ])
            self.lowLevelMesh = llm

            // LowLevelTexture for color output — compute kernel writes RGBA here,
            // UnlitMaterial samples it via the UV coordinates on each quad vertex.
            let texDescriptor = LowLevelTexture.Descriptor(
                pixelFormat: .rgba8Unorm,
                width: depthWidth,
                height: depthHeight,
                textureUsage: [.shaderRead, .shaderWrite]
            )
            let colorTex = try LowLevelTexture(descriptor: texDescriptor)
            self.colorTexture = colorTex

            let textureResource = try TextureResource(from: colorTex)
            var material = UnlitMaterial()
            material.color = .init(tint: .white, texture: .init(textureResource))

            let resource = try MeshResource(from: llm)
            let entity = ModelEntity(mesh: resource, materials: [material])
            parentEntity.addChild(entity)
            self.pointCloudEntity = entity

        } catch {
            print("[PointCloudManager] Failed to create LowLevelMesh: \(error)")
        }
    }

    // MARK: - Update

    func update(
        depthMap: CVPixelBuffer?,
        capturedImage: CVPixelBuffer,
        segBuffer: CVPixelBuffer?,
        confidenceMap: CVPixelBuffer?,
        cameraTransform: simd_float4x4,
        intrinsics: simd_float3x3,
        privacyFilter: Bool
    ) {
        guard let llm = lowLevelMesh,
              let depthMap = depthMap else { return }

        // Skip if previous GPU work hasn't finished — prevents command buffer pile-up
        guard !gpuBusy else { return }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let totalPixels = width * height

        guard totalPixels <= depthPixels else { return }

        // Move skybox with camera so it appears infinitely far away, but do NOT rotate it
        if let skybox = skyboxEntity {
            var newTransform = skybox.transform
            newTransform.translation = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
            skybox.transform = newTransform
        }

        // Flush stale textures from the cache each frame
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }

        let segMap = privacyFilter ? segBuffer : nil

        // Build the compute command buffer — no withUnsafeMutableBytes needed,
        // llm.replace() is the correct GPU-side buffer swap API.
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return }

        computeEncoder.setComputePipelineState(pipelineState)

        // Textures — from cached CVMetalTextureCache
        let depthTexture = makeTexture(from: depthMap, pixelFormat: .r32Float)
        let imageYTexture = makeTexture(from: capturedImage, plane: 0, pixelFormat: .r8Unorm)
        let imageCbCrTexture = makeTexture(from: capturedImage, plane: 1, pixelFormat: .rg8Unorm)

        var segTexture: MTLTexture? = nil
        if let seg = segMap {
            segTexture = makeTexture(from: seg, pixelFormat: .r8Unorm)
        }
        
        var confTexture: MTLTexture? = nil
        if let conf = confidenceMap {
            confTexture = makeTexture(from: conf, pixelFormat: .r8Uint)
        }

        computeEncoder.setTexture(depthTexture, index: 0)
        computeEncoder.setTexture(imageYTexture, index: 1)
        computeEncoder.setTexture(imageCbCrTexture, index: 2)
        if let st = segTexture {
            computeEncoder.setTexture(st, index: 3)
        }
        if let ct = confTexture {
            computeEncoder.setTexture(ct, index: 5)
        }

        // Color output texture — compute kernel writes RGBA here, UnlitMaterial reads via UV
        guard let colorTex = colorTexture else { return }
        let colorOutputMTL = colorTex.replace(using: commandBuffer)
        computeEncoder.setTexture(colorOutputMTL, index: 4)

        // Replace returns a fresh MTLBuffer; LowLevelMesh swaps it in on commandBuffer completion
        let mtlBuffer = llm.replace(bufferIndex: 0, using: commandBuffer)
        computeEncoder.setBuffer(mtlBuffer, offset: 0, index: 0)

        // Uniforms — scale intrinsics from camera resolution to depth resolution
        var scaledIntrinsics = intrinsics
        let cameraRes = SIMD2<Float>(Float(CVPixelBufferGetWidth(capturedImage)), Float(CVPixelBufferGetHeight(capturedImage)))

        let scaleX = Float(width) / cameraRes.x
        let scaleY = Float(height) / cameraRes.y
        scaledIntrinsics[0][0] *= scaleX
        scaledIntrinsics[1][1] *= scaleY
        scaledIntrinsics[2][0] *= scaleX
        scaledIntrinsics[2][1] *= scaleY

        var uniforms = PointCloudUniforms(
            cameraTransform: cameraTransform,
            intrinsics: scaledIntrinsics,
            depthRes: SIMD2<Float>(Float(width), Float(height)),
            cameraRes: cameraRes,
            useSegmentation: segTexture != nil ? 1 : 0
        )
        computeEncoder.setBytes(&uniforms, length: MemoryLayout<PointCloudUniforms>.size, index: 1)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )

        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()

        gpuBusy = true
        commandBuffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                self?.gpuBusy = false
            }
        }
        commandBuffer.commit()

        // Update mesh part with correct index count
        let indexCount = totalPixels * 6
        llm.parts.replaceAll([
            LowLevelMesh.Part(
                indexCount: indexCount,
                topology: .triangle,
                materialIndex: 0,
                bounds: BoundingBox(min: [-100, -100, -100], max: [100, 100, 100])
            )
        ])
    }

    // MARK: - Cleanup

    func destroy() {
        pointCloudEntity?.removeFromParent()
        skyboxEntity?.removeFromParent()
        pointCloudEntity = nil
        skyboxEntity = nil
        lowLevelMesh = nil
        colorTexture = nil
    }

    // MARK: - Helpers

    private func makeTexture(from pixelBuffer: CVPixelBuffer, plane: Int = 0, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, plane)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)

        var cvTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, pixelFormat, width, height, plane, &cvTexture)

        guard let cvTex = cvTexture, let texture = CVMetalTextureGetTexture(cvTex) else { return nil }
        return texture
    }
}

struct PointCloudUniforms {
    var cameraTransform: simd_float4x4
    var intrinsics: simd_float3x3
    var depthRes: SIMD2<Float>
    var cameraRes: SIMD2<Float>
    var useSegmentation: UInt32
    // Padding to match Metal struct alignment (float4x4=64 + float3x3=48 + float2×2=16 + uint+pad=16 = 144 bytes)
    private var pad1: UInt32 = 0
    private var pad2: UInt32 = 0
    private var pad3: UInt32 = 0

    init(cameraTransform: simd_float4x4, intrinsics: simd_float3x3, depthRes: SIMD2<Float>, cameraRes: SIMD2<Float>, useSegmentation: UInt32) {
        self.cameraTransform = cameraTransform
        self.intrinsics = intrinsics
        self.depthRes = depthRes
        self.cameraRes = cameraRes
        self.useSegmentation = useSegmentation
    }
}
