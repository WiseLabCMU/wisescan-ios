import CoreGraphics
import CryptoKit
import ImageIO
import Metal
import UIKit
import simd

/// Cube-face export for equirectangular 360° stills (docs/design/still-source-360.md →
/// "Export: cube map"): each staged still reprojects into **6 synthetic pinhole faces**
/// — front/right/back/left/up/down — each shipping with an operator/rig mask, emitted as ordinary
/// keyframe images + Polycam camera JSONs, so the equirectangular camera model disappears
/// from the data contract entirely. Each face is an exact 90° FOV pinhole:
/// `fx = fy = cx = cy = faceSize / 2`.
///
/// Pose = the **mechanical-prior rig extrinsic** (calibration plan step 1): ARKit is
/// gravity-aligned and Theta zenith correction keeps the equirect level, so the prior only
/// needs position + yaw — the camera sits `AppConstants.rigRodHeightMeters` up the rod from
/// the phone (an offset in the PHONE's frame, so it swings with the device), facing the
/// phone's horizontal forward rotated by
/// `AppConstants.rigYawOffsetDegrees`. The solved hand–eye refinement replaces those two
/// numbers later without changing this contract. Poses are camera-to-world in the ARKit
/// world frame, same convention as every other frame in the bundle.
///
/// PRIVACY ORDER: faces are sampled from the STAGED equirect after `stageEquirectStills`'
/// privacy pass — blur (or the user's per-scan consent) is baked into the pixels the faces
/// inherit. Never call this on a raw_data equirect.
enum EquirectFaceExport {

    /// Whether a camera model's panos can be trusted LEVEL — the rig-prior pose math assumes
    /// zenith-corrected (internally "gimbaled") equirects; a non-leveling camera would bake
    /// its roll/pitch into every face pose. Gate by the sidecar's reported model:
    /// - `.validated` — leveling confirmed on device.
    ///   THETA X: original field validation.
    ///   THETA Z1 (fw 3.60.3, promoted 2026-08-19): three healthy field scans against the
    ///   criterion set for it — solved elevation offsets +1.4° / +2.8° / +1.4° (a leveling
    ///   failure would land here and track rig tilt; it does not), pitch residual collapsed
    ///   to 0.09° / 0.17° once the rod tape was corrected, keyframe-anchor agreement ≤3.6°,
    ///   residuals 3.7–4.4 px in the X's range, and its own IMU agreeing with ARKit to
    ///   1.6–2.3° mean across every scan. Its XMP also asserts PosePitch/Roll = 0.0, the
    ///   same claim the X makes. (A fourth scan, a glass-walled room, was excluded — its
    ///   failure was the edge cost misled by reflections, not leveling, and it is what made
    ///   the yaw anchor binding in v13.)
    /// - `.assumedLevel` — the hardware levels but no field evidence yet; faces emit with a
    ///   marked pose source. No current camera sits here; the case stays for the next model.
    /// - `.unsupported` — unknown model: the level-pano assumption is unsafe, so NO pose-
    ///   bearing faces are emitted (the archived equirect still ships). A later feature can
    ///   compensate from the camera's own gyro metadata and lift this gate.
    enum LevelingSupport {
        case validated
        case assumedLevel
        case unsupported
    }

    static func levelingSupport(forModel model: String?) -> LevelingSupport {
        guard let model = model?.uppercased() else { return .unsupported }
        if model.contains("THETA X") { return .validated }
        if model.contains("THETA Z1") { return .validated }
        return .unsupported
    }

    /// One emitted cube face: name suffix + its rotation FROM the rig camera frame.
    fileprivate struct Face {
        let name: String
        let rotation: simd_float3x3
    }

    /// Cam-space rotations (OpenGL/ARKit camera convention: +X right, +Y up, -Z forward).
    /// Derivation: view direction is -Z rotated by `rotation`; right face looks along +X
    /// (yaw -90°), left along -X (yaw +90°), back along +Z (yaw 180°), up along +Y
    /// (pitch +90°). Pixel content must agree: the sampler's face bases below use the same
    /// axes, so face imagery and face pose rotate together.
    /// Faces emitted per still — the divisor every consumer needs to turn a face count
    /// back into a still count.
    static var faceCount: Int { faces.count }

