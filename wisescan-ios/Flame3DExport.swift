import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

/// Builds the flame3d-core input bundle: the layout flame3d's `polycam` data source reads,
/// so a scan goes straight into flame3d (3D object segmentation + semantic search) with no
/// desktop conversion. The reference implementation and the contract are
/// `tools/scan4d-to-flame3d` (`scan4d_to_flame3d.py` and its README); keep the two in step.
///
///     keyframes/images/<stem>.jpg              one resolution for every frame
///     keyframes/corrected_cameras/<stem>.json  Polycam camera record, intrinsics at that size
///     keyframes/depth/<stem>.png               16-bit mm LiDAR depth, native raster
///     raw.glb                                  mesh.obj + captured vertex colors (COLOR_0)
///     mesh_info.json                           alignmentTransform = registration raw→canonical
///     scan4d/                                  registration.json, roomplan.json, export.json
///
/// Entries sit at the ZIP ROOT: flame3d extracts the upload as-is and expects `keyframes/`
/// directly inside, which is why this writes its own archive instead of the staging
/// directory zip (`NSFileCoordinator`'s puts the folder itself at the top).
///
/// Frames follow flame3d's assumptions: they form a video ordered by the stem's trailing
/// number, and every frame in a SAM3 run must share one resolution. So the stream frames and
/// hi-res stills (one `frame_NNNNN` sequence) are kept, stills resized to the stream size with
/// their intrinsics scaled; a still of another aspect, the 360° cube faces (`face` key, no
/// frame number), and stems without a unique frame number are left out.
enum Flame3DExport {

