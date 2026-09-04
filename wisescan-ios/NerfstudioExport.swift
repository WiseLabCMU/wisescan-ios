import CoreGraphics
import Foundation
import ImageIO
import simd

/// Rebuilds a staged Polycam payload into a `transforms.json` bundle that Nerfstudio and
/// LichtFeld Studio load directly — no desktop conversion step.
///
/// WHY THIS REBUILDS RATHER THAN COPIES: capture's own `transforms.json`
/// (`FrameCaptureSession.writeTransformsJSON`) emits each ARKit matrix **column** as an
/// inner array. Nerfstudio's `transform_matrix` is row-major with translation in the last
/// column of the first three rows, and it slices `poses[:, :3, :4]` — so under the capture
/// layout every camera loads at the origin with a transposed rotation. The per-frame
/// `cameras/frame_*.json` written alongside it are correct (`t_rc` really is row `r`,
/// column `c`), so this reads those instead and leaves the capture path untouched.
///
/// THE TWO ENGINES want the same schema but disagree on sidecars, so the bundle satisfies
/// both at once:
///   * Nerfstudio asserts `mask_path` / `depth_file_path` are on every frame or on none,
///     so frames lacking either get a filler.
///   * LichtFeld compares sidecar dimensions to the image for **exact equality** and
///     aborts the whole load with DEPTH_SIZE_MISMATCH otherwise, so depth is resampled up
///     to each frame's RGB size — including the fillers.
/// The filler is cheap: a uniform image deflates to a few KB even at 12 MP.
enum NerfstudioExport {

    // MARK: - Entry point

    /// Converts `stagingDir` in place. Expects the Polycam payload already staged
    /// (`images/`, `depth/`, `confidence/`, `cameras/`) and leaves behind a bundle with
    /// `transforms.json`, resampled `depth/` and `masks/`. Anything derived by policy —
    /// seed clouds, rendered normals, mesh repair — belongs to the training-side pipeline.
    @discardableResult
    static func build(stagingDir: URL, masksSourceDir: URL?,
                      phase: ((ExportPhase) -> Void)? = nil) -> Bool {
        let fm = FileManager.default
        let camerasDir = stagingDir.appendingPathComponent("cameras")
        guard let cameraFiles = try? fm.contentsOfDirectory(at: camerasDir,
                                                            includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension.lowercased() == "json" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }),
              !cameraFiles.isEmpty else {
            print("[nerfstudio] ✗ no cameras/*.json in staging — cannot build transforms.json")
            return false
        }

        var cams: [CameraRecord] = []
        cams.reserveCapacity(cameraFiles.count)
        for url in cameraFiles {
            if let cam = CameraRecord(contentsOf: url, stem: url.deletingPathExtension().lastPathComponent) {
                cams.append(cam)
            }
        }
        guard !cams.isEmpty else {
            print("[nerfstudio] ✗ cameras/ held no parsable records")
            return false
        }

        // Nerfstudio decides per key: `fx_fixed = "fl_x" in meta`, and a key present at the
        // top level means the per-frame value is NEVER read. So globals and per-frame
        // overrides cannot coexist — with more than one intrinsic set the only correct
        // layout is no globals at all. ARKit refines focal length continuously, so a real
        // capture almost always lands here.
        let uniform = Set(cams.map(\.intrinsicKey)).count == 1

        let depthDir = stagingDir.appendingPathComponent("depth")
        let masksDir = stagingDir.appendingPathComponent("masks")
        var frames: [[String: Any]] = []
        var frameStems: [String] = []       // parallel to `frames`; fillers are keyed by stem
        var withRealDepth: [(CameraRecord, URL)] = []
        var needsDepthFiller: [CameraRecord] = []
        var needsMaskFiller: [CameraRecord] = []
        var realMasks = 0

