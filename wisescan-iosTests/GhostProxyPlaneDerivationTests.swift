import XCTest
import simd
@testable import wisescan_ios

/// `ARCoverageView.deriveLevelPlanes` / `deriveRampPlanes` — recovering the walkable surfaces
/// RoomPlan does not model.
///
/// Why this is worth pinning: RoomPlan emits exactly ONE floor plane per captured room, seated at the
/// lowest adequately-covered horizontal surface, so on a stairwell every other level is missing. The
/// proxy builder used to drop all floor-class mesh faces on the assumption that quad stood in for
/// them, which deleted the upper landings outright.
///
/// These tests fix the boundaries that decide whether the replacement is trustworthy, and each one is
/// a pair of near-identical geometry that has to come out differently:
/// - a LANDING is found, a stair TREAD is not — both flat, horizontal and floor-classified, differing
///   only in area;
/// - a shallow RAMP yields no level, a NOISY FLOOR still does — per-face tilt is larger on the noisy
///   floor, so only the coherence of the slope separates them;
/// - a RAMP fits a tilted plane, a stair FLIGHT does not — both are a climb made of floor-class faces,
///   and only the residual to the fitted plane tells them apart.
final class GhostProxyPlaneDerivationTests: XCTestCase {

    // MARK: - Synthetic classified mesh

    /// Builds the (verts, faces, classes) triple `deriveLevelPlanes` consumes. Surfaces are
    /// tessellated at `cell` rather than emitted as single big triangles because the extraction reads
    /// face CENTROIDS: a 2-triangle 3 m quad would report a ~1 m extent, which is an artifact of the
    /// test mesh, not of the algorithm (real ARKit faces are 5–10 cm).
    private struct MeshBuilder {
        var verts: [SIMD3<Float>] = []
        var faces: [(Int, Int, Int)] = []
        var classes: [UInt8] = []

        /// A flat horizontal surface at height `y`, optionally pitched about the X axis by `pitchDeg`
        /// (rising along +Z) to stand in for a ramp, and optionally roughened by `jitter` metres of
        /// deterministic per-vertex height noise to stand in for real reconstruction.
        mutating func addSurface(y: Float, x: ClosedRange<Float>, z: ClosedRange<Float>,
                                 cls: UInt8 = 2, pitchDeg: Float = 0, jitter: Float = 0,
                                 cell: Float = 0.25) {
            let slope = tan(pitchDeg * .pi / 180)
            // Deterministic hash-based noise: a seeded RNG would make failures unreproducible.
            func noise(_ c: Int, _ r: Int) -> Float {
                guard jitter > 0 else { return 0 }
                let h = UInt32(truncatingIfNeeded: (c &* 73_856_093) ^ (r &* 19_349_663))
                return (Float(h % 2000) / 1000 - 1) * jitter
            }
            let cols = max(1, Int(((x.upperBound - x.lowerBound) / cell).rounded()))
            let rows = max(1, Int(((z.upperBound - z.lowerBound) / cell).rounded()))
            let dx = (x.upperBound - x.lowerBound) / Float(cols)
            let dz = (z.upperBound - z.lowerBound) / Float(rows)
            func vertex(_ c: Int, _ r: Int) -> SIMD3<Float> {
                let px = x.lowerBound + dx * Float(c)
                let pz = z.lowerBound + dz * Float(r)
                return SIMD3(px, y + slope * (pz - z.lowerBound) + noise(c, r), pz)
            }
            let base = verts.count
            for r in 0...rows { for c in 0...cols { verts.append(vertex(c, r)) } }
            func vid(_ c: Int, _ r: Int) -> Int { base + r * (cols + 1) + c }
            for r in 0..<rows {
                for c in 0..<cols {
                    faces.append((vid(c, r), vid(c + 1, r), vid(c + 1, r + 1)))
                    faces.append((vid(c, r), vid(c + 1, r + 1), vid(c, r + 1)))
                    classes.append(cls)
                    classes.append(cls)
                }
            }
        }

        /// A flight of treads: `count` steps of `tread` depth, each `riser` above the last.
        mutating func addFlight(baseY: Float, riser: Float, tread: Float, count: Int,
                                width: ClosedRange<Float>, startZ: Float) {
            for k in 0..<count {
                let z = startZ + tread * Float(k)
                addSurface(y: baseY + riser * Float(k + 1), x: width, z: z...(z + tread), cell: 0.14)
            }
        }

        var classData: Data { Data(classes) }

