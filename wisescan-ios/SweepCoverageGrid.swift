import Foundation
import simd

/// Per-cell sweep observation counters.
///
/// - `free`: number of frame updates in which some ray passed *through* the cell.
/// - `surface`: number of updates in which some ray *ended* in a depth hit in the cell.
/// - `visits`: number of updates that touched the cell in either state.
///
/// All three are de-duplicated within one update (an update counts at most once per counter)
/// and saturate at `UInt16.max` rather than wrapping.
struct SweepCoverageCell: Equatable {
    var free: UInt16 = 0
    var surface: UInt16 = 0
    var visits: UInt16 = 0

    /// Real saturating add: clamps at `UInt16.max`. Never `&+=` — a wrap to 0 would turn a
    /// heavily observed cell into a "never looked" cell.
    static func saturatingIncrement(_ v: inout UInt16) {
        if v < UInt16.max { v += 1 }
    }
}

/// Producer-side counters for the sweep-coverage pipeline (frames and rays accepted / dropped).
struct SweepCoverageStats: Equatable {
    var framesProcessed: UInt32 = 0
    var framesDroppedBusy: UInt32 = 0
    var framesDroppedRate: UInt32 = 0
    var framesSkippedTracking: UInt32 = 0
    var framesSkippedNoDepth: UInt32 = 0
    var raysIntegrated: UInt64 = 0
    var raysTruncated: UInt64 = 0
    var raysLowConfidence: UInt64 = 0
    var raysInvalidDepth: UInt64 = 0
    var depthEverAvailable: Bool = false
}

/// Immutable copy of the grid plus stats, safe to hand across threads.
struct SweepCoverageSnapshot: Equatable {
    var cellSize: Float
    var cells: [SIMD3<Int32>: SweepCoverageCell]
    var stats: SweepCoverageStats

    static func empty(cellSize: Float = AppConstants.sweepCoverageCellSize) -> SweepCoverageSnapshot {
        SweepCoverageSnapshot(cellSize: cellSize, cells: [:], stats: SweepCoverageStats())
    }
}

/// One depth ray: `direction` is a world-frame unit vector, `depth` is metres along it.
struct SweepRay {
    var direction: SIMD3<Float>
    var depth: Float
}

/// Per-call outcome of `SweepCoverageGrid.integrate`.
struct SweepIntegrateResult: Equatable {
    var raysIntegrated = 0
    var raysTruncated = 0
    var raysInvalid = 0
    var cellsTouched = 0
}

/// Sparse voxel record of where the capture has *looked*: free space each depth ray passed
/// through, and the surface cell it ended in.
///
/// **Source.** Derived from camera poses + scene depth, NEVER from ARKit feature points. This is
/// the null-case field for change detection: zero coverage = no claim possible (we never looked,
/// so absence of a feature or surface means nothing); nonzero = we looked.
///
/// **Profile.** This is the ROOM-RELOCALIZATION profile's input — any observation per cell counts.
/// Direction-binned / GSD coverage for detailed partial capture is a planned later layer and is
/// NOT built here.
///
/// **Achievability is not built.** The planned pass — erode OBSERVED-FREE by device clearance,
/// then flood-fill from the camera trajectory — is not implemented. `free` and `surface` are kept
/// as separate counters precisely so that pass can run on `free` later.
///
/// **Frame.** Cells are in the scan's RAW capture frame, co-framed with `cameras/` at capture
/// time. The grid is NOT snap-corrected the way the saved mesh is (`exportMeshOBJ` re-pins
/// anchors at save) and is NOT `mesh.obj`'s canonical frame.
///
/// **Binning.** Origin-anchored floor binning (`floor(p / cellSize)` per axis) — never
/// truncation, never bbox-relative — so it lines up with the promotion gate's `floor(p/0.5)` bins.
struct SweepCoverageGrid {
    let cellSize: Float
    private(set) var cells: [SIMD3<Int32>: SweepCoverageCell] = [:]

    init(cellSize: Float = AppConstants.sweepCoverageCellSize) {
        self.cellSize = cellSize
    }

    /// Origin-anchored floor binning: `floor(p / cellSize)` per axis. -0.1 → -1, not 0.
    static func cellKey(_ p: SIMD3<Float>, cellSize: Float) -> SIMD3<Int32> {
        let q = (p / cellSize).rounded(.down)
        return SIMD3<Int32>(Int32(q.x), Int32(q.y), Int32(q.z))
    }