    private static let faces: [Face] = [
        Face(name: "front", rotation: matrix_identity_float3x3),
        Face(name: "right", rotation: yawRotation(-.pi / 2)),
        Face(name: "back", rotation: yawRotation(.pi)),
        Face(name: "left", rotation: yawRotation(.pi / 2)),
        Face(name: "up", rotation: pitchRotation(.pi / 2)),
        // The down face ships now that a per-face mask ships with it. It was dropped by
        // construction because it is dominated by the operator, grip and rod — but that
        // also threw away the floor immediately under the camera, the closest and
        // best-parallax geometry in the still. Masked precisely rather than discarded
        // wholesale, the useful part survives and downstream keeps the choice.
        Face(name: "down", rotation: pitchRotation(-.pi / 2))
    ]

    // MARK: - Colorize source (Developer Mode probe)

    /// (Re)generate cube-face frames for the COLORIZER under `raw_data/face_frames/`
    /// ({cameras,images} in the exact Polycam per-frame shape the colorizer reads;
    /// faces carry is_keyframe=true and NO depth). Regenerated from scratch on every
    /// call so re-solved sidecar poses (solver-version bumps) are always reflected.
    /// PRIVACY: sources are RAW equirects — the output stays inside raw_data (which the
    /// export stages selectively and the repo privacy guard blocks) and must never be
    /// staged for export.
    static func generateFaceFramesForColorize(rawDataDir: URL) -> (cameras: URL, images: URL)? {
        let stillsDir = rawDataDir.appendingPathComponent("equirect_stills")
        let root = rawDataDir.appendingPathComponent("face_frames")
        let camerasDir = root.appendingPathComponent("cameras")
        let imagesDir = root.appendingPathComponent("images")
        let fileManager = FileManager.default
        guard let stills = try? fileManager.contentsOfDirectory(at: stillsDir, includingPropertiesForKeys: nil)
        else { return nil }
        let jpgs = stills.filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !jpgs.isEmpty else { return nil }
        let depthDir = root.appendingPathComponent("depth")

        // CACHE. Regeneration exists so a re-solved pose is always reflected — but the field
        // loop re-runs Color constantly (ON/OFF comparisons, re-runs after a re-solve), and
        // one 2026-08-19 session regenerated these faces five times over. Each pass costs a
        // ~0.3 s equirect decode plus five GPU reprojects, a mask cut, a depth raster and a
        // JPEG encode PER STILL — roughly half of a 12-27 s colorize.
        //
        // So key the cache on everything that changes what a face contains: each still's
        // baked pose and elevation offset, the solver version that produced them, the face
        // size, and the registration transform the depth raster is un-applied by. A re-solve
        // moves the fingerprint and the faces rebuild; a plain re-run hits.
        let stamp = faceCacheFingerprint(jpgs: jpgs, rawDataDir: rawDataDir)
        let stampURL = root.appendingPathComponent("fingerprint.txt")
        if let stamp, let existing = try? String(contentsOf: stampURL, encoding: .utf8),
           existing == stamp,
           let cameraCount = try? fileManager.contentsOfDirectory(at: camerasDir,
                                                                  includingPropertiesForKeys: nil).count,
           cameraCount == jpgs.count * faceCount {
            PerfDiag.log("[Colorize] face_frames CACHE HIT: \(cameraCount) faces from \(jpgs.count) still(s) — poses unchanged")
            return (camerasDir, imagesDir)
        }

        try? fileManager.removeItem(at: root)
        try? fileManager.createDirectory(at: camerasDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: depthDir, withIntermediateDirectories: true)

        // Depth from the scan's own mesh, so the probe measures POSE rather than bleed.
        // Without it the colorizer disables occlusion for face frames and paints through
        // walls — and bleed looks exactly like misregistration, which is why the
        // 2026-08-17 runs could not separate them.
        var mesh = (try? Data(contentsOf: rawDataDir.appendingPathComponent("mesh.obj")))
            .flatMap { MeshParser.parseOBJ(from: $0) }
            ?? (try? Data(contentsOf: rawDataDir.deletingLastPathComponent()
                            .appendingPathComponent("mesh.obj")))
            .flatMap { MeshParser.parseOBJ(from: $0) }
        if mesh == nil {
            PerfDiag.log("[Colorize] face depth unavailable (no mesh.obj) — occlusion OFF, expect bleed")
        }
        // Registered rescans: BOTH mesh.obj copies are baked into the location's CANONICAL
        // frame (ScanPostprocessor mirrors the transformed mesh into raw_data/), while the
        // face poses below come from the sidecars in this scan's RAW capture frame. Rasterising
        // canonical geometry through raw cameras misregisters the depth by the registration
        // translation — decimeters — so occlusion then rejects nearly every sample. Undo it,
        // exactly as VertexColorAccumulator does for the same reason.
        if let canonical = mesh,
           let reg = SaveRegistration.loadSidecar(scanDirectory: rawDataDir.deletingLastPathComponent()),
           reg.applied, let transform = reg.transformMatrix {
            let inverse = transform.inverse
            mesh = MeshParser.OBJData(vertices: canonical.vertices.map {
                let point = inverse * SIMD4<Float>($0, 1)
                return SIMD3(point.x, point.y, point.z)
            }, faces: canonical.faces)
            PerfDiag.log(String(format: "[Colorize] face depth: un-applied registration (trans=%.1fcm)",
                                simd_length(SIMD3(transform.columns.3.x, transform.columns.3.y,
                                                  transform.columns.3.z)) * 100))
        }

        var written = 0
        for jpg in jpgs {
            let sidecar = jpg.deletingPathExtension().appendingPathExtension("json")
            written += emitFaces(equirectURL: jpg, sidecarURL: sidecar,
                                 imagesDir: imagesDir, camerasDir: camerasDir,
                                 depthDir: mesh == nil ? nil : depthDir, depthMesh: mesh)
        }
        // emitFaces writes staging-relative image paths ("images/<name>") for the
        // EXPORT layout; the colorizer resolves image_path against rawDir, so rewrite
        // to rawDir-relative ("face_frames/images/<name>"). 360post7: without this,
        // every face frame failed its image load silently and the model colored gray.
        if let cams = try? fileManager.contentsOfDirectory(at: camerasDir, includingPropertiesForKeys: nil) {
            for cam in cams where cam.pathExtension == "json" {
                guard let data = try? Data(contentsOf: cam),
                      var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let imagePath = obj["image_path"] as? String,
                      imagePath.hasPrefix("images/") else { continue }
                obj["image_path"] = "face_frames/" + imagePath
                if let depthPath = obj["depth_path"] as? String, depthPath.hasPrefix("depth/") {
                    obj["depth_path"] = "face_frames/" + depthPath
                }
                if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
                    try? out.write(to: cam)
                }
            }
        }
        PerfDiag.log("[Colorize] face_frames regenerated: \(written) faces from \(jpgs.count) still(s)")
        // Stamp LAST, and only on a complete pass: a fingerprint written beside a partial
        // face set would make the next run trust the gap.
        if written == jpgs.count * faceCount, let stamp {
            try? stamp.write(to: stampURL, atomically: true, encoding: .utf8)
        }
        return written > 0 ? (camerasDir, imagesDir) : nil
    }

    /// Everything that changes what a generated face CONTAINS, hashed into one short string:
    /// per still its baked `cam_transform`, `elevation_offset_deg` and solver version, plus
    /// the face-size cap and the registration transform (which the depth raster is
    /// un-applied by). Nil when a still lacks a baked pose — that scan is not cacheable and
    /// should regenerate every time.
    private static func faceCacheFingerprint(jpgs: [URL], rawDataDir: URL) -> String? {
        // SHA256, not Hasher: Swift's Hasher is seeded per PROCESS, so its output would
        // differ across app launches and the cache would miss every cold start — the exact
        // case a field session hits most.
        var canonical = "v1|size=\(AppConstants.equirectFaceSizeMax)|faces=\(faceCount)"
        if let reg = SaveRegistration.loadSidecar(scanDirectory: rawDataDir.deletingLastPathComponent()),
           reg.applied, let transform = reg.transformMatrix {
            for column in 0..<4 {
                for row in 0..<4 { canonical += String(format: "|%.6f", transform[column][row]) }
            }
        }
        for jpg in jpgs {
            let sidecarURL = jpg.deletingPathExtension().appendingPathExtension("json")
            guard let data = try? Data(contentsOf: sidecarURL),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let cam = obj["cam_transform"] as? [Double], cam.count == 16 else { return nil }
            canonical += "|\(jpg.lastPathComponent)"
            for value in cam { canonical += String(format: ":%.6f", value) }
            canonical += String(format: "|e=%.4f", (obj["elevation_offset_deg"] as? Double) ?? 0)
            canonical += "|sv=\((obj["rig_calibration_solver_version"] as? Int) ?? 0)"
            canonical += "|src=\((obj["rig_calibration_source"] as? String) ?? "")"
        }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Entry

    /// Emit 5 face JPEGs + Polycam camera JSONs for one staged (privacy-processed) equirect.
    /// Returns the number of faces written; 0 on failure (the archived equirect still ships —
    /// faces are an additive convenience, so failure here is non-fatal and logged by caller).
    /// Poses come from the sidecar's capture-baked `cam_transform` (solved calibration or
    /// mechanical prior, composed at capture — where the profile↔camera serial binding is
    /// verified). A stored RigProfile is deliberately NOT applied here: export time cannot
    /// verify it belongs to the rig that captured a pre-contract still (review finding #9).
    /// `masksDir` receives one operator/rig mask per face when supplied — required for
    /// the down face to be usable downstream at all.
    /// `depthMesh` turns on OCCLUSION for the faces: without depth the colorizer paints
    /// every vertex in a face's cone, including surfaces behind walls, and that bleed is
    /// indistinguishable from pose error. See FaceDepthRender.
    static func emitFaces(equirectURL: URL, sidecarURL: URL,
                          imagesDir: URL, camerasDir: URL,
                          masksDir: URL? = nil,
                          equirectMask: OperatorRigMask.Mask? = nil,
                          depthDir: URL? = nil,
                          depthMesh: MeshParser.OBJData? = nil) -> Int {
        guard let sidecarData = try? Data(contentsOf: sidecarURL),
              let sidecar = (try? JSONSerialization.jsonObject(with: sidecarData)) as? [String: Any],
              let flat = sidecar["phone_transform"] as? [Double], flat.count == 16 else { return 0 }
        let stillSource = sidecar["still_source"] as? String
        let flatCam = sidecar["cam_transform"] as? [Double]
        let hasBakedPose = flatCam?.count == 16
        // "Solved" provenance is trusted only from the sidecar itself — stamped at capture,
        // when the active profile's camera serial was checked against the connected camera.
        let solvedPose = hasBakedPose
            && ((sidecar["rig_calibration_source"] as? String)?.hasPrefix("solved") ?? false)
        var poseSource: String
        switch levelingSupport(forModel: stillSource) {
        case .validated:
            poseSource = solvedPose ? "rig_calibrated" : "rig_prior"
        case .assumedLevel:
            poseSource = solvedPose ? "rig_calibrated_unvalidated_leveling" : "rig_prior_unvalidated_leveling"
            print("[prepareExport] ⚠️ \(equirectURL.lastPathComponent): \(stillSource ?? "?") leveling "
                + "not yet device-validated — faces emitted with pose source '\(poseSource)'")
        case .unsupported:
            print("[prepareExport] ⚠️ \(equirectURL.lastPathComponent): '\(stillSource ?? "unknown")' has no "
                + "validated zenith/leveling behavior — pose-bearing cube faces NOT emitted for this "
                + "camera yet (the archived equirect still ships; gyro-metadata compensation is a future feature)")
            return 0
        }
        let bitmap: Bitmap? = PerfDiag.timed("cf_decode") { decodeBitmap(from: equirectURL) }
        guard let bitmap else { return 0 }

        let phoneToWorld = matrixFromColumnMajor(flat.map(Float.init))

        // The 360° camera pose: capture-baked cam_transform, else the mechanical prior.
        let camTransform: simd_float4x4
        if hasBakedPose, let flatCam {
            camTransform = matrixFromColumnMajor(flatCam.map(Float.init))
        } else {
            // Pre-contract sidecar (no baked pose): mechanical prior only — nothing ties a
            // stored solved profile to the rig that actually shot this still.
            print("[prepareExport] \(equirectURL.lastPathComponent): no baked cam_transform (pre-contract still) — mechanical-prior pose")
            camTransform = RigModel.composeRigTransform(
                phoneToWorld: phoneToWorld,
                offsetPhone: RigProfile.mechanicalPrior.offsetPhone,
                yaw: AppConstants.rigYawOffsetDegrees * .pi / 180
            )
        }
        let camRot = simd_float3x3(columns: (
            SIMD3<Float>(camTransform.columns.0.x, camTransform.columns.0.y, camTransform.columns.0.z),
            SIMD3<Float>(camTransform.columns.1.x, camTransform.columns.1.y, camTransform.columns.1.z),
            SIMD3<Float>(camTransform.columns.2.x, camTransform.columns.2.y, camTransform.columns.2.z)
        ))
        let camPos = SIMD3<Float>(camTransform.columns.3.x,
                                  camTransform.columns.3.y,
                                  camTransform.columns.3.z)

        let faceSize = min(AppConstants.equirectFaceSizeMax, bitmap.width / 4)
        guard faceSize >= 256 else { return 0 }
        let baseName = equirectURL.deletingPathExtension().lastPathComponent

        // Elevation-registration nuisance solved per scan and stamped by
        // EquirectPostCalibration: image content sits `elevation_offset_deg` LOWER than
        // geometry predicts, so face sampling shifts down by it — face pixels then land
        // where the POSE says they should (≈3° ≈ 10 cm at 2 m otherwise; visible both in
        // the colorize probe and in downstream registration).
        let elevOffsetFrac = Float((sidecar["elevation_offset_deg"] as? Double) ?? 0) / 180

        // Upload bitmap to GPU texture once; reused for all 5 face dispatches.
        let gpuTexture = EquirectGPU.isAvailable
            ? (bitmap.buffer.flatMap {
                // Zero-copy view of the memory the decode already wrote into.
                EquirectGPU.makeTexture(from: $0, width: bitmap.width, height: bitmap.height,
                                        bytesPerRow: bitmap.bytesPerRow)
               } ?? bitmap.array.flatMap {
                EquirectGPU.makeTexture(from: $0, width: bitmap.width, height: bitmap.height)
               })
            : nil

        var written = 0
        for face in faces {
            autoreleasepool {
                let jpeg: Data?
                if let gpuTexture {
                    jpeg = PerfDiag.timed("cf_reproject_gpu") {
                        EquirectGPU.renderFace(from: gpuTexture,
                                              rotation: face.rotation,
                                              faceSize: faceSize,
                                              vOffsetFrac: elevOffsetFrac)
                    }
                } else {
                    jpeg = PerfDiag.timed("cf_reproject_cpu") {
                        renderFace(face.rotation, from: bitmap, side: faceSize,
                                   vOffsetFrac: elevOffsetFrac)
                    }
                }
                guard let jpeg else {
                    return
                }
                let imageName = "\(baseName)_\(face.name).jpg"
                do {
                    try jpeg.write(to: imagesDir.appendingPathComponent(imageName), options: .atomic)
                } catch {
                    return
                }
                writeFaceMask(equirectMask, into: masksDir, face: face, baseName: baseName,
                              faceSize: faceSize, vOffsetFrac: elevOffsetFrac)
                let depthPath = writeFaceDepth(mesh: depthMesh, into: depthDir,
                                               camRot: camRot, camPos: camPos, face: face,
                                               baseName: baseName, faceSize: faceSize)
                writeCameraJSON(FaceCameraRecord(
                    name: "\(baseName)_\(face.name)",
                    imagePath: "images/\(imageName)",
                    depthPath: depthPath,
                    rotation: simd_mul(camRot, face.rotation),
                    position: camPos,
                    side: faceSize,
                    faceName: face.name,
                    stillSource: stillSource,
                    poseSource: poseSource), to: camerasDir)
                written += 1
            }
        }
        return written
    }

    // NOTE: rigCameraRotation (mechanical-prior pose composition) has been superseded by
    // RigModel.composeRigTransform, which handles both the mechanical prior
    // and solved calibration paths. See docs/design/still-source-360.md (Calibration).

    private static func yawRotation(_ angle: Float) -> simd_float3x3 {
        simd_float3x3(simd_quatf(angle: angle, axis: SIMD3<Float>(0, 1, 0)))
    }

    private static func pitchRotation(_ angle: Float) -> simd_float3x3 {
        simd_float3x3(simd_quatf(angle: angle, axis: SIMD3<Float>(1, 0, 0)))
    }

    private static func matrixFromColumnMajor(_ flat: [Float]) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(flat[0], flat[1], flat[2], flat[3]),
            SIMD4<Float>(flat[4], flat[5], flat[6], flat[7]),
            SIMD4<Float>(flat[8], flat[9], flat[10], flat[11]),
            SIMD4<Float>(flat[12], flat[13], flat[14], flat[15])
        ))
    }

    // MARK: - Camera JSON (Polycam shape — mirrors FrameCaptureSession.writePolycamCameras)

    private struct FaceCameraRecord {
        let name: String
        let imagePath: String
        let depthPath: String?
        let rotation: simd_float3x3
        let position: SIMD3<Float>
        let side: Int
        let faceName: String
        let stillSource: String?
        let poseSource: String
    }

    private static func writeCameraJSON(_ rec: FaceCameraRecord, to camerasDir: URL) {
        let rotation = rec.rotation
        let position = rec.position
        let half = Double(rec.side) / 2
        var json: [String: Any] = [
            "t_00": rotation.columns.0.x, "t_01": rotation.columns.1.x, "t_02": rotation.columns.2.x, "t_03": position.x,
            "t_10": rotation.columns.0.y, "t_11": rotation.columns.1.y, "t_12": rotation.columns.2.y, "t_13": position.y,
            "t_20": rotation.columns.0.z, "t_21": rotation.columns.1.z, "t_22": rotation.columns.2.z, "t_23": position.z,
            "fx": half, "fy": half, "cx": half, "cy": half,
            "width": rec.side, "height": rec.side,
            "blur_score": 1.0,
            "image_path": rec.imagePath,
            "is_keyframe": true,
            "face": rec.faceName,
            "camera_pose_source": rec.poseSource
        ]
        if let depthPath = rec.depthPath { json["depth_path"] = depthPath }
        if let stillSource = rec.stillSource { json["still_source"] = stillSource }
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: camerasDir.appendingPathComponent("\(rec.name).json"), options: .atomic)
    }

    // MARK: - Sampling (gnomonic; sibling of EquirectPrivacyBlur's detection-res sampler)

    /// A decoded equirect, held ONCE.
    ///
    /// This used to be a Swift `[UInt8]` that was then uploaded into a `.shared` MTLTexture
    /// via `replace(withBytes:)` — two full-size allocations of the same image, both alive
    /// for the whole six-face loop. At the 8192-wide decode cap that is 134 MB each, so
    /// steady state was ~268 MB per still, and the repo already records an OOM kill on this
    /// path (iPhone 17 Pro, 2026-07-23).
    ///
    /// Now the CGContext draws STRAIGHT into GPU-visible memory: one `MTLBuffer`, wrapped
    /// zero-copy as a texture for the GPU reproject and read directly by the CPU
    /// sampler. One allocation, one decode, no upload copy. Without Metal it falls back to
    /// a plain array, which is what the CPU-only path always used.
    private struct Bitmap {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        /// GPU-visible backing when Metal is available; the texture is a view of THIS.
        let buffer: MTLBuffer?
        /// CPU-only fallback storage.
        let array: [UInt8]?

        /// Base pointer for CPU sampling, whichever backing is in use.
        func withPixels<R>(_ body: (UnsafePointer<UInt8>) -> R) -> R? {
            if let buffer {
                return body(buffer.contents().assumingMemoryBound(to: UInt8.self))
            }
            guard let array else { return nil }
            return array.withUnsafeBufferPointer { body($0.baseAddress!) }
        }
    }

    /// Decode the staged equirect capped at `equirectFaceDecodeMax` wide — face resolution
    /// is width/4, so an 8K decode already saturates the 2048 face cap while bounding the
    /// transient bitmap (~8192×4096 RGBA ≈ 134 MB, inside the caller's per-still pool).
    private static func decodeBitmap(from url: URL) -> Bitmap? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: AppConstants.equirectFaceDecodeMax,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let width = cgImage.width
        let height = cgImage.height

        func draw(into base: UnsafeMutableRawPointer, bytesPerRow: Int) -> Bool {
            guard let ctx = CGContext(data: base, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        // Preferred path: decode straight into GPU-visible memory so the reproject needs no
        // upload copy. The row stride is padded to the device's linear-texture alignment —
        // required for a buffer-backed texture, and CGContext is happy with any stride.
        if let (buffer, bytesPerRow) = EquirectGPU.makeSharedBuffer(width: width, height: height),
           draw(into: buffer.contents(), bytesPerRow: bytesPerRow) {
            PerfDiag.log(String(format: "[Colorize] equirect decode: %dx%d into ONE %.0f MB shared buffer (was 2x, decode + upload copy)",
                                width, height, Double(bytesPerRow * height) / 1_048_576))
            return Bitmap(width: width, height: height, bytesPerRow: bytesPerRow,
                          buffer: buffer, array: nil)
        }

        // No Metal (or allocation refused): plain array, as the CPU-only path always used.
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return draw(into: base, bytesPerRow: bytesPerRow)
        }
        return rendered ? Bitmap(width: width, height: height, bytesPerRow: bytesPerRow,
                                 buffer: nil, array: pixels) : nil
    }

    /// Render one face by gnomonic sampling. The face's view direction is `rotation * -Z`,
    /// with the equirect's lon 0 (image center) at the camera frame's -Z — the same axes the
    /// face POSE uses, so imagery and pose stay consistent by construction.
    private static func renderFace(_ rotation: simd_float3x3, from bmp: Bitmap, side: Int,
                                   vOffsetFrac: Float = 0) -> Data? {
        var buf = [UInt8](repeating: 255, count: side * side * 4)
        // Resolve the source pointer ONCE: the sampler runs side² times (4.2M at a 2048
        // face), so re-deriving it per pixel would dwarf the sampling itself.
        let ok: Bool? = bmp.withPixels { pixels in
        for row in 0..<side {
            let ndcV = 1 - 2 * (Float(row) + 0.5) / Float(side)
            for col in 0..<side {
                let ndcU = 2 * (Float(col) + 0.5) / Float(side) - 1
                // Camera-space ray through the pixel (90° FOV pinhole). Pano semantics: the
                // equirect's image-right shows content to the camera's RIGHT of pano center,
                // so the lookup keys on the ray's yaw ψ = atan2(x, -z) (positive toward cam
                // +X) and pitch = asin(y). The sampler's lon 0 sits at +Z with lon =
                // atan2(dir.x, dir.z), so feeding dir = (x, y, -z) makes lon ≡ ψ exactly.
                let camRay = simd_normalize(rotation * SIMD3<Float>(ndcU, ndcV, -1))
                let dir = SIMD3<Float>(camRay.x, camRay.y, -camRay.z)
                let rgb = sample(bmp, pixels: pixels, dir: dir, vOffsetFrac: vOffsetFrac)
                let out = (row * side + col) * 4
                buf[out] = UInt8(max(0, min(255, rgb.x)))
                buf[out + 1] = UInt8(max(0, min(255, rgb.y)))
                buf[out + 2] = UInt8(max(0, min(255, rgb.z)))
            }
        }
        return true
        }
        guard ok == true else { return nil }
        let image: CGImage? = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
        guard let image else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.9)
    }

    /// Bilinear equirect sample; longitude wraps, latitude clamps. `dir` is in the equirect
    /// sampling frame (lon 0 = +Z, lat +90° = +Y) — same convention as EquirectPrivacyBlur.
    private static func sample(_ bmp: Bitmap, pixels: UnsafePointer<UInt8>, dir: SIMD3<Float>,
                               vOffsetFrac: Float = 0) -> SIMD3<Float> {
        let lat = asin(max(-1, min(1, dir.y)))
        let lon = atan2(dir.x, dir.z)
        let eqX = (lon + .pi) / (2 * .pi) * Float(bmp.width) - 0.5
        let eqY = (Float.pi / 2 - lat + vOffsetFrac * .pi) / .pi * Float(bmp.height) - 0.5
        let floorX = floor(eqX), floorY = floor(eqY)
        let wgtX = eqX - floorX, wgtY = eqY - floorY
        func texel(_ col: Int, _ row: Int) -> SIMD3<Float> {
            let wrapped = ((col % bmp.width) + bmp.width) % bmp.width
            let clamped = max(0, min(bmp.height - 1, row))
            let base = clamped * bmp.bytesPerRow + wrapped * 4
            return SIMD3(Float(pixels[base]), Float(pixels[base + 1]), Float(pixels[base + 2]))
        }
        let col0 = Int(floorX), row0 = Int(floorY)
        let top = simd_mix(texel(col0, row0), texel(col0 + 1, row0), SIMD3(repeating: wgtX))
        let bot = simd_mix(texel(col0, row0 + 1), texel(col0 + 1, row0 + 1), SIMD3(repeating: wgtX))
        return simd_mix(top, bot, SIMD3(repeating: wgtY))
    }
}

