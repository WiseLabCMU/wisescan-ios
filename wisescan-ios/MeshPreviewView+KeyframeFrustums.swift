import Foundation
import SceneKit
import simd

// Capture-pose frustum markers for the single-scan mesh preview. Derived entirely from the
// saved poses (raw_data/transforms.json) — no capture-time cost. Stills (sharp keyframes) and
// motion (sweep) frames are built as two separate node groups so the three-tier
// KeyframeMarkerMode can show neither / stills / stills+motion. Extracted from MeshPreviewView
// to keep that file under the length limit.
extension MeshPreviewView {

    /// The two capture-pose marker groups, each a container node ready to attach (nil if empty).
    struct KeyframeMarkerNodes {
        let stills: SCNNode?
        let motion: SCNNode?
        var hasAny: Bool { stills != nil || motion != nil }
    }

    /// Attaches the marker groups to the mesh container, sets initial visibility from the current
    /// mode, publishes `hasKeyframeMarkers`, and stores the container refs on the coordinator for
    /// later toggling. Main-thread (preview load).
    func attachKeyframeMarkers(_ nodes: KeyframeMarkerNodes, to container: SCNNode, coordinator: Coordinator) {
        hasKeyframeMarkers = nodes.hasAny
        if let stills = nodes.stills {
            stills.isHidden = !keyframeMarkerMode.showStills
            container.addChildNode(stills)
            coordinator.keyframeStillsNode = stills
        }
        if let motion = nodes.motion {
            motion.isHidden = !keyframeMarkerMode.showMotion
            container.addChildNode(motion)
            coordinator.keyframeMotionNode = motion
        }
    }

    /// Builds the still + motion frustum marker groups from the saved `transforms.json` poses.
    /// Stills are `is_keyframe` frames (cyan, full size); motion frames are the rest (amber,
    /// smaller). Each wedge carries its capture pose in `simdTransform`; the returned container
    /// nodes carry the shared mesh-centering offset so they align with the centered mesh.
    /// No capture-time cost — read from raw data already on disk, in the mesh's world frame.
    nonisolated static func buildKeyframeMarkerNodes(
        scanDirectoryURL: URL?, center: SCNVector3
    ) -> KeyframeMarkerNodes {
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
            let color = isStill ? AppConstants.keyframeStillColor : AppConstants.keyframeMotionColor
            let scale: Float = isStill ? 1.0 : AppConstants.keyframeMotionScale
            let node = makeFrustumNode(tanHalfAngle: tanHalf, color: color, scale: scale)
            node.simdTransform = pose
            if isStill { stillNodes.append(node) } else { motionNodes.append(node) }
        }

        return KeyframeMarkerNodes(
            stills: container(named: "keyframeStills", nodes: stillNodes, center: center),
            motion: container(named: "keyframeMotion", nodes: motionNodes, center: center)
        )
    }

    /// Wraps marker nodes in a named container carrying the mesh-centering offset (nil if empty).
    private nonisolated static func container(named name: String, nodes: [SCNNode], center: SCNVector3) -> SCNNode? {
        guard !nodes.isEmpty else { return nil }
        let node = SCNNode()
        node.name = name
        node.position = SCNVector3(-center.x, -center.y, -center.z)
        for child in nodes { node.addChildNode(child) }
        return node
    }

    /// Reconstructs one matrix column (SIMD4) from a JSON `[x, y, z, w]` array.
    private nonisolated static func columnVector(_ arr: [NSNumber]) -> SIMD4<Float> {
        guard arr.count == 4 else { return SIMD4<Float>(0, 0, 0, 0) }
        return SIMD4<Float>(arr[0].floatValue, arr[1].floatValue, arr[2].floatValue, arr[3].floatValue)
    }

    /// Builds a single frustum marker in local space: apex at the origin opening along -Z
    /// (camera forward) to a rectangle at `keyframeFrustumDepth × scale`, plus a solid apex cube.
    /// The base is `~4:3` using the horizontal half-angle tangent; `faceRotation` (identity for a
    /// pinhole still) orients the wedge for the future 360° cube-face case.
    private nonisolated static func makeFrustumNode(
        tanHalfAngle: Float,
        color: SIMD4<Float>,
        scale: Float,
        faceRotation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    ) -> SCNNode {
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

        // Geometry lives on an inner node carrying the face rotation, so the caller can set the
        // outer node's simdTransform = capture pose without clobbering the rotation. World placement
        // is then pose × faceRotation × geometry (identity faceRotation for a pinhole still).
        let inner = SCNNode()
        inner.addChildNode(SCNNode(geometry: wireGeo))
        inner.addChildNode(SCNNode(geometry: fillGeo))
        inner.addChildNode(SCNNode(geometry: apexBox))
        inner.simdOrientation = faceRotation
        let node = SCNNode()
        node.addChildNode(inner)
        return node
    }
}
