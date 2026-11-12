import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd

/// Renders a depth map for a synthetic cube face by rasterising the scan's own mesh from
/// that face's pose.
///
/// WHY THIS EXISTS. Cube faces cut from a 360° still carry no depth, so the colorizer's
/// occlusion test is disabled for them: every vertex inside the face's 90° cone gets
/// painted, including surfaces behind walls. That was accepted while the face colouring
/// was a pose-quality PROBE — "expect bleed, that is the point" — but it makes the probe
/// unreadable for the question it is now being asked. Bleed and pose error look alike:
/// both put colour where it does not belong. Field runs on 2026-08-17 could not
/// distinguish them, which is the whole reason this is here.
///
/// The mesh is the missing information. It is already reconstructed, already in the same
/// world frame as the baked pose, and a z-buffer rasterisation of it from that pose is
/// exactly the depth the face would have had if a depth sensor had been behind it. With
/// it, occlusion works for face frames and the probe measures pose alone.
///
/// It also self-checks: if the baked pose is WRONG, the mesh rasterised from it disagrees
/// with the face imagery, and the resulting colouring is wrong in a way that reads as
/// misregistration rather than as smear.
enum FaceDepthRender {

    /// A 90° pinhole, matching the faces EquirectFaceExport cuts:
    /// `fx = fy = cx = cy = side / 2`.
    static func render(mesh: MeshParser.OBJData, camToWorld: simd_float4x4, side: Int) -> [UInt16] {
        var depth = [Float](repeating: .greatestFiniteMagnitude, count: side * side)
        let worldToCam = camToWorld.inverse
        let half = Float(side) / 2

        // Transform once; the rasteriser then works purely in camera space.
        var camSpace = [SIMD3<Float>]()
        camSpace.reserveCapacity(mesh.vertices.count)
        for vertex in mesh.vertices {
            let local = worldToCam * SIMD4<Float>(vertex, 1)
            camSpace.append(SIMD3<Float>(local.x, local.y, local.z))
        }

        for face in mesh.faces {
            let vertexA = camSpace[Int(face.0)]
            let vertexB = camSpace[Int(face.1)]
            let vertexC = camSpace[Int(face.2)]
            // ARKit convention: the camera looks down −Z, so visible geometry has z < 0.
            // Triangles crossing the near plane are dropped rather than clipped — they are
            // a sliver of the frustum and clipping is not worth the complexity here.
            let near: Float = -0.05
            guard vertexA.z < near, vertexB.z < near, vertexC.z < near else { continue }

            let pointA = project(vertexA, half: half)
            let pointB = project(vertexB, half: half)
            let pointC = project(vertexC, half: half)
            let minX = max(0, Int(floor(min(pointA.x, pointB.x, pointC.x))))
            let maxX = min(side - 1, Int(ceil(max(pointA.x, pointB.x, pointC.x))))
            let minY = max(0, Int(floor(min(pointA.y, pointB.y, pointC.y))))
            let maxY = min(side - 1, Int(ceil(max(pointA.y, pointB.y, pointC.y))))
            guard minX <= maxX, minY <= maxY else { continue }

            let area = edge(pointA, pointB, pointC)
            guard abs(area) > 1e-6 else { continue }

            for row in minY...maxY {
                for column in minX...maxX {
                    let point = SIMD2<Float>(Float(column) + 0.5, Float(row) + 0.5)
                    // Dividing the sub-areas by the signed total area already normalises
                    // the winding: a clockwise triangle flips both numerator and
                    // denominator. Re-negating here would reject every pixel of every
                    // negative-area triangle.
                    let weightA = edge(pointB, pointC, point) / area
                    let weightB = edge(pointC, pointA, point) / area
                    let weightC = edge(pointA, pointB, point) / area
                    guard weightA >= 0, weightB >= 0, weightC >= 0 else { continue }
                    // Distance along the view axis, which is what the colorizer compares
                    // its expected depth against.
                    let distance = -(weightA * vertexA.z + weightB * vertexB.z + weightC * vertexC.z)
                    let index = row * side + column
                    if distance > 0, distance < depth[index] { depth[index] = distance }
                }
            }
        }

        // Millimetres, 0 = no data — the same contract the capture pipeline's depth PNGs
        // use, so the colorizer's existing "depth == 0 ⇒ skip" guard applies unchanged.
        return depth.map { $0 == .greatestFiniteMagnitude ? 0 : UInt16(min(65535, max(0, $0 * 1000))) }
    }

    private static func project(_ point: SIMD3<Float>, half: Float) -> SIMD2<Float> {
        let inverseZ = -1 / point.z
        return SIMD2<Float>(half * point.x * inverseZ + half, half - half * point.y * inverseZ)
    }

    /// Signed area of the triangle formed by three 2-D points — the standard
    /// half-plane test the rasteriser uses for both coverage and barycentrics.
    private static func edge(_ first: SIMD2<Float>, _ second: SIMD2<Float>,
                             _ third: SIMD2<Float>) -> Float {
        (second.x - first.x) * (third.y - first.y) - (second.y - first.y) * (third.x - first.x)
    }

    /// 16-bit grayscale PNG. `byteOrder16Little` must be declared explicitly: the raw
    /// buffer is a native little-endian `[UInt16]`, and without it CoreGraphics treats
    /// every sample as big-endian and writes byte-swapped millimetres (1000 mm -> 59395).
    /// That is the same defect the capture depth PNGs have carried on disk for months.
    static func encodePNG(_ depth: [UInt16], side: Int) -> Data? {
        var bytes = depth
        return bytes.withUnsafeMutableBytes { raw -> Data? in
            guard let provider = CGDataProvider(dataInfo: nil, data: raw.baseAddress!,
                                                size: raw.count, releaseData: { _, _, _ in }),
                  let image = CGImage(width: side, height: side,
                                      bitsPerComponent: 16, bitsPerPixel: 16,
                                      bytesPerRow: side * 2,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGBitmapInfo.byteOrder16Little.union(
                                          CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)),
                                      provider: provider, decode: nil,
                                      shouldInterpolate: false, intent: .defaultIntent)
            else { return nil }
            let out = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                out, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return out as Data
        }
    }
}
