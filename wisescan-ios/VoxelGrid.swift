import Foundation
import Metal
import RealityKit
import ARKit

/// Sparse voxel hash map that accumulates LiDAR depth + camera color across frames.
///
/// The grid covers an 8m cube centered at the origin with 2cm voxels (400³ possible cells).
/// Only occupied cells are stored (surfaces only, typically 1-5% of volume).
///
/// ## GPU Integration Flow
/// 1. `resetAppendBuffer()` — zero the atomic counter before GPU dispatch
/// 2. GPU `integrateVoxels` kernel writes `VoxelEntry` structs to the append buffer
/// 3. `mergeAppendBuffer()` — CPU reads back and merges into the hash map (~1ms for 49K entries)
/// 4. `extractMesh()` — writes camera-facing quads into vertex/color buffers at 2Hz
///
/// ## Memory Budget
/// - Hash map: 350K entries × ~20 bytes = ~7MB
/// - Append buffer: 49,152 entries × 8 bytes = ~400KB
/// - Vertex buffer: 1.4M vertices × 20 bytes = ~28MB (managed by PointCloudManager)
/// - Color texture: 1024×512 × 4 bytes = ~2MB (managed by PointCloudManager)
class VoxelGrid {

    // MARK: - Grid Constants

    /// Grid origin in world space (bottom-left-near corner of the 8m cube)
    static let origin = SIMD3<Float>(-4.0, -4.0, -4.0)
    /// Cell size in meters
    static let cellSize: Float = 0.02
    /// Number of cells per axis (8m / 0.02m = 400)
    static let gridDim: Int = 400
    /// Maximum voxels to render (vertex buffer cap)
    static let maxVoxels: Int = 350_000
    /// Maximum entries in the GPU append buffer (one per depth pixel)
    static let appendCapacity: Int = 49_152  // 256 × 192
    /// Billboard quad half-size in meters (2.5cm / 2 = slightly > cell size for overlap)


    // MARK: - Voxel Data

    /// Per-voxel accumulated color (EMA) with confidence for decay.
    /// Recent observations dominate after ~10 samples (EMA α=0.1).
    /// Confidence tracks whether the voxel is still valid: confirmed by live depth = 1.0,
    /// contradicted by live depth = decays toward 0, pruned when it hits 0.
    struct VoxelData {
        var r: Float = 0           // Current EMA red [0..255]
        var g: Float = 0           // Current EMA green [0..255]
        var b: Float = 0           // Current EMA blue [0..255]
        var count: UInt16 = 0      // Number of observations (for first-sample init)
        var confidence: Float = 1.0  // [0..1], maps to alpha. 0 = prune candidate
        var lastSeenFrame: UInt32 = 0  // Frame counter when last observed

        /// Current color as UInt8 RGB
        var averageColor: (r: UInt8, g: UInt8, b: UInt8) {
            guard count > 0 else { return (0, 0, 0) }
            return (
                UInt8(min(max(r, 0), 255)),
                UInt8(min(max(g, 0), 255)),
                UInt8(min(max(b, 0), 255))
            )
        }

        /// Merge a new observation using exponential moving average.
        /// Also resets confidence to 1.0 (re-confirmed by live depth).
        mutating func addObservation(r newR: UInt8, g newG: UInt8, b newB: UInt8, frame: UInt32) {
            let fr = Float(newR)
            let fg = Float(newG)
            let fb = Float(newB)
            if count == 0 {
                r = fr; g = fg; b = fb
            } else {
                let alpha: Float = 0.1
                let oneMinusAlpha: Float = 0.9
                r = r * oneMinusAlpha + fr * alpha
                g = g * oneMinusAlpha + fg * alpha
                b = b * oneMinusAlpha + fb * alpha
            }
            confidence = 1.0
            lastSeenFrame = frame
            if count < UInt16.max { count += 1 }
        }
    }

    /// GPU-shared struct for the append buffer. Must match Metal `VoxelEntry` layout exactly.
    /// 10 bytes: [gridX: Int16, gridY: Int16, gridZ: Int16, r: UInt8, g: UInt8, b: UInt8, _pad: UInt8]
    struct VoxelEntry {
        var gridX: Int16
        var gridY: Int16
        var gridZ: Int16
        var r: UInt8
        var g: UInt8
        var b: UInt8
        var _pad: UInt8 = 0
    }

    // MARK: - Properties

