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
    private let integratePipelineState: MTLComputePipelineState
    private let extractPipelineState: MTLComputePipelineState
    // Bloom post-processing
    private var bloomThresholdPipeline: MTLComputePipelineState?
    private var bloomCompositePipeline: MTLComputePipelineState?
    private var bloomIntermediateTexture: MTLTexture?
    /// Cached texture cache — creating one per frame retains old ARFrames
    private var textureCache: CVMetalTextureCache?
    /// Track in-flight GPU work so we don't queue faster than the GPU processes
    private var gpuBusy = false
    /// True after the first frame has been dispatched to the GPU.
    /// The coordinator uses this to defer the camera→black background transition.
    private(set) var hasRenderedFirstFrame = false

    // Voxel accumulation properties
    private var voxelGrid: VoxelGrid?
    private var voxelEntity: ModelEntity?
    private var voxelLowLevelMesh: LowLevelMesh?
    private var voxelColorTexture: LowLevelTexture?
    /// Reused GPU buffer of packed occupied voxels (ExtractVoxel) for the extract kernel.
    /// Allocated once at voxel setup, sized to maxVoxels — no per-extraction allocation.
    private var voxelExtractBuffer: MTLBuffer?
    /// Serial queue that owns ALL VoxelGrid hash-map access (merge / decay / pack / reset),
    /// so the 350K-voxel decay no longer blocks the main thread. The GPU append buffer is
    /// snapshotted on the main thread first, and the LowLevelMesh GPU dispatch hops back to
    /// main (LowLevelMesh/LowLevelTexture are @MainActor).
    private let voxelQueue = DispatchQueue(label: "com.scan4d.voxelGrid", qos: .userInitiated)
    private var lastExtractionTime: CFAbsoluteTime = 0
    private var lastDecayTime: CFAbsoluteTime = 0
    private var lastIntegrationTransform: simd_float4x4?
    private var lastIntegrationIntrinsics: simd_float3x3?
    private var lastIntegrationDepthMap: CVPixelBuffer?
    private var extractionInProgress = false
    private var voxelSetupComplete = false
    private var integrationFrameCounter: UInt32 = 0
    /// Parent entity for adding voxel cloud entity lazily
    private weak var parentEntity: Entity?
    /// Voxel color texture dimensions (1024×512 = 524,288 texels, covers 350K voxels)
    private let voxelTexWidth = 1024
    private let voxelTexHeight = 512
    /// Vertices per voxel: 1 camera-facing quad × 4 vertices = 4
    private let vertsPerVoxel = 4
    /// Indices per voxel: 1 quad × 2 triangles × 3 = 6
    private let indicesPerVoxel = 6
    /// Shared sort group for layering: voxels behind live points.
    /// postPass = draw color in order, then depth — last drawn (live) always wins at same depth.
    private let pointCloudSortGroup = ModelSortGroup(depthPass: .postPass)

    init?(arView: ARView) {
        self.arView = arView
        guard let mtlDevice = MTLCreateSystemDefaultDevice(),
              let queue = mtlDevice.makeCommandQueue() else {
            print("[PointCloudManager] Failed to get Metal device")
            return nil
        }
        self.device = mtlDevice
        self.commandQueue = queue

        // Load compute shaders
        guard let library = mtlDevice.makeDefaultLibrary(),
              let function = library.makeFunction(name: "projectPointCloud"),
              let pipeline = try? mtlDevice.makeComputePipelineState(function: function) else {
            print("[PointCloudManager] Failed to load point cloud compute shader")
            return nil
        }
        self.pipelineState = pipeline

        guard let integrateFunction = library.makeFunction(name: "integrateVoxels"),
              let integratePipeline = try? mtlDevice.makeComputePipelineState(function: integrateFunction) else {
            print("[PointCloudManager] Failed to load voxel integration compute shader")
            return nil
        }
        self.integratePipelineState = integratePipeline

        guard let extractFunction = library.makeFunction(name: "extractVoxelQuads"),
              let extractPipeline = try? mtlDevice.makeComputePipelineState(function: extractFunction) else {
            print("[PointCloudManager] Failed to load voxel extraction compute shader")
            return nil
        }
        self.extractPipelineState = extractPipeline

        // Bloom post-processing pipeline states (optional — fail gracefully)
        if let bloomThresholdFn = library.makeFunction(name: "bloomThresholdAndBlurH"),
           let bloomCompositeFn = library.makeFunction(name: "bloomBlurVAndComposite") {
            self.bloomThresholdPipeline = try? mtlDevice.makeComputePipelineState(function: bloomThresholdFn)
            self.bloomCompositePipeline = try? mtlDevice.makeComputePipelineState(function: bloomCompositeFn)
        }

        // Create VoxelGrid for accumulated point cloud
        self.voxelGrid = VoxelGrid(device: mtlDevice)

        // Create CVMetalTextureCache once — reuse across frames
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, mtlDevice, nil, &cache)
        self.textureCache = cache
    }

    func setup(in parentEntity: Entity, activeMeshColor: String) {
        // Store reference for lazy voxel setup
        self.parentEntity = parentEntity

        // 1. Skybox — procedural grid texture on an inverted sphere
        setupSkybox(in: parentEntity, activeMeshColor: activeMeshColor)

        // 2. Point Cloud — billboard quads (4 verts + 6 indices per depth pixel)
        setupPointCloud(in: parentEntity)

        // 3. Voxel Cloud — deferred to first keyframe to avoid 84MB allocation
        //    spike at launch that causes ARFrame retention floods.

        // 4. Bloom post-process — hooks into ARView’s render pipeline
        setupBloomPostProcess()
    }

    // MARK: - Skybox

    private func setupSkybox(in parentEntity: Entity, activeMeshColor: String) {
        // Skybox sphere radius (viewed from inside) + the plain dark fill used when the grid texture
        // can't be built — both were repeated inline across the three paths below; named here once.
        let skyboxRadius: Float = 50.0
        let skyboxFallbackColor = UIColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1.0)
        // Generate a procedural grid texture (active mesh color lines on black)
        // High resolution (2048) to support dense grid lines without aliasing
        let texSize = 2048
        guard let gridTexture = generateGridTexture(size: texSize, colorString: activeMeshColor) else {
            print("[PointCloudManager] Failed to generate grid texture, using fallback")
            let fallback = UnlitMaterial(color: skyboxFallbackColor)
            let skybox = ModelEntity(mesh: .generateSphere(radius: skyboxRadius), materials: [fallback])
            skybox.scale = SIMD3<Float>(-1, 1, 1) // Invert to view from inside
            skybox.isEnabled = false  // Hidden until first voxel frame
            parentEntity.addChild(skybox)
            self.skyboxEntity = skybox
            return
        }

        do {
            let textureResource = try TextureResource(image: gridTexture, options: .init(semantic: .color))
            var material = UnlitMaterial()
            material.color = .init(tint: .white, texture: .init(textureResource))
            let skybox = ModelEntity(mesh: .generateSphere(radius: skyboxRadius), materials: [material])
            skybox.scale = SIMD3<Float>(-1, 1, 1)
            skybox.isEnabled = false  // Hidden until first voxel frame
            parentEntity.addChild(skybox)
            self.skyboxEntity = skybox
        } catch {
            print("[PointCloudManager] Failed to create skybox texture resource: \(error)")
            let fallback = UnlitMaterial(color: skyboxFallbackColor)
            let skybox = ModelEntity(mesh: .generateSphere(radius: skyboxRadius), materials: [fallback])
            skybox.scale = SIMD3<Float>(-1, 1, 1)
            skybox.isEnabled = false  // Hidden until first voxel frame
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
            entity.isEnabled = false  // Hidden until first voxel frame
            // Live points render ON TOP of accumulated voxels (order 2 > order 1)
            entity.components.set(ModelSortGroupComponent(group: pointCloudSortGroup, order: 2))
            parentEntity.addChild(entity)
            self.pointCloudEntity = entity

        } catch {
            print("[PointCloudManager] Failed to create LowLevelMesh: \(error)")
        }
    }

    // MARK: - Bloom Post-Processing

    /// Install a two-pass bloom effect on the ARView's render pipeline.
    /// Pass 1: Threshold bright pixels + horizontal Gaussian blur → intermediate texture
    /// Pass 2: Vertical blur + additive composite → output
    /// Only affects colored pixels (point cloud), black background passes through unchanged.
    private func setupBloomPostProcess() {
        guard let arView = arView,
              let thresholdPipeline = bloomThresholdPipeline,
              let compositePipeline = bloomCompositePipeline else {
            print("[PointCloudManager] Bloom pipelines not available, skipping bloom setup")
            return
        }

        print("[PointCloudManager] Setting up bloom post-process effect")

        // Capture device and pipelines directly — the postProcess closure runs
        // on the render thread, not MainActor, so we can't capture `self`.
        let device = self.device
        var intermediateTexture: MTLTexture?

        arView.renderCallbacks.postProcess = { context in
            #if targetEnvironment(simulator)
            // Metal compute shaders cannot reliably write to RealityKit's targetColorTexture
            // on Simulator because it uses an sRGB format and lacks the shaderWrite usage flag.
            return
            #else
            // Developer isolation test: skip the bloom passes (the VR point-cloud GPU pipeline
            // is gated separately in update()). Reading UserDefaults on the render thread is safe.
            if UserDefaults.standard.bool(forKey: AppConstants.Key.pauseVRCompute) { return }

            let source = context.sourceColorTexture
            let dest = context.targetColorTexture

            // Check if RealityKit provided a texture we can actually write to with a compute shader
            guard dest.usage.contains(.shaderWrite) else {
                return
            }

            let width = source.width
            let height = source.height
            // Bloom is low-frequency: run the threshold + horizontal-blur pass at half
            // resolution (¼ the threads). The composite pass stays full-res.
            let halfW = max(1, width / 2)
            let halfH = max(1, height / 2)

            // Lazily create/recreate the half-res intermediate texture (always linear)
            if intermediateTexture == nil ||
               intermediateTexture!.width != halfW ||
               intermediateTexture!.height != halfH {
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width: halfW,
                    height: halfH,
                    mipmapped: false
                )
                desc.usage = [.shaderRead, .shaderWrite]
                desc.storageMode = .private
                intermediateTexture = device.makeTexture(descriptor: desc)
                intermediateTexture?.label = "BloomIntermediate"
                print("[PointCloudManager] Bloom intermediate texture created: \(halfW)×\(halfH) (half of \(width)×\(height))")
            }

            guard let intermediate = intermediateTexture else { return }

            let commandBuffer = context.commandBuffer

            let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let halfGroups = MTLSize(
                width: (halfW + 15) / 16,
                height: (halfH + 15) / 16,
                depth: 1
            )
            let fullGroups = MTLSize(
                width: (width + 15) / 16,
                height: (height + 15) / 16,
                depth: 1
            )

            // Pass 1: Threshold + Horizontal blur at half-res (source → half-res intermediate)
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(thresholdPipeline)
                encoder.setTexture(source, index: 0)
                encoder.setTexture(intermediate, index: 1)
                encoder.dispatchThreadgroups(halfGroups, threadsPerThreadgroup: threadGroupSize)
                encoder.endEncoding()
            }

            // Pass 2: Vertical blur (upsampling the half-res intermediate) + composite,
            // at full-res (source + intermediate → dest)
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                encoder.setComputePipelineState(compositePipeline)
                encoder.setTexture(source, index: 0)
                encoder.setTexture(intermediate, index: 1)
                encoder.setTexture(dest, index: 2)
                encoder.dispatchThreadgroups(fullGroups, threadsPerThreadgroup: threadGroupSize)
                encoder.endEncoding()
            }
            #endif
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
        // Developer isolation test: skip the entire VR GPU pipeline (point-cloud projection +
        // voxel integration). Bloom is gated separately in setupBloomPostProcess. If the freeze
        // disappears with this on, the GPU pipeline is implicated.
        if UserDefaults.standard.bool(forKey: AppConstants.Key.pauseVRCompute) { return }

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

        var segTexture: MTLTexture?
        if let seg = segMap {
            segTexture = makeTexture(from: seg, pixelFormat: .r8Unorm)
        }

        var confTexture: MTLTexture?
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

        // Voxel integration: encode in same command buffer if keyframe gate passes.
        // Textures and uniforms are still bound from projectPointCloud.
        let integrateThisFrame = shouldIntegrate(currentTransform: cameraTransform)
        var didDispatchIntegration = false
        if integrateThisFrame {
            // Store intrinsics and depth map for confidence decay in handleVoxelCompletion
            lastIntegrationIntrinsics = scaledIntrinsics
            lastIntegrationDepthMap = depthMap
            // Lazy voxel setup: allocate on first keyframe, not at app launch.
            // Skip integration on the setup frame — the 6.3M index pre-fill
            // is expensive and we don't want to also run the GPU kernel.
            if !voxelSetupComplete, let parent = parentEntity {
                setupVoxelCloud(in: parent)
                voxelSetupComplete = true
                // Don't integrate this frame — setup just happened
            } else if voxelSetupComplete {
                encodeVoxelIntegration(encoder: computeEncoder, width: width, height: height)
                didDispatchIntegration = true
            }
        }

        computeEncoder.endEncoding()

        gpuBusy = true
        commandBuffer.addCompletedHandler { [weak self] cb in
            // Perf diagnostics: report the on-GPU duration of the per-frame project(+integrate)
            // pass when it spikes — this competes with ARKit's own depth/VIO GPU work.
            if PerfDiag.enabled {
                let gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000.0
                if gpuMs > 8 {
                    PerfDiag.log("VR GPU project\(didDispatchIntegration ? "+integrate" : "") \(Int(gpuMs))ms")
                }
            }
            DispatchQueue.main.async {
                self?.gpuBusy = false
                if didDispatchIntegration {
                    self?.handleVoxelCompletion()
                }
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

    // MARK: - Voxel Cloud Setup

    private func setupVoxelCloud(in parentEntity: Entity) {
        let maxVoxels = VoxelGrid.maxVoxels
        let maxVerts = maxVoxels * vertsPerVoxel
        let maxIdx = maxVoxels * indicesPerVoxel

        // Reused buffer for packed voxels consumed by the extract kernel (allocated once).
        let extractStride = MemoryLayout<VoxelGrid.ExtractVoxel>.stride
        self.voxelExtractBuffer = device.makeBuffer(length: maxVoxels * extractStride, options: .storageModeShared)
        self.voxelExtractBuffer?.label = "VoxelExtractBuffer"

        var desc = LowLevelMesh.Descriptor()
        desc.vertexCapacity = maxVerts
        desc.vertexAttributes = [
            LowLevelMesh.Attribute(semantic: .position, format: .float3, offset: 0),
            LowLevelMesh.Attribute(semantic: .uv0, format: .float2, offset: MemoryLayout<Float>.stride * 3)
        ]
        desc.vertexLayouts = [
            LowLevelMesh.Layout(bufferIndex: 0, bufferStride: MemoryLayout<Float>.stride * 5)
        ]
        desc.indexCapacity = maxIdx
        desc.indexType = .uint32

        do {
            let llm = try LowLevelMesh(descriptor: desc)

            // Pre-fill indices for camera-facing quad pattern:
            // Each voxel = 1 quad × 2 triangles.
            // Per quad: vertices [0,1,2,3] → triangles (0,1,2) and (2,1,3)
            llm.withUnsafeMutableIndices { buffer in
                let indices = buffer.bindMemory(to: UInt32.self)
                for v in 0..<maxVoxels {
                    let vertBase = UInt32(v * vertsPerVoxel)
                    let idxBase = v * indicesPerVoxel
                    indices[idxBase + 0] = vertBase + 0
                    indices[idxBase + 1] = vertBase + 1
                    indices[idxBase + 2] = vertBase + 2
                    indices[idxBase + 3] = vertBase + 2
                    indices[idxBase + 4] = vertBase + 1
                    indices[idxBase + 5] = vertBase + 3
                }
            }

            // Start with zero rendered voxels
            llm.parts.replaceAll([
                LowLevelMesh.Part(
                    indexCount: 0,
                    topology: .triangle,
                    materialIndex: 0,
                    bounds: BoundingBox(min: [-100, -100, -100], max: [100, 100, 100])
                )
            ])
            self.voxelLowLevelMesh = llm

            // Color texture for voxel cloud (1024×512 = 524K texels)
            let texDesc = LowLevelTexture.Descriptor(
                pixelFormat: .rgba8Unorm,
                width: voxelTexWidth,
                height: voxelTexHeight,
                textureUsage: [.shaderRead, .shaderWrite]
            )
            let voxelTex = try LowLevelTexture(descriptor: texDesc)
            self.voxelColorTexture = voxelTex

            let textureResource = try TextureResource(from: voxelTex)
            var material = UnlitMaterial()
            material.color = .init(tint: .white, texture: .init(textureResource))
            material.blending = .transparent(opacity: .init(floatLiteral: 1.0))

            let resource = try MeshResource(from: llm)
            let entity = ModelEntity(mesh: resource, materials: [material])
            entity.isEnabled = false  // Hidden until first voxel frame
            // Accumulated voxels render BEHIND live points (order 1 < order 2)
            entity.components.set(ModelSortGroupComponent(group: pointCloudSortGroup, order: 1))
            parentEntity.addChild(entity)
            self.voxelEntity = entity

        } catch {
            print("[PointCloudManager] Failed to create voxel LowLevelMesh: \(error)")
        }
    }

    // MARK: - Keyframe Gating

    /// Check if camera has moved enough to justify a new voxel integration.
    /// Returns true if translation ≥ 5cm or rotation ≥ 3°.
    private func shouldIntegrate(currentTransform: simd_float4x4) -> Bool {
        guard let last = lastIntegrationTransform else {
            lastIntegrationTransform = currentTransform
            return true
        }

        // Translation delta
        let lastPos = SIMD3<Float>(last.columns.3.x, last.columns.3.y, last.columns.3.z)
        let curPos = SIMD3<Float>(currentTransform.columns.3.x, currentTransform.columns.3.y, currentTransform.columns.3.z)
        let translationDelta = simd_length(curPos - lastPos)

        // Rotation delta (angle between forward vectors)
        let lastForward = SIMD3<Float>(last.columns.2.x, last.columns.2.y, last.columns.2.z)
        let curForward = SIMD3<Float>(currentTransform.columns.2.x, currentTransform.columns.2.y, currentTransform.columns.2.z)
        let dotProduct = simd_clamp(simd_dot(simd_normalize(lastForward), simd_normalize(curForward)), -1.0, 1.0)
        let angleDelta = acos(dotProduct) * (180.0 / .pi)  // degrees

        if translationDelta >= 0.05 || angleDelta >= 3.0 {
            lastIntegrationTransform = currentTransform
            return true
        }
        return false
    }

    /// Dispatch voxel integration in the same command buffer as the live point cloud.
    /// Called from update() only when keyframe gate passes.
    private func encodeVoxelIntegration(
        encoder: MTLComputeCommandEncoder,
        width: Int,
        height: Int
    ) {
        guard let grid = voxelGrid else { return }

        // Reset append counter before dispatch
        grid.resetAppendBuffer()

        encoder.setComputePipelineState(integratePipelineState)

        // Textures are already bound at indices 0-5 from projectPointCloud.
        // Uniforms are already bound at buffer index 1.
        // We only need to bind the append buffer and counter.
        encoder.setBuffer(grid.appendBuffer, offset: 0, index: 2)
        encoder.setBuffer(grid.appendCounter, offset: 0, index: 3)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )

        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
    }

    /// Merge GPU results and trigger extraction if due.
    /// Called from the command buffer completion handler.
    private func handleVoxelCompletion() {
        guard let grid = voxelGrid else { return }

        // Increment integration frame counter
        integrationFrameCounter += 1
        let frameCounter = integrationFrameCounter

        // Snapshot the GPU append buffer on the MAIN thread now — before the next
        // integration resets/overwrites it — then merge it into the hash map off-main.
        let entries = grid.snapshotAppendBuffer()

        // Timing decisions on the main thread. Merge runs EVERY integration (must, or we lose
        // appended voxels), but the expensive 350K-voxel decay is THROTTLED to ~voxelDecayInterval.
        // Running decay every keyframe pegged a core (200–350ms each) and backed up the voxelQueue,
        // which drove the multi-second stalls (including the post-stop drain). Extraction keeps its
        // own 0.5s gate below.
        let now = CACurrentMediaTime()
        let shouldDecay = now - lastDecayTime > AppConstants.voxelDecayInterval
        if shouldDecay { lastDecayTime = now }

        let transform = lastIntegrationTransform
        // intrinsics + depth are only needed for decay; capture them only when decaying so
        // non-decay completions don't retain the ARFrame depth buffer.
        let intrinsics = shouldDecay ? lastIntegrationIntrinsics : nil
        let depthMap = shouldDecay ? lastIntegrationDepthMap : nil
        lastIntegrationDepthMap = nil // always release the ARFrame depth-map reference promptly

        // Decide extraction timing on the main thread (it owns the gate + flag).
        let willExtract = now - lastExtractionTime > 0.5 && !extractionInProgress
            && voxelLowLevelMesh != nil && voxelColorTexture != nil && voxelExtractBuffer != nil
        let extractBuffer = voxelExtractBuffer
        if willExtract {
            extractionInProgress = true
            lastExtractionTime = now
        }

        // Merge (every time) + throttled decay run off the main thread on the serial queue that
        // owns ALL hash-map access. Pack also runs there; the GPU dispatch (LowLevelMesh is
        // @MainActor) hops back to main.
        voxelQueue.async { [weak self] in
            PerfDiag.timed("voxel_merge", warnOverMs: 5) {
                grid.mergeAppendBuffer(entries, frameCounter: frameCounter)
            }
            if let transform, let intrinsics, let depthMap {
                PerfDiag.timed("voxel_decay", warnOverMs: 5) {
                    grid.decayContradictedVoxels(
                        cameraTransform: transform,
                        intrinsics: intrinsics,
                        depthMap: depthMap,
                        depthWidth: CVPixelBufferGetWidth(depthMap),
                        depthHeight: CVPixelBufferGetHeight(depthMap)
                    )
                }
            }

            guard willExtract, let extractBuffer else { return }
            // Lightweight pack: unpack keys + copy color into the reused GPU buffer.
            let count = PerfDiag.timed("voxel_pack", warnOverMs: 3) { grid.packForExtraction(into: extractBuffer.contents(), maxVoxels: VoxelGrid.maxVoxels) }

            DispatchQueue.main.async {
                guard let self = self else { return }
                if count > 0 {
                    self.dispatchVoxelExtraction(voxelCount: count, camTransform: transform ?? matrix_identity_float4x4)
                } else {
                    self.extractionInProgress = false
                }
            }
        }
    }

    /// GPU mesh extraction: emit one billboard quad + color texel per packed voxel via the
    /// extractVoxelQuads kernel. Runs on the main thread because LowLevelMesh/LowLevelTexture
    /// are @MainActor; the voxels were already packed into `voxelExtractBuffer` on the voxel
    /// queue, and `extractionInProgress` (set when this was scheduled) is cleared here.
    private func dispatchVoxelExtraction(voxelCount: Int, camTransform: simd_float4x4) {
        guard let llm = voxelLowLevelMesh,
              let colorTex = voxelColorTexture,
              let extractBuffer = voxelExtractBuffer else {
            extractionInProgress = false
            return
        }

        // Viewplane billboard basis — computed once, all quads share it (kernel only
        // does per-voxel distance scaling).
        let camPos = SIMD3<Float>(camTransform.columns.3.x, camTransform.columns.3.y, camTransform.columns.3.z)
        let right = simd_normalize(SIMD3<Float>(camTransform.columns.0.x, camTransform.columns.0.y, camTransform.columns.0.z))
        let up = simd_normalize(SIMD3<Float>(camTransform.columns.1.x, camTransform.columns.1.y, camTransform.columns.1.z))

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else {
            extractionInProgress = false
            return
        }

        // Double-buffered GPU resources: replace() hands back fresh backing that the
        // LowLevelMesh/Texture swap in when the command buffer completes. The kernel
        // writes vertices into the buffer and colors into the texture directly.
        let vertexMTLBuffer = llm.replace(bufferIndex: 0, using: cmdBuf)
        let colorMTLTexture = colorTex.replace(using: cmdBuf)

        encoder.setComputePipelineState(extractPipelineState)
        encoder.setBuffer(extractBuffer, offset: 0, index: 0)
        var uniforms = VoxelExtractUniforms(
            camPos: camPos,
            right: right,
            up: up,
            texWidth: UInt32(voxelTexWidth),
            texHeight: UInt32(voxelTexHeight),
            voxelCount: UInt32(voxelCount)
        )
        encoder.setBytes(&uniforms, length: MemoryLayout<VoxelExtractUniforms>.stride, index: 1)
        encoder.setBuffer(vertexMTLBuffer, offset: 0, index: 2)
        encoder.setTexture(colorMTLTexture, index: 0)

        let threadsPerGroup = min(extractPipelineState.maxTotalThreadsPerThreadgroup, 64)
        let threadGroups = MTLSize(width: (voxelCount + threadsPerGroup - 1) / threadsPerGroup, height: 1, depth: 1)
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: MTLSize(width: threadsPerGroup, height: 1, depth: 1))
        encoder.endEncoding()

        let iPerVoxel = indicesPerVoxel
        cmdBuf.addCompletedHandler { [weak self] cb in
            // Perf diagnostics: on-GPU duration of the (up to 350K-thread) voxel extract pass.
            if PerfDiag.enabled {
                let gpuMs = (cb.gpuEndTime - cb.gpuStartTime) * 1000.0
                PerfDiag.log("VR GPU extract \(voxelCount) voxels \(Int(gpuMs))ms")
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Set the visible index count to match the buffer the GPU just filled.
                self.voxelLowLevelMesh?.parts.replaceAll([
                    LowLevelMesh.Part(
                        indexCount: voxelCount * iPerVoxel,
                        topology: .triangle,
                        materialIndex: 0,
                        bounds: BoundingBox(min: [-100, -100, -100], max: [100, 100, 100])
                    )
                ])
                self.extractionInProgress = false
                if !self.hasRenderedFirstFrame && voxelCount > 0 {
                    self.hasRenderedFirstFrame = true
                    // Show all VR entities now that content is ready. The live point cloud
                    // can be hidden via a Developer Mode toggle (read at first reveal) to
                    // isolate and inspect the accumulated voxels on their own.
                    let hideLivePoints = UserDefaults.standard.bool(forKey: AppConstants.Key.hideLivePoints)
                    self.skyboxEntity?.isEnabled = true
                    self.pointCloudEntity?.isEnabled = !hideLivePoints
                    self.voxelEntity?.isEnabled = true
                }
            }
        }
        cmdBuf.commit()
    }

    // MARK: - Voxel Reset

    /// Clear all accumulated voxels without destroying the manager.
    /// Called when ARKit's coordinate system shifts (re-initialization, relocalizing)
    /// to prevent ghost voxels at wrong world positions.
    func resetVoxels() {
        // Route the hash-map reset through the voxel queue so it can't race an in-flight
        // merge/decay. FIFO ordering means it lands after any already-queued work.
        if let grid = voxelGrid {
            voxelQueue.async { grid.reset() }
        }
        lastIntegrationTransform = nil
        lastIntegrationIntrinsics = nil
        lastIntegrationDepthMap = nil
        integrationFrameCounter = 0
        // Also blank the *rendered* voxel mesh, not just the accumulation grid. The voxel
        // entity lives under AnchorEntity(world:.zero); on a tracking loss the relocalization
        // correction snaps the world origin, so a stale cloud left on screen visibly flies off
        // into a corner (it's baked in the pre-correction frame). Dropping the part's index
        // count to 0 renders nothing until the next post-reloc extraction repopulates it in the
        // corrected frame. RealityKit mutation → main.
        DispatchQueue.main.async { [weak self] in
            self?.voxelLowLevelMesh?.parts.replaceAll([
                LowLevelMesh.Part(
                    indexCount: 0,
                    topology: .triangle,
                    materialIndex: 0,
                    bounds: BoundingBox(min: [-100, -100, -100], max: [100, 100, 100])
                )
            ])
        }
    }

    // MARK: - Cleanup

    func destroy() {
        // Remove bloom post-process callback
        arView?.renderCallbacks.postProcess = nil
        bloomIntermediateTexture = nil

        pointCloudEntity?.removeFromParent()
        skyboxEntity?.removeFromParent()
        voxelEntity?.removeFromParent()
        pointCloudEntity = nil
        skyboxEntity = nil
        voxelEntity = nil
        lowLevelMesh = nil
        colorTexture = nil
        voxelLowLevelMesh = nil
        voxelColorTexture = nil
        voxelExtractBuffer = nil
        // Route the reset through the voxel queue so it can't race an in-flight
        // merge/decay; the closure retains `grid` until it runs.
        if let grid = voxelGrid {
            voxelQueue.async { grid.reset() }
        }
        lastIntegrationTransform = nil
        lastIntegrationIntrinsics = nil
        lastIntegrationDepthMap = nil
        extractionInProgress = false
        voxelSetupComplete = false
        integrationFrameCounter = 0
        parentEntity = nil
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

/// Uniforms for the extractVoxelQuads kernel. Layout must match the Metal
/// `VoxelExtractUniforms` struct (SIMD3<Float> is 16-byte aligned → 64 bytes total).
struct VoxelExtractUniforms {
    var camPos: SIMD3<Float>
    var right: SIMD3<Float>
    var up: SIMD3<Float>
    var texWidth: UInt32
    var texHeight: UInt32
    var voxelCount: UInt32
    private var _pad: UInt32 = 0

    init(camPos: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>, texWidth: UInt32, texHeight: UInt32, voxelCount: UInt32) {
        self.camPos = camPos
        self.right = right
        self.up = up
        self.texWidth = texWidth
        self.texHeight = texHeight
        self.voxelCount = voxelCount
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