    /// `stagedDir` holds the Polycam payload after `stagePolycamPayload`, so its images and
    /// depth have already been through the export-time privacy passes. `scanDir` supplies the
    /// mesh, its colors and the registration. Writes the bundle to `zipURL`.
    static func build(stagedDir: URL, scanDir: URL, vertexColorsFromCapture: Bool,
                      zipURL: URL, phase: ((ExportPhase) -> Void)? = nil) -> Bool {
        let fm = FileManager.default
        let camerasDir = stagedDir.appendingPathComponent("cameras")
        guard let files = try? fm.contentsOfDirectory(at: camerasDir, includingPropertiesForKeys: nil) else {
            print("[flame3d] ✗ no cameras/ in staging")
            return false
        }
        let cameras = files.filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { Camera(url: $0, stagedDir: stagedDir) }
            .filter { !$0.isCubeFace }

        // The most common size is the video stream; anything else is a hi-res still.
        var sizeCounts: [Size: Int] = [:]
        for cam in cameras { sizeCounts[cam.size, default: 0] += 1 }
        guard let stream = sizeCounts.max(by: { $0.value < $1.value })?.key else {
            print("[flame3d] ✗ no usable cameras")
            return false
        }
        let scale = min(1, Double(AppConstants.flame3dMaxImageLongEdge) / Double(max(stream.width, stream.height)))
        let target = Size(width: max(1, Int((Double(stream.width) * scale).rounded())),
                          height: max(1, Int((Double(stream.height) * scale).rounded())))
        let targetAspect = Double(target.width) / Double(target.height)

        var frames: [Camera] = []
        var frameNumbers = Set<Int>()
        var dropped: [String: Int] = [:]
        for cam in cameras.sorted(by: { $0.stem < $1.stem }) {
            guard let number = cam.frameNumber, frameNumbers.insert(number).inserted else {
                dropped["no unique frame number", default: 0] += 1
                continue
            }
            guard fm.fileExists(atPath: cam.imageURL.path) else {
                dropped["image missing", default: 0] += 1
                continue
            }
            let aspect = Double(cam.size.width) / Double(cam.size.height)
            guard abs(aspect - targetAspect) <= AppConstants.flame3dAspectTolerance * targetAspect else {
                dropped["aspect differs from the stream", default: 0] += 1
                continue
            }
            frames.append(cam)
        }
        frames.sort { ($0.frameNumber ?? 0) < ($1.frameNumber ?? 0) }
        guard !frames.isEmpty else {
            print("[flame3d] ✗ no frames left to export")
            return false
        }

        // Every frame needs a depth PNG; a frame without LiDAR gets zeros at the LiDAR raster.
        let lidar = frames.lazy.compactMap { $0.depthURL.flatMap(pixelSize) }.first ?? target
        let emptyDepth = DepthPNG.encode([UInt16](repeating: 0, count: lidar.width * lidar.height),
                                         width: lidar.width, height: lidar.height)

        guard let zip = StoredZip(url: zipURL) else {
            print("[flame3d] ✗ cannot create \(zipURL.lastPathComponent)")
            return false
        }
        var kinds: [String: Int] = [:]
        for (index, cam) in frames.enumerated() {
            phase?(.counted("Flame3D frames", index + 1, of: frames.count))
            autoreleasepool {
                guard let jpeg = jpegData(for: cam, at: target),
                      let depth = cam.depthURL.flatMap({ try? Data(contentsOf: $0) }) ?? emptyDepth,
                      let record = try? JSONSerialization.data(
                          withJSONObject: cam.record(at: target, stream: stream),
                          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
                    zip.fail("frame \(cam.stem)")
                    return
                }
                zip.add("keyframes/images/\(cam.stem).jpg", jpeg)
                zip.add("keyframes/corrected_cameras/\(cam.stem).json", record)
                zip.add("keyframes/depth/\(cam.stem).png", depth)
                kinds[cam.size == stream ? "stream" : "still", default: 0] += 1
            }
        }

        phase?(ExportPhase("Mesh…"))
        guard let objData = try? Data(contentsOf: scanDir.appendingPathComponent("mesh.obj")),
              let mesh = MeshParser.parseOBJ(from: objData) else {
            print("[flame3d] ✗ mesh.obj missing or unreadable")
            zip.fail("mesh")
            _ = zip.finish()
            return false
        }
        let colors = vertexColorsFromCapture
            ? capturedLinearColors(scanDir: scanDir, vertexCount: mesh.vertices.count) : nil
        zip.add("raw.glb", glb(vertices: mesh.vertices, faces: mesh.faces, linearColors: colors))

        let registration = SaveRegistration.loadSidecar(scanDirectory: scanDir)
        let alignment: [Float] = {
            if let reg = registration, reg.applied, let t = reg.transform, t.count == 16 { return t }
            return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        }()
        let meshInfo: [String: Any] = [
            "alignmentTransform": alignment,          // column-major, as Polycam and flame3d read it
            "num_frames": frames.count,
            "image_width": target.width,
            "image_height": target.height,
            "coordinate_system": "arkit"
        ]
        if let data = try? JSONSerialization.data(withJSONObject: meshInfo, options: [.prettyPrinted, .sortedKeys]) {
            zip.add("mesh_info.json", data)
        }

        for name in ["registration.json", "roomplan.json"] {
            let candidates = [scanDir.appendingPathComponent(name),
                              scanDir.appendingPathComponent("raw_data").appendingPathComponent(name)]
            if let url = candidates.first(where: { fm.fileExists(atPath: $0.path) }),
               let data = try? Data(contentsOf: url) {
                zip.add("scan4d/\(name)", data)
            }
        }
        let summary: [String: Any] = [
            "exporter": "scan4d-ios",
            "image_size": [target.width, target.height],
            "frames_out": kinds,
            "frames_dropped": dropped,
            "vertex_colors": colors != nil ? "captured" : "none",
            "alignment_applied": registration?.applied ?? false
        ]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            zip.add("scan4d/export.json", data)
        }

