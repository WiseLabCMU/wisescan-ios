import ARKit
import Accelerate
import CoreGraphics
import CoreImage
import ImageIO
import simd

// MARK: - Rig Calibration Solver
// Markerless mesh-edge reprojection solver for the 360° camera rig extrinsic.
// See docs/design/still-source-360.md → "Pose & calibration plan".
//
// Solves a 4-DOF rigid transform (dy, d_lateral, yaw, pitch_residual) between the phone
// and 360° camera by minimizing the distance between LiDAR mesh edges projected into the
// equirect and Canny edges detected in the equirect image.
//
// The solver runs entirely on-device: a Nelder-Mead simplex optimizer over a 4-parameter
// cost function converges in milliseconds from the mechanical-prior initial guess. Call
// `solve(inputs:prior:)` on a background queue (never main — the edge detection and
// projection loops are CPU-bound).

enum RigCalibrationSolver {

    // MARK: - Data types

    /// A world-space line segment from the mesh — a boundary edge of a triangle.
    struct MeshEdge {
        let a: SIMD3<Float>
        let b: SIMD3<Float>
    }

    /// Binary edge map + distance transform for cost evaluation.
    struct EdgeMap {
        let distances: [Float]  // distance transform: distance to nearest edge pixel
        let width: Int
        let height: Int
    }

    /// One calibration capture: phone pose, equirect edge map, nearby mesh edges.
    struct CalibrationInput {
        let phoneToWorld: simd_float4x4
        let edgeMap: EdgeMap
        let meshEdges: [MeshEdge]
    }

    /// Solved calibration result.
    struct CalibrationResult {
        let profile: RigProfile
        let residualCm: Float       // mean edge distance in cm (approximate)
        let converged: Bool
        let iterations: Int
    }

    // MARK: - Entry

    /// Solve the 4-DOF rig transform from calibration inputs.
    /// Call on a background queue. The prior provides the initial guess.
    static func solve(inputs: [CalibrationInput], prior: RigProfile) -> CalibrationResult {
        // Initial simplex vertices: prior ± small perturbations
        let x0 = SIMD4<Float>(prior.dy, prior.dLateral, prior.yaw, prior.pitchResidual)

        // Perturbation scales per parameter (order: dy, dLat, yaw, pitch)
        let scales = SIMD4<Float>(0.1, 0.05, 0.1, 0.05) // meters, meters, radians, radians

        let result = nelderMead(
            initial: x0,
            scales: scales,
            maxIterations: AppConstants.calibrationMaxIterations,
            tolerance: AppConstants.calibrationConvergenceTolerance
        ) { params in
            totalCost(params: params, inputs: inputs)
        }

        let solved = RigProfile(
            dy: result.point.x,
            dLateral: result.point.y,
            yaw: result.point.z,
            pitchResidual: result.point.w,
            residualCm: result.cost,
            timestamp: Date(),
            cameraModel: prior.cameraModel
        )
        return CalibrationResult(
            profile: solved,
            residualCm: result.cost,
            converged: result.converged,
            iterations: result.iterations
        )
    }

    /// Quick validation: evaluate the cost function at the stored calibration parameters
    /// against a single new capture. Returns the current residual — if significantly worse
    /// than the stored calibration residual, the rig may have shifted.
    ///
    /// This is the "first-still spot-check": no optimization (O(1) — one cost evaluation),
    /// runs in milliseconds. Called automatically on the first 360° still of each scan.
    static func validateCalibration(input: CalibrationInput, profile: RigProfile) -> Float {
        let params = SIMD4<Float>(profile.dy, profile.dLateral, profile.yaw, profile.pitchResidual)
        return totalCost(params: params, inputs: [input])
    }

    // MARK: - Cost function

