import Foundation
import ARKit
import simd
import Synchronization
import os

/// Records which parts of the room the LiDAR sweep actually looked at during a recording, as a
/// coarse free/surface grid (`SweepCoverageGrid`). It feeds the room-relocalization profile only:
/// "did this scan look here?" for the promotion gate and change detection, not fine geometry or
/// live guidance.
///
/// Cost discipline (the gen-8 lesson: a log-only probe that competed with ARKit for CPU corrupted
/// the scan it was measuring):
///   - `offer(_:)` runs on the ARSession delegate queue and never blocks. Frames are admitted by
///     `SweepFrameThrottle` (rate cap plus one-in-flight); anything else is dropped, never queued.
///   - The delegate queue copies out only the camera pose/intrinsics and a small depth/confidence
///     lattice (`sweepCoverageRayColumns` x `sweepCoverageRayRows`). No reference to the ARFrame
///     or its CVPixelBuffers survives `offer` — holding them starves ARKit's buffer pool.
///   - Ray building and grid integration run on a private `.utility` serial queue whose label ends
///     in `coverage`, so `ScanStats.currentCPUByThread` reports its cost as `coverage=N%` on the
///     [MemDiag] line. Per-update thread CPU is also measured directly.
///   - Accumulation always runs; only the diagnostic log line is PerfDiag-gated, so the artifact
///     exists in Release builds (same rationale as writeFeatureSidecar in VertexColorAccumulator).
///
/// Snap framing: frames are integrated only while tracking is `.normal`. Relocalizing,
/// initializing and limited states can move the world frame, and in a rescan the
/// pre-relocalization frames are in the wrong frame. The grid is deliberately NOT wiped on a
/// frame shift (unlike the VR voxel wipe in ARCoverageView): wiping would erase real coverage, and
/// the post-snap frames land in the corrected frame anyway.
///
/// Threading: `begin()` and `offer(_:)` on the delegate queue, `freezeAndSnapshot()` on main.
/// `grid`, `stats` and the cost accumulators are touched only on `queue`.
nonisolated final class SweepCoverageRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.arenaxr.scan4d.coverage", qos: .utility)
    private let accepting = Atomic<Bool>(false)
    private let gate = OSAllocatedUnfairLock(initialState: SweepFrameThrottle())

    /// Delegate-side counters for frames rejected before the throttle sees them.
    private struct SkipCounters {
        var skippedTracking: UInt32 = 0
        var skippedNoDepth: UInt32 = 0
        var depthEverAvailable = false
    }
    private let skips = OSAllocatedUnfairLock(initialState: SkipCounters())

    // MARK: Queue-owned state (only touched on `queue`)

    private var grid = SweepCoverageGrid()
    private var stats = SweepCoverageStats()
    private var updates = 0
    private var cpuTotalNs: UInt64 = 0
    private var cpuMaxNs: UInt64 = 0
    private var lastNs: UInt64 = 0
    private var firstUpdateWall: CFAbsoluteTime?

    /// Value-only copy of what one admitted frame contributes. Holds no ARKit references.
    private struct FrameSample {
        let transform: simd_float4x4
        let focalX: Float
        let focalY: Float
        let centerX: Float
        let centerY: Float
        let depths: [Float]
        let confidences: [UInt8]
        let pixels: [SIMD2<Int32>]   // depth-map (col, row) of each sample
    }

    init() {}

    /// Starts a fresh recording. Call from the ARSession delegate queue. The reset is enqueued
    /// before `accepting` flips, so on the serial queue every job admitted afterwards runs after it.
    func begin() {
        queue.async { [self] in
            grid.reset()
            stats = SweepCoverageStats()
            updates = 0
            cpuTotalNs = 0
            cpuMaxNs = 0
            lastNs = 0
            firstUpdateWall = nil
        }
        gate.withLock { $0.reset() }
        skips.withLock { $0 = SkipCounters() }
        accepting.store(true, ordering: .releasing)
    }

    /// Offers one ARKit frame. Runs on the delegate queue; cheap and non-blocking.
    func offer(_ frame: ARFrame) {
        guard accepting.load(ordering: .acquiring) else { return }

        let camera = frame.camera
        guard case .normal = camera.trackingState else {
            skips.withLock { $0.skippedTracking &+= 1 }
            return
        }
        // RoomPlan can drop .sceneDepth until reassertFrameSemantics re-adds it; Lite has none.
        guard let sceneDepth = frame.sceneDepth else {
            skips.withLock { $0.skippedNoDepth &+= 1 }
            return
        }
        skips.withLock { $0.depthEverAvailable = true }

        // Pattern match, not `==`: Decision's Equatable conformance is main-actor isolated
        // under the target's default isolation and cannot be used on the delegate queue.
        guard case .admitted = gate.withLock({ $0.offer(timestamp: frame.timestamp) }) else { return }

        // From here the in-flight slot is ours: every path must release it.
        guard let sample = Self.extractSample(
            camera: camera, depthMap: sceneDepth.depthMap, confidenceMap: sceneDepth.confidenceMap
        ) else {
            gate.withLock { $0.finish() }
            return
        }
        // `sample` holds only value arrays; the frame and pixel buffers are not captured.
        queue.async { [self] in
            defer { gate.withLock { $0.finish() } }
            process(sample)
        }
    }

    /// Stops accepting frames and returns the coverage so far. Call on MAIN at the Stop tap.
    /// The sync drains at most one in-flight job (a few hundred rays). The grid is not cleared
    /// here — the next `begin()` does — so stop(A) → snapshot A → begin(B) stays serialized.
    /// With no recording it returns an empty snapshot with all-zero stats.
    func freezeAndSnapshot() -> SweepCoverageSnapshot {
        accepting.store(false, ordering: .releasing)
        return queue.sync { [self] in
            let (droppedBusy, droppedRate) = gate.withLock { ($0.droppedBusy, $0.droppedRate) }
            let skip = skips.withLock { $0 }
            stats.framesDroppedBusy = droppedBusy
            stats.framesDroppedRate = droppedRate
            stats.framesSkippedTracking = skip.skippedTracking
            stats.framesSkippedNoDepth = skip.skippedNoDepth
            stats.depthEverAvailable = skip.depthEverAvailable
            PerfDiag.log("[Coverage] sweep FINAL " + diagnosticFields(
                droppedBusy: droppedBusy, droppedRate: droppedRate, skip: skip
            ) + " frames=\(stats.framesProcessed) rays=\(stats.raysIntegrated) truncated=\(stats.raysTruncated) lowconf=\(stats.raysLowConfidence) invalid=\(stats.raysInvalidDepth)")
            return grid.snapshot(stats: stats)
        }
    }

    // MARK: Delegate-queue extraction

    /// Copies the pose, depth-resolution intrinsics and a depth/confidence lattice out of the
    /// frame. Returns nil when the geometry is degenerate or the buffer cannot be read.
    private static func extractSample(camera: ARCamera, depthMap: CVPixelBuffer,
                                      confidenceMap: CVPixelBuffer?) -> FrameSample? {
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let imageWidth = Int(camera.imageResolution.width)
        let imageHeight = Int(camera.imageResolution.height)
        guard depthWidth > 0, depthHeight > 0, imageWidth > 0, imageHeight > 0,
              CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else { return nil }

        // Intrinsics are at capture resolution; rescale to depth-map pixels exactly like
        // PhotoCoverageGrid.DepthGeometry.
        let intrinsics = camera.intrinsics
        let scaleX = Float(depthWidth) / Float(imageWidth)
        let scaleY = Float(depthHeight) / Float(imageHeight)
        let focalX = intrinsics[0][0] * scaleX
        let focalY = intrinsics[1][1] * scaleY
        guard focalX > 0, focalY > 0 else { return nil }
        let centerX = intrinsics[2][0] * scaleX
        let centerY = intrinsics[2][1] * scaleY

        let columns = max(1, AppConstants.sweepCoverageRayColumns)
        let rows = max(1, AppConstants.sweepCoverageRayRows)
        let count = columns * rows
        var depths = [Float](); depths.reserveCapacity(count)
        var confidences = [UInt8](); confidences.reserveCapacity(count)
        var pixels = [SIMD2<Int32>](); pixels.reserveCapacity(count)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)

        // A nil confidence map (or one whose shape does not match) means every sample passes the
        // confidence check: report max confidence rather than dropping all depth.
        var confBase: UnsafeMutableRawPointer?
        var confRowBytes = 0
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            if CVPixelBufferGetWidth(confidenceMap) == depthWidth,
               CVPixelBufferGetHeight(confidenceMap) == depthHeight,
               CVPixelBufferGetPixelFormatType(confidenceMap) == kCVPixelFormatType_OneComponent8 {
                confBase = CVPixelBufferGetBaseAddress(confidenceMap)
                confRowBytes = CVPixelBufferGetBytesPerRow(confidenceMap)
            }
        }
        defer { if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) } }
        let assumedConfidence = UInt8(ARConfidenceLevel.high.rawValue)

        for r in 0..<rows {
            // Lattice-cell centre, clamped into the buffer.
            let row = min(depthHeight - 1, Int((Float(r) + 0.5) * Float(depthHeight) / Float(rows)))
            let depthRow = depthBase.advanced(by: row * depthRowBytes).assumingMemoryBound(to: Float32.self)
            let confRow = confBase?.advanced(by: row * confRowBytes).assumingMemoryBound(to: UInt8.self)
            for c in 0..<columns {
                let col = min(depthWidth - 1, Int((Float(c) + 0.5) * Float(depthWidth) / Float(columns)))
                depths.append(depthRow[col])
                confidences.append(confRow?[col] ?? assumedConfidence)
                pixels.append(SIMD2(Int32(col), Int32(row)))
            }
        }

        return FrameSample(transform: camera.transform, focalX: focalX, focalY: focalY,
                           centerX: centerX, centerY: centerY,
                           depths: depths, confidences: confidences, pixels: pixels)
    }

    // MARK: Queue work

    private func process(_ sample: FrameSample) {
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        if firstUpdateWall == nil { firstUpdateWall = CFAbsoluteTimeGetCurrent() }

        let transform = sample.transform
        let c3 = transform.columns.3
        let origin = SIMD3<Float>(c3.x, c3.y, c3.z)
        let minConfidence = AppConstants.sweepCoverageMinConfidence
        var rays = [SweepRay]()
        rays.reserveCapacity(sample.depths.count)
        var lowConfidence: UInt64 = 0

        for i in 0..<sample.depths.count {
            guard sample.confidences[i] >= minConfidence else {
                lowConfidence += 1
                continue
            }
            let meters = sample.depths[i]
            guard meters.isFinite, meters > 0 else {
                // Pass through so the grid counts it as invalid depth.
                rays.append(SweepRay(direction: SIMD3<Float>(0, 0, -1), depth: meters))
                continue
            }
            // PhotoCoverageGrid convention: camera looks down -Z, image row grows downward.
            let pixel = sample.pixels[i]
            let xCam = (Float(pixel.x) - sample.centerX) * meters / sample.focalX
            let yCam = (sample.centerY - Float(pixel.y)) * meters / sample.focalY
            let world4 = transform * SIMD4<Float>(xCam, yCam, -meters, 1)
            let v = SIMD3<Float>(world4.x, world4.y, world4.z) - origin
            let length = simd_length(v)
            let direction = length > 0 ? v / length : SIMD3<Float>(0, 0, 0)
            rays.append(SweepRay(direction: direction, depth: length))
        }

        let result = grid.integrate(origin: origin, rays: rays)
        stats.raysLowConfidence &+= lowConfidence
        stats.raysIntegrated &+= UInt64(result.raysIntegrated)
        stats.raysTruncated &+= UInt64(result.raysTruncated)
        stats.raysInvalidDepth &+= UInt64(result.raysInvalid)
        stats.framesProcessed &+= 1

        let elapsed = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpuStart
        updates += 1
        lastNs = elapsed
        cpuTotalNs &+= elapsed
        cpuMaxNs = max(cpuMaxNs, elapsed)

        let every = max(1, AppConstants.sweepCoverageLogEveryUpdates)
        if updates % every == 0, PerfDiag.enabled {
            let (droppedBusy, droppedRate) = gate.withLock { ($0.droppedBusy, $0.droppedRate) }
            let skip = skips.withLock { $0 }
            PerfDiag.log("[Coverage] sweep " + diagnosticFields(
                droppedBusy: droppedBusy, droppedRate: droppedRate, skip: skip))
        }
    }

    /// Shared field list for the periodic and FINAL lines. Queue-only.
    private func diagnosticFields(droppedBusy: UInt32, droppedRate: UInt32, skip: SkipCounters) -> String {
        let ms = { (ns: UInt64) in String(format: "%.2f", Double(ns) / 1_000_000) }
        let mean: UInt64 = updates > 0 ? cpuTotalNs / UInt64(updates) : 0
        let cpuSeconds = Double(cpuTotalNs) / 1_000_000_000
        var corePct = 0.0
        if let first = firstUpdateWall {
            let wall = CFAbsoluteTimeGetCurrent() - first
            if wall > 0 { corePct = cpuSeconds / wall * 100 }
        }
        return "updates=\(updates) cells=\(grid.cells.count) last=\(ms(lastNs))ms mean=\(ms(mean))ms max=\(ms(cpuMaxNs))ms "
            + "cpu_total=\(String(format: "%.2f", cpuSeconds))s (\(String(format: "%.1f", corePct))% of 1 core since first update) "
            + "drop_busy=\(droppedBusy) drop_rate=\(droppedRate) skip_tracking=\(skip.skippedTracking) skip_nodepth=\(skip.skippedNoDepth)"
    }
}
