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
    ///
    /// Rebuilt as a robust, quality-weighted estimator rather than the old
    /// "latest frame with visibility wins" strategy, which let a single late
    /// frame with a drifted pose (after a tracking hiccup) overwrite all the
    /// good earlier samples and smear color across the mesh.
    ///
    /// For each vertex we collect up to `AppConstants.colorizationMaxObservations`
    /// observations across all sampled frames, keeping the highest-quality ones,
    /// then take the per-channel **weighted median** of those observations. The
    /// median is inherently robust: a few misaligned (drifted-frame) colors don't
    /// move it the way they move a mean. Each observation is weighted by:
    ///   - view angle: |normal · viewDir| — head-on views beat grazing ones
    ///   - distance:   inverse-square (floored) — closer frames resolve the
    ///                 surface at higher pixel density
    ///
    /// Depth occlusion and nearest-pixel sampling are unchanged from before.
    /// Reads saved JPEG images and camera JSON transforms from `rawDataDir`,
    /// parses vertices from `objData`, and projects each vertex into camera frames.
    /// `progress` (0...1) is called after each sampled frame on the calling
    /// (background) thread — callers hop to main to update UI.
    static func colorizeFromSavedFrames(objData: Data, rawDataDir: URL?, progress: ((Double) -> Void)? = nil) -> Data? {
        guard let rawDir = rawDataDir else { return nil }
        let fm = FileManager.default

        // Parse OBJ vertices using shared parser
        guard let parsed = MeshParser.parseOBJ(from: objData) else { return nil }
        let vertices = parsed.vertices
        guard !vertices.isEmpty else { return nil }

        // Per-vertex surface normals (area-weighted face normals) drive the
        // view-angle weight. Sign/winding may be inconsistent across the mesh,
        // so the weight uses |normal · viewDir| and is sign-agnostic.
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        for face in parsed.faces {
            let i0 = Int(face.0), i1 = Int(face.1), i2 = Int(face.2)
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }
            let n = simd_cross(vertices[i1] - vertices[i0], vertices[i2] - vertices[i0])
            normals[i0] += n; normals[i1] += n; normals[i2] += n
        }
        for i in normals.indices {
            normals[i] = simd_length(normals[i]) > 0 ? simd_normalize(normals[i]) : SIMD3<Float>(0, 0, 1)
        }

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

        // Per-vertex top-N observation buffers (flat, row = K entries per vertex).
        // Colors are kept as 8-bit (the source precision) to bound memory.
        let K = max(1, AppConstants.colorizationMaxObservations)
        let vertexCount = vertices.count
        var obsR = [UInt8](repeating: 0, count: vertexCount * K)
        var obsG = [UInt8](repeating: 0, count: vertexCount * K)
        var obsB = [UInt8](repeating: 0, count: vertexCount * K)
        var obsW = [Float](repeating: 0, count: vertexCount * K)
        var obsCount = [UInt8](repeating: 0, count: vertexCount)
        let distFloor = max(AppConstants.colorizationMinDistanceM, 0.001)

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
            // Camera position in world space (translation column of cam2World) —
            // used for the per-observation view-angle and distance weights.
            let camWorld = SIMD3<Float>(t03, t13, t23)

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
                        if expectedMM > depthMM + AppConstants.colorizationOcclusionToleranceMM { continue }
                    }
                }

                // Quality weight: head-on views and closer frames win.
                let toCam = camWorld - vertex
                let dist = simd_length(toCam)
                guard dist > 0 else { continue }
                let viewDir = toCam / dist
                let angleWeight = abs(simd_dot(normals[i], viewDir))   // 1 = head-on, 0 = grazing
                let clampedDist = max(dist, distFloor)
                let distWeight = 1.0 / (clampedDist * clampedDist)     // inverse-square, floored
                let weight = angleWeight * distWeight
                guard weight > 1e-6 else { continue }

                let offset = py * bytesPerRow + px * bytesPerPixel
                let r = ptr[offset]
                let g = ptr[offset + 1]
                let b = ptr[offset + 2]

                // Keep the top-K observations by weight for this vertex.
                let base = i * K
                let cnt = Int(obsCount[i])
                if cnt < K {
                    obsR[base + cnt] = r; obsG[base + cnt] = g; obsB[base + cnt] = b
                    obsW[base + cnt] = weight
                    obsCount[i] = UInt8(cnt + 1)
                } else {
                    // Replace the lowest-weight slot if this observation is better.
                    var minIdx = base
                    var minW = obsW[base]
                    for k in 1..<K where obsW[base + k] < minW {
                        minW = obsW[base + k]; minIdx = base + k
                    }
                    if weight > minW {
                        obsR[minIdx] = r; obsG[minIdx] = g; obsB[minIdx] = b
                        obsW[minIdx] = weight
                    }
                }
            }
            _ = depthPixelDataBuffer // Silence compiler warning while ensuring CFData buffer outlives the pointer
          } // autoreleasepool (per frame)
            progress?(Double(frameIdx + 1) / Double(sampledFiles.count))
        }

        // Reduce each vertex's observations to a per-channel weighted median.
        // Unsampled vertices keep a neutral gray so they read as "no data".
        var coloredCount = 0
        // Scratch buffers reused across vertices (sized K) to avoid per-vertex allocations.
        var sV = [Float](repeating: 0, count: K)
        var sW = [Float](repeating: 0, count: K)

        var data = Data(count: vertexCount * MemoryLayout<SIMD4<Float>>.stride)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: SIMD4<Float>.self)
            for i in 0..<vertexCount {
                let cnt = Int(obsCount[i])
                if cnt == 0 {
                    out[i] = SIMD4<Float>(0.5, 0.5, 0.5, 1.0)
                    continue
                }
                let base = i * K
                let r = Self.weightedMedian(values: obsR, weights: obsW, base: base, count: cnt, sV: &sV, sW: &sW)
                let g = Self.weightedMedian(values: obsG, weights: obsW, base: base, count: cnt, sV: &sV, sW: &sW)
                let b = Self.weightedMedian(values: obsB, weights: obsW, base: base, count: cnt, sV: &sV, sW: &sW)
                out[i] = SIMD4<Float>(r / 255.0, g / 255.0, b / 255.0, 1.0)
                coloredCount += 1
            }
        }
        print("[VertexColor] Colored \(coloredCount)/\(vertexCount) vertices from \(sampledFiles.count) frames (weighted median, K=\(K))")
        return data
    }

    /// Weighted median of one color channel over a vertex's observations.
    /// `values`/`weights` are the flat top-K buffers; `base..<base+count` is this
    /// vertex's slice. `sV`/`sW` are caller-owned scratch buffers (length ≥ count)
    /// reused across vertices to avoid per-vertex allocation. Returns the channel
    /// value at which cumulative weight first reaches half the total weight.
    private static func weightedMedian(
        values: [UInt8], weights: [Float], base: Int, count: Int,
        sV: inout [Float], sW: inout [Float]
    ) -> Float {
        // Copy this vertex's slice into scratch, then insertion-sort by value
        // (count ≤ K is small, so insertion sort is the right tool).
        for k in 0..<count {
            sV[k] = Float(values[base + k])
            sW[k] = weights[base + k]
        }
        for k in 1..<count {
            let v = sV[k], w = sW[k]
            var j = k - 1
            while j >= 0 && sV[j] > v {
                sV[j + 1] = sV[j]; sW[j + 1] = sW[j]; j -= 1
            }
            sV[j + 1] = v; sW[j + 1] = w
        }
        var total: Float = 0
        for k in 0..<count { total += sW[k] }
        let half = total / 2
        var cum: Float = 0
        for k in 0..<count {
            cum += sW[k]
            if cum >= half { return sV[k] }
        }
        return sV[count - 1]
    }
}
