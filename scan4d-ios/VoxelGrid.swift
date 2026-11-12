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
/// 4. `packForExtraction()` — CPU packs occupied voxels into a flat buffer; the
///    `extractVoxelQuads` GPU kernel then emits camera-facing quads + color texels at 2Hz
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
        /// Lies inside a photo-covered coverage cell (see applyPhotoCoverage). Uncovered
        /// voxels are amber-tinted at pack time — the VR analog of the AR amber overlay.
        /// Fits the struct's existing padding: no memory growth.
        var photoCovered: Bool = false

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

    /// CPU→GPU packed occupied-voxel record consumed by the `extractVoxelQuads` kernel.
    /// Must match Metal `ExtractVoxel` layout exactly (10 bytes).
    /// `a` carries confidence mapped to [0,255] (used as the quad's alpha).
    struct ExtractVoxel {
        var gridX: Int16
        var gridY: Int16
        var gridZ: Int16
        var r: UInt8
        var g: UInt8
        var b: UInt8
        var a: UInt8
    }

    // MARK: - Properties

    /// Sparse hash map: packed grid coords → accumulated color.
    /// Key = Int64 packed from (x, y, z) Int16 values.
    private(set) var voxels: [Int64: VoxelData] = [:]

    /// Photo-covered coverage cells (PhotoCoverageGrid.packedKey format), replaced by
    /// applyPhotoCoverage after each keyframe stamp. Voxels created later inherit coverage
    /// from this set (mergeAppendBuffer). Voxel-queue owned, like `voxels`.
    private var photoCoveredCells = Set<Int64>()

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

    /// Copy the GPU-written VoxelEntry structs out of the append buffer into a CPU array.
    ///
    /// Call this on the thread that owns the append-buffer lifecycle (the command-buffer
    /// completion handler, before the next integration resets/overwrites the buffer). The
    /// returned snapshot can then be merged into the hash map off the main thread, since it
    /// no longer references GPU memory. (~1ms for 49K entries.)
    func snapshotAppendBuffer() -> [VoxelEntry] {
        let counterPtr = appendCounter.contents().bindMemory(to: UInt32.self, capacity: 1)
        let count = min(Int(counterPtr.pointee), Self.appendCapacity)
        guard count > 0 else { return [] }
        let entriesPtr = appendBuffer.contents().bindMemory(to: VoxelEntry.self, capacity: count)
        return Array(UnsafeBufferPointer(start: entriesPtr, count: count))
    }

    /// Merge a snapshot of GPU-written VoxelEntry structs into the hash map.
    /// Touches `voxels`/`observedKeysThisFrame`, so it must run on the voxel serial queue.
    func mergeAppendBuffer(_ entries: [VoxelEntry], frameCounter: UInt32) {
        // Track which voxels were observed this frame (for contradiction detection)
        observedKeysThisFrame.removeAll(keepingCapacity: true)

        for entry in entries {
            // Validate grid bounds
            guard entry.gridX >= -Int16(Self.gridDim / 2) && entry.gridX < Int16(Self.gridDim / 2),
                  entry.gridY >= -Int16(Self.gridDim / 2) && entry.gridY < Int16(Self.gridDim / 2),
                  entry.gridZ >= -Int16(Self.gridDim / 2) && entry.gridZ < Int16(Self.gridDim / 2) else {
                continue
            }

            let key = Self.packKey(x: entry.gridX, y: entry.gridY, z: entry.gridZ)
            let countBefore = voxels.count
            voxels[key, default: VoxelData()].addObservation(r: entry.r, g: entry.g, b: entry.b, frame: frameCounter)
            // Newly created voxel (count grew): inherit photo coverage if its coverage cell
            // was already photographed — e.g. densification of an already-shot wall must not
            // re-amber it. O(1) set test, and only for genuinely new voxels.
            if voxels.count != countBefore, !photoCoveredCells.isEmpty,
               photoCoveredCells.contains(Self.packedCoverageKey(gridX: entry.gridX, gridY: entry.gridY, gridZ: entry.gridZ)) {
                voxels[key]?.photoCovered = true
            }
            observedKeysThisFrame.insert(key)
        }
    }

    /// Set of voxel keys that received observations in the most recent merge.
    /// Used by decayContradictedVoxels to skip freshly-confirmed voxels.
    private var observedKeysThisFrame = Set<Int64>()

    // MARK: - Photo Coverage

    /// Applies the latest photo-coverage cell set from a keyframe stamp: flags every voxel
    /// lying in a covered 25cm cell so packForExtraction stops amber-tinting it, and retains
    /// the set so voxels created later inherit coverage at merge time. Runs once per accepted
    /// keyframe (rare) on the voxel serial queue, which owns `voxels`.
    func applyPhotoCoverage(coveredCells: Set<Int64>) {
        photoCoveredCells = coveredCells
        guard !coveredCells.isEmpty else { return }
        // Iterate without mutating (safe), then flip — newly covered flips are a small set
        // (~150 fine voxels per newly covered coarse cell).
        var toFlip: [Int64] = []
        for (key, data) in voxels where !data.photoCovered {
            let (gridX, gridY, gridZ) = Self.unpackKey(key)
            if coveredCells.contains(Self.packedCoverageKey(gridX: gridX, gridY: gridY, gridZ: gridZ)) {
                toFlip.append(key)
            }
        }
        for key in toFlip { voxels[key]?.photoCovered = true }
    }

    /// The PhotoCoverageGrid packed cell key containing a fine voxel — the shared coordinate
    /// bridge between this 2cm grid and the 25cm coverage grid (identical floor quantization).
    static func packedCoverageKey(gridX: Int16, gridY: Int16, gridZ: Int16) -> Int64 {
        PhotoCoverageGrid.packedKey(
            PhotoCoverageGrid.key(for: worldPosition(gridX: gridX, gridY: gridY, gridZ: gridZ))
        )
    }

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

    // (packForExtraction lives in VoxelGrid+Extraction.swift.)

    /// Clear all accumulated voxels (e.g., when starting a new recording)
    func reset() {
        voxels.removeAll(keepingCapacity: true)
        photoCoveredCells.removeAll(keepingCapacity: true)
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
}
