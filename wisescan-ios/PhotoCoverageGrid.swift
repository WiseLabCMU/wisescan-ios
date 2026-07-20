import Foundation
import simd
import CoreVideo

/// Sparse world-space voxel grid tracking which surfaces have been covered by sharp
/// photo keyframes, and from which directions.
///
/// Coverage is stamped by **unprojecting the keyframe's own depth map**: every depth
/// pixel is a surface the photo actually imaged, so marking those voxels is
/// occlusion-correct by construction — geometry behind a wall never appears in the
/// depth map, so it can never be marked covered through the wall (the failure mode of
/// the earlier frustum/AABB approach).
///
/// Distinct from `VoxelGrid` (the VR-mode Metal point-cloud accumulator): this grid is
/// coarse (25cm cells vs 2cm), CPU-only, unbounded in extent (sparse dictionary), and
/// tracks photo coverage + view-direction diversity rather than color.
///
/// Threading: ALL access is main-thread only. Stamping is a rare event (one per
/// stillness keyframe) over ~12K decimated depth samples — sub-millisecond on any
/// supported device — so no locking or queue-hopping is warranted.
final class PhotoCoverageGrid {

    /// Per-voxel coverage record.
    struct Coverage {
        /// Bitmask of world-space view-direction octants this voxel was photographed
        /// from (sign bits of the camera→surface direction). Angular diversity — a
        /// SECONDARY quality signal (view-dependent effects like speculars need it).
        var viewOctants: UInt8 = 0
        /// Bitmask of quantized camera STANDPOINTS (~0.5m cells, hashed to 8 bits)
        /// this voxel was photographed from. Parallax/baseline diversity — the PRIMARY
        /// multi-view signal for reconstruction: rotating in place re-sets the same bit
        /// (no credit); stepping sideways sets a new one.
        var standpointMask: UInt8 = 0
        /// Number of keyframes that covered this voxel.
        var count: UInt16 = 0
    }

    /// Result of stamping one keyframe.
    struct StampResult {
        /// Distinct voxels this keyframe's depth map touched.
        let stamped: Int
        /// Of those, how many were not covered by any earlier keyframe.
        let newlyCovered: Int
        /// Fraction of this keyframe's voxels shared with earlier keyframes (0 when
        /// nothing was stamped). Photogrammetry-style still-to-still overlap: ~0.6 is
        /// the classic target; ~0 means texture seams, ~1 means a redundant still.
        var overlap: Double {
            stamped > 0 ? Double(stamped - newlyCovered) / Double(stamped) : 0
        }
    }

    private(set) var covered: [SIMD3<Int32>: Coverage] = [:]

    /// Voxels newly covered by the most recent stamp (for incremental consumers).
    private(set) var lastStampNewCount: Int = 0

    // Running still-to-still overlap stats across the session (first still excluded —
    // it has nothing to overlap with, so counting it would drag the mean toward 0).
    private var overlapSum: Double = 0
    private var overlapSamples: Int = 0
    /// Mean still-to-still overlap across all stills after the first (0 when <2 stills).
    var meanStillOverlap: Double { overlapSamples > 0 ? overlapSum / Double(overlapSamples) : 0 }

    var coveredCount: Int { covered.count }

    /// Fraction of covered voxels photographed from ≥2 distinct standpoints — the
    /// parallax-diversity aggregate the coach and scan metadata report.
    var multiStandpointFraction: Double {
        guard !covered.isEmpty else { return 0 }
        let multi = covered.values.reduce(0) { $0 + ($1.standpointMask.nonzeroBitCount >= 2 ? 1 : 0) }
        return Double(multi) / Double(covered.count)
    }

    /// Grid key for a world-space position.
    static func key(for position: SIMD3<Float>) -> SIMD3<Int32> {
        let cell = AppConstants.photoCoverageVoxelSize
        return SIMD3<Int32>(
            Int32((position.x / cell).rounded(.down)),
            Int32((position.y / cell).rounded(.down)),
            Int32((position.z / cell).rounded(.down))
        )
    }