    /// Sparse hash map: packed grid coords → accumulated color.
    /// Key = Int64 packed from (x, y, z) Int16 values.
    private(set) var voxels: [Int64: VoxelData] = [:]

    /// GPU append buffer — the integrateVoxels kernel writes VoxelEntry structs here.
    let appendBuffer: MTLBuffer
    /// Atomic counter for the append buffer (UInt32).
    let appendCounter: MTLBuffer

    /// Number of currently occupied voxels
    var voxelCount: Int { voxels.count }

    // MARK: - Init

    init?(device: MTLDevice) {
        let entrySize = MemoryLayout<VoxelEntry>.stride
        guard let appendBuf = device.makeBuffer(
            length: Self.appendCapacity * entrySize,
            options: .storageModeShared
        ) else {
            print("[VoxelGrid] Failed to allocate append buffer")
            return nil
        }
        guard let counterBuf = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else {
            print("[VoxelGrid] Failed to allocate counter buffer")
            return nil
        }
        self.appendBuffer = appendBuf
        self.appendCounter = counterBuf
        appendBuf.label = "VoxelAppendBuffer"
        counterBuf.label = "VoxelAppendCounter"

        // Pre-reserve capacity for the hash map
        voxels.reserveCapacity(Self.maxVoxels)
    }

    // MARK: - GPU Buffer Management

    /// Zero the atomic counter before dispatching the GPU integration kernel.
    func resetAppendBuffer() {
        let ptr = appendCounter.contents().bindMemory(to: UInt32.self, capacity: 1)
        ptr.pointee = 0
    }

    /// Read back GPU-written VoxelEntry structs and merge into the hash map.
    /// Called from the command buffer completion handler (~1ms for 49K entries).
    func mergeAppendBuffer(frameCounter: UInt32) {
        let counterPtr = appendCounter.contents().bindMemory(to: UInt32.self, capacity: 1)
        let count = min(Int(counterPtr.pointee), Self.appendCapacity)
        guard count > 0 else { return }

        let entriesPtr = appendBuffer.contents().bindMemory(to: VoxelEntry.self, capacity: count)

        // Track which voxels were observed this frame (for contradiction detection)
        observedKeysThisFrame.removeAll(keepingCapacity: true)

        for i in 0..<count {
            let entry = entriesPtr[i]

            // Validate grid bounds
            guard entry.gridX >= -Int16(Self.gridDim / 2) && entry.gridX < Int16(Self.gridDim / 2),
                  entry.gridY >= -Int16(Self.gridDim / 2) && entry.gridY < Int16(Self.gridDim / 2),
                  entry.gridZ >= -Int16(Self.gridDim / 2) && entry.gridZ < Int16(Self.gridDim / 2) else {
                continue
            }

            let key = Self.packKey(x: entry.gridX, y: entry.gridY, z: entry.gridZ)
            voxels[key, default: VoxelData()].addObservation(r: entry.r, g: entry.g, b: entry.b, frame: frameCounter)
            observedKeysThisFrame.insert(key)
        }
    }

    /// Set of voxel keys that received observations in the most recent merge.
    /// Used by decayContradictedVoxels to skip freshly-confirmed voxels.
    private var observedKeysThisFrame = Set<Int64>()

    // MARK: - Confidence Decay

    /// Decay voxels that are visible in the current camera frustum but were NOT re-observed.
    ///
    /// If the camera can see a voxel's world position but no depth pixel mapped to that cell,
    /// it means either (a) the surface moved or (b) the surface was occluded by something closer.
    /// We check the live depth: if the live depth at the projected pixel is significantly
    /// different from the voxel's expected depth, we reduce confidence.
    ///
    /// - Parameters:
    ///   - cameraTransform: Current camera world-space transform (4×4)
    ///   - intrinsics: Camera intrinsics (3×3) for projection
    ///   - depthMap: Live depth map from ARFrame.sceneDepth (CVPixelBuffer)
    ///   - depthWidth: Width of the depth map
    ///   - depthHeight: Height of the depth map
    func decayContradictedVoxels(
        cameraTransform: simd_float4x4,
        intrinsics: simd_float3x3,
        depthMap: CVPixelBuffer,
        depthWidth: Int,
        depthHeight: Int
    ) {
        let viewMatrix = cameraTransform.inverse
        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]

        // Lock the depth buffer for CPU read
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let depthPtr = depthBaseAddress.assumingMemoryBound(to: Float32.self)
        let floatsPerRow = bytesPerRow / MemoryLayout<Float32>.stride