extension EquirectFaceExport {
    /// Ships the face's operator/rig mask WITH the face. A face without its mask is
    /// worse than no face — downstream would reconstruct the rig and the operator as
    /// scene content, which is exactly why the down face used to be discarded outright.
    /// Mask faces are coarse on purpose: they reject regions, they do not cut edges.
    fileprivate static func writeFaceMask(_ equirectMask: OperatorRigMask.Mask?, into masksDir: URL?,
                                          face: Face, baseName: String,
                                          faceSize: Int, vOffsetFrac: Float) {
        guard let equirectMask, let masksDir else { return }
        let side = max(128, faceSize / 4)
        let maskFace = OperatorRigMask.faceMask(from: equirectMask, rotation: face.rotation,
                                                side: side, vOffsetFrac: vOffsetFrac)
        guard let png = OperatorRigMask.encodePNG(maskFace) else { return }
        try? png.write(to: masksDir.appendingPathComponent("\(baseName)_\(face.name).png"),
                       options: .atomic)
    }
}

// MARK: - Face depth

extension EquirectFaceExport {
    /// Rasterises the mesh from one face's pose and writes it beside the face image.
    /// Returns the rawDir-relative path for the camera JSON, or nil when there is no mesh
    /// (occlusion then stays off, as before).
    fileprivate static func writeFaceDepth(mesh: MeshParser.OBJData?, into depthDir: URL?,
                                           camRot: simd_float3x3, camPos: SIMD3<Float>,
                                           face: Face, baseName: String,
                                           faceSize: Int) -> String? {
        guard let mesh, let depthDir else { return nil }
        let rotation = simd_mul(camRot, face.rotation)
        let pose = simd_float4x4(SIMD4<Float>(rotation.columns.0, 0),
                                 SIMD4<Float>(rotation.columns.1, 0),
                                 SIMD4<Float>(rotation.columns.2, 0),
                                 SIMD4<Float>(camPos, 1))
        let depth = FaceDepthRender.render(mesh: mesh, camToWorld: pose, side: faceSize)
        let name = "\(baseName)_\(face.name).png"
        guard let png = FaceDepthRender.encodePNG(depth, side: faceSize),
              (try? png.write(to: depthDir.appendingPathComponent(name), options: .atomic)) != nil
        else { return nil }
        return "depth/\(name)"
    }
}