    func isCovered(_ key: SIMD3<Int32>) -> Bool {
        covered[key] != nil
    }

    /// Packs a coverage-cell key into an Int64 for cross-grid set membership (21 bits per
    /// axis — unambiguous within ±1M cells, i.e. ±260km at 25cm cells). VoxelGrid uses this
    /// to test its fine voxels against the covered set without touching this main-owned grid.
    static func packedKey(_ key: SIMD3<Int32>) -> Int64 {
        (Int64(key.x) & 0x1F_FFFF) | ((Int64(key.y) & 0x1F_FFFF) << 21) | ((Int64(key.z) & 0x1F_FFFF) << 42)
    }

    /// Snapshot of all covered cells as packed keys — safe to hand to another queue
    /// (the VR voxel queue) since it shares no storage with this grid.
    func coveredPackedKeys() -> Set<Int64> {
        var keys = Set<Int64>(minimumCapacity: covered.count)
        for key in covered.keys { keys.insert(Self.packedKey(key)) }
        return keys
    }

    /// Number of distinct view octants this voxel has been photographed from (0 if uncovered).
    func viewDiversity(_ key: SIMD3<Int32>) -> Int {
        covered[key].map { $0.viewOctants.nonzeroBitCount } ?? 0
    }

    /// Number of distinct standpoint bits (~parallax diversity) for this voxel (0 if uncovered).
    func standpointDiversity(_ key: SIMD3<Int32>) -> Int {
        covered[key].map { $0.standpointMask.nonzeroBitCount } ?? 0
    }

    func reset() {
        covered.removeAll(keepingCapacity: true)
        lastStampNewCount = 0
        overlapSum = 0
        overlapSamples = 0
    }

    /// Stamps coverage from a keyframe's depth map.
    ///
    /// - Parameters:
    ///   - depthMap: the keyframe's scene depth (Float32, typically 256×192).
    ///   - cameraTransform: camera-to-world pose of the keyframe.
    ///   - intrinsics: pinhole intrinsics of the keyframe's RGB image.
    ///   - imageWidth/imageHeight: RGB image dimensions the intrinsics refer to
    ///     (the depth map is smaller; intrinsics are rescaled internally).
    /// - Returns: number of newly covered voxels.
    @discardableResult
    func stamp(
        depthMap: CVPixelBuffer,
        cameraTransform: simd_float4x4,
        intrinsics: simd_float3x3,
        imageWidth: Int,
        imageHeight: Int
    ) -> StampResult {
        let empty = StampResult(stamped: 0, newlyCovered: 0)
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            return empty
        }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let depthW = CVPixelBufferGetWidth(depthMap)
        let depthH = CVPixelBufferGetHeight(depthMap)
        guard depthW > 0, depthH > 0, imageWidth > 0, imageHeight > 0,
              let base = CVPixelBufferGetBaseAddress(depthMap) else { return empty }
        guard let geometry = DepthGeometry(
            intrinsics: intrinsics, imageWidth: imageWidth, imageHeight: imageHeight,
            depthWidth: depthW, depthHeight: depthH
        ) else { return empty }

        let camPos = SIMD3<Float>(
            cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z
        )
        let wasEmpty = covered.isEmpty
        let context = StampContext(
            geometry: geometry,
            cameraTransform: cameraTransform,
            cameraPosition: camPos,
            // Standpoint bit: camera position quantized to ~0.5m cells, hashed to one
            // of 8 bits. All samples of one keyframe share it (one photo = one standpoint).
            standpointBit: Self.standpointBit(for: camPos)
        )
        let result = integrate(
            depthPtr: base.assumingMemoryBound(to: Float32.self),
            floatsPerRow: CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride,
            width: depthW, height: depthH,
            context: context
        )

