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

            // Feature count of the map we're about to persist. A relocalized generation
            // should save *more* features than it loaded (inherited + newly observed); a
            // sudden collapse here is the inherited map being dropped before export.
            LocalizationDiag.logMapStats(map, context: "save (about to persist)")

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
        let normals = MeshParser.accumulateVertexNormals(vertices: vertices, faces: parsed.faces)

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
    /// Selects up to `max` camera-JSON files to sample for vertex coloring, **always
    /// including every sharp keyframe** and filling the remainder with evenly-spaced
    /// sweep frames. Keyframes carry the least motion blur and best registration, so
    /// guaranteeing their inclusion (rather than only weighting them if they happen to
    /// land on an even-stride sample) sharpens the colored preview on scans that paused
    /// for stills. A pure sweep with no keyframes falls back to plain even-stride, and
    /// when keyframes alone exceed the budget they're even-strided among themselves.
    /// `cameraFiles` must be sorted chronologically; the returned subset preserves that order.
    /// `keyframeStems` are the flagged frames from `keyframeStems(rawDir:)` — resolved from
    /// transforms.json in one read rather than opening every per-frame camera JSON here.
    static func selectColorizationFrames(
        from cameraFiles: [URL], max maxFrames: Int, keyframeStems: Set<String>
    ) -> [URL] {
        guard cameraFiles.count > maxFrames, maxFrames > 0 else { return cameraFiles }

        let isKeyframe: [Bool] = cameraFiles.map {
            keyframeStems.contains($0.deletingPathExtension().lastPathComponent)
        }
        let keyframeIdx = cameraFiles.indices.filter { isKeyframe[$0] }

        func evenStride(_ indices: [Int], count: Int) -> [Int] {
            guard indices.count > count else { return indices }
            let step = Swift.max(1, indices.count / count)
            return Swift.stride(from: 0, to: indices.count, by: step).prefix(count).map { indices[$0] }
        }

        let selected: [Int]
        if keyframeIdx.isEmpty {
            // No stills — even-stride across all frames (original behavior).
            selected = evenStride(Array(cameraFiles.indices), count: maxFrames)
        } else if keyframeIdx.count >= maxFrames {
            // More keyframes than the budget — even-stride among the keyframes.
            selected = evenStride(keyframeIdx, count: maxFrames)
        } else {
            // All keyframes, then even-stride fill from the sweep frames.
            let nonKeyframeIdx = cameraFiles.indices.filter { !isKeyframe[$0] }
            let fill = evenStride(nonKeyframeIdx, count: maxFrames - keyframeIdx.count)
            selected = (keyframeIdx + fill).sorted()
        }
        return selected.map { cameraFiles[$0] }
    }

    /// Frame stems (e.g. "frame_00042") flagged `is_keyframe` in the scan's transforms.json.
    /// One file read replaces opening every camera JSON — `is_keyframe` is recorded per frame
    /// there by the capture writers. Missing/old transforms.json degrades to an empty set
    /// (pure even-stride selection, the pre-keyframe behavior).
    static func keyframeStems(rawDir: URL) -> Set<String> {
        let url = rawDir.appendingPathComponent("transforms.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let frames = json["frames"] as? [[String: Any]] else { return [] }
        var stems = Set<String>()
        for frame in frames where (frame["is_keyframe"] as? Bool) == true {
            if let path = frame["file_path"] as? String {
                stems.insert(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
            }
        }
        return stems
    }

    static func colorizeFromSavedFrames(objData: Data, rawDataDir: URL?, progress: ((Double) -> Void)? = nil) -> Data? {
        guard let rawDir = rawDataDir else { return nil }
        let startTime = CACurrentMediaTime()
        let fm = FileManager.default

        // Parse OBJ vertices using shared parser
        guard let parsed = MeshParser.parseOBJ(from: objData) else { return nil }
        var vertices = parsed.vertices
        guard !vertices.isEmpty else { return nil }

        // Registered scans: mesh.obj is in the location's CANONICAL frame, but the saved camera
        // poses/depth are in this scan's RAW capture frame — projecting canonical vertices through
        // raw cameras would misproject by the applied registration transform (decimeters). Undo it
        // here for the projection only; the emitted colors are per-vertex-ordered, so they attach
        // to the canonical mesh unchanged. (Normals are derived from these remapped vertices below,
        // keeping the view-angle weights frame-consistent.)
        if let sidecar = SaveRegistration.loadSidecar(scanDirectory: rawDir.deletingLastPathComponent()),
           sidecar.applied, let t = sidecar.transformMatrix {
            let inv = t.inverse
            for i in vertices.indices {
                let p = inv * SIMD4<Float>(vertices[i], 1)
                vertices[i] = SIMD3(p.x, p.y, p.z)
            }
            let trans = simd_length(SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z))
            print(String(format: "[VertexColor] un-applied registration (trans=%.1fcm) → projecting canonical mesh through raw cameras", trans * 100))
        }

        // Per-vertex surface normals (area-weighted face normals) drive the
        // view-angle weight. Sign/winding may be inconsistent across the mesh,
        // so the weight uses |normal · viewDir| and is sign-agnostic.
        var normals = MeshParser.accumulateVertexNormals(vertices: vertices, faces: parsed.faces)
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

        // Sample up to maxColorizationFrames, preferring sharp keyframes (see helper).
        let sampledFiles = Self.selectColorizationFrames(
            from: cameraFiles, max: AppConstants.maxColorizationFrames,
            keyframeStems: Self.keyframeStems(rawDir: rawDir)
        )

        // ── Privacy: keep person pixels out of colors.bin ──
        // Colorize bakes sampled pixels into colors.bin, which exports as PLY vertex colors — a
        // path the export-time privacy blur never revisits. The old capture pipeline zeroed person
        // regions in the depth PNG at capture, so the depth==0 skip in the projection loop already
        // excluded people for free. The deferred-blur pipeline instead writes RAW depth + per-frame
        // person masks under masks/ and defers blur to export — silently removing that free
        // protection. Restore the invariant here: in the deferred-blur era, skip masked pixels and
        // (per 2026-07-21 decision) skip whole frames whose stencil hadn't warmed up, so no person
        // pixel is ever baked. Legacy captures have no masks/ dir → this stays dormant and the
        // depth==0 skip keeps protecting them; privacy-off captures have an empty masks/ → no-op.
        let masksDir = rawDir.appendingPathComponent("masks")
        // Deferred-blur era (RAW depth, needs per-frame masks) vs legacy (depth already person-zeroed
        // at capture, so the depth==0 skip protects). masks/ (created unconditionally at session
        // start) is the primary signal. If it was lost (partial restore / manual cleanup), the
        // metadata `privacy_filter` KEY marks the era — every deferred capture stamps it
        // (FrameCaptureSession), legacy metadata predates it. UNREADABLE metadata (missing/corrupt —
        // abnormal, since it's written for every scan) fails CLOSED into the deferred era so a
        // lost-masks deferred scan can't silently colorize raw depth. Only READABLE metadata WITHOUT
        // the key is genuine legacy. Mirrors ScanExportManager's gate.
        let meta: [String: Any]? = {
            guard let metaData = try? Data(contentsOf: rawDir.appendingPathComponent("scan4d_metadata.json")),
                  let obj = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] else { return nil }
            return obj
        }()
        let masksDirExists = fm.fileExists(atPath: masksDir.path)
        let hasPrivacyKey = meta?.keys.contains("privacy_filter") ?? false
        let deferredBlurEra = masksDirExists || hasPrivacyKey || meta == nil
        var privacyWasOn = false
        if deferredBlurEra {
            let maskCount = !masksDirExists ? 0
                : ((try? fm.contentsOfDirectory(at: masksDir, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "png" }.count
            privacyWasOn = maskCount > 0
            if !privacyWasOn {
                // No surviving masks: honor an explicit Bool; a present-but-garbage flag or
                // unreadable metadata fails CLOSED (assume privacy was on — never bake a person).
                privacyWasOn = (meta?["privacy_filter"] as? Bool) ?? true
            }
        }
        let maskMode = deferredBlurEra && privacyWasOn   // sample per-frame masks + skip unmasked frames
        if maskMode { print("[VertexColor] privacy mask mode ON (deferred-blur capture) — masking person regions") }

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

            // Sharp stillness keyframes (hi-res stills captured while the device was
            // stationary) carry far less motion blur than sweep frames, so their color
            // observations get a weight bonus — where a keyframe saw a surface, its
            // crisp samples dominate the weighted median over blur-prone sweep samples.
            let frameWeight: Float = (json["is_keyframe"] as? Bool) == true
                ? AppConstants.colorizationKeyframeWeight : 1.0

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

            // Load this frame's person mask (deferred-blur era only). No mask ⇒ the stencil hadn't
            // warmed up on this frame → skip the whole frame rather than risk baking an unmasked
            // person (the top-K redundancy across other frames absorbs the coverage loss).
            var maskPtr: UnsafePointer<UInt8>?
            var maskWidth = 0, maskHeight = 0, maskBytesPerRow = 0
            var maskDataBuffer: CFData?
            if maskMode {
                let frameName = (imagePath as NSString).lastPathComponent
                let maskURL = masksDir.appendingPathComponent(((frameName as NSString).deletingPathExtension) + ".png")
                guard let mData = try? Data(contentsOf: maskURL),
                      let mImg = UIImage(data: mData)?.cgImage,
                      mImg.bitsPerPixel == 8,   // fail closed: only the known 8bpp-gray layout is safe to index 1 byte/pixel
                      let mProvider = mImg.dataProvider?.data else { return }   // missing/unreadable/unexpected mask → skip frame
                maskDataBuffer = mProvider
                maskPtr = CFDataGetBytePtr(mProvider)
                maskWidth = mImg.width
                maskHeight = mImg.height
                maskBytesPerRow = mImg.bytesPerRow
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

                // Person-mask exclusion (deferred-blur era): skip any vertex projecting into a
                // person region so its pixels never bake into colors.bin. A ±1 mask-pixel
                // neighborhood approximates export's 12 px silhouette dilation (the mask is ~⅛
                // image resolution) — conservative on privacy, negligible coverage cost.
                if let mPtr = maskPtr {
                    let mpx = px * downscaleFactor * maskWidth / max(imgW, 1)
                    let mpy = py * downscaleFactor * maskHeight / max(imgH, 1)
                    var person = false
                    for ddy in -1...1 where !person {
                        for ddx in -1...1 {
                            let sx = mpx + ddx, sy = mpy + ddy
                            if sx >= 0, sx < maskWidth, sy >= 0, sy < maskHeight,
                               mPtr[sy * maskBytesPerRow + sx] > 0 { person = true; break }
                        }
                    }
                    if person { continue }
                }

                // Quality weight: head-on views and closer frames win.
                let toCam = camWorld - vertex
                let dist = simd_length(toCam)
                guard dist > 0 else { continue }
                let viewDir = toCam / dist
                let angleWeight = abs(simd_dot(normals[i], viewDir))   // 1 = head-on, 0 = grazing
                let clampedDist = max(dist, distFloor)
                let distWeight = 1.0 / (clampedDist * clampedDist)     // inverse-square, floored
                let weight = angleWeight * distWeight * frameWeight    // keyframes get a sharpness bonus
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
            _ = maskDataBuffer       // ditto — keep the mask CFData alive for the vertex loop
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
        let elapsed = CACurrentMediaTime() - startTime
        print("[VertexColor] Colored \(coloredCount)/\(vertexCount) vertices from \(sampledFiles.count) frames (weighted median, K=\(K)) in \(String(format: "%.1f", elapsed))s")
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
