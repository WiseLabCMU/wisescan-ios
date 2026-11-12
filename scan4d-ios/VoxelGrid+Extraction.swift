import Foundation
import simd

// Mesh-extraction packing for the VR voxel grid. Extracted from VoxelGrid.swift to keep
// that file under the length limit.
extension VoxelGrid {

    /// Pack the occupied voxels into a flat buffer for the `extractVoxelQuads` GPU kernel.
    ///
    /// This replaces the former CPU `extractMesh`, which built every billboard quad and
    /// color texel on the main thread (~33ms for 350K voxels). All of that geometry math
    /// now runs on the GPU; the CPU only does this lightweight pass — unpack each key and
    /// copy color/confidence — so the main thread is no longer blocked per extraction.
    ///
    /// Runs on the voxel serial queue, which owns `voxels`.
    ///
    /// - Parameters:
    ///   - buffer: Destination for `ExtractVoxel` records (must hold at least `maxVoxels`).
    ///   - maxVoxels: Capacity of the destination buffer (the kernel's vertex-buffer cap).
    /// - Returns: Number of voxels written (capped at `maxVoxels`).
    func packForExtraction(into buffer: UnsafeMutableRawPointer, maxVoxels: Int) -> Int {
        let out = buffer.bindMemory(to: ExtractVoxel.self, capacity: maxVoxels)
        var voxelIndex = 0

        // Amber blend for voxels not yet photo-covered (VR analog of the AR amber tint).
        // Baked into the packed RGB on the CPU: no shader, format, or extra-pass changes.
        // The blend darkens slightly, so covered voxels visibly return to full color/bloom.
        let keep = 1.0 - AppConstants.vrPhotoTintBlend
        let tintR = AppConstants.photoTintColor.x * 255 * AppConstants.vrPhotoTintBlend
        let tintG = AppConstants.photoTintColor.y * 255 * AppConstants.vrPhotoTintBlend
        let tintB = AppConstants.photoTintColor.z * 255 * AppConstants.vrPhotoTintBlend

        for (key, data) in voxels {
            if voxelIndex >= maxVoxels { break }

            let (gridX, gridY, gridZ) = Self.unpackKey(key)
            var avg = data.averageColor
            if !data.photoCovered {
                avg = (
                    r: UInt8(min(Float(avg.r) * keep + tintR, 255)),
                    g: UInt8(min(Float(avg.g) * keep + tintG, 255)),
                    b: UInt8(min(Float(avg.b) * keep + tintB, 255))
                )
            }

            out[voxelIndex] = ExtractVoxel(
                gridX: gridX, gridY: gridY, gridZ: gridZ,
                r: avg.r, g: avg.g, b: avg.b,
                a: UInt8(min(max(data.confidence * 255.0, 0), 255))
            )

            voxelIndex += 1
        }

        return voxelIndex
    }
}
