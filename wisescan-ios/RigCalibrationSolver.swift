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
        let residualPx: Float       // RMS reprojection error in equirect pixels (512-wide working image)
        let converged: Bool
        let iterations: Int
    }

    // MARK: - Entry

    /// Solve the 4-DOF rig transform from calibration inputs.
    /// Call on a background queue. The prior provides the initial guess.
    /// Returns a failed result if no input contains mesh edges (solver has nothing to align).
    static func solve(inputs: [CalibrationInput], prior: RigProfile) -> CalibrationResult {
        // Guard: if no input has mesh edges, the solver has nothing to work with.
        let totalEdges = inputs.reduce(0) { $0 + $1.meshEdges.count }
        if totalEdges == 0 {
            return CalibrationResult(
                profile: prior, residualPx: -1,
                converged: false, iterations: 0
            )
        }

        // Subsample mesh edges per input to cap solver time. With 70K+ edges and 100+
        // iterations, the cost function dominates (O(edges × inputs × iters)); 2000
        // uniformly-sampled edges per input are sufficient for convergence (~5s vs ~227s).
        let maxEdges = AppConstants.calibrationMaxEdgesPerInput
        let sampledInputs = inputs.map { input -> CalibrationInput in
            if input.meshEdges.count <= maxEdges { return input }
            let stride = max(1, input.meshEdges.count / maxEdges)
            let sampled = Swift.stride(from: 0, to: input.meshEdges.count, by: stride)
                .prefix(maxEdges)
                .map { input.meshEdges[$0] }
            return CalibrationInput(
                phoneToWorld: input.phoneToWorld,
                edgeMap: input.edgeMap,
                meshEdges: sampled
            )
        }

        // Physical bounds anchored to the MECHANICAL prior (not the possibly-garbage
        // stored profile): a monopod rig cannot be outside rod ±0.3 m, |lateral| 0.3 m,
        // yaw ±30°, pitch ±10°. Candidates outside hit a flat penalty wall — run8 showed
        // the chamfer surface is flat enough that the unbounded solver wandered to
        // dy=4.4 m / yaw=−240° at "normal" residuals.
        let anchor = RigProfile.mechanicalPrior
        let yawHalf = AppConstants.calibrationBoundYawDeg * Float.pi / 180
        let pitchHalf = AppConstants.calibrationBoundPitchDeg * Float.pi / 180
        let lo = SIMD4<Float>(anchor.dy - AppConstants.calibrationBoundDyM,
                              -AppConstants.calibrationBoundLateralM,
                              anchor.yaw - yawHalf,
                              -pitchHalf)
        let hi = SIMD4<Float>(anchor.dy + AppConstants.calibrationBoundDyM,
                              AppConstants.calibrationBoundLateralM,
                              anchor.yaw + yawHalf,
                              pitchHalf)

        // Initial simplex vertices: prior ± small perturbations, clamped into bounds
        // (the stored prior itself may be a garbage unbounded-era solve).
        let x0 = simd_clamp(
            SIMD4<Float>(prior.dy, prior.dLateral, prior.yaw, prior.pitchResidual), lo, hi)

        // Perturbation scales per parameter (order: dy, dLat, yaw, pitch)
        let scales = SIMD4<Float>(0.1, 0.05, 0.1, 0.05) // meters, meters, radians, radians

        let result = nelderMead(
            initial: x0,
            scales: scales,
            maxIterations: AppConstants.calibrationMaxIterations,
            tolerance: AppConstants.calibrationConvergenceTolerance
        ) { params in
            if any(params .< lo) || any(params .> hi) { return 1e6 }
            return totalCost(params: params, inputs: sampledInputs)
        }

        let solved = RigProfile(
            dy: result.point.x,
            dLateral: result.point.y,
            yaw: result.point.z,
            pitchResidual: result.point.w,
            residualPx: result.cost,
            timestamp: Date(),
            cameraModel: prior.cameraModel,
            cameraSerialNumber: prior.cameraSerialNumber
        )
        return CalibrationResult(
            profile: solved,
            residualPx: result.cost,
            converged: result.converged,
            iterations: result.iterations
        )
    }

    // MARK: - Diagnostic overlay

    /// Render a per-still alignment diagnostic PNG: detected image edges (white, the
    /// distance-transform zeros), mesh edges projected at the mechanical PRIOR (cyan)
    /// and at the SOLVED params (red). If red doesn't hug white visibly better than
    /// cyan, the solve added nothing over the prior — the ground-truth visual for a
    /// flat/mushy cost surface that residual numbers can't distinguish.
    static func renderDiagnostic(input: CalibrationInput,
                                 solved: RigProfile,
                                 prior: RigProfile) -> Data? {
        let width = input.edgeMap.width
        let height = input.edgeMap.height
        guard width > 0, height > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            if input.edgeMap.distances[i] == 0 {
                rgba[i * 4] = 255; rgba[i * 4 + 1] = 255; rgba[i * 4 + 2] = 255
            }
            rgba[i * 4 + 3] = 255
        }

        // Mark the masked-band boundary (everything below is excluded from the solve).
        let maskBoundary = maskStartRow(height: height)
        if maskBoundary < height {
            for col in 0..<width {
                let idx = (maskBoundary * width + col) * 4
                rgba[idx] = 255; rgba[idx + 1] = 200; rgba[idx + 2] = 0
            }
        }

        func splat(_ profile: RigProfile, red: UInt8, green: UInt8, blue: UInt8) {
            let rig = composeRigTransform(
                phoneToWorld: input.phoneToWorld,
                dy: profile.dy, dLateral: profile.dLateral,
                yaw: profile.yaw, pitchResidual: profile.pitchResidual)
            let camPos = SIMD3<Float>(rig.columns.3.x, rig.columns.3.y, rig.columns.3.z)
            for edge in input.meshEdges {
                for i in 0..<4 {
                    let t = (Float(i) + 0.5) / 4
                    let point = edge.a + t * (edge.b - edge.a)
                    let dir = simd_normalize(point - camPos)
                    if dir.y < sinElevationCutoff { continue }   // masked from the solve — don't draw
                    let (eqX, eqY) = dirToEquirect(dir: dir, width: width, height: height)
                    let col = Int(eqX), row = Int(eqY)
                    guard col >= 0, col < width, row >= 0, row < height else { continue }
                    let idx = (row * width + col) * 4
                    rgba[idx] = red; rgba[idx + 1] = green; rgba[idx + 2] = blue
                }
            }
        }
        splat(prior, red: 0, green: 190, blue: 255)     // cyan = mechanical prior
        splat(solved, red: 255, green: 70, blue: 70)    // red = solved (draws over cyan)

        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(width: width, height: height,
                                    bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: bytesPerRow,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                    provider: provider, decode: nil,
                                    shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
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
                if let cost = edgeCost(edge: edge, camPos: camPos, edgeMap: input.edgeMap) {
                    total += cost
                    count += 1
                }
            }
        }
        // RMS pixel distance: edgeCost accumulates SQUARED px on the 512-wide equirect
        // distance transform, so √(mean) restores honest linear-pixel units. (Previously
        // the raw mean-squared value was returned and labeled "cm" — review finding #3.)
        return count > 0 ? sqrt(total / Float(count)) : Float.greatestFiniteMagnitude
    }

    /// sin of the elevation cutoff: a normalized direction is below the cutoff iff
    /// dir.y < sin(cutoff) (asin is monotonic). −90° disables (sin = −1).
    private static let sinElevationCutoff =
        sin(AppConstants.calibrationElevationCutoffDeg * Float.pi / 180)

    /// First equirect row at or below the elevation cutoff. Rows map latitude via
    /// eqY = (90° − lat)/180° × H (top row = +90°), so cutoff −45° ⇒ row 0.75 H and
    /// cutoff −90° (disabled) ⇒ row H (no masking). run11: the sign was flipped
    /// ((90 + cutoff) ⇒ 0.25 H), which cleared edges from 75% of the image while the
    /// cost still sampled into the void — 112 px residuals, all params wall-pinned.
    private static func maskStartRow(height: Int) -> Int {
        let frac = (90 - AppConstants.calibrationElevationCutoffDeg) / 180
        return min(height, max(0, Int(Float(height) * frac)))
    }

    /// Cost of one mesh edge: sample points along the projected edge in equirect space
    /// and sum their distances to the nearest detected image edge. Samples below the
    /// elevation cutoff are EXCLUDED (symmetric with the detect-time band mask, so the
    /// masked zone neither attracts nor inflates the residual); returns nil when every
    /// sample is masked so the edge drops out of the mean entirely.
    private static func edgeCost(edge: MeshEdge, camPos: SIMD3<Float>, edgeMap: EdgeMap) -> Float? {
        let samples = 8
        var cost: Float = 0
        var counted = 0
        for i in 0..<samples {
            let t = (Float(i) + 0.5) / Float(samples)
            let point = edge.a + t * (edge.b - edge.a)
            let dir = simd_normalize(point - camPos)
            if dir.y < sinElevationCutoff { continue }
            let (eqX, eqY) = dirToEquirect(dir: dir, width: edgeMap.width, height: edgeMap.height)
            let col = max(0, min(edgeMap.width - 1, Int(eqX)))
            let row = max(0, min(edgeMap.height - 1, Int(eqY)))
            let dist = edgeMap.distances[row * edgeMap.width + col]
            cost += dist * dist
            counted += 1
        }
        guard counted > 0 else { return nil }
        return cost / Float(counted)
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
            // Anchor-level cull BEFORE any per-vertex work: mesh anchors are ~1–2 m tiles, so
            // an anchor whose origin is far outside the radius can't contribute edges. Saves
            // transforming every vertex of every distant anchor on a large mid-scan mesh.
            let anchorOrigin = SIMD3<Float>(transform.columns.3.x,
                                            transform.columns.3.y,
                                            transform.columns.3.z)
            guard simd_distance(anchorOrigin, position) <= radius + 5.0 else { continue }

            let geometry = anchor.geometry
            let vertexSource = geometry.vertices
            let faceElement = geometry.faces

            // Read vertices from the raw MTLBuffer (ARGeometrySource is not subscriptable).
            // BOUNDED reads: clamp the advertised count to what the buffer actually holds —
            // live geometry buffers have bitten this repo before (page-aligned overread
            // EXC_BAD_ACCESS in the wireframe reader; same clamp pattern as ARCoverageView).
            let vertexStride = max(vertexSource.stride, MemoryLayout<Float>.size * 3)
            let vertexOffset = vertexSource.offset
            let vertexBuffer = vertexSource.buffer.contents()
            let vertexBytesAvail = max(0, vertexSource.buffer.length - vertexOffset)
            let vertexCount_local = min(vertexSource.count, vertexBytesAvail / vertexStride)

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

            // Extract triangle edges (deduplicated by sorting vertex indices). Face reads are
            // bounded the same way as vertex reads.
            let indexBuffer = faceElement.buffer.contents()
            let bytesPerIndex = faceElement.bytesPerIndex
            let indexCountPerPrimitive = faceElement.indexCountPerPrimitive
            let bytesPerPrimitive = indexCountPerPrimitive * bytesPerIndex
            let faceCount = bytesPerPrimitive > 0
                ? min(faceElement.count, faceElement.buffer.length / bytesPerPrimitive)
                : 0
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

                // Skip triangles referencing out-of-range vertices (clamped vertex read above
                // can leave stale indices pointing past worldVerts).
                guard indices.allSatisfy({ Int($0) < worldVerts.count }) else { continue }
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

        // Convert to grayscale bitmap. The context must not outlive the pointer, so both
        // creation and draw stay inside withUnsafeMutableBytes (an `&array` argument is only
        // valid for the call itself — same pattern as EquirectPrivacyBlur.decodeWorkingBitmap).
        let bytesPerRow = width
        var grayscale = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = grayscale.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

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

        // Exclude the bottom elevation band: it holds the rig hardware (rod/tripod) and
        // usually the operator — the only scene content that moves WITH the rig, i.e.
        // systematic attractors for the solve (runs 8-10). Symmetric with edgeCost's
        // per-sample skip; the spot-check shares this path automatically.
        let maskStart = maskStartRow(height: height)
        if maskStart < height {
            for row in maskStart..<height {
                for col in 0..<width { edgeMask[row * width + col] = false }
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
    /// Calibration residual — RMS reprojection error in equirect pixels (512-wide).
    /// NOTE: renamed from residualCm (which was actually mean-SQUARED px, finding #3).
    /// The Codable key change deliberately invalidates previously-persisted profiles —
    /// a stored squared-px value must not be reinterpreted as RMS px. Recalibrate.
    let residualPx: Float
    /// When this calibration was performed.
    let timestamp: Date
    /// Camera model string (e.g. "RICOH THETA X") for provenance.
    let cameraModel: String?
    /// Camera serial number for binding a calibration to a specific hardware device.
    let cameraSerialNumber: String?

    /// The mechanical prior: `AppConstants` defaults, no calibration.
    static var mechanicalPrior: RigProfile {
        RigProfile(
            dy: AppConstants.rigRodHeightMeters,
            dLateral: 0,
            yaw: AppConstants.rigYawOffsetDegrees * .pi / 180,
            pitchResidual: 0,
            residualPx: -1,  // sentinel: not calibrated
            timestamp: .distantPast,
            cameraModel: nil,
            cameraSerialNumber: nil
        )
    }

    var isSolved: Bool { residualPx >= 0 && residualPx.isFinite }

    func with(cameraModel: String?, cameraSerialNumber: String?) -> RigProfile {
        RigProfile(
            dy: dy,
            dLateral: dLateral,
            yaw: yaw,
            pitchResidual: pitchResidual,
            residualPx: residualPx,
            timestamp: timestamp,
            cameraModel: cameraModel ?? self.cameraModel,
            cameraSerialNumber: cameraSerialNumber ?? self.cameraSerialNumber
        )
    }

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
