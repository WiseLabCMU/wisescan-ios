import Foundation
import ARKit
import simd

/// Mid-scan tracking-stability detector (Phase 2.1 build order item 2; see docs/fix-localization-plan.md).
///
/// **What this is — corrected by device testing (2026-06-25).** The original premise was "a mid-scan snap
/// splits the *saved mesh*." That turned out **false for this pipeline**: `exportMeshOBJ` rebuilds the OBJ
/// at save time from each `ARMeshAnchor`'s *current* (re-pinned) transform, and ARKit re-pins all anchors
/// consistently on a correction — so a single loop-closure snap leaves the saved mesh clean (confirmed: a
/// scan with an 11 cm snap AND a 2.4 m degraded bounce produced a clean mesh). See
/// [[saved-mesh-repins-immune-to-snaps]]. So a **single** snap is benign and must not warn.
///
/// **What it IS good for: a snap *storm* = session collapse the VIO guard misses.** When a space is
/// self-similar (repeating desks, a corridor), ARKit's relocalizer flip-flops between two identical-looking
/// locations — the camera pose oscillates by tens of cm *every frame* (observed: `71→22→71→22 cm`, dozens of
/// times) **while tracking still reports `.normal`.** The VIO starvation guard never trips (it keys on
/// degraded states), so nothing catches this "broken-but-reports-normal" collapse. A burst of non-physical
/// jumps in a short window is the signature, and it's a real "this scan is unreliable" signal.
///
/// **The per-jump discriminator: non-physical velocity between two `.normal` frames.** A handheld scanner
/// never moves faster than a few m/s; a single-frame camera jump implying >`snapVelocity` m/s is not motion,
/// it's the world frame being re-pinned. Gating on `.normal`→`.normal` excludes degraded-junk poses (the VIO
/// guard owns the degraded-*loss* path) and catches the continuous-normal loop-closure jump `SnapTracker`
/// couldn't. A frame-delivery gap (`dt > maxDt`) resets the monitor (the delta across a gap is accumulated
/// motion, not a discontinuity) — kills the dropped-frame false positive. **A storm is then ≥`stormThreshold`
/// such jumps within `stormWindow` seconds** — that, not any single jump, is what flags the scan.
///
/// Pure logic, no `PerfDiag` gate. The *surfacing* (warning) is gated by the caller during dev validation.
struct TrackingStabilityMonitor {
    /// A confirmed mid-scan frame discontinuity (one non-physical jump). `stormActive` says whether
    /// enough of these have clustered to call the session destabilized; a lone jump is benign.
    struct Snap {
        let dPosM: Float
        let dRotDeg: Float
        let velocityMS: Float
        let stormActive: Bool        // ≥ stormThreshold jumps within stormWindow are now in play
        let stormJustTriggered: Bool // this jump is the one that crossed the threshold (log it once)
    }

    /// Per-scan accumulators (reset at `reset()`).
    private(set) var snapCount = 0
    private(set) var maxSnapPosM: Float = 0
    private(set) var maxSnapRotDeg: Float = 0
    private(set) var stormActive = false

    private var prevPos: SIMD3<Float>?
    private var prevRot: simd_quatf?
    private var prevTimestamp: TimeInterval = 0
    private var prevNormal = false
    /// Timestamps of recent jumps, pruned to `stormWindow` — a storm is a cluster, not a lifetime count
    /// (a long scan with a few isolated benign jumps must not read as a storm).
    private var recentSnapTimes: [TimeInterval] = []

