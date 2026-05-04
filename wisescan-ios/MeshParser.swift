import Foundation
import RealityKit
import simd
import ARKit

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

    // MARK: - Procedural Wireframe Mesh

    /// Generates a MeshResource where each triangle edge is rendered as a thin 3D ribbon.
    /// This produces a true wireframe visual using only standard geometry — no CustomMaterial needed.
    /// - Parameters:
    ///   - objData: Raw OBJ file data
    ///   - thickness: Width of the wireframe lines in meters (default 0.001 = 1mm)
    static func generateWireframeMeshResource(from objData: Data, thickness: Float = 0.001) -> MeshResource? {
        guard let parsed = parseOBJ(from: objData) else {
            print("MeshParser: wireframe: Found 0 vertices or 0 faces.")
            return nil
        }
        return buildWireframeMesh(vertices: parsed.vertices, faces: parsed.faces, thickness: thickness)
    }

    /// Builds wireframe geometry from vertices and triangle faces.
    /// For each unique edge, creates a thin quad (2 triangles) oriented perpendicular to the edge.
    private static func buildWireframeMesh(vertices: [SIMD3<Float>], faces: [(UInt32, UInt32, UInt32)], thickness: Float) -> MeshResource? {

        // Collect unique edges using a sorted pair key to avoid duplicates
        struct Edge: Hashable {
            let a: UInt32, b: UInt32
            init(_ v0: UInt32, _ v1: UInt32) {
                a = min(v0, v1)
                b = max(v0, v1)
            }
        }

        var uniqueEdges = Set<Edge>()
        for (i0, i1, i2) in faces {
            uniqueEdges.insert(Edge(i0, i1))
            uniqueEdges.insert(Edge(i1, i2))
            uniqueEdges.insert(Edge(i2, i0))
        }

        // Pre-allocate: 4 verts and 6 indices (2 triangles) per edge
        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(uniqueEdges.count * 4)
        var indices = [UInt32]()
        indices.reserveCapacity(uniqueEdges.count * 6)

        let halfT = thickness * 0.5
        var idx: UInt32 = 0

        for edge in uniqueEdges {
            let p0 = vertices[Int(edge.a)]
            let p1 = vertices[Int(edge.b)]

            let dir = p1 - p0
            let len = simd_length(dir)
            guard len > 1e-8 else { continue }

            // Find a perpendicular offset vector
            let up = SIMD3<Float>(0, 1, 0)
            var perp = simd_cross(dir, up)
            if simd_length(perp) < 1e-6 {
                // Edge is parallel to up — use a different reference
                perp = simd_cross(dir, SIMD3<Float>(1, 0, 0))
            }
            perp = simd_normalize(perp) * halfT

            // Build a thin quad: 4 corners
            let v0 = p0 - perp
            let v1 = p0 + perp
            let v2 = p1 + perp
            let v3 = p1 - perp

            positions.append(contentsOf: [v0, v1, v2, v3])

            // Two triangles: (0,1,2) and (0,2,3)
            indices.append(contentsOf: [idx, idx+1, idx+2, idx, idx+2, idx+3])
            idx += 4
        }

        guard !positions.isEmpty else { return nil }

        var desc = MeshDescriptor(name: "WireframeMesh")
        desc.positions = MeshBuffer(positions)
        desc.primitives = .triangles(indices)

        return try? MeshResource.generate(from: [desc])
    }

    // MARK: - Un-indexed mesh generation (for wireframe shader with barycentric UVs)

    /// Generates an un-indexed MeshResource from an ARMeshAnchor's geometry.
    /// Each triangle is duplicated so each vertex gets a unique barycentric coordinate
    /// encoded in uv0, enabling the Metal wireframe shader.
    static func generateUnindexedMeshResource(from meshAnchor: ARMeshAnchor) -> MeshResource? {
        let geometry = meshAnchor.geometry
        let vertices = geometry.vertices
        let faces = geometry.faces

        // Extract vertex positions
        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(vertices.count)
        for i in 0..<vertices.count {
            let ptr = vertices.buffer.contents().advanced(by: i * vertices.stride)
            positions.append(ptr.assumingMemoryBound(to: SIMD3<Float>.self).pointee)
        }

        // Validate face format (must be UInt32 triangles)
        guard faces.bytesPerIndex == 4, faces.indexCountPerPrimitive == 3 else {
            return nil
        }

        // Extract face indices
        let faceStride = faces.bytesPerIndex * faces.indexCountPerPrimitive
        var faceIndices: [(UInt32, UInt32, UInt32)] = []
        faceIndices.reserveCapacity(faces.count)
        for i in 0..<faces.count {
            let ptr = faces.buffer.contents().advanced(by: i * faceStride)
            faceIndices.append(ptr.assumingMemoryBound(to: (UInt32, UInt32, UInt32).self).pointee)
        }

        return buildUnindexedMesh(vertices: positions, faces: faceIndices)
    }

    /// Generates an un-indexed MeshResource from OBJ data.
    static func generateUnindexedMeshResource(from objData: Data) -> MeshResource? {
        guard let parsed = parseOBJ(from: objData) else { return nil }
        return buildUnindexedMesh(vertices: parsed.vertices, faces: parsed.faces)
    }

    /// Core un-indexing: duplicates vertices per-triangle, assigns barycentric UVs.
    private static func buildUnindexedMesh(vertices: [SIMD3<Float>], faces: [(UInt32, UInt32, UInt32)]) -> MeshResource? {
        let triCount = faces.count
        var outPositions = [SIMD3<Float>]()
        outPositions.reserveCapacity(triCount * 3)
        var outUVs = [SIMD2<Float>]()
        outUVs.reserveCapacity(triCount * 3)
        var outIndices = [UInt32]()
        outIndices.reserveCapacity(triCount * 3)

        var idx: UInt32 = 0
        for (a, b, c) in faces {
            outPositions.append(vertices[Int(a)])
            outPositions.append(vertices[Int(b)])
            outPositions.append(vertices[Int(c)])

            // Barycentric coords encoded in uv0 — shader reconstructs 3rd coord as 1-u-v
            outUVs.append(SIMD2<Float>(1, 0))
            outUVs.append(SIMD2<Float>(0, 1))
            outUVs.append(SIMD2<Float>(0, 0))

            outIndices.append(contentsOf: [idx, idx + 1, idx + 2])
            idx += 3
        }

        var desc = MeshDescriptor(name: "WireframeMesh")
        desc.positions = MeshBuffer(outPositions)
        desc.textureCoordinates = MeshBuffer(outUVs)
        desc.primitives = .triangles(outIndices)

        return try? MeshResource.generate(from: [desc])
    }
}