        /// The same mesh as an OBJ, for the end-to-end builder test.
        var objData: Data {
            var s = "# test mesh\n"
            for v in verts { s += "v \(v.x) \(v.y) \(v.z)\n" }
            for f in faces { s += "f \(f.0 + 1) \(f.1 + 1) \(f.2 + 1)\n" }
            return Data(s.utf8)
        }
    }

    private func levels(_ m: MeshBuilder,
                        reference: PlaneRegistration.Plane? = nil) -> [PlaneRegistration.Plane] {
        ARCoverageView.deriveLevelPlanes(verts: m.verts, faces: m.faces,
                                         faceClasses: m.classData, reference: reference)
    }

    /// Ramps are fitted to what the levels leave over, so the two always run in that order.
    private func ramps(_ m: MeshBuilder) -> [PlaneRegistration.Plane] {
        ARCoverageView.deriveRampPlanes(verts: m.verts, faces: m.faces, faceClasses: m.classData,
                                        explainedBy: levels(m))
    }

    // MARK: - Levels

    func testSingleFlatFloor_yieldsOneLevelAtItsHeight() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-1.5)...1.5, z: (-1.5)...1.5)

        let out = levels(m)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].center.y, 0, accuracy: 0.01)
        // Centroid-bounded, so the extent comes in just under the true 3 m span.
        XCTAssertEqual(out[0].width, 3.0, accuracy: 0.3)
        XCTAssertEqual(out[0].height, 3.0, accuracy: 0.3)
        XCTAssertEqual(out[0].normal.y, 1, accuracy: 1e-5)
    }

    /// The headline case: two landings joined by a flight. Both landings must come out, and the flight
    /// must contribute nothing — every tread is flat, horizontal and floor-classified, so only the
    /// area gate separates them.
    func testStairwell_findsBothLandings_andNoTreads() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-1)...1, z: (-2)...0)                    // lower landing, 4 m²
        m.addFlight(baseY: 0, riser: 0.1875, tread: 0.28, count: 8,
                    width: (-0.6)...0.6, startZ: 0)                     // 8 treads, ~0.34 m² each
        m.addSurface(y: 1.5, x: (-1)...1, z: 2.24...4.24)                // upper landing, 4 m²

        let out = levels(m)
        XCTAssertEqual(out.count, 2, "expected exactly the two landings, got \(out.map(\.center.y))")
        XCTAssertEqual(out[0].center.y, 0, accuracy: 0.02)
        XCTAssertEqual(out[1].center.y, 1.5, accuracy: 0.02)
    }

    /// A scan confined to the middle of a flight has no level to find. Returning nothing is the
    /// correct answer — inventing one would seat a quad at an arbitrary height mid-climb.
    func testFlightWithoutLandings_yieldsNoLevels() {
        var m = MeshBuilder()
        m.addFlight(baseY: 0, riser: 0.1875, tread: 0.28, count: 10,
                    width: (-0.6)...0.6, startZ: 0)

        XCTAssertTrue(levels(m).isEmpty)
    }

    /// A ramp is not a level: it produces nothing here and survives as mesh in the proxy instead of
    /// being replaced by a flat quad at some averaged height.
    func testRamp_yieldsNoLevel() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-1)...1, z: 0...6, pitchDeg: 15)

        XCTAssertTrue(levels(m).isEmpty)
    }

    /// The subtle one, and the reason the mean-tilt gate exists. A shallow ramp is UNDER the per-face
    /// pitch gate, and any thin horizontal slice of it holds metres² of area — so slab area alone
    /// would chop it into a level every 20 cm of rise, stair-stepping flat quads up a continuous
    /// slope. At the ADA maximum grade over 6 m that is several bogus levels.
    func testShallowRamp_isNotChoppedIntoLevels() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-0.75)...0.75, z: 0...6, pitchDeg: 4.8)

        XCTAssertTrue(levels(m).isEmpty, "ramp was sliced into \(levels(m).map(\.center.y))")
    }

    /// The counterpart: per-face normals on a reconstructed floor are noisy well past the mean-tilt
    /// threshold, and that must not cost the floor its level. Noise cancels under area weighting;
    /// slope does not. Here ±1 cm of vertex jitter over 25 cm cells tilts individual faces by several
    /// degrees — more than the mean gate allows — yet the surface is still one level.
    func testNoisyFlatFloor_stillYieldsOneLevel() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-1.5)...1.5, z: (-1.5)...1.5, jitter: 0.01)

        let out = levels(m)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].center.y, 0, accuracy: 0.02)
    }

    /// Only floor-classified faces vote. A table top is flat, horizontal and big enough to pass the
    /// area gate, so class is the only thing keeping it from registering as a mezzanine.
    func testTableTop_doesNotRegisterAsLevel() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-1.5)...1.5, z: (-1.5)...1.5)
        m.addSurface(y: 0.75, x: (-0.8)...0.8, z: (-0.8)...0.8, cls: 4)   // table, 2.56 m²
        m.addSurface(y: 1.1, x: (-0.8)...0.8, z: (-0.8)...0.8, cls: 0)    // unclassified clutter

        let out = levels(m)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].center.y, 0, accuracy: 0.01)
    }

    /// Derived levels adopt the reference floor's horizontal axes so they read as storeys of one
    /// building rather than independently-oriented slabs.
    func testLevelsAdoptReferenceFrameAxes() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-1.5)...1.5, z: (-1.5)...1.5)
        let yaw = Float.pi / 6
        let reference = PlaneRegistration.Plane(
            center: .zero, normal: SIMD3(0, 1, 0),
            xAxis: SIMD3(cos(yaw), 0, sin(yaw)), yAxis: SIMD3(-sin(yaw), 0, cos(yaw)),
            width: 3, height: 3, category: .floor)

        guard let level = levels(m, reference: reference).first else { return XCTFail("no level") }
        XCTAssertEqual(level.xAxis.x, cos(yaw), accuracy: 1e-5)
        XCTAssertEqual(level.xAxis.z, sin(yaw), accuracy: 1e-5)
    }

    // MARK: - Ramps

    /// The other half of the ramp story: it is not a level, but it is a real plane, so it should come
    /// back as a tilted quad rather than staying a lump of mesh.
    func testRamp_isFittedAsATiltedPlane() throws {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-0.75)...0.75, z: 0...6, pitchDeg: 4.8)

        let out = ramps(m)
        XCTAssertEqual(out.count, 1)
        let ramp = try XCTUnwrap(out.first)
        let tilt = acos(min(abs(ramp.normal.y), 1)) * 180 / .pi
        XCTAssertEqual(tilt, 4.8, accuracy: 0.3)
        // yAxis runs up the slope, so `height` spans the ramp's 6 m run (centroid-bounded).
        XCTAssertEqual(ramp.height, 6.0, accuracy: 0.4)
        XCTAssertEqual(ramp.width, 1.5, accuracy: 0.4)
    }

    /// A staircase must not be smoothed into a ramp. Its unexplained faces are the treads of the
    /// flight — flat, floor-classified, and spread over a metre of climb, so they are nowhere near any
    /// single plane. The residual gate is what has to catch this; the mean tilt of level treads is
    /// near zero, so tilt alone would not.
    func testStairFlight_isNotFittedAsARamp() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-1)...1, z: (-2)...0)
        m.addFlight(baseY: 0, riser: 0.1875, tread: 0.28, count: 8,
                    width: (-0.6)...0.6, startZ: 0)
        m.addSurface(y: 1.5, x: (-1)...1, z: 2.24...4.24)

        XCTAssertTrue(ramps(m).isEmpty, "the flight was smoothed into a ramp")
    }

    /// A flat room leaves only edge speckle unexplained, which must not fit anything.
    func testFlatFloor_yieldsNoRamp() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-1.5)...1.5, z: (-1.5)...1.5, jitter: 0.01)

        XCTAssertTrue(ramps(m).isEmpty)
    }

    /// A floor with a ramp leading off it: the flat part is a level, the slope is a ramp, and neither
    /// claims the other's geometry.
    func testFloorWithRamp_yieldsOneOfEach() throws {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-2)...2, z: (-4)...0)
        m.addSurface(y: 0, x: (-0.75)...0.75, z: 0...6, pitchDeg: 8)

        let lv = levels(m)
        XCTAssertEqual(lv.count, 1)
        XCTAssertEqual(lv[0].center.y, 0, accuracy: 0.05)

        let rp = ramps(m)
        XCTAssertEqual(rp.count, 1)
        let tilt = acos(min(abs(try XCTUnwrap(rp.first).normal.y), 1)) * 180 / .pi
        XCTAssertEqual(tilt, 8, accuracy: 1.0)
    }

    // MARK: - End to end through the proxy builder

    /// The regression this whole change exists to prevent: an upper landing must not vanish from
    /// mesh_proxy.obj. Before the fix its faces were dropped as "floor" with nothing standing in;
    /// now a derived level quad sits at its height.
    func testProxyBuild_keepsUpperLandingAsBakedLevel() throws {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-2)...2, z: (-2)...2)                     // floor RoomPlan modelled
        m.addSurface(y: 1.5, x: (-1)...1, z: (-1)...1)                   // landing it did not

        let wall = PlaneRegistration.Plane(
            center: SIMD3(0, 1.25, -2), normal: SIMD3(0, 0, 1),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0),
            width: 4, height: 2.5, category: .wall)
        let floor = PlaneRegistration.Plane(
            center: .zero, normal: SIMD3(0, 1, 0),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, 1),
            width: 4, height: 4, category: .floor)

        let built = try XCTUnwrap(ARCoverageView.buildGhostProxyOBJ(
            objData: m.objData, faceClasses: m.classData, roomPlanPlanes: [wall, floor]))

        let text = try XCTUnwrap(String(data: built.proxy.data, encoding: .utf8))
        let landingVerts = text.split(separator: "\n").filter { line in
            guard line.hasPrefix("v ") else { return false }
            let parts = line.split(separator: " ")
            guard parts.count == 4, let y = Float(parts[2]) else { return false }
            return abs(y - 1.5) < 0.05
        }
        XCTAssertFalse(landingVerts.isEmpty, "the upper landing left no geometry in the proxy")

        // Neither the floor nor the landing is content, so the change-detection artifact stays empty.
        XCTAssertEqual(built.dynamic.faceCount, 0)

        // The sidecar gets BOTH levels, including the one RoomPlan already models: skipping that one
        // is a baking concern (two quads at one height), not a description of the scan.
        XCTAssertEqual(built.levels.count, 2)
        XCTAssertEqual(built.levels.map { ($0.center.y * 10).rounded() / 10 }, [0, 1.5])
    }

    /// The sidecar has to survive the round trip with its frame intact — a consumer reading it back
    /// draws quads or feeds a fit, and a transposed or mis-ordered transform would be silently wrong
    /// rather than obviously broken.
    func testDerivedSurfacesSidecar_roundTripsFrameAndCategory() throws {
        let level = PlaneRegistration.Plane(
            center: SIMD3(1, 1.5, -2), normal: SIMD3(0, 1, 0),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, 1),
            width: 2, height: 3, category: .floor)
        let tilt = Float.pi / 36   // 5°
        let ramp = PlaneRegistration.Plane(
            center: SIMD3(0, 0.25, 4), normal: SIMD3(0, cos(tilt), -sin(tilt)),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, sin(tilt), cos(tilt)),
            width: 1.5, height: 6, category: .floor)

        let encoded = try JSONEncoder().encode(DerivedSurfacesData(levels: [level], ramps: [ramp]))
        let decoded = try JSONDecoder().decode(DerivedSurfacesData.self, from: encoded)

        XCTAssertEqual(decoded.surfaces.map(\.category),
                       [DerivedSurfacesData.levelCategory, DerivedSurfacesData.rampCategory])
        XCTAssertEqual(decoded.surfaces[0].centerY, 1.5)
        XCTAssertEqual(decoded.surfaces[0].dimensions.width, 2)
        XCTAssertEqual(decoded.surfaces[0].dimensions.depth, 0, "these are planes, not volumes")

        let m = try XCTUnwrap(decoded.surfaces[1].matrix)
        // col0 = xAxis, col1 = yAxis, col2 = normal, col3 = center.
        XCTAssertEqual(m.columns.2.y, cos(tilt), accuracy: 1e-6)
        XCTAssertEqual(m.columns.2.z, -sin(tilt), accuracy: 1e-6)
        XCTAssertEqual(m.columns.3.z, 4, accuracy: 1e-6)
    }

    /// A ramp must not be readable as a `floor` by the registration decoder. The plane matcher there
    /// admits pairs up to 25° apart, so a shallow ramp would correspond to a flat floor and drag the
    /// vertical solution with it — anything wiring these in has to opt in per category.
    func testDerivedCategories_areNotAcceptedByThePlaneRegistrationDecoder() {
        for category in [DerivedSurfacesData.levelCategory, DerivedSurfacesData.rampCategory] {
            XCTAssertNil(PlaneRegistration.plane(category: category, width: 2, height: 2,
                                                 transform: [1, 0, 0, 0, 0, 1, 0, 0,
                                                             0, 0, 1, 0, 0, 0, 0, 1]),
                         "\(category) leaked into the registration plane decoder")
        }
    }
}