    /// Total cost across all calibration inputs for a candidate rig parameter set.
    private static func totalCost(params: SIMD4<Float>, inputs: [CalibrationInput]) -> Float {
        var total: Float = 0
        var count = 0
        for input in inputs {
            let rigTransform = composeRigTransform(
                phoneToWorld: input.phoneToWorld,
                dy: params.x, dLateral: params.y,
                yaw: params.z, pitchResidual: params.w
            )
            let camPos = SIMD3<Float>(rigTransform.columns.3.x,
                                     rigTransform.columns.3.y,
                                     rigTransform.columns.3.z)
            for edge in input.meshEdges {
                total += edgeCost(edge: edge, camPos: camPos, edgeMap: input.edgeMap)
                count += 1
            }
        }
        // Mean cost scaled to approximate cm (edge map pixels → rough spatial mapping)
        return count > 0 ? total / Float(count) : Float.greatestFiniteMagnitude
    }

    /// Cost of one mesh edge: sample points along the projected edge in equirect space
    /// and sum their distances to the nearest detected image edge.
    private static func edgeCost(edge: MeshEdge, camPos: SIMD3<Float>, edgeMap: EdgeMap) -> Float {
        let samples = 8
        var cost: Float = 0
        for i in 0..<samples {
            let t = (Float(i) + 0.5) / Float(samples)
            let point = edge.a + t * (edge.b - edge.a)
            let dir = simd_normalize(point - camPos)
            let (eqX, eqY) = dirToEquirect(dir: dir, width: edgeMap.width, height: edgeMap.height)
            let col = max(0, min(edgeMap.width - 1, Int(eqX)))
            let row = max(0, min(edgeMap.height - 1, Int(eqY)))
            let dist = edgeMap.distances[row * edgeMap.width + col]
            cost += dist * dist
        }
        return cost / Float(samples)
    }

    // MARK: - Rig transform composition

