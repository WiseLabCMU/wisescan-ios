import Foundation
import ARKit
import UIKit

/// Post-processing utilities for vertex coloring and ARWorldMap export.
/// Extracted from ARCoverageView for clearer separation of concerns.
enum VertexColorAccumulator {

    // MARK: - Export Helpers

    /// Exports the current ARWorldMap to a local URL.
    static func exportWorldMap(from session: ARSession?, completion: @escaping (URL?) -> Void) {
        guard let session = session else {
            completion(nil)
            return
        }

        let completionLock = NSLock()
        var didComplete = false

        session.getCurrentWorldMap { worldMap, error in
            completionLock.lock()
            if didComplete {
                completionLock.unlock()
                return
            }
            didComplete = true
            completionLock.unlock()

            guard let map = worldMap, error == nil else {
                print("Error getting ARWorldMap: \(String(describing: error))")
                completion(nil)
                return
            }

            do {
                let data = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                let filename = "worldmap_\(UUID().uuidString.prefix(8)).worldmap"
                let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                try data.write(to: fileURL)
                completion(fileURL)
            } catch {
                print("Error saving ARWorldMap: \(error)")
                completion(nil)
            }
        }

        // Failsafe so a non-responsive getCurrentWorldMap can't hang the save forever. On a real
        // device getCurrentWorldMap honors its contract (always calls back with a map or an error),
        // so this is a "something is broken" escape hatch, NOT a normal-operation cap: 30s is far
        // longer than serializing even a large map (~1–3s, e.g. after several successive extends of
        // one location), so it never race-drops a valid map the way the old 2s cap did (which saved
        // scans with no worldMapURL → not relocalizable/extendable later, only a card badge). The
        // Simulator never yields a real map, so keep it short there so test flows don't stall.
        #if targetEnvironment(simulator)
        let worldMapTimeout: TimeInterval = 2.0
        #else
        let worldMapTimeout: TimeInterval = 30.0
        #endif
        DispatchQueue.main.asyncAfter(deadline: .now() + worldMapTimeout) {
            completionLock.lock()
            if didComplete {
                completionLock.unlock()
                return
            }
            didComplete = true
            completionLock.unlock()

            print("[Warning] ARWorldMap export timed out after \(worldMapTimeout)s. Proceeding without map.")
            completion(nil)
        }
    }

    /// Generate normals-based vertex colors (fast, no image I/O).
    /// Uses the standard tangent-space normal mapping convention where normals
    /// are remapped from [-1,1] to [0,1] via (normal + 1) / 2:
    ///   R = X axis, G = Y axis, B = Z axis.
    /// This preserves directional information and produces the familiar
    /// blue/purple/green visualization used in 3D workflows.
    /// Used as the default coloring when a scan is first saved, before camera-based coloring.
    static func generateNormalsColors(objData: Data) -> Data? {
        guard let parsed = MeshParser.parseOBJ(from: objData) else { return nil }
        let vertices = parsed.vertices
        guard !vertices.isEmpty else { return nil }

        // Accumulate face normals per vertex
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)

        for face in parsed.faces {
            let i0 = Int(face.0)
            let i1 = Int(face.1)
            let i2 = Int(face.2)
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }

            let v0 = vertices[i0]
            let v1 = vertices[i1]
            let v2 = vertices[i2]

            let edge1 = v1 - v0
            let edge2 = v2 - v0
            let normal = simd_cross(edge1, edge2)

