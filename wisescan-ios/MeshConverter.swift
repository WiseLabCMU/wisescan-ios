import Foundation
import ModelIO
import SceneKit

/// Mesh format conversion utilities for export.
enum MeshConverter {

    // MARK: - OBJ + colors

    /// Writes `objURL` to `outputURL` with every `v x y z` line extended to `v x y z r g b`
    /// from colors.bin (per-vertex SIMD4<Float> RGBA, in mesh.obj's vertex order) — the
    /// vertex-color extension MeshLab, Blender, CloudCompare, Open3D and ModelIO read. Every
    /// other line passes through unchanged. Returns `false`, writing nothing, unless there is
    /// exactly one color per vertex — any other count means colors.bin belongs to another mesh
    /// (the viewer applies the same rule).
    static func objWithVertexColors(objURL: URL, colorsURL: URL, outputURL: URL) -> Bool {
        guard let obj = try? Data(contentsOf: objURL),
              let colorData = try? Data(contentsOf: colorsURL) else {
            print("[MeshConverter] Failed to read OBJ or colors.bin")
            return false
        }
        let colorCount = colorData.count / MemoryLayout<SIMD4<Float>>.stride
        var out = Data()
        out.reserveCapacity(obj.count + colorData.count / 2)
        var vertex = 0
        var covered = true
        colorData.withUnsafeBytes { (rawColors: UnsafeRawBufferPointer) in
            let colors = rawColors.bindMemory(to: SIMD4<Float>.self)
            obj.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                let n = bytes.count
                var start = 0
                while start < n {
                    var end = start
                    while end < n && bytes[end] != 0x0A { end += 1 }          // '\n'
                    var lineEnd = end
                    if lineEnd > start && bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }   // '\r'
                    out.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[start..<lineEnd]))
                    // "v " — a vertex position (not "vn"/"vt").
                    if lineEnd - start > 2 && bytes[start] == 0x76 && bytes[start + 1] == 0x20 {
                        guard vertex < colors.count else { covered = false; return }
                        let c = colors[vertex]
                        let rgb = String(format: " %.4f %.4f %.4f",
                                         min(max(c.x, 0), 1), min(max(c.y, 0), 1), min(max(c.z, 0), 1))
                        out.append(contentsOf: rgb.utf8)
                        vertex += 1
                    }
                    out.append(0x0A)
                    start = end + 1
                }
            }
        }
        guard covered, vertex > 0, vertex == colorCount else {
            print("[MeshConverter] colors.bin has \(colorCount) colors for \(vertex) OBJ vertices — not writing colors")
            return false
        }
        do {
            try out.write(to: outputURL, options: .atomic)
            print("[MeshConverter] OBJ with vertex colors written: \(vertex) vertices")
            return true
        } catch {
            print("[MeshConverter] Failed to write colored OBJ: \(error)")
            return false
        }
    }

    // MARK: - OBJ → PLY

    /// Converts an OBJ mesh + colors.bin (per-vertex SIMD4<Float> RGBA) to a binary PLY file
    /// (`binary_little_endian 1.0`). Returns `true` on success.
    ///
    /// Binary PLY is read by all standard mesh tools (MeshLab, CloudCompare, Blender,
    /// Open3D, …) and is ~3–5× smaller and far faster to write than ASCII (no per-value
    /// decimal formatting). `binary_little_endian` matches all target platforms (iOS/macOS).
    ///
    /// `colorsURL` nil writes geometry only. Callers pass it only for camera-sampled colors:
    /// the save-time normals colors are an in-app preview and must never ship in an export.
    static func objToPLY(objURL: URL, colorsURL: URL?, outputURL: URL) -> Bool {
        guard let objData = try? Data(contentsOf: objURL),
              let parsed = MeshParser.parseOBJ(from: objData) else {
            print("[MeshConverter] Failed to read/parse OBJ file")
            return false
        }

        let vertices = parsed.vertices
        let faces = parsed.faces

        // Load vertex colors (SIMD4<Float> per vertex: R, G, B, A — 16 bytes each)
        let colorData = colorsURL.flatMap { try? Data(contentsOf: $0) }
        let stride = MemoryLayout<SIMD4<Float>>.stride
        // Exactly one color per vertex, as the viewer requires; any other count is another mesh's.
        let hasColors = colorData != nil && colorData!.count == vertices.count * stride

        // ASCII header (always text), then a little-endian binary data section.
        var header = "ply\n"
        header += "format binary_little_endian 1.0\n"
        header += "element vertex \(vertices.count)\n"
        header += "property float x\n"
        header += "property float y\n"
        header += "property float z\n"
        if hasColors {
            header += "property uchar red\n"
            header += "property uchar green\n"
            header += "property uchar blue\n"
        }
        header += "element face \(faces.count)\n"
        header += "property list uchar int vertex_indices\n"
        header += "end_header\n"

        var out = Data(header.utf8)
        // vertex = 3 floats (+ 3 color bytes); face = 1 count byte + 3 int32 indices.
        let vertexRecord = 12 + (hasColors ? 3 : 0)
        out.reserveCapacity(out.count + vertices.count * vertexRecord + faces.count * 13)

        // Append a value's little-endian bytes (correct on any host endianness).
        func putFloat(_ f: Float) {
            var le = f.bitPattern.littleEndian
            Swift.withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        func putUInt32(_ u: UInt32) {
            var le = u.littleEndian
            Swift.withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }

        // Vertex data — hoist the color buffer binding out of the loop.
        if hasColors, let colorData = colorData {
            colorData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let colors = raw.bindMemory(to: SIMD4<Float>.self)
                for (i, v) in vertices.enumerated() {
                    putFloat(v.x); putFloat(v.y); putFloat(v.z)
                    let rgba = colors[i]
                    out.append(UInt8(min(max(rgba.x * 255.0, 0), 255)))
                    out.append(UInt8(min(max(rgba.y * 255.0, 0), 255)))
                    out.append(UInt8(min(max(rgba.z * 255.0, 0), 255)))
                }
            }
        } else {
            for v in vertices {
                putFloat(v.x); putFloat(v.y); putFloat(v.z)
            }
        }

        // Face data: uchar count (3) + 3 int32 indices. The index bit patterns are written
        // as-is; PLY "int" reads them back identically for in-range non-negative values.
        for face in faces {
            out.append(UInt8(3))
            putUInt32(face.0)
            putUInt32(face.1)
            putUInt32(face.2)
        }

        do {
            try out.write(to: outputURL, options: .atomic)
            print("[MeshConverter] PLY (binary) written: \(vertices.count) vertices, \(faces.count) faces, colors=\(hasColors)")
            return true
        } catch {
            print("[MeshConverter] Failed to write PLY: \(error)")
            return false
        }
    }

    // MARK: - OBJ → USDZ

    /// Converts an OBJ mesh to USDZ using Apple's ModelIO framework.
    /// Returns `true` on success.
    static func objToUSDZ(objURL: URL, outputURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: objURL.path) else {
            print("[MeshConverter] OBJ file not found at \(objURL.path)")
            return false
        }

        // Try ModelIO first
        if MDLAsset.canExportFileExtension("usdz") {
            let asset = MDLAsset(url: objURL)
            if asset.count > 0 {
                do {
                    try asset.export(to: outputURL)
                    print("[MeshConverter] USDZ written via ModelIO to \(outputURL.lastPathComponent)")
                    return true
                } catch {
                    print("[MeshConverter] ModelIO USDZ export failed: \(error), trying SceneKit fallback")
                }
            } else {
                print("[MeshConverter] ModelIO found no objects, trying SceneKit fallback")
            }
        } else {
            print("[MeshConverter] ModelIO does not support USDZ export, trying SceneKit fallback")
        }

        // SceneKit fallback
        do {
            let scene = try SCNScene(url: objURL, options: nil)
            let success = scene.write(to: outputURL, options: nil, delegate: nil, progressHandler: nil)
            if success {
                print("[MeshConverter] USDZ written via SceneKit to \(outputURL.lastPathComponent)")
            } else {
                print("[MeshConverter] SceneKit USDZ write returned false")
            }
            return success
        } catch {
            print("[MeshConverter] SceneKit USDZ export failed: \(error)")
            return false
        }
    }
}