        lastStampNewCount = result.newlyCovered
        // Track mean still-to-still overlap, excluding the session's first still (it
        // has nothing to overlap with) and empty stamps (no usable depth).
        if !wasEmpty && result.stamped > 0 {
            overlapSum += result.overlap
            overlapSamples += 1
        }
        return result
    }

    /// Pinhole intrinsics rescaled to depth-map pixel coordinates (nil when degenerate).
    private struct DepthGeometry {
        let focalX: Float
        let focalY: Float
        let centerX: Float
        let centerY: Float

        init?(intrinsics: simd_float3x3, imageWidth: Int, imageHeight: Int, depthWidth: Int, depthHeight: Int) {
            let scaleX = Float(depthWidth) / Float(imageWidth)
            let scaleY = Float(depthHeight) / Float(imageHeight)
            focalX = intrinsics[0][0] * scaleX
            focalY = intrinsics[1][1] * scaleY
            guard focalX > 0, focalY > 0 else { return nil }
            centerX = intrinsics[2][0] * scaleX
            centerY = intrinsics[2][1] * scaleY
        }
    }

    /// Everything the per-sample integration loop needs about the keyframe being stamped.
    private struct StampContext {
        let geometry: DepthGeometry
        let cameraTransform: simd_float4x4
        let cameraPosition: SIMD3<Float>
        let standpointBit: UInt8
    }

    /// Unprojects the (strided) depth samples of one keyframe into world space and marks
    /// their voxels. Must run while the depth buffer's base address is locked.
    private func integrate(
        depthPtr: UnsafePointer<Float32>,
        floatsPerRow: Int,
        width: Int,
        height: Int,
        context: StampContext
    ) -> StampResult {
        let stride = AppConstants.photoCoverageDepthStride
        let maxDepth = AppConstants.photoCoverageMaxDistance
        var newlyCovered = 0
        // Distinct voxels touched by THIS stamp — adjacent depth samples often land in
        // the same 25cm cell, and overlap must be measured in distinct voxels.
        var touched = Set<SIMD3<Int32>>()

        for row in Swift.stride(from: 0, to: height, by: stride) {
            let rowStart = row * floatsPerRow
            for col in Swift.stride(from: 0, to: width, by: stride) {
                let meters = depthPtr[rowStart + col]
                guard meters.isFinite, meters > 0.1, meters < maxDepth else { continue }

                // Unproject depth pixel to camera space (ARKit camera looks down -Z),
                // then to world space. Same convention as the face-anchor unprojection.
                let xCam = (Float(col) - context.geometry.centerX) * meters / context.geometry.focalX
                let yCam = (context.geometry.centerY - Float(row)) * meters / context.geometry.focalY
                let world4 = context.cameraTransform * SIMD4<Float>(xCam, yCam, -meters, 1.0)
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)

                // View-direction octant (world-space camera→surface direction sign bits).
                let dir = world - context.cameraPosition
                let octant = (dir.x >= 0 ? 1 : 0) | (dir.y >= 0 ? 2 : 0) | (dir.z >= 0 ? 4 : 0)
                let octantBit = UInt8(1 << octant)

                let key = Self.key(for: world)
                touched.insert(key)
                if var existing = covered[key] {
                    existing.viewOctants |= octantBit
                    existing.standpointMask |= context.standpointBit
                    existing.count &+= 1
                    covered[key] = existing
                } else {
                    covered[key] = Coverage(viewOctants: octantBit, standpointMask: context.standpointBit, count: 1)
                    newlyCovered += 1
                }
            }
        }
        return StampResult(stamped: touched.count, newlyCovered: newlyCovered)
    }

    /// Hashes a camera position (quantized to `photoCoverageStandpointCell` cells) to
    /// one of 8 standpoint bits. Collisions across distant standpoints are acceptable —
    /// the mask is a diversity estimate, not an exact count.
    private static func standpointBit(for position: SIMD3<Float>) -> UInt8 {
        let cell = AppConstants.photoCoverageStandpointCell
        let cellX = Int32((position.x / cell).rounded(.down))
        let cellY = Int32((position.y / cell).rounded(.down))
        let cellZ = Int32((position.z / cell).rounded(.down))
        let hash = (cellX &* 73_856_093) ^ (cellY &* 19_349_663) ^ (cellZ &* 83_492_791)
        return UInt8(1 << (Int(hash & 0x7FFF_FFFF) % 8))
    }
}