        // Decay rate per contradiction. At 5Hz integration, 0.15 → full fade in ~1.3s (7 frames)
        let decayRate: Float = 0.15
        // Depth tolerance: how far off the live depth can be before we call it a contradiction.
        // 2 cells (4cm) allows for normal noise; anything beyond = surface changed.
        let depthTolerance: Float = Self.cellSize * 2.0

        var keysToRemove: [Int64] = []

        for (key, var data) in voxels {
            // Skip voxels that were just re-observed — they're confirmed
            if observedKeysThisFrame.contains(key) { continue }

            let (gx, gy, gz) = Self.unpackKey(key)
            let worldPos = Self.worldPosition(gridX: gx, gridY: gy, gridZ: gz)

            // Project world position into camera space
            let camSpace4 = viewMatrix * SIMD4<Float>(worldPos.x, worldPos.y, worldPos.z, 1.0)
            let camSpace = SIMD3<Float>(camSpace4.x, camSpace4.y, camSpace4.z)

            // Camera looks along -Z. Point must be in front of camera.
            let voxelDepth = -camSpace.z
            if voxelDepth < 0.1 || voxelDepth > 5.0 { continue }

            // Project to pixel coordinates
            let px = (camSpace.x * fx / (-camSpace.z)) + cx
            let py = (-camSpace.y * fy / (-camSpace.z)) + cy

            let ix = Int(px)
            let iy = Int(py)

            // Must be within the depth map bounds (in frustum)
            if ix < 0 || ix >= depthWidth || iy < 0 || iy >= depthHeight { continue }

            // Read live depth at this pixel
            let liveDepth = depthPtr[iy * floatsPerRow + ix]

            // Skip invalid depth readings
            if liveDepth <= 0 || liveDepth.isNaN { continue }

            // Contradiction: live depth is significantly different from voxel depth.
            // If live depth is CLOSER → something new is in front (occlusion, not contradiction).
            // If live depth is FARTHER → the surface that was here is gone.
            let depthDiff = liveDepth - voxelDepth
            if depthDiff > depthTolerance {
                // Live depth sees FARTHER than the voxel → surface has moved away
                data.confidence -= decayRate
                if data.confidence <= 0 {
                    keysToRemove.append(key)
                } else {
                    voxels[key] = data
                }
            }
            // If live depth is closer (negative diff) → something is occluding, don't decay
            // If depth matches → consistent, but we don't boost confidence here
            // (only fresh observations boost confidence via addObservation)
        }

