import ARKit
import RealityKit
import simd

/// Floor rings marking where 360° stills have been taken, so the operator can space the
/// next one without guessing (REQ-033).
///
/// WHY RINGS AND NOT A COVERAGE VOLUME: a 360° still sees every direction at once, so
/// "is this a good spot" is not a frustum-coverage question like the phone's amber
/// overlay — it collapses to "how far am I from the stills already taken". That needs
/// no voxel grid: ≤20 points and a distance test answer it exactly. Fog or a third grid
/// would cost memory and occlude the mesh the operator is reading during the scan.
///
/// The radius is HALF the spacing target, so two rings that just touch are exactly
/// `stillSpacingTargetMeters` apart — the operator reads spacing off the geometry
/// instead of a number.
///
/// Rendering follows the ghost-mesh rules in ARCoverageView: procedural geometry with
/// opaque `UnlitMaterial` only. Transparency and CustomMaterial are not viable in this
/// ARView, so a ring is drawn as a thin opaque BAND rather than a translucent disc —
/// which also leaves the floor visible inside it.
enum StillSpacingRings {

    /// One place a still was taken (`taken`), or one a future 4D pass suggests
    /// (`suggested` — the server-driven case: same visual language, different source).
    enum PointSource { case taken, suggested }

    struct Point {
        let position: SIMD3<Float>      // world position of the CAPTURE (phone pose)
        let source: PointSource
    }

    /// Ring band geometry on the XZ plane at `y`, centered on `center`.
    /// `segments` is fixed: at ~1 m radius, 48 segments is smooth and cheap (96 tris).
    private static func bandMesh(center: SIMD3<Float>, height: Float, radius: Float,
                                 width: Float, segments: Int = 48) -> MeshDescriptor? {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(segments * 2)
        indices.reserveCapacity(segments * 6)

        let inner = max(radius - width * 0.5, 0.001)
        let outer = radius + width * 0.5
        for step in 0..<segments {
            let theta = Float(step) / Float(segments) * 2 * .pi
            let dir = SIMD3<Float>(cos(theta), 0, sin(theta))
            positions.append(SIMD3(center.x, height, center.z) + dir * inner)
            positions.append(SIMD3(center.x, height, center.z) + dir * outer)
        }
        for step in 0..<segments {
            let inA = UInt32(step * 2), outA = UInt32(step * 2 + 1)
            let next = (step + 1) % segments
            let inB = UInt32(next * 2), outB = UInt32(next * 2 + 1)
            // Two triangles per segment, wound both ways so the band reads from above
            // AND from below (the operator may look down on it from any side).
            indices.append(contentsOf: [inA, outA, outB, inA, outB, inB])
            indices.append(contentsOf: [inA, outB, outA, inA, inB, outB])
        }
        guard !positions.isEmpty else { return nil }
        var desc = MeshDescriptor(name: "still_ring")
        desc.positions = MeshBuffers.Positions(positions)
        desc.primitives = .triangles(indices)
        return desc
    }

    /// Ring + center pip for one point. Built on the caller's thread; the caller must
    /// turn descriptors into resources on MAIN (RealityKit resource-generation rule).
    static func descriptors(for point: Point, floorY: Float) -> [MeshDescriptor] {
        let radius = AppConstants.stillSpacingTargetMeters * 0.5
        // Lift clear of the floor mesh — see stillRingLiftMeters.
        let floorY = floorY + AppConstants.stillRingLiftMeters
        var out: [MeshDescriptor] = []
        if let ring = bandMesh(center: point.position, height: floorY, radius: radius,
                               width: AppConstants.stillRingBandWidthMeters) {
            out.append(ring)
        }
        // Center pip: a small filled band reads as a dot at distance and marks the exact
        // spot the still was taken from, so a returning operator can stand off it.
        if let pip = bandMesh(center: point.position, height: floorY,
                              radius: AppConstants.stillRingPipRadiusMeters,
                              width: AppConstants.stillRingPipRadiusMeters * 1.6,
                              segments: 16) {
            out.append(pip)
        }
        return out
    }

    /// Floor height for the rings: the lowest classified floor plane wins; otherwise
    /// drop a fixed distance below the capture pose. A wrong-by-20cm floor still reads
    /// correctly as a spacing guide, so an estimate is preferable to drawing nothing.
    static func floorY(planes: [ARPlaneAnchor], fallbackFrom capture: SIMD3<Float>) -> Float {
        let floors = planes.filter { $0.classification == .floor }
        if let lowest = floors.map({ $0.transform.columns.3.y }).min() {
            return lowest
        }
        return capture.y - AppConstants.stillRingFallbackDropMeters
    }

    /// How far the given position is from the nearest already-taken still.
    /// `.infinity` when none — the first still of a scan is always a good spot.
    static func distanceToNearest(_ position: SIMD3<Float>, points: [SIMD3<Float>]) -> Float {
        points.map { simd_distance($0, position) }.min() ?? .infinity
    }

    /// Spacing verdict for the live chip.
    enum Spacing {
        case first          // nothing taken yet
        case tooClose(Float)
        case good(Float)

        var isGood: Bool {
            if case .tooClose = self { return false }
            return true
        }
    }

    static func spacing(at position: SIMD3<Float>, points: [SIMD3<Float>]) -> Spacing {
        guard !points.isEmpty else { return .first }
        let nearest = distanceToNearest(position, points: points)
        return nearest < AppConstants.stillSpacingTargetMeters ? .tooClose(nearest) : .good(nearest)
    }
}
