import CoreGraphics
import Foundation
import ImageIO
import simd

/// The full photometric rig solver (v15) — EquirectYawAnchor grown up, exactly as the
/// offline A/B recommended (`tools/rigcal-ab/`, 2026-08-19, all 23 field bundles).
///
/// THE COST. Unproject each keyframe's depth into world points that carry their own
/// brightness, project them into every selected still through the candidate rig transform
/// (the same `composeRigTransform` / `dirToEquirect` the rest of the pipeline uses), and
/// score 1 − trimmed-mean ZNCC per (keyframe, still) pair. ZNCC per PAIR, not pooled:
/// exposure differs between keyframes and between stills, and zero-normalising per pair is
/// what makes brightness comparable at all. The worst 20% of pairs are dropped — a pair can
/// legitimately fail (occlusion the depth didn't capture, a person who moved) without the
/// solve caring.
///
/// WHY IT REPLACED THE EDGE COST. On the archive it solves the glass room natively (+0.9°,
/// where the edge cost needed v13's clamp to avoid a 50° miss — reflections are edges that
/// move with the camera, but they are not photometrically consistent with keyframes), it
/// solves the weak-geometry scans the edge cost triple-railed, and it needs ZERO elevation
/// nuisance on 22 of 23 bundles INCLUDING the old-era scans where the edge cost railed at
/// ±11.25° — that offset was absorbing mesh/model error the image never had. No mesh, no
/// edge extraction, no distance transform, no inclusion masks, no elevation sweep.
///
/// WHAT IT DOES NOT MEASURE: rod length, same as the edge cost. Freed of the tape it
/// biases LOW (median −3 cm on the archive) where the edge cost biased HIGH (+8 to +10
/// against ground truth) — opposite pulls, one lesson: the tape owns that axis, and the
/// solve stays inside the v14 cylinder. NOTE the rod-rail direction semantics therefore
/// FLIP versus v14: this cost's known pull rides the tape's LOWER wall.
///
/// QUALITY METRIC: per-still yaw agreement. After the joint solve, each still re-solves
/// yaw alone at the solved offset; the spread across stills is the honest confidence
/// number (archive: 1.0–4.5° healthy, 7.5° on the weakest scans). Above
/// `photometricYawSpreadMaxDeg` the solve is rejected and the prior ships instead —
/// unlike a residual, this cannot be flattered by having fewer inputs.
enum PhotometricRigSolver {

    struct Result {
        let profile: RigProfile
        /// Trimmed-mean ZNCC at the solution (higher is better; archive 0.51–0.77).
        let zncc: Float
        /// Max−min of per-still yaw re-solves at the solved offset (degrees).
        let yawSpreadDeg: Float
        /// The coarse full-circle winner — handed to the edge-cost compare run as its
        /// anchor so the two solvers are compared inside the same basin.
        let coarseYawRad: Float
        let converged: Bool
        let iterations: Int
        let usedStills: Int
        /// True when fewer than 4 usable stills forced a yaw-only solve at the tape
        /// anchor (geometry needs baseline; yaw only needs one still's content).
        let yawOnly: Bool
    }

    private struct Gray {
        let pixels: [Float]
        let width: Int
        let height: Int
    }

    private struct StillData {
        let phoneToWorld: simd_float4x4
        let gray: Gray
        let mask: OperatorRigMask.Mask?
    }

    // MARK: - Entry