        // Prune dead voxels
        for key in keysToRemove {
            voxels.removeValue(forKey: key)
        }
    }

    // MARK: - Mesh Extraction

    /// Write viewplane-aligned billboard quads for all occupied voxels into the provided buffers.
    ///
    /// Uses **viewplane billboarding**: all quads share the same camera-plane orientation,
    /// computed once from the camera transform. Only distance-based scaling is per-voxel.
    /// This is O(1) orientation + O(n) scaling vs O(n) orientation with spherical billboarding.
    /// For 2cm voxels the visual difference is negligible.
    ///
    /// - Parameters:
    ///   - vertexBuffer: Destination for position + UV data (20 bytes per vertex)
    ///   - colorBuffer: Destination for RGBA8 texel data (4 bytes per voxel)
    ///   - texWidth: Color texture width (for UV calculation)
    ///   - texHeight: Color texture height (for UV calculation)
    ///   - cameraTransform: Full 4×4 camera transform for viewplane orientation + position
    /// - Returns: Number of voxels written (capped at maxVoxels)
    func extractMesh(
        vertexBuffer: UnsafeMutableRawPointer,
        colorBuffer: UnsafeMutableRawPointer,
        texWidth: Int,
        texHeight: Int,
        cameraTransform: simd_float4x4
    ) -> Int {
        let vertices = vertexBuffer.bindMemory(to: Float.self, capacity: Self.maxVoxels * 4 * 5)
        let colors = colorBuffer.bindMemory(to: UInt8.self, capacity: Self.maxVoxels * 4)

        // Precompute viewplane orientation ONCE for all voxels.
        let camPos = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)

        // Right = camera's X axis (already orthonormal in the transform)
        let right = simd_normalize(SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z))
        // Up = camera's Y axis
        let up = simd_normalize(SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z))

        var voxelIndex = 0

        for (key, data) in voxels {
            if voxelIndex >= Self.maxVoxels { break }

            let (gx, gy, gz) = Self.unpackKey(key)
            let center = Self.worldPosition(gridX: gx, gridY: gy, gridZ: gz)
            let avg = data.averageColor

            // Write color texel (one per voxel)
            let colorOffset = voxelIndex * 4
            colors[colorOffset + 0] = avg.r
            colors[colorOffset + 1] = avg.g
            colors[colorOffset + 2] = avg.b
            colors[colorOffset + 3] = UInt8(min(max(data.confidence * 255.0, 0), 255))

            // UV for this voxel's texel (center of the texel)
            let texX = voxelIndex % texWidth
            let texY = voxelIndex / texWidth
            let u = (Float(texX) + 0.5) / Float(texWidth)
            // Flip V for OpenGL convention (RealityKit UV origin at bottom-left)
            let v = 1.0 - (Float(texY) + 0.5) / Float(texHeight)

            // Per-voxel distance for size scaling (only per-voxel computation)
            let delta = camPos - center
            let dist = sqrtf(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)

            // Push voxel quad 2mm AWAY from camera so live points always render in front.
            // More reliable than ModelSortGroup for coplanar geometry.
            let pushDir = dist > 0.001 ? delta / dist : SIMD3<Float>(0, 0, 0)
            let biasedCenter = center - pushDir * 0.002

            // Scale quad size based on distance from camera.
            // Minimum = cellSize (2cm half = 0.01) so quads always fill the grid with no gaps.
            // Far away: larger (up to 4cm) to ensure gap-free coverage.
            // At 0.5m → 0.01 (2cm quad = cell size), at 2.5m+ → 0.02 (4cm quad)
            let half = min(max(dist * 0.008, 0.01), 0.02)

            // Scale shared right/up vectors by per-voxel half-size
            let r = right * half
            let u_vec = up * half

            let baseVertex = voxelIndex * 4 * 5  // 4 vertices × 5 floats each

            // Quad vertices: bottom-left, bottom-right, top-left, top-right
            writeVertex(vertices, baseVertex + 0,  biasedCenter - r - u_vec, u, v)
            writeVertex(vertices, baseVertex + 5,  biasedCenter + r - u_vec, u, v)
            writeVertex(vertices, baseVertex + 10, biasedCenter - r + u_vec, u, v)
            writeVertex(vertices, baseVertex + 15, biasedCenter + r + u_vec, u, v)

            voxelIndex += 1
        }

        return voxelIndex
    }

    /// Clear all accumulated voxels (e.g., when starting a new recording)
    func reset() {
        voxels.removeAll(keepingCapacity: true)
    }

    // MARK: - Helpers

    /// Pack (x, y, z) grid coordinates into a single Int64 key
    static func packKey(x: Int16, y: Int16, z: Int16) -> Int64 {
        return (Int64(x) & 0xFFFF) | ((Int64(y) & 0xFFFF) << 16) | ((Int64(z) & 0xFFFF) << 32)
    }

    /// Unpack an Int64 key back into (x, y, z) grid coordinates
    static func unpackKey(_ key: Int64) -> (Int16, Int16, Int16) {
        let x = Int16(truncatingIfNeeded: key)
        let y = Int16(truncatingIfNeeded: key >> 16)
        let z = Int16(truncatingIfNeeded: key >> 32)
        return (x, y, z)
    }

    /// Convert signed grid coordinates to world-space position (center of the voxel).
    /// Grid coords are signed offsets from center: gridX=0 → center of 8m cube (world origin).
    /// Metal kernel stores: entry.gridX = short(absoluteGrid.x - gridDim/2)
    /// World = origin + (gridX + gridDim/2 + 0.5) * cellSize
    static func worldPosition(gridX: Int16, gridY: Int16, gridZ: Int16) -> SIMD3<Float> {
        let halfDim = Float(gridDim / 2)
        return SIMD3<Float>(
            origin.x + (Float(gridX) + halfDim + 0.5) * cellSize,
            origin.y + (Float(gridY) + halfDim + 0.5) * cellSize,
            origin.z + (Float(gridZ) + halfDim + 0.5) * cellSize
        )
    }

    /// Write a single vertex (position + UV) into a float buffer
    @inline(__always)
    private func writeVertex(_ buf: UnsafeMutablePointer<Float>, _ offset: Int, _ pos: SIMD3<Float>, _ u: Float, _ v: Float) {
        buf[offset + 0] = pos.x
        buf[offset + 1] = pos.y
        buf[offset + 2] = pos.z
        buf[offset + 3] = u
        buf[offset + 4] = v
    }
}
