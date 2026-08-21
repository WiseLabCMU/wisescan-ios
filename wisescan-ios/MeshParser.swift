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

    /// Accumulates area-weighted per-vertex normals: each face's edge cross product is
    /// summed into its three vertices. Deliberately NOT normalized — callers normalize
    /// per their own needs (normal-map color remap, sign-agnostic view weighting, or
    /// inflation direction). Out-of-range indices are skipped.
    static func accumulateVertexNormals(
        vertices: [SIMD3<Float>], faces: [(UInt32, UInt32, UInt32)]
    ) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        for face in faces {
            accumulateFaceNormal(Int(face.0), Int(face.1), Int(face.2), vertices: vertices, into: &normals)
        }
        return normals
    }

    /// Flat-triangle-index variant of `accumulateVertexNormals` (indices in groups of 3,
    /// as used by RealityKit mesh descriptors).
    static func accumulateVertexNormals(
        vertices: [SIMD3<Float>], flatIndices: [UInt32]
    ) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        for base in stride(from: 0, to: flatIndices.count - 2, by: 3) {
            accumulateFaceNormal(
                Int(flatIndices[base]), Int(flatIndices[base + 1]), Int(flatIndices[base + 2]),
                vertices: vertices, into: &normals
            )
        }
        return normals
    }

    private static func accumulateFaceNormal(
        _ indexA: Int, _ indexB: Int, _ indexC: Int,
        vertices: [SIMD3<Float>], into normals: inout [SIMD3<Float>]
    ) {
        guard indexA < vertices.count, indexB < vertices.count, indexC < vertices.count else { return }
        let faceNormal = simd_cross(vertices[indexB] - vertices[indexA], vertices[indexC] - vertices[indexA])
        normals[indexA] += faceNormal
        normals[indexB] += faceNormal
        normals[indexC] += faceNormal
    }

    /// Parses an OBJ file from raw data into vertices and triangle faces.
    /// Face indices are converted from 1-based to 0-based.
    ///
    /// The byte-level core plus the out-of-range face filter — the combination every
    /// consumer that indexes `vertices` directly needs. Callers that must preserve a
    /// one-record-per-face alignment with an external sidecar want `parseOBJRaw` instead,
    /// since a silently dropped face breaks that contract.
    static func parseOBJ(from data: Data) -> OBJData? {
        let parsed = parseOBJRaw(from: data)
        guard !parsed.vertices.isEmpty, !parsed.faces.isEmpty else { return nil }

        // Drop faces referencing out-of-range vertices (malformed/truncated OBJ) so every
        // downstream consumer can index `vertices` without its own bounds check.
        let validFaces = parsed.faces.filter {
            Int($0.0) < parsed.vertices.count && Int($0.1) < parsed.vertices.count
                && Int($0.2) < parsed.vertices.count
        }
        guard !validFaces.isEmpty else { return nil }
        return OBJData(vertices: parsed.vertices, faces: validFaces)
    }

    /// UNFILTERED parse: every well-formed `v `/`f ` line, faces included whose indices point
    /// past the vertex list. Callers must bounds-check before indexing `vertices`; in exchange
    /// the emitted face count matches the file's face-line count exactly, which is what a
    /// face-aligned sidecar (face_classes.bin) is checked against.
    ///
    /// Parses the raw bytes directly (no whole-file String, no per-line/per-token
    /// Substring allocations), which is the dominant cost for large meshes. A trailing NUL
    /// is appended and each line is temporarily NUL-terminated so the C numeric parsers
    /// (strtof/strtol) always stop at the line boundary. Only `v ` lines become vertices (not
    /// `vn`/`vt`), only `f ` lines become faces, the first three face tokens are used (handles
    /// `a`, `a/b`, `a/b/c`), indices are 1-based→0-based, and malformed lines — including any
    /// face token that is not a positive integer — are skipped.
    static func parseOBJRaw(from data: Data) -> OBJData {
        var vertices: [SIMD3<Float>] = []
        var faces: [(UInt32, UInt32, UInt32)] = []
        vertices.reserveCapacity(data.count / 30)
        faces.reserveCapacity(data.count / 30)

        // Sentinel so strtof/strtol always terminate. Reserve FIRST: `[UInt8](data)` sizes
        // the buffer exactly to data.count, so the append exceeded capacity and triggered
        // geometric growth — a second allocation plus a full memcpy of a 16-45 MB file, on
        // every one of this function's nine call sites.
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count + 1)
        bytes.append(contentsOf: data)
        bytes.append(0)

        bytes.withUnsafeMutableBufferPointer { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            base.withMemoryRebound(to: CChar.self, capacity: rawBuf.count) { cbuf in
                let total = rawBuf.count // includes trailing NUL
                let NL: CChar = 10, SP: CChar = 32, V: CChar = 118, F: CChar = 102

                // Parse a float at p (strtof skips leading whitespace); nil if none.
                func parseFloat(_ p: UnsafeMutablePointer<CChar>) -> (Float, UnsafeMutablePointer<CChar>)? {
                    var end: UnsafeMutablePointer<CChar>?
                    let v = strtof(p, &end)
                    guard let e = end, e != p else { return nil }
                    return (v, e)
                }
                // Parse the leading 1-based index of a face token (e.g. "3", "3/2", "3/2/1"),
                // then advance past the rest of the token. nil unless a positive, in-range int.
                func parseFaceIndex(_ p0: UnsafeMutablePointer<CChar>) -> (UInt32, UnsafeMutablePointer<CChar>)? {
                    var p = p0
                    while p.pointee == SP { p += 1 }
                    var end: UnsafeMutablePointer<CChar>?
                    let v = strtol(p, &end, 10)
                    guard let e = end, e != p, v > 0, v <= Int(UInt32.max) else { return nil }
                    p = e
                    while p.pointee != SP && p.pointee != 0 { p += 1 }
                    return (UInt32(v), p)
                }

                var lineStart = 0
                while lineStart < total - 1 {
                    var lineEnd = lineStart
                    while lineEnd < total && cbuf[lineEnd] != NL { lineEnd += 1 }
                    if lineEnd < total { cbuf[lineEnd] = 0 } // terminate this line

                    if cbuf[lineStart] == V, lineStart + 1 < lineEnd, cbuf[lineStart + 1] == SP {
                        if let (x, p1) = parseFloat(cbuf + lineStart + 2),
                           let (y, p2) = parseFloat(p1),
                           let (z, _) = parseFloat(p2) {
                            vertices.append(SIMD3<Float>(x, y, z))
                        }
                    } else if cbuf[lineStart] == F, lineStart + 1 < lineEnd, cbuf[lineStart + 1] == SP {
                        if let (i1, p1) = parseFaceIndex(cbuf + lineStart + 2),
                           let (i2, p2) = parseFaceIndex(p1),
                           let (i3, _) = parseFaceIndex(p2) {
                            faces.append((i1 - 1, i2 - 1, i3 - 1))
                        }
                    }

                    lineStart = lineEnd + 1
                }
            }
        }

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
        indices.reserveCapacity(parsed.faces.count * 3)
        for face in parsed.faces {
            indices.append(face.0)
            indices.append(face.1)
            indices.append(face.2)
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
    static func generateWireframeDescriptors(from objData: Data, thickness: Float = 0.001) -> [MeshDescriptor] {
        guard let parsed = parseOBJ(from: objData) else {
            print("MeshParser: wireframe: Found 0 vertices or 0 faces.")
            return []
        }
        return buildWireframeDescriptors(vertices: parsed.vertices, faces: parsed.faces, thickness: thickness)
    }

    /// Builds wireframe geometry descriptors from vertices and triangle faces.
    /// For each unique edge, creates a thin quad (2 triangles) oriented perpendicular to the edge.
    /// Chunks the descriptors to prevent 16-bit index overflows in RealityKit.
    static func buildWireframeDescriptors(vertices: [SIMD3<Float>], faces: [(UInt32, UInt32, UInt32)], thickness: Float) -> [MeshDescriptor] {

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

        let edgesArray = Array(uniqueEdges)
        let maxEdgesPerChunk = 16000 // 64,000 vertices per chunk (keeps under 16-bit index limit)
        var descriptors = [MeshDescriptor]()

        let halfT = thickness * 0.5

        for chunkStart in stride(from: 0, to: edgesArray.count, by: maxEdgesPerChunk) {
            let chunkEnd = min(chunkStart + maxEdgesPerChunk, edgesArray.count)
            let chunk = edgesArray[chunkStart..<chunkEnd]

            var positions = [SIMD3<Float>]()
            positions.reserveCapacity(chunk.count * 4)
            var indices = [UInt32]()
            indices.reserveCapacity(chunk.count * 6)

            var idx: UInt32 = 0

            for edge in chunk {
                guard Int(edge.a) < vertices.count && Int(edge.b) < vertices.count else { continue }
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

            if !positions.isEmpty {
                var desc = MeshDescriptor(name: "WireframeChunk_\(chunkStart)")
                desc.positions = MeshBuffer(positions)
                desc.primitives = .triangles(indices)
                descriptors.append(desc)
            }
        }

        return descriptors
    }

    /// Cross-section wireframe for SPARSE architectural lines (the ghost proxy's RoomPlan
    /// lattice): each unique edge gets TWO perpendicular ribbons (a "+" cross-section), each
    /// emitted with BOTH windings (double-sided). The single-flat-ribbon builder above is
    /// invisible edge-on and backface-culled from one whole side — statistically irrelevant for
    /// dense mesh wireframes (a million randomly-oriented edges average out), but systematically
    /// fatal for axis-aligned grid lines: horizontal lines ride a horizontal ribbon (edge-on near
    /// eye height, culled from one side), and vertical lines hit the degenerate-cross fallback
    /// whose fixed world plane is edge-on for walls of particular orientations — the 2026-07-20
    /// "lattice clips on SOME walls" device finding. Cost: 8 tris/edge vs 2 — fine for the ~10²
    /// lattice edges, wrong tool for the 10⁵-edge mesh remainder.
    static func buildCrossWireframeDescriptors(vertices: [SIMD3<Float>],
                                               faces: [(UInt32, UInt32, UInt32)],
                                               thickness: Float) -> [MeshDescriptor] {
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

        let halfT = thickness * 0.5
        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(uniqueEdges.count * 8)
        var indices = [UInt32]()
        indices.reserveCapacity(uniqueEdges.count * 24)
        var idx: UInt32 = 0
        var descriptors = [MeshDescriptor]()
        // 8 verts/edge → chunk well under the 16-bit vertex limit (mirrors the flat builder).
        let maxEdgesPerChunk = 8000

        func flushChunk() {
            guard !positions.isEmpty else { return }
            var desc = MeshDescriptor(name: "CrossWireframeChunk_\(descriptors.count)")
            desc.positions = MeshBuffer(positions)
            desc.primitives = .triangles(indices)
            descriptors.append(desc)
            positions.removeAll(keepingCapacity: true)
            indices.removeAll(keepingCapacity: true)
            idx = 0
        }

        var edgesInChunk = 0
        for edge in uniqueEdges {
            guard Int(edge.a) < vertices.count && Int(edge.b) < vertices.count else { continue }
            let p0 = vertices[Int(edge.a)]
            let p1 = vertices[Int(edge.b)]
            appendCrossEdge(p0, p1, halfT: halfT, positions: &positions, indices: &indices, idx: &idx)
            edgesInChunk += 1
            if edgesInChunk >= maxEdgesPerChunk {
                flushChunk()
                edgesInChunk = 0
            }
        }
        flushChunk()
        return descriptors
    }

    /// Cross-section wireframe from EXPLICIT edge pairs — same double-sided "+" geometry as the
    /// faces variant above. Used for synthesized architectural outlines (the ghost proxy's room
    /// perimeter: wall-wall corners, wall-floor seams) where the edges come from plane rectangles
    /// rather than mesh triangles.
    static func buildCrossWireframeDescriptors(edges: [(SIMD3<Float>, SIMD3<Float>)],
                                               thickness: Float) -> [MeshDescriptor] {
        guard !edges.isEmpty else { return [] }
        let halfT = thickness * 0.5
        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(edges.count * 8)
        var indices = [UInt32]()
        indices.reserveCapacity(edges.count * 24)
        var idx: UInt32 = 0
        for (p0, p1) in edges {
            appendCrossEdge(p0, p1, halfT: halfT, positions: &positions, indices: &indices, idx: &idx)
        }
        guard !positions.isEmpty else { return [] }
        var desc = MeshDescriptor(name: "CrossOutline")
        desc.positions = MeshBuffer(positions)
        desc.primitives = .triangles(indices)
        return [desc]
    }

    /// Emit one edge as two perpendicular ribbons, each wound both ways (the shared "+" cross-
    /// section primitive of the two builders above).
    private static func appendCrossEdge(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, halfT: Float,
                                        positions: inout [SIMD3<Float>], indices: inout [UInt32],
                                        idx: inout UInt32) {
        let dir = p1 - p0
        let len = simd_length(dir)
        guard len > 1e-8 else { return }
        let d = dir / len

        var perp1 = simd_cross(d, SIMD3<Float>(0, 1, 0))
        if simd_length(perp1) < 1e-6 {
            perp1 = simd_cross(d, SIMD3<Float>(1, 0, 0))
        }
        perp1 = simd_normalize(perp1) * halfT
        let perp2 = simd_normalize(simd_cross(d, perp1)) * halfT

        for perp in [perp1, perp2] {
            positions.append(contentsOf: [p0 - perp, p0 + perp, p1 + perp, p1 - perp])
            // Both windings — visible from either side regardless of material culling.
            indices.append(contentsOf: [idx, idx + 1, idx + 2, idx, idx + 2, idx + 3,
                                        idx + 2, idx + 1, idx, idx + 3, idx + 2, idx])
            idx += 4
        }
    }

    /// Builds wireframe geometry descriptors from explicit edge pairs (start, end positions).
    /// Used for bounding box outlines where edges are known (not derived from triangles).
    static func buildWireframeDescriptors(
        edges: [(SIMD3<Float>, SIMD3<Float>)],
        thickness: Float
    ) -> [MeshDescriptor] {
        guard !edges.isEmpty else { return [] }
        let halfT = thickness * 0.5
        var positions = [SIMD3<Float>]()
        positions.reserveCapacity(edges.count * 4)
        var indices = [UInt32]()
        indices.reserveCapacity(edges.count * 6)
        var idx: UInt32 = 0

        for (p0, p1) in edges {
            let dir = p1 - p0
            let len = simd_length(dir)
            guard len > 1e-8 else { continue }

            let up = SIMD3<Float>(0, 1, 0)
            var perp = simd_cross(dir, up)
            if simd_length(perp) < 1e-6 {
                perp = simd_cross(dir, SIMD3<Float>(1, 0, 0))
            }
            perp = simd_normalize(perp) * halfT

            positions.append(contentsOf: [p0 - perp, p0 + perp, p1 + perp, p1 - perp])
            indices.append(contentsOf: [idx, idx + 1, idx + 2, idx, idx + 2, idx + 3])
            idx += 4
        }

        guard !positions.isEmpty else { return [] }
        var desc = MeshDescriptor(name: "BBoxWireframe")
        desc.positions = MeshBuffer(positions)
        desc.primitives = .triangles(indices)
        return [desc]
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

        let vertexCount = vertices.count
        var idx: UInt32 = 0
        for (a, b, c) in faces {
            // Skip triangles referencing out-of-range vertices (malformed OBJ or
            // corrupted ARMeshAnchor geometry) rather than trapping.
            guard Int(a) < vertexCount, Int(b) < vertexCount, Int(c) < vertexCount else { continue }
            outPositions.append(vertices[Int(a)])
            outPositions.append(vertices[Int(b)])
            outPositions.append(vertices[Int(c)])

            // Barycentric coords encoded in uv0 — shader reconstructs 3rd coord as 1-u-v
            outUVs.append(SIMD2<Float>(1, 0))
            outUVs.append(SIMD2<Float>(0, 1))
            outUVs.append(SIMD2<Float>(0, 0))

            outIndices.append(idx)
            outIndices.append(idx + 1)
            outIndices.append(idx + 2)
            idx += 3
        }

        var desc = MeshDescriptor(name: "WireframeMesh")
        desc.positions = MeshBuffer(outPositions)
        desc.textureCoordinates = MeshBuffer(outUVs)
        desc.primitives = .triangles(outIndices)

        return try? MeshResource.generate(from: [desc])
    }
}
