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
        /// Uniform vertical (elevation) registration offset between the equirect rows and
        /// the latitude mapping, solved per scan as a 1-D nuisance (deg; + = image content
        /// sits lower than geometry predicts). Rig/mount-tilt dependent, NOT constant.
        let elevOffsetDeg: Float
    }

    // MARK: - Entry

    /// Solve the 4-DOF rig transform from calibration inputs.
    /// Call on a background queue. The prior provides the initial guess.
    /// Returns a failed result if no input contains mesh edges (solver has nothing to align).
    /// Geometry search box for the solve. Yaw is ALWAYS global (coarse circle scan) —
    /// only dy/dLateral/pitch are bounded, around either the mechanical prior (first
    /// solve) or a previously-solved profile (rolling refinement — run13/14 showed the
    /// geometry repeats across sessions within ~4 cm / 2°).
    struct SolveBounds {
        let anchorDy: Float
        let anchorLat: Float
        let dyHalf: Float
        let latHalf: Float
        let pitchHalfDeg: Float

        static let mechanical = SolveBounds(
            anchorDy: RigProfile.mechanicalPrior.dy, anchorLat: 0,
            dyHalf: AppConstants.calibrationBoundDyM,
            latHalf: AppConstants.calibrationBoundLateralM,
            pitchHalfDeg: AppConstants.calibrationBoundPitchDeg)

        static func refinement(around profile: RigProfile) -> SolveBounds {
            SolveBounds(anchorDy: profile.dy, anchorLat: profile.dLateral,
                        dyHalf: 0.15, latHalf: 0.15, pitchHalfDeg: 6)
        }
    }

    static func solve(inputs: [CalibrationInput], prior: RigProfile,
                      bounds: SolveBounds = .mechanical) -> CalibrationResult {
        // Guard: if no input has mesh edges, the solver has nothing to work with.
        let totalEdges = inputs.reduce(0) { $0 + $1.meshEdges.count }
        if totalEdges == 0 {
            return CalibrationResult(
                profile: prior, residualPx: -1,
                converged: false, iterations: 0, elevOffsetDeg: 0
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

        // Freeze the elevation-cut sample set at the ANCHOR pose (offline finding,
        // run12 bundle): when inclusion depends on the candidate, the optimizer GAMES
        // the cut — raising dy pushes awkward samples below the line where they cost
        // nothing (cost fell monotonically to the dy wall, retained samples 57%→23%).
        // With inclusion frozen, a real dy basin appears.
        let anchor = RigProfile.mechanicalPrior
        let sampleMasks = sampledInputs.map { input -> [Bool] in
            let rig = composeRigTransform(phoneToWorld: input.phoneToWorld,
                                          dy: anchor.dy, dLateral: 0, yaw: 0, pitchResidual: 0)
            let camPos = SIMD3<Float>(rig.columns.3.x, rig.columns.3.y, rig.columns.3.z)
            return anchorInclusionMask(edges: input.meshEdges, camPos: camPos)
        }

        // Coarse full-circle yaw scan (offline finding): the camera-frame cost gives yaw
        // a real basin, but a rectangular room aliases every ~90°, so a single local
        // descent lands in the wrong lobe. 24 cheap evals pick the best starts; local
        // Nelder-Mead runs from each within ±calibrationBoundYawDeg.
        var yawStarts: [(yaw: Float, cost: Float)] = []
        for step in 0..<24 {
            let yaw = -Float.pi + Float(step) * (2 * Float.pi / 24)
            let params = SIMD4<Float>(anchor.dy, 0, yaw, 0)
            yawStarts.append((yaw, totalCost(params: params, inputs: sampledInputs,
                                             masks: sampleMasks, stride: 3)))
        }
        yawStarts.sort { $0.cost < $1.cost }

        // ELEVATION-REGISTRATION nuisance (5th parameter, 1-D): a uniform vertical
        // offset between the equirect's rows and the latitude mapping — measured +5.6°
        // on the stand rig and ~+10° on the sagging handheld clamp (offline, 2026-07-31).
        // Pitch cannot absorb it (rotation: front-horizon down = back-horizon up) so dy
        // used to fake it (+0.3-0.5 m bias vs tape measure). Clean basin → cheap sweep
        // at the best coarse yaw; NM then solves geometry with the offset held fixed.
        var bestElevRows: Float = 0
        var bestElevCost = Float.greatestFiniteMagnitude
        for rows in Swift.stride(from: -16, through: 16, by: 2) {
            let params = SIMD4<Float>(anchor.dy, 0, yawStarts[0].yaw, 0)
            let cost = totalCost(params: params, inputs: sampledInputs, masks: sampleMasks,
                                 stride: 3, elevOffsetRows: Float(rows))
            if cost < bestElevCost { bestElevCost = cost; bestElevRows = Float(rows) }
        }
        // Keep the best starts at least 60° apart (distinct lobes, not one lobe thrice) —
        // and skip the runner-up entirely when the best lobe is decisive (>25% cheaper):
        // the second local descent roughly doubles solve time and, on a decisive
        // landscape, never wins (360post1: 60-70 s Debug postprocess solves).
        var starts: [Float] = []
        for cand in yawStarts where starts.allSatisfy({ abs(angleDelta(cand.yaw, $0)) > Float.pi / 3 }) {
            if starts.count == 1, cand.cost > yawStarts[0].cost * 1.15 { break }
            starts.append(cand.yaw)
            if starts.count >= 2 { break }
        }

        let yawHalf = AppConstants.calibrationBoundYawDeg * Float.pi / 180
        let pitchHalf = bounds.pitchHalfDeg * Float.pi / 180
        // Perturbation scales per parameter (order: dy, dLat, yaw, pitch)
        let scales = SIMD4<Float>(0.1, 0.05, 0.1, 0.05) // meters, meters, radians, radians

        var result: NMResult?
        for yaw0 in starts {
            let lo = SIMD4<Float>(bounds.anchorDy - bounds.dyHalf,
                                  bounds.anchorLat - bounds.latHalf,
                                  yaw0 - yawHalf,
                                  -pitchHalf)
            let hi = SIMD4<Float>(bounds.anchorDy + bounds.dyHalf,
                                  bounds.anchorLat + bounds.latHalf,
                                  yaw0 + yawHalf,
                                  pitchHalf)
            let x0 = SIMD4<Float>(bounds.anchorDy, bounds.anchorLat, yaw0, 0)
            let run = nelderMead(
                initial: x0,
                scales: scales,
                maxIterations: AppConstants.calibrationMaxIterations,
                tolerance: AppConstants.calibrationConvergenceTolerance
            ) { params in
                if any(params .< lo) || any(params .> hi) { return 1e6 }
                return totalCost(params: params, inputs: sampledInputs, masks: sampleMasks,
                                 elevOffsetRows: bestElevRows)
            }
            if result == nil || run.cost < result!.cost { result = run }
        }
        guard var result else {
            return CalibrationResult(profile: prior, residualPx: -1, converged: false,
                                     iterations: 0, elevOffsetDeg: 0)
        }
        // Normalize yaw to (−π, π] for storage/display.
        result = NMResult(point: SIMD4<Float>(result.point.x, result.point.y,
                                              normalizeAngle(result.point.z), result.point.w),
                          cost: result.cost, converged: result.converged,
                          iterations: result.iterations)

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
            iterations: result.iterations,
            elevOffsetDeg: bestElevRows * 180 / Float(sampledInputs.first?.edgeMap.height ?? 256)
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
            // Camera-frame projection — must match edgeCost's lookup exactly.
            let rot = simd_float3x3(
                SIMD3<Float>(rig.columns.0.x, rig.columns.0.y, rig.columns.0.z),
                SIMD3<Float>(rig.columns.1.x, rig.columns.1.y, rig.columns.1.z),
                SIMD3<Float>(rig.columns.2.x, rig.columns.2.y, rig.columns.2.z)
            ).transpose
            for edge in input.meshEdges {
                for i in 0..<4 {
                    let t = (Float(i) + 0.5) / 4
                    let point = edge.a + t * (edge.b - edge.a)
                    let dirWorld = simd_normalize(point - camPos)
                    if dirWorld.y < sinElevationCutoff { continue }   // masked from the solve — don't draw
                    let dir = rot * dirWorld
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

    /// Solve the SESSION yaw from a single still, holding the calibrated dy/dLat/pitch
    /// fixed. Run14 (rig untouched between sessions) proved the Theta re-derives its
    /// equirect yaw reference per session — the image "front" moved 103° with zero
    /// physical change — so yaw is NOT a persistable rig constant. dy/dLat/pitch repeat
    /// across sessions (Δ ≤ 3 cm / ~2°); yaw must be re-solved from each scan's first
    /// still. Coarse full-circle scan (15°) then two fine passes — ~46 cost evals, ms.
    static func solveSessionYaw(input: CalibrationInput, profile: RigProfile)
        -> (yaw: Float, residualPx: Float)? {
        guard !input.meshEdges.isEmpty else { return nil }
        let maxEdges = AppConstants.calibrationMaxEdgesPerInput
        let edges: [MeshEdge]
        if input.meshEdges.count <= maxEdges {
            edges = input.meshEdges
        } else {
            let step = max(1, input.meshEdges.count / maxEdges)
            edges = Swift.stride(from: 0, to: input.meshEdges.count, by: step)
                .prefix(maxEdges).map { input.meshEdges[$0] }
        }
        let sub = CalibrationInput(phoneToWorld: input.phoneToWorld,
                                   edgeMap: input.edgeMap, meshEdges: edges)
        let anchor = RigProfile.mechanicalPrior
        let rig = composeRigTransform(phoneToWorld: sub.phoneToWorld,
                                      dy: anchor.dy, dLateral: 0, yaw: 0, pitchResidual: 0)
        let camPos = SIMD3<Float>(rig.columns.3.x, rig.columns.3.y, rig.columns.3.z)
        let mask = anchorInclusionMask(edges: sub.meshEdges, camPos: camPos)

        func cost(_ yaw: Float) -> Float {
            totalCost(params: SIMD4<Float>(profile.dy, profile.dLateral,
                                           yaw, profile.pitchResidual),
                      inputs: [sub], masks: [mask])
        }
        var best: (yaw: Float, cost: Float) = (0, .greatestFiniteMagnitude)
        for step in 0..<24 {
            let yaw = -Float.pi + Float(step) * (2 * Float.pi / 24)
            let c = cost(yaw)
            if c < best.cost { best = (yaw, c) }
        }
        for halfSpanDeg in [Float(7.5), 1.5] {
            let halfSpan = halfSpanDeg * .pi / 180
            let step = halfSpan / 5
            var localBest = best
            var yaw = best.yaw - halfSpan
            while yaw <= best.yaw + halfSpan + 1e-6 {
                let c = cost(yaw)
                if c < localBest.cost { localBest = (yaw, c) }
                yaw += step
            }
            best = localBest
        }
        return (normalizeAngle(best.yaw), best.cost)
    }

        // MARK: - Cost function

    /// Smallest signed difference between two angles (radians).
    private static func angleDelta(_ a: Float, _ b: Float) -> Float {
        var d = a - b
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }

    /// Normalize an angle to (−π, π].
    private static func normalizeAngle(_ a: Float) -> Float {
        var v = a
        while v > .pi { v -= 2 * .pi }
        while v <= -.pi { v += 2 * .pi }
        return v
    }

    /// Elevation-cut inclusion per edge sample, evaluated ONCE at the anchor camera
    /// position (candidate-independent, so the optimizer can't game the cut). Layout:
    /// edges × 8 samples, flattened.
    static func anchorInclusionMask(edges: [MeshEdge], camPos: SIMD3<Float>) -> [Bool] {
        var mask = [Bool](repeating: false, count: edges.count * 8)
        for (e, edge) in edges.enumerated() {
            for i in 0..<8 {
                let t = (Float(i) + 0.5) / 8
                let point = edge.a + t * (edge.b - edge.a)
                let dir = simd_normalize(point - camPos)
                mask[e * 8 + i] = dir.y >= sinElevationCutoff
            }
        }
        return mask
    }

    /// Total cost across all calibration inputs for a candidate rig parameter set.
    /// `masks` is the anchor-frozen per-sample inclusion (see anchorInclusionMask).
    /// `stride` evaluates every Nth edge — the coarse yaw scan only ranks lobes, so it
    /// runs 3× cheaper without changing which basin wins.
    private static func totalCost(params: SIMD4<Float>, inputs: [CalibrationInput],
                                  masks: [[Bool]], stride: Int = 1,
                                  elevOffsetRows: Float = 0) -> Float {
        var total: Float = 0
        var count = 0
        for (k, input) in inputs.enumerated() {
            let rigTransform = composeRigTransform(
                phoneToWorld: input.phoneToWorld,
                dy: params.x, dLateral: params.y,
                yaw: params.z, pitchResidual: params.w
            )
            let camPos = SIMD3<Float>(rigTransform.columns.3.x,
                                     rigTransform.columns.3.y,
                                     rigTransform.columns.3.z)
            // World→camera rotation (transpose of the cam→world basis columns): the
            // equirect lookup happens in the CAMERA frame, so yaw and pitch genuinely
            // move the projection. (The old world-frame lookup made both parameters
            // literally unobservable — cost flat across ±180° of yaw; run12 bundle.)
            let rot = simd_float3x3(
                SIMD3<Float>(rigTransform.columns.0.x, rigTransform.columns.0.y, rigTransform.columns.0.z),
                SIMD3<Float>(rigTransform.columns.1.x, rigTransform.columns.1.y, rigTransform.columns.1.z),
                SIMD3<Float>(rigTransform.columns.2.x, rigTransform.columns.2.y, rigTransform.columns.2.z)
            ).transpose
            let mask = masks[k]
            for (e, edge) in input.meshEdges.enumerated() {
                guard stride == 1 || e % stride == 0 else { continue }
                if let cost = edgeCost(edge: edge, camPos: camPos, worldToCam: rot,
                                       edgeMap: input.edgeMap,
                                       mask: mask, maskBase: e * 8,
                                       elevOffsetRows: elevOffsetRows) {
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

    /// Cost of one mesh edge: sample points along the edge, project into the CAMERA
    /// frame, and mean the squared distance-transform lookups. Sample inclusion comes
    /// from the anchor-frozen `mask` (elevation cut evaluated once, candidate-
    /// independent); returns nil when every sample is masked so the edge drops out of
    /// the mean entirely.
    private static func edgeCost(edge: MeshEdge, camPos: SIMD3<Float>,
                                 worldToCam: simd_float3x3, edgeMap: EdgeMap,
                                 mask: [Bool], maskBase: Int,
                                 elevOffsetRows: Float = 0) -> Float? {
        let samples = 8
        var cost: Float = 0
        var counted = 0
        for i in 0..<samples {
            guard mask[maskBase + i] else { continue }
            let t = (Float(i) + 0.5) / Float(samples)
            let point = edge.a + t * (edge.b - edge.a)
            let dir = worldToCam * simd_normalize(point - camPos)
            let (eqX, eqY) = dirToEquirect(dir: dir, width: edgeMap.width, height: edgeMap.height)
            let col = max(0, min(edgeMap.width - 1, Int(eqX)))
            let row = max(0, min(edgeMap.height - 1, Int(eqY + elevOffsetRows)))
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
        // atan2(x, −z): PROPER chirality (device-verified 2026-07-31 — the old
        // atan2(x, z) sampled the equirect MIRRORED: whiteboard text read backwards in
        // pinhole re-renders; a rotation can never mirror, so every solve was matching
        // flipped geometry) AND front-centered, matching EquirectFaceExport's sampler —
        // the solver and the face cut now share one convention, closing the 180°
        // solver-vs-export yaw question.
        let lon = atan2(dir.x, -dir.z)
        let eqX = (lon + .pi) / (2 * .pi) * Float(width)
        let eqY = (.pi / 2 - lat) / .pi * Float(height)
        return (eqX, eqY)
    }

    // MARK: - Saved-mesh edge extraction (post-process solve)

    /// A parsed mesh.obj (RAW capture frame — the post-process solve runs BEFORE
    /// registration bakes the file). Parsed once per scan, queried per still position.
    struct SavedMeshOBJ {
        let vertices: [SIMD3<Float>]
        let faces: [[UInt32]]

        static func load(objURL: URL) -> SavedMeshOBJ? {
            guard let text = try? String(contentsOf: objURL, encoding: .utf8) else { return nil }
            var vertices: [SIMD3<Float>] = []
            var faces: [[UInt32]] = []
            for line in text.split(separator: "\n") {
                if line.hasPrefix("v ") {
                    let parts = line.split(separator: " ")
                    guard parts.count >= 4,
                          let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3])
                    else { continue }
                    vertices.append(SIMD3<Float>(x, y, z))
                } else if line.hasPrefix("f ") {
                    // "f v", "f v/vt", "f v/vt/vn", "f v//vn" — vertex index is the first field,
                    // 1-based; negative (relative) indices are not produced by our exporter.
                    let idx = line.split(separator: " ").dropFirst().compactMap { part -> UInt32? in
                        guard let first = part.split(separator: "/").first,
                              let v = Int(first), v > 0 else { return nil }
                        return UInt32(v - 1)
                    }
                    if idx.count >= 3 { faces.append(idx) }
                }
            }
            guard !vertices.isEmpty, !faces.isEmpty else { return nil }
            return SavedMeshOBJ(vertices: vertices, faces: faces)
        }
    }

    /// Same semantics as the live-anchor variant — every deduplicated polygon edge with
    /// at least one endpoint within `radius` of a position — extracted for ALL positions
    /// in ONE pass over the faces (the face loop dominates; 360post2's prep spent ~20 s
    /// running it once per still).
    static func extractMeshEdges(mesh: SavedMeshOBJ, nearAll positions: [SIMD3<Float>],
                                 radius: Float) -> [[MeshEdge]] {
        var edges = [[MeshEdge]](repeating: [], count: positions.count)
        var edgeSets = [Set<UInt64>](repeating: [], count: positions.count)
        let verts = mesh.vertices
        for face in mesh.faces {
            guard face.allSatisfy({ Int($0) < verts.count }) else { continue }
            for (p, position) in positions.enumerated() {
                let near = face.contains { simd_distance(verts[Int($0)], position) <= radius }
                guard near else { continue }
                for i in 0..<face.count {
                    let a = face[i], b = face[(i + 1) % face.count]
                    let key = a < b ? (UInt64(a) << 32 | UInt64(b)) : (UInt64(b) << 32 | UInt64(a))
                    guard edgeSets[p].insert(key).inserted else { continue }
                    edges[p].append(MeshEdge(a: verts[Int(a)], b: verts[Int(b)]))
                }
            }
        }
        return edges
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
        // per-sample skip; the post-process solve shares this path.
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

    /// Same geometry with a substituted (per-session) yaw.
    func replacingYaw(_ yaw: Float) -> RigProfile {
        RigProfile(dy: dy, dLateral: dLateral, yaw: yaw, pitchResidual: pitchResidual,
                   residualPx: residualPx, timestamp: timestamp,
                   cameraModel: cameraModel, cameraSerialNumber: cameraSerialNumber)
    }

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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970   // CONTRIBUTING → Units & time
        return try? decoder.decode(RigProfile.self, from: data)
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970   // CONTRIBUTING → Units & time
        guard let data = try? encoder.encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}
