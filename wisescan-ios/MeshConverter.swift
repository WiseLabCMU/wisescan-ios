import Foundation
import ModelIO
import SceneKit

/// Mesh format conversion utilities for export.
enum MeshConverter {

    // MARK: - OBJ → PLY

    /// Converts an OBJ mesh + colors.bin (per-vertex RGB bytes) to an ASCII PLY file.
    /// Returns `true` on success.
    static func objToPLY(objURL: URL, colorsURL: URL, outputURL: URL) -> Bool {
        guard let objData = try? String(contentsOf: objURL, encoding: .utf8) else {
            print("[MeshConverter] Failed to read OBJ file")
            return false
        }

        // Parse vertices and faces from OBJ
        var vertices: [(Float, Float, Float)] = []
        var faces: [[Int]] = []

        for line in objData.components(separatedBy: .newlines) {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces)
            guard !parts.isEmpty else { continue }

            if parts[0] == "v" && parts.count >= 4 {
                if let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) {
                    vertices.append((x, y, z))
                }
            } else if parts[0] == "f" && parts.count >= 4 {
                // OBJ face indices are 1-based and may contain v/vt/vn format
                let indices = parts[1...].compactMap { component -> Int? in
                    let idx = component.components(separatedBy: "/").first ?? component
                    guard let i = Int(idx) else { return nil }
                    return i - 1 // Convert to 0-based
                }
                if indices.count >= 3 {
                    faces.append(indices)
                }
            }
        }

        // Load vertex colors (3 bytes per vertex: R, G, B)
        let colorData = try? Data(contentsOf: colorsURL)
        let hasColors = colorData != nil && colorData!.count >= vertices.count * 3

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
                let r = colors[i * 3]
                let g = colors[i * 3 + 1]
                let b = colors[i * 3 + 2]
                ply += "\(v.0) \(v.1) \(v.2) \(r) \(g) \(b)\n"
            } else {
                ply += "\(v.0) \(v.1) \(v.2)\n"
            }
        }

        // Face data
        for face in faces {
            let indexStr = face.map { String($0) }.joined(separator: " ")
            ply += "\(face.count) \(indexStr)\n"
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