    /// Amanatides-Woo voxel traversal from `a` to `b`, visiting every cell the segment crosses.
    ///
    /// Robustness: the step count is fixed up front as the Manhattan distance between the start
    /// and end cells, so float drift can never loop forever or overshoot, and the end cell is
    /// always the last one visited. Each step advances exactly one axis by ±1 (ties break
    /// x, then y, then z). Axes with no remaining steps are never consulted, so a zero
    /// direction component never produces `inf * 0 = NaN`. A zero-length segment, or one that
    /// ends in its own cell, visits only the start cell.
    static func traverse(from a: SIMD3<Float>, to b: SIMD3<Float>, cellSize: Float,
                         visit: (SIMD3<Int32>) -> Void) {
        let start = cellKey(a, cellSize: cellSize)
        let end = cellKey(b, cellSize: cellSize)
        var idx = start
        visit(idx)

        let d = b - a
        var remaining = SIMD3<Int32>(0, 0, 0)
        var step = SIMD3<Int32>(0, 0, 0)
        var tMax = SIMD3<Float>(repeating: .infinity)
        var tDelta = SIMD3<Float>(repeating: .infinity)
        for axis in 0..<3 {
            let diff = end[axis] - start[axis]
            remaining[axis] = abs(diff)
            guard diff != 0 else { continue }
            step[axis] = diff > 0 ? 1 : -1
            let da = d[axis]
            // diff != 0 implies a and b sit in different cells on this axis, so da != 0.
            let boundary: Float = diff > 0
                ? Float(idx[axis] + 1) * cellSize
                : Float(idx[axis]) * cellSize
            tMax[axis] = (boundary - a[axis]) / da
            tDelta[axis] = cellSize / abs(da)
        }

        var stepsLeft = Int(remaining.x) + Int(remaining.y) + Int(remaining.z)
        while stepsLeft > 0 {
            var best = -1
            for axis in 0..<3 where remaining[axis] > 0 {
                if best < 0 || tMax[axis] < tMax[best] { best = axis }
            }
            // stepsLeft > 0 guarantees some axis has remaining > 0.
            idx[best] += step[best]
            remaining[best] -= 1
            tMax[best] += tDelta[best]
            stepsLeft -= 1
            visit(idx)
        }
    }

    /// Integrate one frame update: `rays` cast from `origin` (world frame).
    ///
    /// Invalid rays (non-finite or ≤ `minDepth` depth, non-finite or zero direction) are counted
    /// and skipped. Rays deeper than `maxRange` are truncated at the cap: free space all the way,
    /// no surface. Every counter is incremented at most once per cell per call.
    @discardableResult
    mutating func integrate(origin: SIMD3<Float>, rays: [SweepRay],
                            maxRange: Float = AppConstants.sweepCoverageMaxRange,
                            minDepth: Float = AppConstants.sweepCoverageMinDepth) -> SweepIntegrateResult {
        var result = SweepIntegrateResult()
        var freeSet = Set<SIMD3<Int32>>()
        var surfaceSet = Set<SIMD3<Int32>>()
        let size = cellSize

        for ray in rays {
            let dir = ray.direction
            let dirLen = simd_length(dir)
            guard ray.depth.isFinite, ray.depth > minDepth,
                  dir.x.isFinite, dir.y.isFinite, dir.z.isFinite,
                  dirLen.isFinite, dirLen > 0 else {
                result.raysInvalid += 1
                continue
            }
            let hit = ray.depth <= maxRange
            let endpoint = origin + dir * (hit ? ray.depth : maxRange)
            if !hit { result.raysTruncated += 1 }
            result.raysIntegrated += 1

            var previous: SIMD3<Int32>?
            Self.traverse(from: origin, to: endpoint, cellSize: size) { key in
                if let p = previous { freeSet.insert(p) }
                previous = key
            }
            if let last = previous {
                if hit { surfaceSet.insert(last) } else { freeSet.insert(last) }
            }
        }

        let touched = freeSet.union(surfaceSet)
        for key in touched {
            var cell = cells[key] ?? SweepCoverageCell()
            if freeSet.contains(key) { SweepCoverageCell.saturatingIncrement(&cell.free) }
            if surfaceSet.contains(key) { SweepCoverageCell.saturatingIncrement(&cell.surface) }
            SweepCoverageCell.saturatingIncrement(&cell.visits)
            cells[key] = cell
        }
        result.cellsTouched = touched.count
        return result
    }

    func snapshot(stats: SweepCoverageStats) -> SweepCoverageSnapshot {
        SweepCoverageSnapshot(cellSize: cellSize, cells: cells, stats: stats)
    }

    mutating func reset() {
        cells.removeAll()
    }
}
