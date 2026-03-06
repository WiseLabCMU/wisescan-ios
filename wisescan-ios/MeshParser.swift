import Foundation
import RealityKit
import simd

/// Utility to parse a simple wavefront OBJ string into a RealityKit MeshResource.
enum MeshParser {

    /// Reconstructs a MeshResource from an `.obj` file format string.
    /// - Parameter objData: The raw `Data` containing the OBJ string.
    /// - Returns: A RealityKit `MeshResource` if parsing succeeds, otherwise nil.
    static func generateMeshResource(from objData: Data) -> MeshResource? {
        guard let objStr = String(data: objData, encoding: .utf8) else {
            print("MeshParser: Failed to decode OBJ data to string")
            return nil
        }

        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []

        let lines = objStr.split(separator: "\n")

        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let type = parts.first else { continue }

            if type == "v" && parts.count >= 4 {
                // Vertex position: v x y z
                if let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) {
                    positions.append(SIMD3<Float>(x, y, z))
                }
            } else if type == "f" && parts.count >= 4 {
                // Face definition (supports only triangles for simplicity, which matches our exporter)
                // Format: f v1 v2 v3 OR f v1/vt1/vn1 v2/vt2/vn2 v3/vt3/vn3
                let v1Str = parts[1].split(separator: "/").first ?? ""
                let v2Str = parts[2].split(separator: "/").first ?? ""
                let v3Str = parts[3].split(separator: "/").first ?? ""

                // OBJ is 1-indexed, RealityKit is 0-indexed
                if let i1 = UInt32(v1Str), let i2 = UInt32(v2Str), let i3 = UInt32(v3Str) {
                    indices.append(i1 - 1)
                    indices.append(i2 - 1)
                    indices.append(i3 - 1)
                }
            }
        }

        guard !positions.isEmpty, !indices.isEmpty else {
            print("MeshParser: Found 0 vertices or 0 faces.")
            return nil
        }

        var descriptor = MeshDescriptor(name: "GhostMesh")
        descriptor.positions = MeshBuffer(positions)
        descriptor.primitives = .triangles(indices)

        do {
            let resource = try MeshResource.generate(from: [descriptor])
            return resource
        } catch {
            print("MeshParser: Failed to generate MeshResource: \(error)")
            return nil
        }
    }
}