        for (index, cam) in cams.enumerated() {
            phase?(.counted("Nerfstudio frames", index + 1, of: cams.count))
            let imageRel = cam.imagePath
            guard fm.fileExists(atPath: stagingDir.appendingPathComponent(imageRel).path) else {
                continue
            }

            var entry: [String: Any] = [
                "file_path": imageRel,
                "transform_matrix": cam.rowMajorMatrix
            ]
            if !uniform {
                entry["fl_x"] = cam.fx
                entry["fl_y"] = cam.fy
                entry["cx"] = cam.cx
                entry["cy"] = cam.cy
                entry["w"] = cam.width
                entry["h"] = cam.height
            }
            // Passed through for downstream triage; both engines ignore keys they do not know.
            for key in ["is_keyframe", "sharpness", "exposure_duration_s",
                        "face", "still_source", "camera_pose_source"] {
                if let value = cam.passthrough[key] { entry[key] = value }
            }
            if let confRel = cam.confidencePath,
               fm.fileExists(atPath: stagingDir.appendingPathComponent(confRel).path) {
                entry["confidence_file_path"] = confRel
            }

            // Depth: resample to the frame's RGB size so LichtFeld's equality check passes.
            if let depthRel = cam.depthPath {
                let src = stagingDir.appendingPathComponent(depthRel)
                if fm.fileExists(atPath: src.path) {
                    entry["depth_file_path"] = "depth/\(cam.stem).png"
                    withRealDepth.append((cam, src))
                } else {
                    needsDepthFiller.append(cam)
                }
            } else {
                needsDepthFiller.append(cam)
            }

            // Masks: the 360° cube faces ship operator/rod masks at quarter resolution.
            // White = keep already matches what both engines want; only the size changes.
            if let source = masksSourceDir?.appendingPathComponent("\(cam.stem).png"),
               fm.fileExists(atPath: source.path) {
                if placeMask(from: source, stem: cam.stem, width: cam.width, height: cam.height,
                             into: masksDir) {
                    entry["mask_path"] = "masks/\(cam.stem).png"
                    realMasks += 1
                } else {
                    needsMaskFiller.append(cam)
                }
            } else {
                needsMaskFiller.append(cam)
            }

            frames.append(entry)
            frameStems.append(cam.stem)
        }

        guard !frames.isEmpty else {
            print("[nerfstudio] ✗ no frames survived — every camera record lacked its image")
            return false
        }

        // Depth resample pass, then fillers for the cameras the LiDAR never covered.
        var resampled = 0
        for (index, pair) in withRealDepth.enumerated() {
            phase?(.counted("Nerfstudio depth", index + 1, of: withRealDepth.count))
            if resampleDepth(from: pair.1, stem: pair.0.stem,
                             width: pair.0.width, height: pair.0.height, into: depthDir) {
                resampled += 1
            }
        }
        var depthFillers = 0
        if resampled > 0 {
            for cam in needsDepthFiller {
                if writeEmptyDepth(stem: cam.stem, width: cam.width, height: cam.height,
                                   into: depthDir) {
                    depthFillers += 1
                }
            }
        }
        var maskFillers = 0
        if realMasks > 0 {
            for cam in needsMaskFiller {
                if writeOpaqueMask(stem: cam.stem, width: cam.width, height: cam.height,
                                   into: masksDir) {
                    maskFillers += 1
                }
            }
        }

        // The fillers now exist on disk for every frame that lacked a real sidecar — so key
        // those frames too. Without this the bundle had 394 depth files but only the 279
        // real ones referenced, and Nerfstudio's `len(depth_filenames) == len(image_filenames)`
        // assertion tripped on the count while LichtFeld (stem discovery) sailed through.
        if resampled > 0 && depthFillers == needsDepthFiller.count {
            for i in frames.indices where frames[i]["depth_file_path"] == nil {
                frames[i]["depth_file_path"] = "depth/\(frameStems[i]).png"
            }
        }
        if realMasks > 0 && maskFillers == needsMaskFiller.count {
            for i in frames.indices where frames[i]["mask_path"] == nil {
                frames[i]["mask_path"] = "masks/\(frameStems[i]).png"
            }
        }

        // A frame whose filler failed to write would break the all-or-nothing assertion, so
        // drop the key rather than ship a bundle Nerfstudio refuses outright.
        if realMasks == 0 || (realMasks + maskFillers) != frames.count {
            if realMasks > 0 {
                print("[nerfstudio] ⚠︎ mask filler incomplete (\(realMasks + maskFillers)/\(frames.count)) — dropping mask_path")
            }
            for i in frames.indices { frames[i].removeValue(forKey: "mask_path") }
            try? fm.removeItem(at: masksDir)
        }
        if resampled == 0 || (resampled + depthFillers) != frames.count {
            if resampled > 0 {
                print("[nerfstudio] ⚠︎ depth filler incomplete (\(resampled + depthFillers)/\(frames.count)) — dropping depth_file_path")
            }
            for i in frames.indices { frames[i].removeValue(forKey: "depth_file_path") }
        }

