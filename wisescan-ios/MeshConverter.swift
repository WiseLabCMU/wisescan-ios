import Foundation
import ModelIO
import SceneKit

/// Mesh format conversion utilities for export.
enum MeshConverter {

    // MARK: - OBJ → PLY

    /// Converts an OBJ mesh + colors.bin (per-vertex SIMD4<Float> RGBA) to an ASCII PLY file.
    /// Returns `true` on success.
    static func objToPLY(objURL: URL, colorsURL: URL, outputURL: URL) -> Bool {
        guard let objData = try? Data(contentsOf: objURL),
              let parsed = MeshParser.parseOBJ(from: objData) else {
            print("[MeshConverter] Failed to read/parse OBJ file")
            return false
        }

        let vertices = parsed.vertices
        let faces = parsed.faces

        // Load vertex colors (SIMD4<Float> per vertex: R, G, B, A — 16 bytes each)
        let colorData = try? Data(contentsOf: colorsURL)
        let stride = MemoryLayout<SIMD4<Float>>.stride
        let hasColors = colorData != nil && colorData!.count >= vertices.count * stride

        // Write ASCII PLY into a single reserved Data buffer. Appending UTF-8 line
        // fragments avoids growing one huge String (repeated reallocs) and the final
        // String→Data re-encode that doubled peak memory. Output bytes are identical.
        var out = Data()
        out.reserveCapacity(vertices.count * (hasColors ? 64 : 48) + faces.count * 24 + 256)
        func append(_ s: String) { out.append(contentsOf: s.utf8) }

        append("ply\n")
        append("format ascii 1.0\n")
        append("element vertex \(vertices.count)\n")
        append("property float x\n")
        append("property float y\n")
        append("property float z\n")
        if hasColors {
            append("property uchar red\n")
            append("property uchar green\n")
            append("property uchar blue\n")
        }
        append("element face \(faces.count)\n")
        append("property list uchar int vertex_indices\n")
        append("end_header\n")

        // Vertex data — hoist the color buffer binding out of the loop (was a per-vertex
        // withUnsafeBytes closure).
        if hasColors, let colorData = colorData {
            colorData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let colors = raw.bindMemory(to: SIMD4<Float>.self)
                for (i, v) in vertices.enumerated() {
                    let rgba = colors[i]
                    let r = UInt8(min(max(rgba.x * 255.0, 0), 255))
                    let g = UInt8(min(max(rgba.y * 255.0, 0), 255))
                    let b = UInt8(min(max(rgba.z * 255.0, 0), 255))
                    append("\(v.x) \(v.y) \(v.z) \(r) \(g) \(b)\n")
                }
            }
        } else {
            for v in vertices {
                append("\(v.x) \(v.y) \(v.z)\n")
            }
        }

        // Face data
        for face in faces {
            append("3 \(face.0) \(face.1) \(face.2)\n")
        }

        do {
            try out.write(to: outputURL, options: .atomic)
            print("[MeshConverter] PLY written: \(vertices.count) vertices, \(faces.count) faces, colors=\(hasColors)")
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
