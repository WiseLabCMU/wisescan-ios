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
        /// from (sign bits of the camera→surface direction). Multi-view splat quality
        /// needs diverse bits set, not just any bit.
        var viewOctants: UInt8 = 0
        /// Number of keyframes that covered this voxel.
        var count: UInt16 = 0
    }

    private(set) var covered: [SIMD3<Int32>: Coverage] = [:]

    /// Voxels newly covered by the most recent stamp (for incremental consumers).
    private(set) var lastStampNewCount: Int = 0

    var coveredCount: Int { covered.count }

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

    /// Number of distinct view octants this voxel has been photographed from (0 if uncovered).
    func viewDiversity(_ key: SIMD3<Int32>) -> Int {
        covered[key].map { $0.viewOctants.nonzeroBitCount } ?? 0
    }

    func reset() {
        covered.removeAll(keepingCapacity: true)
        lastStampNewCount = 0
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
    ) -> Int {
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            return 0
        }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let depthW = CVPixelBufferGetWidth(depthMap)
        let depthH = CVPixelBufferGetHeight(depthMap)
        guard depthW > 0, depthH > 0, imageWidth > 0, imageHeight > 0,
              let base = CVPixelBufferGetBaseAddress(depthMap) else { return 0 }
        let floatsPerRow = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.stride
        let depthPtr = base.assumingMemoryBound(to: Float32.self)

        // Rescale image intrinsics to depth-map pixel coordinates.
        // fx/fy/cx/cy/px/py below are standard pinhole-camera notation.
        // swiftlint:disable identifier_name
        let scaleX = Float(depthW) / Float(imageWidth)
        let scaleY = Float(depthH) / Float(imageHeight)
        let fx = intrinsics[0][0] * scaleX
        let fy = intrinsics[1][1] * scaleY
        let cx = intrinsics[2][0] * scaleX
        let cy = intrinsics[2][1] * scaleY
        guard fx > 0, fy > 0 else { return 0 }

        let camPos = SIMD3<Float>(
            cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z
        )
        let stride = AppConstants.photoCoverageDepthStride
        let maxDepth = AppConstants.photoCoverageMaxDistance
        var newlyCovered = 0

        for py in Swift.stride(from: 0, to: depthH, by: stride) {
            let rowStart = py * floatsPerRow
            for px in Swift.stride(from: 0, to: depthW, by: stride) {
                let meters = depthPtr[rowStart + px]
                guard meters.isFinite, meters > 0.1, meters < maxDepth else { continue }

                // Unproject depth pixel to camera space (ARKit camera looks down -Z),
                // then to world space. Same convention as the face-anchor unprojection.
                let xCam = (Float(px) - cx) * meters / fx
                let yCam = (cy - Float(py)) * meters / fy
                let world4 = cameraTransform * SIMD4<Float>(xCam, yCam, -meters, 1.0)
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)

                // View-direction octant (world-space camera→surface direction sign bits).
                let dir = world - camPos
                let octant = (dir.x >= 0 ? 1 : 0) | (dir.y >= 0 ? 2 : 0) | (dir.z >= 0 ? 4 : 0)
                let octantBit = UInt8(1 << octant)

                let key = Self.key(for: world)
                if var existing = covered[key] {
                    existing.viewOctants |= octantBit
                    existing.count &+= 1
                    covered[key] = existing
                } else {
                    covered[key] = Coverage(viewOctants: octantBit, count: 1)
                    newlyCovered += 1
                }
            }
        }

        lastStampNewCount = newlyCovered
        return newlyCovered
    }
    // swiftlint:enable identifier_name
}