    /// Compose the world→360cam transform from the phone pose and rig parameters.
    /// Returns a 4×4 camera-to-world matrix for the 360° camera.
    static func composeRigTransform(
        phoneToWorld: simd_float4x4,
        dy: Float, dLateral: Float,
        yaw: Float, pitchResidual: Float
    ) -> simd_float4x4 {
        // Phone position in world
        let phonePos = SIMD3<Float>(phoneToWorld.columns.3.x,
                                   phoneToWorld.columns.3.y,
                                   phoneToWorld.columns.3.z)
        // Phone's horizontal forward (gravity-projected)
        let phoneFwd = -SIMD3<Float>(phoneToWorld.columns.2.x,
                                     phoneToWorld.columns.2.y,
                                     phoneToWorld.columns.2.z)
        var horiz = SIMD3<Float>(phoneFwd.x, 0, phoneFwd.z)
        if simd_length(horiz) < 1e-3 {
            let phoneUp = SIMD3<Float>(phoneToWorld.columns.1.x, 0, phoneToWorld.columns.1.z)
            horiz = simd_length(phoneUp) > 1e-3 ? phoneUp : SIMD3<Float>(0, 0, -1)
        }
        let fwdNorm = simd_normalize(horiz)

        // Lateral offset: perpendicular to forward in the horizontal plane
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), -fwdNorm))

        // Camera position = phone position + height offset + lateral offset
        var camPos = phonePos
        camPos.y += dy
        camPos += right * dLateral

        // Camera orientation: level, rotated by yaw from phone forward, with pitch residual
        var fwd = fwdNorm
        if yaw != 0 {
            let yawRot = simd_float3x3(simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)))
            fwd = yawRot * fwd
        }

        // Apply pitch residual around the camera's right axis
        let camRight = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), -fwd))
        if pitchResidual != 0 {
            let pitchRot = simd_float3x3(simd_quatf(angle: pitchResidual, axis: camRight))
            fwd = pitchRot * fwd
        }

        let camUp = simd_normalize(simd_cross(-fwd, camRight))
        let back = -fwd

        // Camera-to-world: columns are (right, up, back, position) in OpenGL/ARKit convention
        return simd_float4x4(columns: (
            SIMD4<Float>(camRight.x, camRight.y, camRight.z, 0),
            SIMD4<Float>(camUp.x, camUp.y, camUp.z, 0),
            SIMD4<Float>(back.x, back.y, back.z, 0),
            SIMD4<Float>(camPos.x, camPos.y, camPos.z, 1)
        ))
    }

    // MARK: - Sphere math

    /// Convert a direction to equirect pixel coordinates.
    /// Convention: lon 0 = +Z (equirect center), lat +90° = +Y (north pole).
    private static func dirToEquirect(dir: SIMD3<Float>, width: Int, height: Int) -> (Float, Float) {
        let lat = asin(max(-1, min(1, dir.y)))
        let lon = atan2(dir.x, dir.z)
        let eqX = (lon + .pi) / (2 * .pi) * Float(width)
        let eqY = (.pi / 2 - lat) / .pi * Float(height)
        return (eqX, eqY)
    }

    // MARK: - Mesh edge extraction

    /// Extract triangle boundary edges from ARMeshAnchors within `radius` of `position`.
    /// Returns edges in world coordinates and the vertex count within the radius (for the
    /// environment quality gate).
    static func extractMeshEdges(
        from anchors: [ARMeshAnchor],
        near position: SIMD3<Float>,
        radius: Float
    ) -> (edges: [MeshEdge], vertexCount: Int) {
        var edges: [MeshEdge] = []
        var vertexCount = 0

        for anchor in anchors {
            let transform = anchor.transform
            let geometry = anchor.geometry
            let vertexSource = geometry.vertices
            let faceElement = geometry.faces

            // Read vertices from the raw MTLBuffer (ARGeometrySource is not subscriptable)
            let vertexCount_local = vertexSource.count
            let vertexStride = vertexSource.stride
            let vertexOffset = vertexSource.offset
            let vertexBuffer = vertexSource.buffer.contents()

            var worldVerts: [SIMD3<Float>] = []
            worldVerts.reserveCapacity(vertexCount_local)

            for i in 0..<vertexCount_local {
                let ptr = vertexBuffer.advanced(by: vertexOffset + i * vertexStride)
                let x = ptr.load(as: Float.self)
                let y = ptr.advanced(by: MemoryLayout<Float>.size).load(as: Float.self)
                let z = ptr.advanced(by: MemoryLayout<Float>.size * 2).load(as: Float.self)
                let local4 = SIMD4<Float>(x, y, z, 1)
                let world4 = transform * local4
                worldVerts.append(SIMD3<Float>(world4.x, world4.y, world4.z))
            }

            // Count vertices near the position
            for vert in worldVerts {
                if simd_distance(vert, position) <= radius {
                    vertexCount += 1
                }
            }

            // Extract triangle edges (deduplicated by sorting vertex indices)
            let faceCount = faceElement.count
            let indexBuffer = faceElement.buffer.contents()
            let bytesPerIndex = faceElement.bytesPerIndex
            let indexCountPerPrimitive = faceElement.indexCountPerPrimitive
            var edgeSet: Set<UInt64> = []

            for f in 0..<faceCount {
                let offset = f * indexCountPerPrimitive * bytesPerIndex
                var indices: [UInt32] = []
                for v in 0..<indexCountPerPrimitive {
                    let ptr = indexBuffer.advanced(by: offset + v * bytesPerIndex)
                    if bytesPerIndex == 4 {
                        indices.append(ptr.load(as: UInt32.self))
                    } else {
                        indices.append(UInt32(ptr.load(as: UInt16.self)))
                    }
                }

                // Check if any vertex of this triangle is within radius
                let triNear = indices.contains { idx in
                    simd_distance(worldVerts[Int(idx)], position) <= radius
                }
                guard triNear else { continue }

                // Add edges (sorted pair → deduplicate)
                let edgePairs: [(UInt32, UInt32)] = [
                    (indices[0], indices[1]),
                    (indices[1], indices[2]),
                    (indices[2], indices[0])
                ]
                for (a, b) in edgePairs {
                    let key = a < b ? (UInt64(a) << 32 | UInt64(b)) : (UInt64(b) << 32 | UInt64(a))
                    if edgeSet.insert(key).inserted {
                        edges.append(MeshEdge(a: worldVerts[Int(a)], b: worldVerts[Int(b)]))
                    }
                }
            }
        }

        return (edges, vertexCount)
    }

    // MARK: - Equirect edge detection

    /// Detect edges in an equirect JPEG and produce a distance transform.
    /// Uses CoreImage's edge detection + a brute-force distance transform on a small image.
    static func detectEquirectEdges(in jpegData: Data, maxWidth: Int = 512) -> EdgeMap? {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxWidth,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }

        let width = cgImage.width
        let height = cgImage.height

        // Convert to grayscale bitmap
        let bytesPerRow = width
        var grayscale = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let ctx = CGContext(data: &grayscale, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Simple Sobel edge detection
        var edgeMask = [Bool](repeating: false, count: width * height)
        let threshold: Float = 40  // gradient magnitude threshold
        for row in 1..<(height - 1) {
            for col in 1..<(width - 1) {
                let gx = Float(grayscale[(row - 1) * width + col + 1])
                    + 2 * Float(grayscale[row * width + col + 1])
                    + Float(grayscale[(row + 1) * width + col + 1])
                    - Float(grayscale[(row - 1) * width + col - 1])
                    - 2 * Float(grayscale[row * width + col - 1])
                    - Float(grayscale[(row + 1) * width + col - 1])
                let gy = Float(grayscale[(row + 1) * width + col - 1])
                    + 2 * Float(grayscale[(row + 1) * width + col])
                    + Float(grayscale[(row + 1) * width + col + 1])
                    - Float(grayscale[(row - 1) * width + col - 1])
                    - 2 * Float(grayscale[(row - 1) * width + col])
                    - Float(grayscale[(row - 1) * width + col + 1])
                let mag = sqrt(gx * gx + gy * gy)
                if mag > threshold { edgeMask[row * width + col] = true }
            }
        }

        // Distance transform: for each pixel, distance to nearest edge pixel.
        // Use a fast two-pass (top-left → bottom-right, then bottom-right → top-left)
        // chamfer approximation — adequate for the cost function at 512px width.
        var distances = [Float](repeating: Float(width + height), count: width * height)
        for i in 0..<distances.count where edgeMask[i] { distances[i] = 0 }

        // Forward pass
        for row in 0..<height {
            for col in 0..<width {
                let idx = row * width + col
                if col > 0 { distances[idx] = min(distances[idx], distances[idx - 1] + 1) }
                if row > 0 { distances[idx] = min(distances[idx], distances[(row - 1) * width + col] + 1) }
                if row > 0 && col > 0 {
                    distances[idx] = min(distances[idx], distances[(row - 1) * width + col - 1] + 1.414)
                }
                if row > 0 && col < width - 1 {
                    distances[idx] = min(distances[idx], distances[(row - 1) * width + col + 1] + 1.414)
                }
            }
        }
        // Backward pass
        for row in stride(from: height - 1, through: 0, by: -1) {
            for col in stride(from: width - 1, through: 0, by: -1) {
                let idx = row * width + col
                if col < width - 1 { distances[idx] = min(distances[idx], distances[idx + 1] + 1) }
                if row < height - 1 { distances[idx] = min(distances[idx], distances[(row + 1) * width + col] + 1) }
                if row < height - 1 && col < width - 1 {
                    distances[idx] = min(distances[idx], distances[(row + 1) * width + col + 1] + 1.414)
                }
                if row < height - 1 && col > 0 {
                    distances[idx] = min(distances[idx], distances[(row + 1) * width + col - 1] + 1.414)
                }
            }
        }

        return EdgeMap(distances: distances, width: width, height: height)
    }

    // MARK: - Nelder-Mead optimizer

    private struct NMResult {
        let point: SIMD4<Float>
        let cost: Float
        let converged: Bool
        let iterations: Int
    }

    /// Nelder-Mead simplex optimizer for 4 dimensions.
    private static func nelderMead(
        initial: SIMD4<Float>,
        scales: SIMD4<Float>,
        maxIterations: Int,
        tolerance: Float,
        cost: (SIMD4<Float>) -> Float
    ) -> NMResult {
        let n = 4  // dimensions
        let alpha: Float = 1.0   // reflection
        let gamma: Float = 2.0   // expansion
        let rho: Float = 0.5     // contraction
        let sigma: Float = 0.5   // shrink

        // Initialize simplex: n+1 vertices
        var simplex: [(point: SIMD4<Float>, cost: Float)] = []
        simplex.append((initial, cost(initial)))
        for d in 0..<n {
            var vertex = initial
            vertex[d] += scales[d]
            simplex.append((vertex, cost(vertex)))
        }

        var converged = false
        var iteration = 0

        while iteration < maxIterations {
            // Sort by cost
            simplex.sort { $0.cost < $1.cost }

            // Convergence check: cost range of simplex
            let costRange = simplex.last!.cost - simplex.first!.cost
            if costRange < tolerance {
                converged = true
                break
            }

            // Centroid of all except worst
            var centroid = SIMD4<Float>.zero
            for i in 0..<n {
                centroid += simplex[i].point
            }
            centroid /= Float(n)

            let worst = simplex[n]

            // Reflection
            let reflected = centroid + alpha * (centroid - worst.point)
            let reflectedCost = cost(reflected)

            if reflectedCost < simplex[0].cost {
                // Expansion
                let expanded = centroid + gamma * (reflected - centroid)
                let expandedCost = cost(expanded)
                simplex[n] = expandedCost < reflectedCost
                    ? (expanded, expandedCost)
                    : (reflected, reflectedCost)
            } else if reflectedCost < simplex[n - 1].cost {
                simplex[n] = (reflected, reflectedCost)
            } else {
                // Contraction
                let contracted = centroid + rho * (worst.point - centroid)
                let contractedCost = cost(contracted)
                if contractedCost < worst.cost {
                    simplex[n] = (contracted, contractedCost)
                } else {
                    // Shrink
                    let best = simplex[0]
                    for i in 1...n {
                        let shrunk = best.point + sigma * (simplex[i].point - best.point)
                        simplex[i] = (shrunk, cost(shrunk))
                    }
                }
            }

            iteration += 1
        }

        simplex.sort { $0.cost < $1.cost }
        return NMResult(point: simplex[0].point, cost: simplex[0].cost,
                        converged: converged, iterations: iteration)
    }
}

