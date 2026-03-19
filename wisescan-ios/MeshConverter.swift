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

        // Write ASCII PLY
        var ply = "ply\n"
        ply += "format ascii 1.0\n"
        ply += "element vertex \(vertices.count)\n"
        ply += "property float x\n"
        ply += "property float y\n"
        ply += "property float z\n"
        if hasColors {
            ply += "property uchar red\n"
            ply += "property uchar green\n"
            ply += "property uchar blue\n"
        }
        ply += "element face \(faces.count)\n"
        ply += "property list uchar int vertex_indices\n"
        ply += "end_header\n"

        // Vertex data
        for (i, v) in vertices.enumerated() {
            if hasColors, let colors = colorData {
                // Read SIMD4<Float> and convert to UInt8 [0..255]
                let offset = i * stride
                let rgba: SIMD4<Float> = colors.withUnsafeBytes { buf in
                    buf.load(fromByteOffset: offset, as: SIMD4<Float>.self)
                }
                let r = UInt8(min(max(rgba.x * 255.0, 0), 255))
                let g = UInt8(min(max(rgba.y * 255.0, 0), 255))
                let b = UInt8(min(max(rgba.z * 255.0, 0), 255))
                ply += "\(v.x) \(v.y) \(v.z) \(r) \(g) \(b)\n"
            } else {
                ply += "\(v.x) \(v.y) \(v.z)\n"
            }
        }

        // Face data
        for face in faces {
            ply += "3 \(face.0) \(face.1) \(face.2)\n"
        }

        do {
            try ply.write(to: outputURL, atomically: true, encoding: .utf8)
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