    // Tuning — deliberately conservative so a fire is almost certainly a real correction, not motion.
    /// Frames must be this close together to compare (consecutive ~16–33 ms frames). A wider gap is a
    /// frame-delivery stall: the delta across it is accumulated motion, not a single-frame discontinuity.
    private static let maxDt: TimeInterval = 0.05
    /// Linear velocity above which a one-frame jump can't be hand motion (≈ 22 km/h handheld). The
    /// world-frame re-pin shows up as exactly this kind of impossible instantaneous speed.
    private static let snapVelocity: Float = 6.0   // m/s
    /// Absolute floor so sub-cm jitter scaled by a tiny `dt` can't read as high velocity.
    private static let minSnapPos: Float = 0.08    // m
    /// Rotational counterparts (≈ 1 full turn/sec is already implausible for a deliberate scan sweep).
    private static let snapAngularVel: Float = 350 // deg/s
    private static let minSnapRotDeg: Float = 18
    /// Storm = a *cluster* of jumps, not any single one (a lone snap is benign — the mesh re-pins).
    /// ≥`stormThreshold` non-physical jumps within `stormWindow` s ⇒ session destabilizing. Observed:
    /// the self-similar-room collapse fired dozens in seconds; a clean scan fires 0–1. (Internal, not
    /// private, so the caller can quote them in the storm log.)
    static let stormWindow: TimeInterval = 3.0
    static let stormThreshold = 4

    /// Feed each frame's camera transform during **recording** (the only phase where committed geometry
    /// is at stake). Returns a `Snap` on each confirmed non-physical jump (with storm state), else nil.
    /// Call on the AR delegate queue (where the frame lives); the caller hops to main to set the flag.
    mutating func observe(_ transform: simd_float4x4,
                          tracking: ARCamera.TrackingState,
                          timestamp: TimeInterval) -> Snap? {
        let pos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let rot = simd_quatf(transform)
        let nowNormal = (tracking == .normal)
        defer { prevPos = pos; prevRot = rot; prevTimestamp = timestamp; prevNormal = nowNormal }

        guard let pp = prevPos, let pr = prevRot, prevTimestamp > 0 else { return nil }
        let dt = timestamp - prevTimestamp
        // A frame gap (compute stall / pause) breaks the consecutive-frame assumption — the delta is
        // motion accumulated over the gap, not an instantaneous snap. Skip; prev is refreshed via defer.
        guard dt > 0, dt <= Self.maxDt else { return nil }
        // Only a normal→normal discontinuity is a trustworthy persistent snap. While tracking is
        // degraded the pose is junk (and the VIO guard owns that path), and the recovery-into-normal
        // jump is measured against a junk pose — so we require BOTH frames normal. This is the case
        // SnapTracker explicitly could not catch (a loop closure under continuous normal tracking).
        guard nowNormal, prevNormal else { return nil }

        let dPos = simd_distance(pos, pp)
        let dot = min(1, abs(simd_dot(rot.vector, pr.vector)))
        let dRotDeg = (2 * acos(dot)) * 180 / .pi
        let velocity = dPos / Float(dt)
        let angularVel = dRotDeg / Float(dt)

        let posSnap = velocity > Self.snapVelocity && dPos > Self.minSnapPos
        let rotSnap = angularVel > Self.snapAngularVel && dRotDeg > Self.minSnapRotDeg
        guard posSnap || rotSnap else { return nil }

        snapCount += 1
        maxSnapPosM = max(maxSnapPosM, dPos)
        maxSnapRotDeg = max(maxSnapRotDeg, dRotDeg)

        // Storm bookkeeping: keep jumps within the window, flag once the cluster crosses the threshold.
        recentSnapTimes.append(timestamp)
        recentSnapTimes.removeAll { timestamp - $0 > Self.stormWindow }
        let wasStorm = stormActive
        if recentSnapTimes.count >= Self.stormThreshold { stormActive = true }
        return Snap(dPosM: dPos, dRotDeg: dRotDeg, velocityMS: velocity,
                    stormActive: stormActive, stormJustTriggered: stormActive && !wasStorm)
    }

    /// Clear per-scan accumulators + history. Call at record-start.
    mutating func reset() {
        snapCount = 0
        maxSnapPosM = 0
        maxSnapRotDeg = 0
        stormActive = false
        recentSnapTimes.removeAll()
        prevPos = nil
        prevRot = nil
        prevTimestamp = 0
        prevNormal = false
    }
}