        var transforms: [String: Any] = [
            "camera_model": "OPENCV",
            "k1": 0.0, "k2": 0.0, "p1": 0.0, "p2": 0.0
        ]
        if uniform, let first = cams.first {
            transforms["fl_x"] = first.fx
            transforms["fl_y"] = first.fy
            transforms["cx"] = first.cx
            transforms["cy"] = first.cy
            transforms["w"] = first.width
            transforms["h"] = first.height
        }
        if frames.contains(where: { $0["depth_file_path"] != nil }) {
            // Informational. Nerfstudio takes the real value from
            // `nerfstudio-data --depth-unit-scale-factor`, whose default (1e-3) matches.
            transforms["depth_unit_scale_factor"] = 0.001
        }

        // No seed cloud here: which points seed the splats (voxel size, confidence weighting,
        // mesh vs LiDAR) is training-side policy, not a representation of the capture. The
        // pipeline writes `sparse_pc.ply` and adds `ply_file_path` itself; both engines
        // load without the key.

        transforms["frames"] = frames
        guard let data = try? JSONSerialization.data(withJSONObject: transforms,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            print("[nerfstudio] ✗ failed to serialise transforms.json")
            return false
        }
        do {
            try data.write(to: stagingDir.appendingPathComponent("transforms.json"), options: .atomic)
        } catch {
            print("[nerfstudio] ✗ failed to write transforms.json: \(error.localizedDescription)")
            return false
        }

        // cameras/ and mesh_info.json stay: transforms.json is built from them, but the
        // export never discards captured data — a few hundred KB of JSON is cheap insurance
        // against a future transforms.json schema disagreement.