            normals[i0] += normal
            normals[i1] += normal
            normals[i2] += normal
        }

        // Normalize and remap to [0,1] using standard normal map convention: (n + 1) / 2.
        // Fill the output Data in place to avoid an intermediate [SIMD4<Float>] allocation.
        var data = Data(count: normals.count * MemoryLayout<SIMD4<Float>>.stride)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: SIMD4<Float>.self)
            for i in normals.indices {
                let n = normals[i]
                let normalized = simd_length(n) > 0 ? simd_normalize(n) : SIMD3<Float>(0, 0, 1)
                out[i] = SIMD4<Float>(
                    (normalized.x + 1) / 2,
                    (normalized.y + 1) / 2,
                    (normalized.z + 1) / 2,
                    1.0
                )
            }
        }
        return data
    }

    /// Colorize OBJ mesh vertices using saved camera frames (post-processing).
    /// Reads saved JPEG images and camera JSON transforms from `rawDataDir`,
    /// parses vertices from `objData`, and projects each vertex into camera frames
    /// to sample RGB color.
    /// Vertex-colors the mesh by sampling saved frames. `progress` (0...1) is called after each
    /// sampled frame on the calling (background) thread — callers hop to main to update UI.
    static func colorizeFromSavedFrames(objData: Data, rawDataDir: URL?, progress: ((Double) -> Void)? = nil) -> Data? {
        guard let rawDir = rawDataDir else { return nil }
        let fm = FileManager.default

        // Parse OBJ vertices using shared parser
        guard let parsed = MeshParser.parseOBJ(from: objData) else { return nil }
        let vertices = parsed.vertices
        guard !vertices.isEmpty else { return nil }

        // Find saved camera JSONs
        let camerasDir = rawDir.appendingPathComponent("cameras")
        let imagesDir = rawDir.appendingPathComponent("images")
        guard fm.fileExists(atPath: camerasDir.path),
              fm.fileExists(atPath: imagesDir.path) else { return nil }

        let cameraFiles = (try? fm.contentsOfDirectory(at: camerasDir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        guard !cameraFiles.isEmpty else { return nil }

        // Sample up to maxColorizationFrames evenly-spaced frames for high coverage
        let maxFrames = min(cameraFiles.count, AppConstants.maxColorizationFrames)
        let stride = max(1, cameraFiles.count / maxFrames)
        let sampledFiles = Swift.stride(from: 0, to: cameraFiles.count, by: stride).prefix(maxFrames).map { cameraFiles[$0] }

        // Initialize color array (gray default for unsampled vertices)
        var colors = [SIMD3<Float>](repeating: SIMD3<Float>(0.5, 0.5, 0.5), count: vertices.count)
        var colored = [Bool](repeating: false, count: vertices.count)

        // Downscale factor — vertex coloring doesn't need full-res images
        let downscaleFactor = 2

        for (frameIdx, cameraFile) in sampledFiles.enumerated() {
          // Bound peak memory: each frame decodes a UIImage/CGImage + a downsample
          // context + a depth image, all autoreleased. Without a per-frame pool these
          // accumulate across every sampled frame and can spike memory / trigger jetsam.
          autoreleasepool {
            // Parse camera JSON (Polycam format with t_XX transform and intrinsics)
            guard let jsonData = try? Data(contentsOf: cameraFile),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }

            guard let fx = (json["fx"] as? NSNumber)?.floatValue,
                  let fy = (json["fy"] as? NSNumber)?.floatValue,
                  let cx = (json["cx"] as? NSNumber)?.floatValue,
                  let cy = (json["cy"] as? NSNumber)?.floatValue,
                  let imgW = (json["width"] as? NSNumber)?.intValue,
                  let imgH = (json["height"] as? NSNumber)?.intValue else { return }

            // Reconstruct 4x4 camera-to-world transform (row-major t_XX values)
            guard let t00 = (json["t_00"] as? NSNumber)?.floatValue,
                  let t01 = (json["t_01"] as? NSNumber)?.floatValue,
                  let t02 = (json["t_02"] as? NSNumber)?.floatValue,
                  let t03 = (json["t_03"] as? NSNumber)?.floatValue,
                  let t10 = (json["t_10"] as? NSNumber)?.floatValue,
                  let t11 = (json["t_11"] as? NSNumber)?.floatValue,
                  let t12 = (json["t_12"] as? NSNumber)?.floatValue,
                  let t13 = (json["t_13"] as? NSNumber)?.floatValue,
                  let t20 = (json["t_20"] as? NSNumber)?.floatValue,
                  let t21 = (json["t_21"] as? NSNumber)?.floatValue,
                  let t22 = (json["t_22"] as? NSNumber)?.floatValue,
                  let t23 = (json["t_23"] as? NSNumber)?.floatValue else { return }

            // Camera-to-world (row-major → column-major for simd)
            let cam2World = simd_float4x4(columns: (
                SIMD4<Float>(t00, t10, t20, 0),
                SIMD4<Float>(t01, t11, t21, 0),
                SIMD4<Float>(t02, t12, t22, 0),
                SIMD4<Float>(t03, t13, t23, 1)
            ))
            // World-to-camera
            let world2Cam = cam2World.inverse

            // Load corresponding image
            guard let imagePath = json["image_path"] as? String else { return }
            let imageURL = rawDir.appendingPathComponent(imagePath)
            guard let imageData = try? Data(contentsOf: imageURL),
                  let uiImage = UIImage(data: imageData),
                  let cgImage = uiImage.cgImage else { return }

            // Downsample image to reduce memory peak (#9)
            let targetWidth = cgImage.width / downscaleFactor
            let targetHeight = cgImage.height / downscaleFactor
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: targetWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

            guard let downsampled = context.makeImage(),
                  let pixelData = downsampled.dataProvider?.data,
                  let ptr = CFDataGetBytePtr(pixelData) else { return }
            let width = downsampled.width
            let height = downsampled.height
            let bytesPerRow = downsampled.bytesPerRow
            let bytesPerPixel = downsampled.bitsPerPixel / 8

            // Adjust intrinsics for downscale
            let scaledFx = fx / Float(downscaleFactor)
            let scaledFy = fy / Float(downscaleFactor)
            let scaledCx = cx / Float(downscaleFactor)
            let scaledCy = cy / Float(downscaleFactor)
            let scaledW = imgW / downscaleFactor
            let scaledH = imgH / downscaleFactor

            // Load corresponding depth image for occlusion testing
            var depthPtr: UnsafePointer<UInt8>?
            var depthWidth = 0
            var depthHeight = 0
            var depthBytesPerRow = 0
            var depthPixelDataBuffer: CFData?
            var isDepthLittleEndian = false

            if let depthPath = json["depth_path"] as? String {
                let depthURL = rawDir.appendingPathComponent(depthPath)
                if let depthData = try? Data(contentsOf: depthURL),
                   let depthImage = UIImage(data: depthData),
                   let cgDepth = depthImage.cgImage,
                   cgDepth.bitsPerPixel == 16,
                   let cgDepthData = cgDepth.dataProvider?.data {
                    depthPixelDataBuffer = cgDepthData
                    depthPtr = CFDataGetBytePtr(cgDepthData)
                    depthWidth = cgDepth.width
                    depthHeight = cgDepth.height
                    depthBytesPerRow = cgDepth.bytesPerRow
                    let info = cgDepth.bitmapInfo.rawValue
                    isDepthLittleEndian = (info & CGBitmapInfo.byteOrder16Little.rawValue) != 0 || (info & CGBitmapInfo.byteOrder32Little.rawValue) != 0
                }
            }

            // Project each vertex into this camera frame
            for (i, vertex) in vertices.enumerated() {
                let worldPos = SIMD4<Float>(vertex.x, vertex.y, vertex.z, 1.0)
                let camPos = world2Cam * worldPos

                // Must be in front of camera (z < 0 in camera space for ARKit convention)
                guard camPos.z < 0 else { continue }

                // Project using intrinsics (adjusted for downscale)
                let invZ = -1.0 / camPos.z
                let px = Int(scaledFx * camPos.x * invZ + scaledCx)
                let py = Int(scaledCy - scaledFy * camPos.y * invZ)

                guard px >= 0 && px < scaledW && py >= 0 && py < scaledH else { continue }
                guard px < width && py < height else { continue }

                // Depth Occlusion Test
                if let dPtr = depthPtr {
                    let dpx = px * downscaleFactor * depthWidth / max(imgW, 1)
                    let dpy = py * downscaleFactor * depthHeight / max(imgH, 1)
                    if dpx >= 0 && dpx < depthWidth && dpy >= 0 && dpy < depthHeight {
                        let dOffset = dpy * depthBytesPerRow + dpx * 2
                        let b0 = UInt16(dPtr[dOffset])
                        let b1 = UInt16(dPtr[dOffset + 1])
                        let depthValue = isDepthLittleEndian ? (b1 << 8) | b0 : (b0 << 8) | b1

                        let depthMM = Float(depthValue)
                        let expectedMM = -camPos.z * 1000.0

                        // If depth pixel is 0, it means no valid depth or privacy mask. Skip coloring.
                        if depthMM == 0 { continue }

                        // If expected distance is > tolerance farther than what the depth sensor saw, we are occluded
                        if expectedMM > depthMM + AppConstants.depthOcclusionToleranceMM { continue }
                    }
                }

                let offset = py * bytesPerRow + px * bytesPerPixel
                let r = Float(ptr[offset]) / 255.0
                let g = Float(ptr[offset + 1]) / 255.0
                let b = Float(ptr[offset + 2]) / 255.0

                // Latest frame with visibility wins (simple strategy)
                colors[i] = SIMD3<Float>(r, g, b)
                colored[i] = true
            }
            _ = depthPixelDataBuffer // Silence compiler warning while ensuring CFData buffer outlives the pointer
          } // autoreleasepool (per frame)
            progress?(Double(frameIdx + 1) / Double(sampledFiles.count))
        }

        let coloredCount = colored.reduce(0) { $0 + ($1 ? 1 : 0) }
        print("[VertexColor] Colored \(coloredCount)/\(vertices.count) vertices from \(sampledFiles.count) frames")

        // Convert to SIMD4<Float> with alpha=1 (matches buildColorData format), filling the
        // output Data in place to avoid an intermediate [SIMD4<Float>] allocation.
        var data = Data(count: colors.count * MemoryLayout<SIMD4<Float>>.stride)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: SIMD4<Float>.self)
            for i in colors.indices {
                let c = colors[i]
                out[i] = SIMD4<Float>(c.x, c.y, c.z, 1.0)
            }
        }
        return data
    }
}
