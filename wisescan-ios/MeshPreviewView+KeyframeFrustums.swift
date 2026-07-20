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

    /// The two capture-pose marker groups, each a container node ready to attach (nil if empty).
    struct KeyframeMarkerNodes {
        let stills: SCNNode?
        let motion: SCNNode?
        var hasAny: Bool { stills != nil || motion != nil }
    }

    /// Attaches the marker groups to the mesh container, applies the mesh-centering offset
    /// (known only once the mesh node exists), sets initial visibility from the current mode,
    /// publishes `hasKeyframeMarkers`, and stores the container refs on the coordinator for
    /// later toggling. Main-thread (preview load); the groups themselves are built off-main.
    func attachKeyframeMarkers(
        _ nodes: KeyframeMarkerNodes, to container: SCNNode, coordinator: Coordinator, center: SCNVector3
    ) {
        hasKeyframeMarkers = nodes.hasAny
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
    }

    /// Builds the still + motion frustum marker groups from the saved `transforms.json` poses.
    /// Stills are `is_keyframe` frames (cyan, full size); motion frames are the rest (amber,
    /// smaller). Each wedge carries its capture pose; the mesh-centering offset is applied at
    /// attach time. No capture-time cost — read from raw data already on disk, in the mesh's
    /// world frame. Runs OFF-main on the preview-load queue (detached SCNNode trees are legal
    /// to build on any thread): a long scan parses a multi-MB transforms.json and assembles
    /// hundreds of wedge nodes, which would be a visible hitch stacked onto the main-thread attach.
    nonisolated static func buildKeyframeMarkerNodes(scanDirectoryURL: URL?) -> KeyframeMarkerNodes {
        guard let scanDir = scanDirectoryURL else { return KeyframeMarkerNodes(stills: nil, motion: nil) }
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
            return KeyframeMarkerNodes(stills: nil, motion: nil)
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

        return KeyframeMarkerNodes(
            stills: container(named: "keyframeStills", nodes: stillNodes),
            motion: container(named: "keyframeMotion", nodes: motionNodes)
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
    /// geometry (identity faceRotation for a pinhole still; the future 360° cube-face case
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
}