    /// `stills` are the solve set (steadiest-first, capped) — jpg + capture-time phone pose.
    static func solve(stills: [(jpgURL: URL, phoneToWorld: simd_float4x4)],
                      rawDataDir: URL,
                      bounds: RigCalibrationSolver.SolveBounds,
                      report: (String) -> Void) -> Result? {
        let groups = EquirectYawAnchor.keyframeSampleGroups(
            rawDataDir: rawDataDir,
            maxFrames: AppConstants.photometricKeyframes,
            pixelStride: AppConstants.photometricPixelStride)
        let sampleCount = groups.reduce(0) { $0 + $1.count }
        guard sampleCount >= 500 else {
            report("Photometric solve unavailable (\(sampleCount) keyframe points) — prior poses ship")
            return nil
        }
        var data: [StillData] = []
        for still in stills {
            guard let gray = gray(at: still.jpgURL, maxPixel: AppConstants.photometricStillMaxPixel)
            else { continue }
            let maskURL = rawDataDir.appendingPathComponent("equirect_masks")
                .appendingPathComponent(still.jpgURL.deletingPathExtension()
                    .appendingPathExtension("png").lastPathComponent)
            data.append(StillData(phoneToWorld: still.phoneToWorld, gray: gray,
                                  mask: OperatorRigMask.load(pngAt: maskURL)))
        }
        guard !data.isEmpty else { return nil }

        // Coarse full-circle yaw at the tape anchor — the basin choice, absolute because
        // the keyframes are. 5° steps: the offline run showed basins far wider than that.
        var coarse: (yaw: Float, cost: Float) = (0, .greatestFiniteMagnitude)
        var step: Float = -.pi
        while step < .pi {
            let c = cost(t: bounds.anchorOffset, yaw: step, stills: data, groups: groups)
            if c < coarse.cost { coarse = (step, c) }
            step += 5 * .pi / 180
        }

        let yawOnly = data.count < 4
        var point = [bounds.anchorOffset.x, bounds.anchorOffset.y, bounds.anchorOffset.z, coarse.yaw]
        var iterations = 0
        var converged = true
        if yawOnly {
            // Geometry needs baseline; with <4 stills hold the offset at the tape anchor
            // and refine yaw alone (0.75° golden-ratio-free fine scan around the basin).
            var best: (yaw: Float, cost: Float) = coarse
            var y = coarse.yaw - 6 * Float.pi / 180
            while y <= coarse.yaw + 6 * Float.pi / 180 {
                let c = cost(t: bounds.anchorOffset, yaw: y, stills: data, groups: groups)
                if c < best.cost { best = (y, c) }
                y += 0.75 * .pi / 180
            }
            point[3] = best.yaw
        } else {
            let yawWindow = AppConstants.yawAnchorWindowDeg * Float.pi / 180
            let clamped: ([Float]) -> Float = { v in
                let t = SIMD3<Float>(v[0], v[1], v[2])
                let e = bounds.excursion(t)
                if e.along > bounds.alongHalf || e.across > bounds.acrossHalf { return 3 }
                if abs(v[3] - coarse.yaw) > yawWindow { return 3 }
                return cost(t: t, yaw: v[3], stills: data, groups: groups)
            }
            let run = nelderMead(initial: point, scales: [0.02, 0.02, 0.02, 0.08],
                                 maxIterations: 160, tolerance: 1e-4, cost: clamped)
            point = run.point
            iterations = run.iterations
            converged = run.converged
        }
        let solvedT = SIMD3<Float>(point[0], point[1], point[2])
        let solvedYaw = normalize(point[3])
        let finalCost = cost(t: solvedT, yaw: solvedYaw, stills: data, groups: groups)

        // Per-still yaw agreement at the solved offset — the quality metric.
        var perStill: [Float] = []
        for index in data.indices {
            var best: (yaw: Float, cost: Float) = (solvedYaw, .greatestFiniteMagnitude)
            var y = solvedYaw - 12 * Float.pi / 180
            while y <= solvedYaw + 12 * Float.pi / 180 {
                let c = cost(t: solvedT, yaw: y, stills: data, groups: groups, only: index)
                if c < best.cost { best = (y, c) }
                y += 0.75 * .pi / 180
            }
            perStill.append((best.yaw - solvedYaw) * 180 / .pi)
        }
        let spread = (perStill.max() ?? 0) - (perStill.min() ?? 0)

        let profile = RigProfile(
            offsetPhone: solvedT,
            yaw: solvedYaw,
            pitchResidual: 0,
            // The persistence slot wants "≥0, finite, lower is better" (isSolved gate).
            // 1 − ZNCC is exactly that; it is NOT pixels and solver ≥15 no longer writes
            // residual_px_rms to the sidecar.
            residualPx: 1 - finalCost >= -1 ? finalCost : 2,
            timestamp: Date(),
            cameraModel: nil,
            cameraSerialNumber: nil)
        return Result(profile: profile, zncc: 1 - finalCost, yawSpreadDeg: spread,
                      coarseYawRad: coarse.yaw, converged: converged,
                      iterations: iterations, usedStills: data.count, yawOnly: yawOnly)
    }

    // MARK: - Cost