        let ok = zip.finish()
        print("[flame3d] \(ok ? "✓" : "✗") \(frames.count) frames at \(target.width)x\(target.height) "
              + "\(kinds), dropped \(dropped), colors=\(colors != nil)")
        return ok
    }

    // MARK: - Frames

    private struct Size: Hashable {
        let width: Int
        let height: Int
    }

    /// One `cameras/<stem>.json` record from the staged Polycam payload.
    private struct Camera {
        let stem: String
        let json: [String: Any]
        let size: Size
        let imageURL: URL
        let depthURL: URL?

        init?(url: URL, stagedDir: URL) {
            guard let data = try? Data(contentsOf: url),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let width = (json["width"] as? NSNumber)?.intValue,
                  let height = (json["height"] as? NSNumber)?.intValue,
                  width > 0, height > 0,
                  ["fx", "fy", "cx", "cy"].allSatisfy({ json[$0] is NSNumber }),
                  (0..<3).allSatisfy({ r in (0..<4).allSatisfy({ json["t_\(r)\($0)"] is NSNumber }) })
            else { return nil }
            let stem = url.deletingPathExtension().lastPathComponent
            self.stem = stem
            self.json = json
            size = Size(width: width, height: height)
            imageURL = stagedDir.appendingPathComponent((json["image_path"] as? String) ?? "images/\(stem).jpg")
            let depth = (json["depth_path"] as? String).map { stagedDir.appendingPathComponent($0) }
            depthURL = depth.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        }

        var isCubeFace: Bool { json["face"] != nil }

        /// flame3d orders frames by the stem's trailing number and keys them by it.
        var frameNumber: Int? {
            let digits = String(stem.reversed().prefix(while: { $0.isASCII && $0.isNumber }).reversed())
            return digits.isEmpty ? nil : Int(digits)
        }

        /// The Polycam camera record flame3d reads: camera-to-world rows (ARKit raw frame,
        /// OpenGL axes, passed through) and intrinsics scaled to the exported image size.
        func record(at target: Size, stream: Size) -> [String: Any] {
            let sx = Double(target.width) / Double(size.width)
            let sy = Double(target.height) / Double(size.height)
            func number(_ key: String) -> Double { (json[key] as? NSNumber)?.doubleValue ?? 0 }
            var out: [String: Any] = [:]
            for r in 0..<3 {
                for c in 0..<4 { out["t_\(r)\(c)"] = number("t_\(r)\(c)") }
            }
            out["fx"] = number("fx") * sx
            out["fy"] = number("fy") * sy
            out["cx"] = number("cx") * sx
            out["cy"] = number("cy") * sy
            out["width"] = target.width
            out["height"] = target.height
            out["blur_score"] = 1.0
            out["scan4d_kind"] = size == stream ? "stream" : "still"
            out["scan4d_source_size"] = [size.width, size.height]
            for key in ["is_keyframe", "sharpness", "still_source", "camera_pose_source"] {
                if let value = json[key] { out[key] = value }
            }
            return out
        }
    }

    private static func pixelSize(_ url: URL) -> Size? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else { return nil }
        return Size(width: width, height: height)
    }

    /// JPEG at `target`, in the stored pixel layout the intrinsics describe. A frame already at
    /// that size with no EXIF rotation ships byte-for-byte; anything else (the 12 MP stills) is
    /// decoded, scaled and re-encoded without an orientation tag, which would otherwise make
    /// flame3d's cv2.imread rotate the pixels away from the intrinsics.
    private static func jpegData(for cam: Camera, at target: Size) -> Data? {
        guard let source = CGImageSourceCreateWithURL(cam.imageURL as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if cam.size == target, orientation == 1 {
            return try? Data(contentsOf: cam.imageURL)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target.width, target.height),
            kCGImageSourceCreateThumbnailWithTransform: false
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        var image = decoded
        if decoded.width != target.width || decoded.height != target.height {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: target.width, height: target.height,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(decoded, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
            guard let scaled = context.makeImage() else { return nil }
            image = scaled
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image,
                                   [kCGImageDestinationLossyCompressionQuality: AppConstants.flame3dJPEGQuality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    // MARK: - Mesh

    /// colors.bin (sRGB RGBA per vertex) as linear RGB, which glTF's COLOR_0 requires. Only
    /// called for captured colors; nil when the count doesn't match the mesh (another mesh's).
    private static func capturedLinearColors(scanDir: URL, vertexCount: Int) -> [SIMD3<Float>]? {
        guard let data = try? Data(contentsOf: scanDir.appendingPathComponent("colors.bin")),
              data.count == vertexCount * MemoryLayout<SIMD4<Float>>.stride else {
            print("[flame3d] colors.bin missing or not one color per vertex — mesh without colors")
            return nil
        }
        func linear(_ c: Float) -> Float {
            let v = min(max(c, 0), 1)
            return v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
        }
        return data.withUnsafeBytes { raw in
            raw.bindMemory(to: SIMD4<Float>.self).map { SIMD3(linear($0.x), linear($0.y), linear($0.z)) }
        }
    }

    /// Binary glTF: one triangle primitive with POSITION, optional COLOR_0 and uint32 indices,
    /// no material (flame3d's viewer turns vertex colors on when COLOR_0 is present). glTF is
    /// Y-up, as ARKit is, so the canonical-frame vertices are written as they are. Matches
    /// `glb_bytes()` in the converter. Little-endian host (arm64) assumed for the buffers.
    static func glb(vertices: [SIMD3<Float>], faces: [(UInt32, UInt32, UInt32)],
                    linearColors: [SIMD3<Float>]?) -> Data {
        var positions = [Float](); positions.reserveCapacity(vertices.count * 3)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for v in vertices {
            positions += [v.x, v.y, v.z]
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        var indices = [UInt32](); indices.reserveCapacity(faces.count * 3)
        for f in faces { indices += [f.0, f.1, f.2] }

        var binary = Data()
        var views: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var attributes: [String: Int] = [:]
        func addView(_ bytes: Data, target: Int) -> Int {
            views.append(["buffer": 0, "byteOffset": binary.count, "byteLength": bytes.count, "target": target])
            binary.append(bytes)                       // 4-byte elements keep every offset aligned
            return views.count - 1
        }
        let arrayBuffer = 34962, elementArrayBuffer = 34963
        let float32 = 5126, uint32 = 5125
        attributes["POSITION"] = accessors.count
        accessors.append(["bufferView": addView(positions.withUnsafeBufferPointer { Data(buffer: $0) }, target: arrayBuffer),
                          "componentType": float32, "count": vertices.count, "type": "VEC3",
                          "min": [lo.x, lo.y, lo.z], "max": [hi.x, hi.y, hi.z]])
        if let colors = linearColors, colors.count == vertices.count {
            let flat = colors.flatMap { [$0.x, $0.y, $0.z] }
            attributes["COLOR_0"] = accessors.count
            accessors.append(["bufferView": addView(flat.withUnsafeBufferPointer { Data(buffer: $0) }, target: arrayBuffer),
                              "componentType": float32, "count": colors.count, "type": "VEC3"])
        }
        let indexAccessor = accessors.count
        accessors.append(["bufferView": addView(indices.withUnsafeBufferPointer { Data(buffer: $0) }, target: elementArrayBuffer),
                          "componentType": uint32, "count": indices.count, "type": "SCALAR"])

        let node: [String: Any] = ["mesh": 0, "name": "scan4d_mesh"]
        let primitive: [String: Any] = ["attributes": attributes, "indices": indexAccessor, "mode": 4]
        let gltf: [String: Any] = [
            "asset": ["version": "2.0", "generator": "scan4d-ios Flame3DExport"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [node],
            "meshes": [["primitives": [primitive]]],
            "buffers": [["byteLength": binary.count]],
            "bufferViews": views,
            "accessors": accessors
        ]
        var json = (try? JSONSerialization.data(withJSONObject: gltf)) ?? Data()
        json.append(contentsOf: [UInt8](repeating: 0x20, count: (4 - json.count % 4) % 4))
        binary.append(contentsOf: [UInt8](repeating: 0, count: (4 - binary.count % 4) % 4))

        var out = Data()
        out.appendLE(UInt32(0x4654_6C67))              // "glTF"
        out.appendLE(UInt32(2))
        out.appendLE(UInt32(12 + 8 + json.count + 8 + binary.count))
        out.appendLE(UInt32(json.count)); out.appendLE(UInt32(0x4E4F_534A))   // "JSON"
        out.append(json)
        out.appendLE(UInt32(binary.count)); out.appendLE(UInt32(0x004E_4942)) // "BIN\0"
        out.append(binary)
        return out
    }
}

// MARK: - ZIP (stored)

/// A store-only ZIP writer: entries uncompressed (the frames are JPEG and PNG already) and at
/// the archive root. No ZIP64, so the archive and every entry must stay under 4 GiB and the
/// entry count under 65 535; past that it fails rather than writing a broken archive.
private final class StoredZip {
    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var central = Data()
    private var entries = 0
    private var failure: String?

    private static let localHeader: UInt32 = 0x0403_4b50
    private static let centralHeader: UInt32 = 0x0201_4b50
    private static let endOfCentral: UInt32 = 0x0605_4b50
    private static let version: UInt16 = 20
    private static let utf8Names: UInt16 = 0x0800
    private static let dosDate1980: UInt16 = 0x0021  // 1980-01-01, 00:00

    init?(url: URL) {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
    }

    func fail(_ reason: String) {
        if failure == nil { failure = reason }
    }

    func add(_ name: String, _ data: Data) {
        guard failure == nil else { return }
        let nameBytes = Data(name.utf8)
        let crc = CRC32.checksum(data)
        let headerSize = 30 + nameBytes.count
        guard offset + UInt64(headerSize + data.count) < UInt64(UInt32.max) else {
            fail("archive over 4 GiB at \(name)")
            return
        }
        var header = Data(capacity: headerSize)
        header.appendLE(Self.localHeader)
        header.appendLE(Self.version)
        header.appendLE(Self.utf8Names)
        header.appendLE(UInt16(0))                       // stored
        header.appendLE(UInt16(0))                       // time
        header.appendLE(Self.dosDate1980)
        header.appendLE(crc)
        header.appendLE(UInt32(data.count))
        header.appendLE(UInt32(data.count))
        header.appendLE(UInt16(nameBytes.count))
        header.appendLE(UInt16(0))                       // extra
        header.append(nameBytes)
        do {
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: data)
        } catch {
            fail("write \(name): \(error.localizedDescription)")
            return
        }

        central.appendLE(Self.centralHeader)
        central.appendLE(Self.version)                   // made by
        central.appendLE(Self.version)                   // needed
        central.appendLE(Self.utf8Names)
        central.appendLE(UInt16(0))                      // stored
        central.appendLE(UInt16(0))
        central.appendLE(Self.dosDate1980)
        central.appendLE(crc)
        central.appendLE(UInt32(data.count))
        central.appendLE(UInt32(data.count))
        central.appendLE(UInt16(nameBytes.count))
        central.appendLE(UInt16(0))                      // extra
        central.appendLE(UInt16(0))                      // comment
        central.appendLE(UInt16(0))                      // disk
        central.appendLE(UInt16(0))                      // internal attributes
        central.appendLE(UInt32(0))                      // external attributes
        central.appendLE(UInt32(offset))
        central.append(nameBytes)
        offset += UInt64(headerSize + data.count)
        entries += 1
    }

    /// Writes the central directory. False if any entry failed or a limit was exceeded.
    func finish() -> Bool {
        defer { try? handle.close() }
        if entries >= Int(UInt16.max) { fail("\(entries) entries") }
        if offset + UInt64(central.count) >= UInt64(UInt32.max) { fail("archive over 4 GiB") }
        if let failure {
            print("[flame3d] ✗ zip: \(failure)")
            return false
        }
        var end = Data()
        end.appendLE(Self.endOfCentral)
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(entries))
        end.appendLE(UInt16(entries))
        end.appendLE(UInt32(central.count))
        end.appendLE(UInt32(offset))
        end.appendLE(UInt16(0))
        do {
            try handle.write(contentsOf: central)
            try handle.write(contentsOf: end)
            return true
        } catch {
            print("[flame3d] ✗ zip: \(error.localizedDescription)")
            return false
        }
    }
}

private enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        table.withUnsafeBufferPointer { t in
            data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for byte in bytes { crc = t[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