// MARK: - Rig Profile (persistable calibration)

/// Solved rig calibration profile: the 4 parameters, residual, and provenance metadata.
/// Persisted to UserDefaults as JSON so the calibration survives app restarts.
struct RigProfile: Codable, Equatable {
    /// Vertical offset — rod height along gravity (meters).
    let dy: Float
    /// Horizontal offset — phone clip distance from rod axis (meters).
    let dLateral: Float
    /// Yaw offset — rotation around the vertical axis (radians).
    let yaw: Float
    /// Pitch residual — small correction for imperfect zenith compensation (radians).
    let pitchResidual: Float
    /// Calibration residual (approximate cm).
    let residualCm: Float
    /// When this calibration was performed.
    let timestamp: Date
    /// Camera model string (e.g. "RICOH THETA X") for provenance.
    let cameraModel: String?

    /// The mechanical prior: `AppConstants` defaults, no calibration.
    static var mechanicalPrior: RigProfile {
        RigProfile(
            dy: AppConstants.rigRodHeightMeters,
            dLateral: 0,
            yaw: AppConstants.rigYawOffsetDegrees * .pi / 180,
            pitchResidual: 0,
            residualCm: -1,  // sentinel: not calibrated
            timestamp: .distantPast,
            cameraModel: nil
        )
    }

    var isSolved: Bool { residualCm >= 0 }

    // MARK: - Persistence

    private static let userDefaultsKey = "rig_calibration_profile"

    static func load() -> RigProfile? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return nil }
        return try? JSONDecoder().decode(RigProfile.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}