    private static func cost(t: SIMD3<Float>, yaw: Float,
                             stills: [StillData], groups: [[EquirectYawAnchor.Sample]],
                             only: Int? = nil) -> Float {
        var znccs: [Float] = []
        znccs.reserveCapacity(stills.count * groups.count)
        for (index, still) in stills.enumerated() {
            if let only, index != only { continue }
            let rig = RigCalibrationSolver.composeRigTransform(
                phoneToWorld: still.phoneToWorld, offsetPhone: t, yaw: yaw, pitchResidual: 0)
            let camPos = SIMD3<Float>(rig.columns.3.x, rig.columns.3.y, rig.columns.3.z)
            let rot = simd_float3x3(
                SIMD3<Float>(rig.columns.0.x, rig.columns.0.y, rig.columns.0.z),
                SIMD3<Float>(rig.columns.1.x, rig.columns.1.y, rig.columns.1.z),
                SIMD3<Float>(rig.columns.2.x, rig.columns.2.y, rig.columns.2.z)).transpose
            let width = still.gray.width, height = still.gray.height
            for group in groups {
                var n = 0
                var sumA: Float = 0, sumB: Float = 0
                var sumAA: Float = 0, sumBB: Float = 0, sumAB: Float = 0
                for sample in group {
                    let local = rot * (sample.world - camPos)
                    let length = simd_length(local)
                    guard length > 0.3 else { continue }
                    let (ex, ey) = RigCalibrationSolver.dirToEquirect(
                        dir: local / length, width: width, height: height)
                    let x = min(max(Int(ex), 0), width - 1)
                    let y = min(max(Int(ey), 0), height - 1)
                    if let mask = still.mask {
                        let mx = min(mask.width - 1, x * mask.width / width)
                        let my = min(mask.height - 1, y * mask.height / height)
                        if mask.bytes[my * mask.width + mx] == 0 { continue }
                    }
                    let a = still.gray.pixels[y * width + x]
                    let b = sample.gray
                    n += 1
                    sumA += a; sumB += b
                    sumAA += a * a; sumBB += b * b; sumAB += a * b
                }
                guard n >= AppConstants.photometricMinPairSamples else { continue }
                let fn = Float(n)
                let meanA = sumA / fn, meanB = sumB / fn
                let varA = max(0, sumAA / fn - meanA * meanA)
                let varB = max(0, sumBB / fn - meanB * meanB)
                guard varA > 1e-8, varB > 1e-8 else { continue }
                znccs.append((sumAB / fn - meanA * meanB) / (varA * varB).squareRoot())
            }
        }
        guard !znccs.isEmpty else { return 2 }
        znccs.sort()
        let keep = max(1, Int(Float(znccs.count) * (1 - AppConstants.photometricTrimFrac)))
        let kept = znccs.suffix(keep)
        return 1 - kept.reduce(0, +) / Float(kept.count)
    }

    // MARK: - Optimizer (4-D Nelder-Mead; small and local, matching the offline harness)

    private static func nelderMead(initial: [Float], scales: [Float], maxIterations: Int,
                                   tolerance: Float, cost: ([Float]) -> Float)
        -> (point: [Float], converged: Bool, iterations: Int) {
        let n = initial.count
        var simplex: [(point: [Float], cost: Float)] = [(initial, cost(initial))]
        for d in 0..<n {
            var v = initial; v[d] += scales[d]
            simplex.append((v, cost(v)))
        }
        func combine(_ a: [Float], _ b: [Float], _ w: Float) -> [Float] {
            zip(a, b).map { $0 + w * ($1 - $0) }
        }
        var iteration = 0
        var converged = false
        while iteration < maxIterations {
            iteration += 1
            simplex.sort { $0.cost < $1.cost }
            if simplex[n].cost - simplex[0].cost < tolerance { converged = true; break }
            var centroid = [Float](repeating: 0, count: n)
            for i in 0..<n {
                for d in 0..<n { centroid[d] += simplex[i].point[d] / Float(n) }
            }
            let worst = simplex[n]
            let reflected = combine(worst.point, centroid, 2)
            let fr = cost(reflected)
            if fr < simplex[0].cost {
                let expanded = combine(centroid, reflected, 2)
                let fe = cost(expanded)
                simplex[n] = fe < fr ? (expanded, fe) : (reflected, fr)
            } else if fr < simplex[n - 1].cost {
                simplex[n] = (reflected, fr)
            } else {
                let contracted = combine(centroid, worst.point, 0.5)
                let fc = cost(contracted)
                if fc < worst.cost {
                    simplex[n] = (contracted, fc)
                } else {
                    for i in 1...n {
                        let shrunk = combine(simplex[0].point, simplex[i].point, 0.5)
                        simplex[i] = (shrunk, cost(shrunk))
                    }
                }
            }
        }
        simplex.sort { $0.cost < $1.cost }
        return (simplex[0].point, converged, iteration)
    }

    private static func normalize(_ angle: Float) -> Float {
        var a = angle
        while a > .pi { a -= 2 * .pi }
        while a <= -.pi { a += 2 * .pi }
        return a
    }

    /// Downsampled grayscale (same decode the anchor uses; kept local because the
    /// anchor's is private and this file outlives the anchor's own solve path).
    private static func gray(at url: URL, maxPixel: Int) -> Gray? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Gray(pixels: bytes.map { Float($0) / 255 }, width: width, height: height)
    }
}
