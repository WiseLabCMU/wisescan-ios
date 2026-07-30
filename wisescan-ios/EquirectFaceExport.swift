import CoreGraphics
import ImageIO
import UIKit
import simd

/// Cube-face export for equirectangular 360° stills (docs/design/still-source-360.md →
/// "Export: cube map, bottom face discarded"): each staged still reprojects into **5
/// synthetic pinhole faces** — front/right/back/left/up; the bottom face is dominated by
/// the operator, grip, and rod and is dropped by construction — emitted as ordinary
/// keyframe images + Polycam camera JSONs, so the equirectangular camera model disappears
/// from the data contract entirely. Each face is an exact 90° FOV pinhole:
/// `fx = fy = cx = cy = faceSize / 2`.
///
/// Pose = the **mechanical-prior rig extrinsic** (calibration plan step 1): ARKit is
/// gravity-aligned and Theta zenith correction keeps the equirect level, so the prior only
/// needs position + yaw — the camera sits `AppConstants.rigRodHeightMeters` above the phone
/// along WORLD up, facing the phone's horizontal forward rotated by
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
    /// - `.validated` — leveling confirmed on device (Theta X).
    /// - `.assumedLevel` — the hardware levels (Theta Z1 zenith correction) but we have not
    ///   validated its OSC-configured behavior; faces emit with a marked pose source.
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
        if model.contains("THETA Z1") { return .assumedLevel }
        return .unsupported
    }

    /// One emitted cube face: name suffix + its rotation FROM the rig camera frame.
    private struct Face {
        let name: String
        let rotation: simd_float3x3
    }

    /// Cam-space rotations (OpenGL/ARKit camera convention: +X right, +Y up, -Z forward).
    /// Derivation: view direction is -Z rotated by `rotation`; right face looks along +X
    /// (yaw -90°), left along -X (yaw +90°), back along +Z (yaw 180°), up along +Y
    /// (pitch +90°). Pixel content must agree: the sampler's face bases below use the same
    /// axes, so face imagery and face pose rotate together.
    private static let faces: [Face] = [
        Face(name: "front", rotation: matrix_identity_float3x3),
        Face(name: "right", rotation: yawRotation(-.pi / 2)),
        Face(name: "back", rotation: yawRotation(.pi)),
        Face(name: "left", rotation: yawRotation(.pi / 2)),
        Face(name: "up", rotation: pitchRotation(.pi / 2))
    ]

    // MARK: - Entry

    /// Emit 5 face JPEGs + Polycam camera JSONs for one staged (privacy-processed) equirect.
    /// Returns the number of faces written; 0 on failure (the archived equirect still ships —
    /// faces are an additive convenience, so failure here is non-fatal and logged by caller).
    /// Poses come from the sidecar's capture-baked `cam_transform` (solved calibration or
    /// mechanical prior, composed at capture — where the profile↔camera serial binding is
    /// verified). A stored RigProfile is deliberately NOT applied here: export time cannot
    /// verify it belongs to the rig that captured a pre-contract still (review finding #9).
    static func emitFaces(equirectURL: URL, sidecarURL: URL,
                          imagesDir: URL, camerasDir: URL) -> Int {
        guard let sidecarData = try? Data(contentsOf: sidecarURL),
              let sidecar = (try? JSONSerialization.jsonObject(with: sidecarData)) as? [String: Any],
              let flat = sidecar["phone_transform"] as? [Double], flat.count == 16 else { return 0 }
        let stillSource = sidecar["still_source"] as? String
        let flatCam = sidecar["cam_transform"] as? [Double]
        let hasBakedPose = flatCam?.count == 16
        // "Solved" provenance is trusted only from the sidecar itself — stamped at capture,
        // when the active profile's camera serial was checked against the connected camera.
        let solvedPose = hasBakedPose && (sidecar["rig_calibration_source"] as? String) == "solved"
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
            camTransform = RigCalibrationSolver.composeRigTransform(
                phoneToWorld: phoneToWorld,
                dy: AppConstants.rigRodHeightMeters, dLateral: 0,
                yaw: AppConstants.rigYawOffsetDegrees * .pi / 180, pitchResidual: 0
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

        // Upload bitmap to GPU texture once; reused for all 5 face dispatches.
        let gpuTexture = EquirectGPU.isAvailable
            ? EquirectGPU.makeTexture(from: bitmap.pixels, width: bitmap.width, height: bitmap.height)
            : nil

        var written = 0
        for face in faces {
            autoreleasepool {
                let jpeg: Data?
                if let gpuTexture {
                    jpeg = PerfDiag.timed("cf_reproject_gpu") {
                        EquirectGPU.renderFace(from: gpuTexture,
                                              rotation: face.rotation,
                                              faceSize: faceSize)
                    }
                } else {
                    jpeg = PerfDiag.timed("cf_reproject_cpu") { renderFace(face.rotation, from: bitmap, side: faceSize) }
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
                writeCameraJSON(FaceCameraRecord(
                    name: "\(baseName)_\(face.name)",
                    imagePath: "images/\(imageName)",
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
    // RigCalibrationSolver.composeRigTransform, which handles both the mechanical prior
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
        if let stillSource = rec.stillSource { json["still_source"] = stillSource }
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: camerasDir.appendingPathComponent("\(rec.name).json"), options: .atomic)
    }

    // MARK: - Sampling (gnomonic; sibling of EquirectPrivacyBlur's detection-res sampler)

    private struct Bitmap {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let bytesPerRow: Int
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
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? Bitmap(pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow) : nil
    }

    /// Render one face by gnomonic sampling. The face's view direction is `rotation * -Z`,
    /// with the equirect's lon 0 (image center) at the camera frame's -Z — the same axes the
    /// face POSE uses, so imagery and pose stay consistent by construction.
    private static func renderFace(_ rotation: simd_float3x3, from bmp: Bitmap, side: Int) -> Data? {
        var buf = [UInt8](repeating: 255, count: side * side * 4)
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
                let rgb = sample(bmp, dir: dir)
                let out = (row * side + col) * 4
                buf[out] = UInt8(max(0, min(255, rgb.x)))
                buf[out + 1] = UInt8(max(0, min(255, rgb.y)))
                buf[out + 2] = UInt8(max(0, min(255, rgb.z)))
            }
        }
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
    private static func sample(_ bmp: Bitmap, dir: SIMD3<Float>) -> SIMD3<Float> {
        let lat = asin(max(-1, min(1, dir.y)))
        let lon = atan2(dir.x, dir.z)
        let eqX = (lon + .pi) / (2 * .pi) * Float(bmp.width) - 0.5
        let eqY = (Float.pi / 2 - lat) / .pi * Float(bmp.height) - 0.5
        let floorX = floor(eqX), floorY = floor(eqY)
        let wgtX = eqX - floorX, wgtY = eqY - floorY
        func texel(_ col: Int, _ row: Int) -> SIMD3<Float> {
            let wrapped = ((col % bmp.width) + bmp.width) % bmp.width
            let clamped = max(0, min(bmp.height - 1, row))
            let base = clamped * bmp.bytesPerRow + wrapped * 4
            return SIMD3(Float(bmp.pixels[base]), Float(bmp.pixels[base + 1]), Float(bmp.pixels[base + 2]))
        }
        let col0 = Int(floorX), row0 = Int(floorY)
        let top = simd_mix(texel(col0, row0), texel(col0 + 1, row0), SIMD3(repeating: wgtX))
        let bot = simd_mix(texel(col0, row0 + 1), texel(col0 + 1, row0 + 1), SIMD3(repeating: wgtX))
        return simd_mix(top, bot, SIMD3(repeating: wgtY))
    }
}
