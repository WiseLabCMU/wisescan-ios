import Foundation
import SceneKit
import simd

// Capture-pose frustum markers for the single-scan mesh preview. Derived entirely from the
// saved poses (raw_data/transforms.json) — no capture-time cost. Stills (sharp keyframes) and
// motion (sweep) frames are built as two separate node groups so the three-tier
// KeyframeMarkerMode can show neither / stills / stills+motion. Extracted from MeshPreviewView
// to keep that file under the length limit.

/// The shared wire/fill/apex geometry set for one marker shape — reused across every wedge
/// with the same FOV and tier (see the cache in `buildKeyframeMarkerNodes`). Explicitly
/// nonisolated (the module defaults to MainActor): it is built and read on the background
/// preview-load queue.
private nonisolated struct FrustumGeometry {
    let wire: SCNGeometry
    let fill: SCNGeometry
    let apex: SCNBox
}

extension MeshPreviewView {

    /// Capture-pose marker groups, each a container node ready to attach (nil if empty).
    struct KeyframeMarkerNodes {
        let stills: SCNNode?
        let motion: SCNNode?
        let equirectFaces: SCNNode?
        var hasAny: Bool { stills != nil || motion != nil || equirectFaces != nil }
        var hasEquirects: Bool { equirectFaces != nil }
    }

    /// Attaches the marker groups to the mesh container, applies the mesh-centering offset
    /// (known only once the mesh node exists), sets initial visibility from the current mode,
    /// publishes `hasKeyframeMarkers`, and stores the container refs on the coordinator for
    /// later toggling. Main-thread (preview load); the groups themselves are built off-main.
    func attachKeyframeMarkers(
        _ nodes: KeyframeMarkerNodes, to container: SCNNode, coordinator: Coordinator, center: SCNVector3
    ) {
        hasKeyframeMarkers = nodes.hasAny
        hasEquirects = (nodes.equirectFaces != nil)
        let offset = SCNVector3(-center.x, -center.y, -center.z)
        if let stills = nodes.stills {
            stills.position = offset
            stills.isHidden = !keyframeMarkerMode.showStills
            container.addChildNode(stills)
            coordinator.keyframeStillsNode = stills
        }
        if let motion = nodes.motion {
            motion.position = offset
            motion.isHidden = !keyframeMarkerMode.showMotion
            container.addChildNode(motion)
            coordinator.keyframeMotionNode = motion
        }
        if let equirect = nodes.equirectFaces {
            equirect.position = offset
            equirect.isHidden = !keyframeMarkerMode.showEquirectFaces
            container.addChildNode(equirect)
            coordinator.equirectFacesNode = equirect
        }
    }

