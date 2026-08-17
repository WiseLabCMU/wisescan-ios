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
    /// Two rings per point, at the floor and at the LENS.
    ///
    /// One ring is only visible if the operator happens to be looking that way. Scanning
    /// is done heads-up — the iPad is often level or tilted up at a wall — so a marker
    /// that lives only on the floor drops out of view exactly when someone is deciding
    /// where to stand next. The lens-height ring sits at eye line and catches the other
    /// half of the time; the floor ring stays because it is what you walk to.
    ///
    /// `cameraY` nil draws the floor ring alone (no rig height known yet).
    static func descriptors(for point: Point, floorY: Float, cameraY: Float?) -> [MeshDescriptor] {
        let radius = AppConstants.stillSpacingTargetMeters * 0.5
        // Lift clear of the floor mesh — see stillRingLiftMeters.
        let groundY = floorY + AppConstants.stillRingLiftMeters
        var out: [MeshDescriptor] = []
        if let ring = bandMesh(center: point.position, height: groundY, radius: radius,
                               width: AppConstants.stillRingBandWidthMeters) {
            out.append(ring)
        }
        // Center pip: a small filled band reads as a dot at distance and marks the exact
        // spot the still was taken from, so a returning operator can stand off it.
        if let pip = bandMesh(center: point.position, height: groundY,
                              radius: AppConstants.stillRingPipRadiusMeters,
                              width: AppConstants.stillRingPipRadiusMeters * 1.6,
                              segments: 16) {
            out.append(pip)
        }
        // Lens-height ring: thinner, so at a glance the floor ring still reads as the
        // one you stand on and this one as where the camera was.
        if let cameraY, let air = bandMesh(center: point.position, height: cameraY, radius: radius,
                                           width: AppConstants.stillRingBandWidthMeters * 0.6) {
            out.append(air)
        }
        return out
    }

    /// Floor height for the rings when the mesh field has nothing yet: a classified
    /// floor plane if one exists, else this operator's LEARNED capture height, else the
    /// constant. Operators scan from wheelchairs and at very different statures, so the
    /// learned offset matters — a standing 1.3 m assumption puts a seated user's rings
    /// half a metre underground, where the mesh swallows them.
    static func floorY(planes: [ARPlaneAnchor], fallbackFrom capture: SIMD3<Float>) -> Float {
        let floors = planes.filter { $0.classification == .floor }
        if let lowest = floors.map({ $0.transform.columns.3.y }).min() {
            return lowest
        }
        let learned = UserDefaults.standard.double(forKey: AppConstants.Key.operatorCaptureHeight)
        let drop = learned > 0.2 ? Float(learned) : AppConstants.stillRingFallbackDropMeters
        return capture.y - drop
    }

    /// Records how high this operator holds the device above a KNOWN floor, so later
    /// stills (and later scans) can place rings without waiting for mesh coverage.
    /// Smoothed, and sanity-bounded to plausible capture heights — seated operators sit
    /// near the bottom of this range, tall standing ones near the top.
    static func learnCaptureHeight(capturePose: SIMD3<Float>, floorY: Float) {
        let height = Double(capturePose.y - floorY)
        guard height > 0.4, height < 2.2 else { return }
        let known = UserDefaults.standard.double(forKey: AppConstants.Key.operatorCaptureHeight)
        // A LARGE mismatch is a different person, not drift — the rig gets handed from
        // a tall operator to a seated one and the height changes by half a metre in one
        // still. Smoothing through that would leave the new operator using the old
        // one's height for most of their first scan, so a big jump is adopted outright
        // and only small differences are smoothed.
        let isNewOperator = known > 0.2 && abs(known - height) > 0.15
        let learned = (known > 0.2 && !isNewOperator) ? known * 0.7 + height * 0.3 : height
        UserDefaults.standard.set(learned, forKey: AppConstants.Key.operatorCaptureHeight)
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
