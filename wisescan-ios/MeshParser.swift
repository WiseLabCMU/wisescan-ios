import Foundation
import RealityKit
import simd

/// Utility to parse a simple wavefront OBJ string into vertices/faces or a RealityKit MeshResource.
enum MeshParser {

    /// Parsed OBJ result with vertices and triangle face indices (0-based).
    struct OBJData {
        let vertices: [SIMD3<Float>]
        let faces: [(UInt32, UInt32, UInt32)]
    }

    /// Parses an OBJ file from raw data into vertices and triangle faces.
    /// Face indices are converted from 1-based to 0-based.
    static func parseOBJ(from data: Data) -> OBJData? {
        guard let objStr = String(data: data, encoding: .utf8) else { return nil }

        var vertices: [SIMD3<Float>] = []
        var faces: [(UInt32, UInt32, UInt32)] = []

        for line in objStr.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let type = parts.first else { continue }

            if type == "v" && parts.count >= 4 {
                if let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) {
                    vertices.append(SIMD3<Float>(x, y, z))
                }
            } else if type == "f" && parts.count >= 4 {
                // Handles "f v1 v2 v3" and "f v1/vt1/vn1 v2/vt2/vn2 v3/vt3/vn3"
                let v1Str = parts[1].split(separator: "/").first ?? ""
                let v2Str = parts[2].split(separator: "/").first ?? ""
                let v3Str = parts[3].split(separator: "/").first ?? ""

                if let i1 = UInt32(v1Str), let i2 = UInt32(v2Str), let i3 = UInt32(v3Str) {
                    faces.append((i1 - 1, i2 - 1, i3 - 1))
                }
            }
        }

        guard !vertices.isEmpty, !faces.isEmpty else { return nil }
        return OBJData(vertices: vertices, faces: faces)
    }

    /// Reconstructs a MeshResource from an `.obj` file format string.
    /// - Parameter objData: The raw `Data` containing the OBJ string.
    /// - Returns: A RealityKit `MeshResource` if parsing succeeds, otherwise nil.
    static func generateMeshResource(from objData: Data) -> MeshResource? {
        guard let parsed = parseOBJ(from: objData) else {
            print("MeshParser: Found 0 vertices or 0 faces.")
            return nil
        }

        var indices: [UInt32] = []
        for face in parsed.faces {
            indices.append(contentsOf: [face.0, face.1, face.2])
        }

        var descriptor = MeshDescriptor(name: "GhostMesh")
        descriptor.positions = MeshBuffer(parsed.vertices)
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