    /// Builds the still + motion frustum marker groups from the saved `transforms.json` poses.
    /// Stills are `is_keyframe` frames (cyan, full size); motion frames are the rest (amber,
    /// smaller). Each wedge carries its capture pose; the mesh-centering offset is applied at
    /// attach time. No capture-time cost — read from raw data already on disk, in the mesh's
    /// world frame. Runs OFF-main on the preview-load queue (detached SCNNode trees are legal
    /// to build on any thread): a long scan parses a multi-MB transforms.json and assembles
    /// hundreds of wedge nodes, which would be a visible hitch stacked onto the main-thread attach.
    nonisolated static func buildKeyframeMarkerNodes(scanDirectoryURL: URL?, rigProfile: RigProfile?) -> KeyframeMarkerNodes {
        guard let scanDir = scanDirectoryURL else { return KeyframeMarkerNodes(stills: nil, motion: nil, equirectFaces: nil) }
        let candidates = [
            scanDir.appendingPathComponent("raw_data").appendingPathComponent("transforms.json"),
            scanDir.appendingPathComponent("transforms.json")
        ]
        var root: [String: Any]?
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = dict
                break
            }
        }
        guard let root = root, let frames = root["frames"] as? [[String: Any]] else {
            return KeyframeMarkerNodes(stills: nil, motion: nil, equirectFaces: nil)
        }

        // Session-global intrinsics/dimensions (video stream); keyframes may override per-frame.
        let globalFL = (root["fl_x"] as? NSNumber)?.floatValue ?? 0
        let globalW = (root["w"] as? NSNumber)?.floatValue ?? 0

        var stillNodes: [SCNNode] = []
        var motionNodes: [SCNNode] = []
        // Frames overwhelmingly share intrinsics (per-session video format; stills one hi-res
        // format), so hundreds of wedges reuse 1-2 geometry sets instead of allocating three
        // SCNGeometries each.
        var geometryCache: [Int32: FrustumGeometry] = [:]
        // Era detection (#92): files written with `transform_layout` are row-major as the
        // Nerfstudio schema requires; files without it predate the fix and store the matrix
        // columns as the four arrays. Both eras exist on devices, so read either.
        let rowMajor = (root["transform_layout"] as? String) == "row-major"
        for frame in frames {
            guard let arrays = frame["transform_matrix"] as? [[NSNumber]], arrays.count == 4 else { continue }
            let pose: simd_float4x4
            if rowMajor {
                pose = simd_float4x4(rows: [
                    columnVector(arrays[0]), columnVector(arrays[1]), columnVector(arrays[2]), columnVector(arrays[3])
                ])
            } else {
                pose = simd_float4x4(
                    columnVector(arrays[0]), columnVector(arrays[1]), columnVector(arrays[2]), columnVector(arrays[3])
                )
            }
            let isStill = (frame["is_keyframe"] as? Bool) == true
            // Horizontal half-angle tangent from focal length: tan(hFov/2) = (imageWidth/2) / fx.
            // Keyframes may carry per-frame intrinsics; motion frames use the session globals.
            let focal = (frame["fl_x"] as? NSNumber)?.floatValue ?? globalFL
            let width = (frame["w"] as? NSNumber)?.floatValue ?? globalW
            let tanHalf = (focal > 0 && width > 0) ? (width * 0.5) / focal : 0.45
            let cacheKey = (Int32(tanHalf * 1000) << 1) | (isStill ? 1 : 0)
            let geometry: FrustumGeometry
            if let cached = geometryCache[cacheKey] {
                geometry = cached
            } else {
                geometry = makeFrustumGeometry(
                    tanHalfAngle: tanHalf,
                    color: isStill ? AppConstants.keyframeStillColor : AppConstants.keyframeMotionColor,
                    scale: isStill ? 1.0 : AppConstants.keyframeMotionScale
                )
                geometryCache[cacheKey] = geometry
            }
            let node = makeFrustumNode(geometry: geometry)
            node.simdTransform = pose
            if isStill { stillNodes.append(node) } else { motionNodes.append(node) }
        }

        // Build equirect face frustums from sidecar JSONs (pure pose math, no pixel data).
        let equirectNodes = buildEquirectFaceNodes(scanDirectoryURL: scanDir, rigProfile: rigProfile)

        return KeyframeMarkerNodes(
            stills: container(named: "keyframeStills", nodes: stillNodes),
            motion: container(named: "keyframeMotion", nodes: motionNodes),
            equirectFaces: equirectNodes
        )
    }

    /// Wraps marker nodes in a named container (nil if empty; positioned at attach time).
    /// Do NOT flattenedClone() the group: SceneKit merges by geometry object, and the wedges
    /// share cached geometry instances — flattening collapsed every wedge onto one transform
    /// (device-observed: exactly one still + one motion marker rendered per scan). Plain nodes
    /// sharing a geometry render correctly at each node's own transform.
    private nonisolated static func container(named name: String, nodes: [SCNNode]) -> SCNNode? {
        guard !nodes.isEmpty else { return nil }
        let node = SCNNode()
        node.name = name
        for child in nodes { node.addChildNode(child) }
        return node
    }

    /// Reconstructs one matrix column (SIMD4) from a JSON `[x, y, z, w]` array.
    private nonisolated static func columnVector(_ arr: [NSNumber]) -> SIMD4<Float> {
        guard arr.count == 4 else { return SIMD4<Float>(0, 0, 0, 0) }
        return SIMD4<Float>(arr[0].floatValue, arr[1].floatValue, arr[2].floatValue, arr[3].floatValue)
    }

    /// Builds the geometry set for a frustum marker in local space: apex at the origin opening
    /// along -Z (camera forward) to a rectangle at `keyframeFrustumDepth × scale`, plus a solid
    /// apex cube. The base is `~4:3` using the horizontal half-angle tangent.
    private nonisolated static func makeFrustumGeometry(
        tanHalfAngle: Float,
        color: SIMD4<Float>,
        scale: Float
    ) -> FrustumGeometry {
        let depth = AppConstants.keyframeFrustumDepth * scale
        let halfW = depth * tanHalfAngle
        let halfH = halfW * 0.75 // ~4:3 aspect
        let apex = SCNVector3(0, 0, 0)
        let corners = [
            SCNVector3(-halfW, -halfH, -depth), SCNVector3(halfW, -halfH, -depth),
            SCNVector3(halfW, halfH, -depth), SCNVector3(-halfW, halfH, -depth)
        ]
        let verts = [apex] + corners
        let uiColor = UIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1.0)

        // Wireframe: 4 apex→corner edges + 4 base-rectangle edges.
        let edges: [UInt32] = [0, 1, 0, 2, 0, 3, 0, 4, 1, 2, 2, 3, 3, 4, 4, 1]
        let wireSource = SCNGeometrySource(vertices: verts)
        let wireElement = SCNGeometryElement(
            data: Data(bytes: edges, count: edges.count * MemoryLayout<UInt32>.size),
            primitiveType: .line, primitiveCount: 8, bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let wireGeo = SCNGeometry(sources: [wireSource], elements: [wireElement])
        let wireMat = SCNMaterial()
        wireMat.lightingModel = .constant
        wireMat.diffuse.contents = uiColor
        wireMat.isDoubleSided = true
        wireGeo.materials = [wireMat]

        // Translucent side fill so orientation reads at a glance.
        let sideTris: [UInt32] = [0, 1, 2, 0, 2, 3, 0, 3, 4, 0, 4, 1]
        let fillSource = SCNGeometrySource(vertices: verts)
        let fillElement = SCNGeometryElement(
            data: Data(bytes: sideTris, count: sideTris.count * MemoryLayout<UInt32>.size),
            primitiveType: .triangles, primitiveCount: 4, bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let fillGeo = SCNGeometry(sources: [fillSource], elements: [fillElement])
        let fillMat = SCNMaterial()
        fillMat.lightingModel = .constant
        fillMat.diffuse.contents = uiColor.withAlphaComponent(0.18)
        fillMat.isDoubleSided = true
        fillMat.blendMode = .alpha
        fillGeo.materials = [fillMat]

        // Solid apex cube marking the exact capture position.
        let apexSize = CGFloat(AppConstants.keyframeApexSize * scale)
        let apexBox = SCNBox(width: apexSize, height: apexSize, length: apexSize, chamferRadius: 0)
        let apexMat = SCNMaterial()
        apexMat.lightingModel = .constant
        apexMat.diffuse.contents = uiColor
        apexBox.materials = [apexMat]

        return FrustumGeometry(wire: wireGeo, fill: fillGeo, apex: apexBox)
    }

    /// Assembles one marker node around a (shared) geometry set. Geometry lives on an inner node
    /// carrying the face rotation, so the caller can set the outer node's simdTransform = capture
    /// pose without clobbering the rotation. World placement is then pose × faceRotation ×
    /// geometry (identity faceRotation for a pinhole still; the 360° cube-face case
    /// passes one rotation per face).
    private nonisolated static func makeFrustumNode(
        geometry: FrustumGeometry,
        faceRotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    ) -> SCNNode {
        let inner = SCNNode()
        inner.addChildNode(SCNNode(geometry: geometry.wire))
        inner.addChildNode(SCNNode(geometry: geometry.fill))
        inner.addChildNode(SCNNode(geometry: geometry.apex))
        inner.simdOrientation = faceRotation
        let node = SCNNode()
        node.addChildNode(inner)
        return node
    }

    // MARK: - Equirect Face Frustums

    /// Shared geometry for the 360° still sphere marker.
    private nonisolated struct EquirectSphereGeometry {
        let sphere: SCNSphere
        let ring: SCNTorus
        let box: SCNBox
        let arrow: SCNCone
    }

    private nonisolated static func makeEquirectSphereGeometry() -> EquirectSphereGeometry {
        let radius = CGFloat(AppConstants.equirectMarkerRadius)
        let accent = AppConstants.equirectFrontColor
        let accentColor = UIColor(red: CGFloat(accent.x), green: CGFloat(accent.y),
                                  blue: CGFloat(accent.z), alpha: 1.0)

        let sphere = SCNSphere(radius: radius)
        sphere.segmentCount = 24
        let sphereMat = SCNMaterial()
        sphereMat.lightingModel = .constant
        sphereMat.diffuse.contents = UIColor.white
        sphereMat.transparency = 0.15
        sphereMat.isDoubleSided = true
        sphere.materials = [sphereMat]

        let solid = SCNMaterial()
        solid.lightingModel = .constant
        solid.diffuse.contents = accentColor

        let ring = SCNTorus(ringRadius: radius, pipeRadius: radius * 0.035)
        ring.materials = [solid]
        let box = SCNBox(width: 0.02, height: 0.02, length: 0.02, chamferRadius: 0)
        box.materials = [solid]
        let arrow = SCNCone(topRadius: 0, bottomRadius: radius * 0.18, height: radius * 0.5)
        arrow.materials = [solid]
        return EquirectSphereGeometry(sphere: sphere, ring: ring, box: box, arrow: arrow)
    }

    /// Assemble one marker node (geometry shared across stills; nodes own transforms).
    private nonisolated static func makeEquirectSphereNode(marker: EquirectSphereGeometry) -> SCNNode {
        let node = SCNNode()
        node.addChildNode(SCNNode(geometry: marker.sphere))
        node.addChildNode(SCNNode(geometry: marker.ring))       // equator rim (XZ plane)
        node.addChildNode(SCNNode(geometry: marker.box))        // origin cube

        // Forward arrow: cone apex pointing along −Z (camera forward = equirect front).
        // SCNCone points +Y; rotate −90° about X so +Y → −Z, park it just outside the rim.
        let arrowNode = SCNNode(geometry: marker.arrow)
        arrowNode.eulerAngles.x = -.pi / 2
        arrowNode.position = SCNVector3(0, 0, -Float(AppConstants.equirectMarkerRadius) * 1.3)
        node.addChildNode(arrowNode)
        return node
    }

    /// One sphere marker per 360° still: a translucent sphere (the full capture volume)
    /// with an equator rim ring, a small origin cube, and a forward arrow along the
    /// camera's −Z (the equirect's front/identity direction). Replaced the 5-frustum
    /// rendering, which was too busy to read at a glance. Poses come from the sidecar's
    /// baked `cam_transform` (Process-step calibration) or the prior. Runs off-main.
    private nonisolated static func buildEquirectFaceNodes(scanDirectoryURL: URL, rigProfile: RigProfile?) -> SCNNode? {
        let fileMgr = FileManager.default
        let equirectDir = scanDirectoryURL
            .appendingPathComponent("raw_data")
            .appendingPathComponent("equirect_stills")
        guard fileMgr.fileExists(atPath: equirectDir.path) else { return nil }

        let sidecars = ((try? fileMgr.contentsOfDirectory(at: equirectDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !sidecars.isEmpty else { return nil }

        // Shared marker geometry (one set across all stills).
        let marker = makeEquirectSphereGeometry()

        var allNodes: [SCNNode] = []
        for sidecarURL in sidecars {
            guard let data = try? Data(contentsOf: sidecarURL),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let flat = dict["phone_transform"] as? [Double], flat.count == 16
            else { continue }

            let phoneToWorld = simd_float4x4(columns: (
                SIMD4<Float>(Float(flat[0]), Float(flat[1]), Float(flat[2]), Float(flat[3])),
                SIMD4<Float>(Float(flat[4]), Float(flat[5]), Float(flat[6]), Float(flat[7])),
                SIMD4<Float>(Float(flat[8]), Float(flat[9]), Float(flat[10]), Float(flat[11])),
                SIMD4<Float>(Float(flat[12]), Float(flat[13]), Float(flat[14]), Float(flat[15]))
            ))

            let camTransform: simd_float4x4
            if let flatCam = dict["cam_transform"] as? [Double], flatCam.count == 16 {
                camTransform = simd_float4x4(columns: (
                    SIMD4<Float>(Float(flatCam[0]), Float(flatCam[1]), Float(flatCam[2]), Float(flatCam[3])),
                    SIMD4<Float>(Float(flatCam[4]), Float(flatCam[5]), Float(flatCam[6]), Float(flatCam[7])),
                    SIMD4<Float>(Float(flatCam[8]), Float(flatCam[9]), Float(flatCam[10]), Float(flatCam[11])),
                    SIMD4<Float>(Float(flatCam[12]), Float(flatCam[13]), Float(flatCam[14]), Float(flatCam[15]))
                ))
            } else if let profile = rigProfile, profile.isSolved {
                camTransform = RigModel.composeRigTransform(
                    phoneToWorld: phoneToWorld,
                    offsetPhone: profile.offsetPhone,
                    yaw: profile.yaw
                )
            } else {
                camTransform = RigModel.composeRigTransform(
                    phoneToWorld: phoneToWorld,
                    offsetPhone: RigProfile.mechanicalPrior.offsetPhone,
                    yaw: AppConstants.rigYawOffsetDegrees * .pi / 180
                )
            }

            let node = makeEquirectSphereNode(marker: marker)
            node.simdTransform = camTransform
            allNodes.append(node)
        }

        return container(named: "equirectFaces", nodes: allNodes)
    }
}