        print("[nerfstudio] ✓ \(frames.count) frames, \(uniform ? "global" : "per-frame") intrinsics, "
              + "depth \(resampled)+\(depthFillers) filler, masks \(realMasks)+\(maskFillers) filler")
        return true
    }

    // MARK: - Camera records

    /// One `cameras/frame_*.json`. `t_rc` is row `r`, column `c` of the camera-to-world
    /// matrix — the layout Nerfstudio wants, unlike the sibling transforms.json.
    private struct CameraRecord {
        let stem: String
        let fx, fy, cx, cy: Double
        let width, height: Int
        let rows: [[Double]]           // 3x4
        let imagePath: String
        let depthPath: String?
        let confidencePath: String?
        let passthrough: [String: Any]

        init?(contentsOf url: URL, stem: String) {
            guard let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let fx = (json["fx"] as? NSNumber)?.doubleValue,
                  let fy = (json["fy"] as? NSNumber)?.doubleValue,
                  let cx = (json["cx"] as? NSNumber)?.doubleValue,
                  let cy = (json["cy"] as? NSNumber)?.doubleValue,
                  let width = (json["width"] as? NSNumber)?.intValue,
                  let height = (json["height"] as? NSNumber)?.intValue,
                  width > 0, height > 0 else { return nil }

            var rows: [[Double]] = []
            for r in 0..<3 {
                var row: [Double] = []
                for c in 0..<4 {
                    guard let v = (json["t_\(r)\(c)"] as? NSNumber)?.doubleValue else { return nil }
                    row.append(v)
                }
                rows.append(row)
            }

            self.stem = stem
            self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
            self.width = width; self.height = height
            self.rows = rows
            self.imagePath = (json["image_path"] as? String) ?? "images/\(stem).jpg"
            self.depthPath = json["depth_path"] as? String
            self.confidencePath = json["confidence_path"] as? String
            var extras: [String: Any] = [:]
            for key in ["is_keyframe", "sharpness", "exposure_duration_s",
                        "face", "still_source", "camera_pose_source"] {
                if let value = json[key] { extras[key] = value }
            }
            self.passthrough = extras
        }

        /// Row-major 4x4, `[0,0,0,1]` appended — ARKit's convention is already Nerfstudio's
        /// (+X right, +Y up, -Z forward), so nothing is remapped.
        var rowMajorMatrix: [[Double]] {
            rows + [[0.0, 0.0, 0.0, 1.0]]
        }

        var intrinsicKey: String {
            "\(fx)|\(fy)|\(cx)|\(cy)|\(width)|\(height)"
        }
    }

    // MARK: - Sidecar resampling

    /// Nearest-neighbour, never bilinear: interpolating between two depths across an object
    /// boundary invents a surface at a range nothing measured, and those "flying pixels" are
    /// worse than no depth at all.
    private static func resampleDepth(from src: URL, stem: String, width: Int, height: Int,
                                      into dir: URL) -> Bool {
        // Read through Data, not the URL: the destination is this same path (staging holds
        // capture's depth under the frame's own name), and a memory-mapped source being
        // rewritten underneath is not worth risking. Decoding to Data first releases the
        // file before the write.
        guard let raw = try? Data(contentsOf: src),
              let source = CGImageSourceCreateWithData(raw as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let decoded = DepthPNG.millimetres(from: image) else { return false }

        let out: [UInt16]
        if decoded.width == width && decoded.height == height {
            out = decoded.values
        } else {
            var resized = [UInt16](repeating: 0, count: width * height)
            for y in 0..<height {
                let sy = y * decoded.height / height
                let srcRow = sy * decoded.width
                let dstRow = y * width
                for x in 0..<width {
                    resized[dstRow + x] = decoded.values[srcRow + x * decoded.width / width]
                }
            }
            out = resized
        }
        guard let data = DepthPNG.encode(out, width: width, height: height) else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: dir.appendingPathComponent("\(stem).png"), options: .atomic)
            return true
        } catch {
            print("[nerfstudio] ✗ depth write \(stem): \(error.localizedDescription)")
            return false
        }
    }

    /// All-zero depth for cameras the LiDAR never covered (the 360° cube faces).
    ///
    /// Zero is the safe filler because both engines mask it out themselves: Nerfstudio's
    /// `ds_nerf_depth_loss` / `urban_radiance_field_depth_loss` build
    /// `depth_mask = termination_depth > 0`, and LichtFeld's depth-anchor collector and
    /// `pixel_active` both reject `!(t > 0)`. These frames therefore contribute no depth
    /// supervision rather than false supervision at range 0.
    private static func writeEmptyDepth(stem: String, width: Int, height: Int, into dir: URL) -> Bool {
        guard let data = DepthPNG.encode([UInt16](repeating: 0, count: width * height),
                                         width: width, height: height) else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? data.write(to: dir.appendingPathComponent("\(stem).png"), options: .atomic)) != nil
    }

    private static func placeMask(from src: URL, stem: String, width: Int, height: Int,
                                  into dir: URL) -> Bool {
        guard var mask = OperatorRigMask.load(pngAt: src) else { return false }
        if mask.width != width || mask.height != height {
            var scaled = [UInt8](repeating: 255, count: width * height)
            for y in 0..<height {
                let sy = y * mask.height / height
                let srcRow = sy * mask.width
                let dstRow = y * width
                for x in 0..<width {
                    scaled[dstRow + x] = mask.bytes[srcRow + x * mask.width / width]
                }
            }
            mask = OperatorRigMask.Mask(bytes: scaled, width: width, height: height)
        }
        guard let data = OperatorRigMask.encodePNG(mask) else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? data.write(to: dir.appendingPathComponent("\(stem).png"), options: .atomic)) != nil
    }

    /// All-keep mask, for frames with no real one. Nerfstudio wants `mask_path` on every
    /// frame or none; white excludes nothing, so this is a no-op that satisfies the check.
    private static func writeOpaqueMask(stem: String, width: Int, height: Int, into dir: URL) -> Bool {
        let mask = OperatorRigMask.Mask(bytes: [UInt8](repeating: 255, count: width * height),
                                        width: width, height: height)
        guard let data = OperatorRigMask.encodePNG(mask) else { return false }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? data.write(to: dir.appendingPathComponent("\(stem).png"), options: .atomic)) != nil
    }
}
