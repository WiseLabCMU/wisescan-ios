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
    nonisolated static func buildKeyframeMarkerNodes(scanDirectoryURL: URL?) -> KeyframeMarkerNodes {
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
        for frame in frames {
            guard let cols = frame["transform_matrix"] as? [[NSNumber]], cols.count == 4 else { continue }
            let pose = simd_float4x4(
                columnVector(cols[0]), columnVector(cols[1]), columnVector(cols[2]), columnVector(cols[3])
            )
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
        let equirectNodes = buildEquirectFaceNodes(scanDirectoryURL: scanDir)

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

    /// Cube-face direction: name, rotation quaternion (cam-space, ARKit convention),
    /// and direction-specific color. Matches EquirectFaceExport's face definitions.
    private nonisolated struct EquirectFace {
        let name: String
        let rotation: simd_quatf
        let color: SIMD4<Float>
    }

    /// The 5 cube-map faces (bottom dropped — operator/rod). Rotations are in camera
    /// space: +X right, +Y up, -Z forward (ARKit/OpenGL convention).
    private nonisolated static let equirectFaceDefinitions: [EquirectFace] = [
        EquirectFace(name: "front", rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                     color: AppConstants.equirectFrontColor),
        EquirectFace(name: "right", rotation: simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(0, 1, 0)),
                     color: AppConstants.equirectRightColor),
        EquirectFace(name: "back",  rotation: simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)),
                     color: AppConstants.equirectBackColor),
        EquirectFace(name: "left",  rotation: simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0)),
                     color: AppConstants.equirectLeftColor),
        EquirectFace(name: "up",    rotation: simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(1, 0, 0)),
                     color: AppConstants.equirectUpColor)
    ]

    /// Builds 5 direction-colored frustum cones per equirect still. Poses are computed
    /// on-the-fly from the sidecar's `phone_transform` + rig calibration (or prior).
    /// Each face is a 90° FOV pinhole (tan(45°) = 1.0). Runs off-main alongside the
    /// keyframe builder. Returns nil if no equirect stills exist.
    private nonisolated static func buildEquirectFaceNodes(scanDirectoryURL: URL) -> SCNNode? {
        let fileMgr = FileManager.default
        let equirectDir = scanDirectoryURL
            .appendingPathComponent("raw_data")
            .appendingPathComponent("equirect_stills")
        guard fileMgr.fileExists(atPath: equirectDir.path) else { return nil }

        let sidecars = ((try? fileMgr.contentsOfDirectory(at: equirectDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !sidecars.isEmpty else { return nil }

        // Load rig profile (calibrated or nil → mechanical prior)
        let rigProfile = RigProfile.load()

        // Pre-build geometry for each face direction (5 cache entries; shared across all stills).
        // 90° FOV pinhole: tan(45°) = 1.0.
        var geometryCache: [String: FrustumGeometry] = [:]
        for face in equirectFaceDefinitions {
            geometryCache[face.name] = makeFrustumGeometry(
                tanHalfAngle: 1.0,
                color: face.color,
                scale: 1.0
            )
        }

        var allNodes: [SCNNode] = []
        for sidecarURL in sidecars {
            guard let data = try? Data(contentsOf: sidecarURL),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let flat = (dict["phone_transform"] ?? dict["phoneTransform"]) as? [Double], flat.count == 16
            else { continue }

            let phoneToWorld = simd_float4x4(columns: (
                SIMD4<Float>(Float(flat[0]), Float(flat[1]), Float(flat[2]), Float(flat[3])),
                SIMD4<Float>(Float(flat[4]), Float(flat[5]), Float(flat[6]), Float(flat[7])),
                SIMD4<Float>(Float(flat[8]), Float(flat[9]), Float(flat[10]), Float(flat[11])),
                SIMD4<Float>(Float(flat[12]), Float(flat[13]), Float(flat[14]), Float(flat[15]))
            ))

            // Compose rig camera pose (calibrated or mechanical prior)
            let camTransform: simd_float4x4
            if let profile = rigProfile, profile.isSolved {
                camTransform = RigCalibrationSolver.composeRigTransform(
                    phoneToWorld: phoneToWorld,
                    dy: profile.dy, dLateral: profile.dLateral,
                    yaw: profile.yaw, pitchResidual: profile.pitchResidual
                )
            } else {
                camTransform = RigCalibrationSolver.composeRigTransform(
                    phoneToWorld: phoneToWorld,
                    dy: AppConstants.rigRodHeightMeters, dLateral: 0,
                    yaw: AppConstants.rigYawOffsetDegrees * .pi / 180, pitchResidual: 0
                )
            }

            // Build one frustum node per face direction at the rig camera position.
            // The rig transform is the 360° camera's camera-to-world; each face rotation
            // is composed into the frustum node's inner transform.
            for face in equirectFaceDefinitions {
                guard let geometry = geometryCache[face.name] else { continue }
                let node = makeFrustumNode(geometry: geometry, faceRotation: face.rotation)
                node.simdTransform = camTransform
                allNodes.append(node)
            }
        }

        return container(named: "equirectFaces", nodes: allNodes)
    }
}
