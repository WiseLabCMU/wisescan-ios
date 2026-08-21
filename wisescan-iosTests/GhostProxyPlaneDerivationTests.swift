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
        /// `skewX` shears the footprint: each vertex shifts in X by `skewX` per metre of Z, so the
        /// strip's long axis runs diagonal to Z while the surface normal still tilts about X — the
        /// cross-slope geometry of a real walkway, where steepest descent is rotated off the run.
        mutating func addSurface(y: Float, x: ClosedRange<Float>, z: ClosedRange<Float>,
                                 cls: UInt8 = 2, pitchDeg: Float = 0, jitter: Float = 0,
                                 skewX: Float = 0, cell: Float = 0.25) {
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
                return SIMD3(px + skewX * (pz - z.lowerBound),
                             y + slope * (pz - z.lowerBound) + noise(c, r), pz)
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

        /// A helical ramp — an annular sector swept through `turns`, rising `rise` in total. Local pitch
        /// is ramp-like everywhere (a 3 m rise per turn at 3 m radius is ~9°), which is exactly why a
        /// helix is dangerous: every patch of it looks like a legitimate ramp face.
        mutating func addHelix(innerR: Float, outerR: Float, turns: Float, rise: Float,
                               steps: Int = 48, rings: Int = 4) {
            let base = verts.count
            let totalAngle = turns * 2 * .pi
            for i in 0...steps {
                let a = totalAngle * Float(i) / Float(steps)
                for j in 0...rings {
                    let r = innerR + (outerR - innerR) * Float(j) / Float(rings)
                    verts.append(SIMD3(r * cos(a), rise * Float(i) / Float(steps), r * sin(a)))
                }
            }
            func vid(_ i: Int, _ j: Int) -> Int { base + i * (rings + 1) + j }
            for i in 0..<steps {
                for j in 0..<rings {
                    faces.append((vid(i, j), vid(i + 1, j), vid(i + 1, j + 1)))
                    faces.append((vid(i, j), vid(i + 1, j + 1), vid(i, j + 1)))
                    classes.append(2)
                    classes.append(2)
                }
            }
        }

        /// A vertical wall curved in plan — a cylindrical band around the origin, wall-classified.
        mutating func addCurvedWall(radius: Float, startDeg: Float, endDeg: Float, height: Float,
                                    steps: Int = 40, rows: Int = 6) {
            let base = verts.count
            for i in 0...steps {
                let a = (startDeg + (endDeg - startDeg) * Float(i) / Float(steps)) * .pi / 180
                for j in 0...rows {
                    verts.append(SIMD3(radius * cos(a), height * Float(j) / Float(rows), radius * sin(a)))
                }
            }
            func vid(_ i: Int, _ j: Int) -> Int { base + i * (rows + 1) + j }
            for i in 0..<steps {
                for j in 0..<rows {
                    faces.append((vid(i, j), vid(i + 1, j), vid(i + 1, j + 1)))
                    faces.append((vid(i, j), vid(i + 1, j + 1), vid(i, j + 1)))
                    classes.append(1)
                    classes.append(1)
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
                                         faceClasses: m.classData, reference: reference).levels
    }

    /// The search's own account of what it examined and why it turned things down.
    private func levelCandidates(_ m: MeshBuilder) -> [ARCoverageView.LevelDerivation.Candidate] {
        ARCoverageView.deriveLevelPlanes(verts: m.verts, faces: m.faces,
                                         faceClasses: m.classData, reference: nil).candidates
    }

    /// Ramps are fitted to what the levels leave over, so the two always run in that order.
    private func ramps(_ m: MeshBuilder) -> [PlaneRegistration.Plane] {
        ARCoverageView.deriveRampPlanes(verts: m.verts, faces: m.faces, faceClasses: m.classData,
                                        explainedBy: levels(m)).ramps
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

    /// A near-miss has to be distinguishable from an absence. A landing just under the area bar must be
    /// reported as rejected-on-area rather than vanishing, because that is what tells you a threshold
    /// wants moving instead of that the room has no landing there.
    func testLandingJustUnderTheAreaBar_isReportedAsANearMiss() throws {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-1.5)...1.5, z: (-1.5)...1.5)          // real floor
        m.addSurface(y: 2.0, x: (-0.45)...0.45, z: (-0.45)...0.45)    // ~0.8 m² — under the 1 m² bar

        XCTAssertEqual(levels(m).count, 1, "the small upper surface must not become a level")
        let nearMiss = try XCTUnwrap(levelCandidates(m).first { abs($0.y - 2.0) < 0.1 })
        XCTAssertEqual(nearMiss.verdict, .belowMinArea)
        XCTAssertLessThan(nearMiss.areaM2, ARCoverageView.levelMinAreaM2)
        XCTAssertGreaterThan(nearMiss.areaM2, 0.5, "should be a near-miss, not noise")
    }

    /// The accepted levels have to show up in the trace too, or a log with no rejections would look
    /// like a search that never ran.
    func testAcceptedLevelsAppearInTheTrace() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-1)...1, z: (-2)...0)
        m.addSurface(y: 1.5, x: (-1)...1, z: 2.24...4.24)

        let accepted = levelCandidates(m).filter { $0.verdict == .accepted }
        XCTAssertEqual(accepted.count, 2)
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

    /// The regression that motivated per-direction grouping. Two ramps facing opposite ways used to
    /// destroy each other: one global fit averaged them into a normal fitting neither, the residual blew
    /// the gate, and BOTH were lost — including a ramp that would have fitted perfectly alone. Observed
    /// on a real scan containing a straight ramp, a helical ramp and a stair flight, where nothing at all
    /// came out.
    func testTwoRampsFacingOppositeWays_areBothFitted() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-0.75)...0.75, z: 0...6, pitchDeg: 8)      // rises toward +Z
        m.addSurface(y: 0, x: 3...4.5, z: 0...6, pitchDeg: -8)            // rises toward -Z

        let out = ramps(m)
        XCTAssertEqual(out.count, 2, "each ramp must be fitted on its own direction")
        // Opposite slopes, so the up-slope components point opposite ways along Z.
        let zs = out.map { $0.normal.z }.sorted()
        XCTAssertLessThan(zs[0], 0)
        XCTAssertGreaterThan(zs[1], 0)
    }

    /// A helix must NOT be forced into planes. Its local pitch is ramp-like everywhere, so nothing about
    /// a single face gives it away — but grouped by direction it yields annular sectors whose bounding
    /// rectangle is mostly empty, and a quad laid over that is the "plane sticking into open space"
    /// failure. Declining it and leaving the mesh is the correct answer.
    func testHelicalRamp_isNotFittedAsQuads() {
        var m = MeshBuilder()
        m.addHelix(innerR: 2, outerR: 3.5, turns: 1, rise: 3)

        XCTAssertTrue(ramps(m).isEmpty, "helix produced \(ramps(m).count) quad(s)")
    }

    /// Grouping must not cost the ordinary case. A straight ramp is one direction, so it still comes out
    /// as exactly one plane rather than being split.
    func testStraightRamp_isStillOnePlaneAfterGrouping() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-0.75)...0.75, z: 0...6, pitchDeg: 4.8)

        XCTAssertEqual(ramps(m).count, 1)
    }

    /// The device failure verbatim: direction alone cannot separate PARALLEL surfaces. A helix's tangent
    /// parallels a straight ramp somewhere on every turn, so its fragments join the ramp's direction
    /// group at a different offset, the single fit straddles both planes, and an 8.3 m² group at the
    /// ramp's exact tilt died notPlanar at 94 mm RMS. The offset split has to rescue the ramp.
    func testStraightRamp_survivesParallelContaminationAtAnotherOffset() throws {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-0.75)...0.75, z: 0...6, pitchDeg: 8)          // the real ramp
        // Same pitch, same direction, 1.2 m overhead — a helix pass whose tangent parallels the ramp.
        // 0.96 m², under the 1.5 m² ramp bar, so alone it is too small to be a ramp; its only effect
        // should be nothing at all.
        m.addSurface(y: 1.2, x: (-0.4)...0.4, z: 2...3.2, pitchDeg: 8)

        let out = ramps(m)
        XCTAssertEqual(out.count, 1, "the contaminant must be separated, not averaged in")
        let ramp = try XCTUnwrap(out.first)
        let tilt = acos(min(abs(ramp.normal.y), 1)) * 180 / .pi
        XCTAssertEqual(tilt, 8, accuracy: 0.5)
        XCTAssertEqual(ramp.height, 6.0, accuracy: 0.5, "the fitted extent must be the real ramp's run")
    }

    /// The device failure the occupancy map finally made visible: a clean constant-width strip lying
    /// DIAGONAL in its fitted frame. A slope-aligned box assumes the walkway runs up the steepest
    /// descent, but any cross-slope rotates steepest descent off the run — at a 3.9° main slope even
    /// ~1° of drainage fall skews the frame by ~15°, the box balloons around the diagonal band, and
    /// fill kills a perfectly real ramp. The box must align with the strip's own principal axis.
    func testCrossSlopedRamp_getsATightBoxAndFits() throws {
        var m = MeshBuilder()
        // 1.5 m strip, 6 m run, 8° pitch, drifting 0.25 m sideways per metre (~14° skew).
        m.addSurface(y: 0, x: (-0.75)...0.75, z: 0...6, pitchDeg: 8, skewX: 0.25)

        let out = ramps(m)
        XCTAssertEqual(out.count, 1, "a cross-sloped ramp is still one clean quad")
        let ramp = try XCTUnwrap(out.first)
        XCTAssertEqual(ramp.width, 1.5, accuracy: 0.4,
                       "the box must hug the strip, not the slope-aligned bounding rectangle")
        XCTAssertGreaterThan(ramp.height, 5.0, "the long axis must run along the strip")
    }

    /// The failure after the offset split: a fragment COPLANAR with the ramp costs no residual — the
    /// offset window cannot separate what is genuinely on the plane — and only shows up as a ballooned
    /// bounding box (device: rms 9 mm, fill 0.33 → poorFill, ramp lost). Contiguity is the remaining
    /// separator: the ramp is its own connected component and fills its box, the distant fragment is
    /// another and dies on area.
    func testStraightRamp_survivesCoplanarFragmentFarAwayInPlane() throws {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-0.75)...0.75, z: 0...6, pitchDeg: 8)
        // Exactly coplanar (the plane y = tan(8°)·z is independent of x), 4+ m away laterally, and
        // under the area bar on its own.
        let y2 = tan(Float(8) * .pi / 180) * 2
        m.addSurface(y: y2, x: 5...5.8, z: 2...3.2, pitchDeg: 8)

        let out = ramps(m)
        XCTAssertEqual(out.count, 1, "the coplanar fragment must be split off, not boxed in")
        let ramp = try XCTUnwrap(out.first)
        XCTAssertEqual(ramp.width, 1.5, accuracy: 0.4, "extent must be the ramp's, not the spanning box")
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

    // MARK: - Ramp end-snapping

    /// The seam problem: the flattening band where a ramp meets its landing belongs to neither plane,
    /// so the fitted extent stops short of the intersection and the proxy shows a visible gap. The quad
    /// extends to the plane-intersection line — extend only, never trim (overlap beats gap by decision).
    func testRampEndsShortOfItsLanding_snapsToTheSeam() {
        let tilt: Float = 8 * .pi / 180
        // Ramp rising along +Z through the origin, fitted extent ending at v=+2.5 (world z≈2.48) —
        // 0.4 m short of the landing plane at y = tan(8°)·2.87.
        let ramp = PlaneRegistration.Plane(
            center: .zero, normal: SIMD3(0, cos(tilt), -sin(tilt)),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, sin(tilt), cos(tilt)),
            width: 1.5, height: 5, category: .floor)
        let seamV: Float = 2.9
        let landingY = sin(tilt) * seamV
        let landing = PlaneRegistration.Plane(
            center: SIMD3(0, landingY, cos(tilt) * seamV + 2), normal: SIMD3(0, 1, 0),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, 1),
            width: 4, height: 5, category: .floor)

        let snapped = ARCoverageView.snapRampEnds([ramp], to: [landing])[0]
        // Top extends from +2.5 to the seam at +2.9; bottom (−2.5) untouched → height 5.4.
        XCTAssertEqual(snapped.plane.height, 5.4, accuracy: 0.02)
        XCTAssertEqual(snapped.extendedTopM, 0.4, accuracy: 0.02)
        XCTAssertEqual(snapped.extendedBottomM, 0, accuracy: 1e-4)
        // The new top edge lies ON the landing plane.
        let topEdge = snapped.plane.center + snapped.plane.yAxis * (snapped.plane.height / 2)
        XCTAssertEqual(topEdge.y, landingY, accuracy: 0.01)
    }

    /// A level at the right height but far away laterally is a coincidence, not a junction — the seam
    /// point falls outside its rectangle, so no snap.
    func testRampDoesNotSnapToADistantLevelAtTheSameHeight() {
        let tilt: Float = 8 * .pi / 180
        let ramp = PlaneRegistration.Plane(
            center: .zero, normal: SIMD3(0, cos(tilt), -sin(tilt)),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, sin(tilt), cos(tilt)),
            width: 1.5, height: 5, category: .floor)
        let farLevel = PlaneRegistration.Plane(
            center: SIMD3(30, sin(tilt) * 2.9, 2.9), normal: SIMD3(0, 1, 0),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, 1),
            width: 4, height: 4, category: .floor)

        XCTAssertEqual(ARCoverageView.snapRampEnds([ramp], to: [farLevel])[0].plane.height, 5,
                       "snapped across open space to an unrelated level")
    }

    /// Extend-only: a ramp already overlapping past the seam is left alone.
    func testRampOverlappingItsFloor_isNotTrimmed() {
        let tilt: Float = 8 * .pi / 180
        let ramp = PlaneRegistration.Plane(
            center: .zero, normal: SIMD3(0, cos(tilt), -sin(tilt)),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, sin(tilt), cos(tilt)),
            width: 1.5, height: 5, category: .floor)
        // Floor plane whose seam sits at v = −2.0, INSIDE the ramp's extent (bottom overlap).
        let floor = PlaneRegistration.Plane(
            center: SIMD3(0, sin(tilt) * -2, -2), normal: SIMD3(0, 1, 0),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, 1),
            width: 4, height: 6, category: .floor)

        XCTAssertEqual(ARCoverageView.snapRampEnds([ramp], to: [floor])[0].plane.height, 5,
                       "overlap beats gap — never trim")
    }

    /// The cap must bound the TOTAL extension per end, not each hop. Measured from the running bound,
    /// two levels past the same end walk the rectangle out one qualifying step at a time — 1.5 m then
    /// another 1.5 m — so a 2 m cap silently permits 3 m of extension, and the declined-seam trace
    /// reports the gap to the previous level rather than to the ramp's own end.
    func testTwoLevelsPastTheSameRampEnd_capsFromTheFittedEnd() {
        let tilt: Float = 8 * .pi / 180
        // Fitted extent ends at v = +2.5. Levels put seams at v = 4.0 (+1.5, inside the cap) and
        // v = 5.5 (+3.0, past it).
        let ramp = PlaneRegistration.Plane(
            center: .zero, normal: SIMD3(0, cos(tilt), -sin(tilt)),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, sin(tilt), cos(tilt)),
            width: 1.5, height: 5, category: .floor)
        func level(seamV: Float) -> PlaneRegistration.Plane {
            PlaneRegistration.Plane(
                center: SIMD3(0, sin(tilt) * seamV, cos(tilt) * seamV), normal: SIMD3(0, 1, 0),
                xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, 1),
                width: 4, height: 4, category: .floor)
        }

        let snapped = ARCoverageView.snapRampEnds([ramp], to: [level(seamV: 4.0), level(seamV: 5.5)])[0]
        XCTAssertEqual(snapped.extendedTopM, 1.5, accuracy: 0.02,
                       "extended \(snapped.extendedTopM)m — the cap is being measured per hop, not from the fitted end")
        XCTAssertEqual(snapped.extendedBottomM, 0, accuracy: 1e-4)
        // Top edge lands on the NEARER level's intersection line.
        let topEdge = snapped.plane.center + snapped.plane.yAxis * (snapped.plane.height / 2)
        XCTAssertEqual(topEdge.y, sin(tilt) * 4.0, accuracy: 0.01)
        let note = snapped.note ?? "nil"
        XCTAssertTrue(note.contains("3.00m beyond end"),
                      "far seam should be declined at its distance from the fitted end, got: \(note)")
        XCTAssertFalse(note.contains("1.50m beyond end"),
                       "declined distance measured from the other level, not the ramp end: \(note)")
    }

    /// A level whose seam falls INSIDE the fitted extent is not a declined snap, it is a non-event —
    /// the running-bound form reported it as a cap violation with a negative distance.
    func testRampOverlappingItsFloor_reportsNoDeclinedSeam() {
        let tilt: Float = 8 * .pi / 180
        let ramp = PlaneRegistration.Plane(
            center: .zero, normal: SIMD3(0, cos(tilt), -sin(tilt)),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, sin(tilt), cos(tilt)),
            width: 1.5, height: 5, category: .floor)
        let floor = PlaneRegistration.Plane(
            center: SIMD3(0, sin(tilt) * -2, -2), normal: SIMD3(0, 1, 0),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, 1),
            width: 4, height: 6, category: .floor)

        let snapped = ARCoverageView.snapRampEnds([ramp], to: [floor])[0]
        XCTAssertNil(snapped.note, "a seam inside the fitted extent produced a bogus note: \(snapped.note ?? "")")
    }

    /// The pinhole metric must distinguish the two kinds of unbacked cell: honest partial coverage
    /// (touches the mask border — a thin scan, a truncated chord) counts zero, while a genuinely
    /// enclosed gap counts. It is the objective form of "do the walls look patchy".
    func testInteriorHoleCells_countEnclosedGapsOnly() {
        var mask = ARCoverageView.QuadSupport(cols: 5, rows: 5)
        // Fill everything, then punch one interior cell and one border-touching notch.
        for r in 0..<5 { for c in 0..<5 { mask.mark(c, r) } }
        XCTAssertEqual(mask.interiorHoleCells, 0)

        var holed = ARCoverageView.QuadSupport(cols: 5, rows: 5)
        for r in 0..<5 { for c in 0..<5 where !(c == 2 && r == 2) && !(c == 0 && r == 1) { holed.mark(c, r) } }
        XCTAssertEqual(holed.interiorHoleCells, 1, "the centre gap is a hole; the border notch is not")
    }

    /// The 15–20 cm band, closed from above: a standard 17 cm riser resolves into two levels. This was
    /// the gap where a single-step split level — sunken lounge, raised dais — got no quad because the
    /// height-histogram clearing wiped the second surface.
    func testSingleRiserStep_yieldsTwoLevels() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-2)...2, z: (-2)...1)          // main floor
        m.addSurface(y: 0.17, x: (-2)...2, z: 1...3)          // platform one riser up

        let out = levels(m)
        XCTAssertEqual(out.count, 2, "one riser must be two surfaces, got \(out.map(\.center.y))")
        XCTAssertEqual(out[0].center.y, 0, accuracy: 0.02)
        XCTAssertEqual(out[1].center.y, 0.17, accuracy: 0.02)
    }

    /// The same band, closed from below: a step too shallow to resolve into its own level must stay
    /// honest mesh, not be silently flattened. Under the loose 15 cm band a 12 cm platform sat inside
    /// its floor's tolerance and was subtracted as if it were that floor; the tight derived-plane band
    /// leaves it offPlane, which the proxy keeps.
    func testSubRiserStep_staysMeshInsteadOfBeingFlattened() throws {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-2)...2, z: (-2)...1)
        m.addSurface(y: 0.12, x: (-1)...1, z: 1.2...2.6)      // 12 cm platform, sub-riser

        let out = levels(m)
        XCTAssertEqual(out.count, 1, "a sub-riser step is below the resolvable spacing")
        let floor = try XCTUnwrap(out.first)
        XCTAssertEqual(floor.center.y, 0, accuracy: 0.03)

        let masks = ARCoverageView.buildQuadSupport(planes: out, verts: m.verts, faces: m.faces,
                                                    faceClasses: m.classData,
                                                    dilateBy: 0)
        // Derived-plane tolerance: the platform's surface is 12 cm off the floor plane — outside the
        // 8 cm band, so it must NOT be covered (old behaviour: inside 15 cm, silently subtracted).
        let tight = [ARCoverageView.derivedQuadCoverageMeters]
        let onPlatform = SIMD3<Float>(0, 0.12, 1.9)
        XCTAssertEqual(ARCoverageView.quadCoverage(out, support: masks, tolerances: tight, onPlatform),
                       .offPlane, "the platform was absorbed by its neighbouring floor")
        // And the floor itself is still covered under the tight band.
        XCTAssertTrue(ARCoverageView.quadCovers(out, support: masks, tolerances: tight,
                                                SIMD3(0, 0, -0.5)))
    }

    // MARK: - Model fitness (per-quad graceful degradation)

    /// The 5-sided-room case: RoomPlan models a curved wall as a straight chord, and historically that
    /// chord REPLACED the curve — the mesh was lopped and a flat quad stood in. Fitness is the per-quad
    /// box-room detector: a chord explains only its tangency strip of the curve's mesh (low ratio), so
    /// it is demoted and the curve survives as mesh; a genuinely straight wall explains ~everything.
    func testChordAcrossACurvedWall_scoresLowFitness() {
        var m = MeshBuilder()
        // 80° of arc at R=4 (sagitta ~0.94 m), 3 m tall.
        m.addCurvedWall(radius: 4, startDeg: -40, endDeg: 40, height: 3)

        // The chord RoomPlan would emit: normal along +X, seated mid-sagitta, spanning the arc.
        let chord = PlaneRegistration.Plane(
            center: SIMD3(3.5, 1.5, 0), normal: SIMD3(1, 0, 0),
            xAxis: SIMD3(0, 0, 1), yAxis: SIMD3(0, 1, 0),
            width: 5.2, height: 3, category: .wall)

        let fitness = ARCoverageView.quadModelFitness(planes: [chord], verts: m.verts,
                                                      faces: m.faces, faceClasses: m.classData)[0]
        XCTAssertLessThan(fitness, ARCoverageView.quadModelMinExplainedRatio,
                          "a chord across a curve must be demoted, got \(fitness)")
    }

    /// The flat-room false demotion, reproduced: a straight wall's fitness band sweeps through the room
    /// corner and captures a deep strip of the PERPENDICULAR wall — mesh this quad could never explain,
    /// counted against it. In a small box room two corners rival the wall's own area, which demoted two
    /// genuinely straight walls at 14% and 49% on device. Perpendicular mesh must not count as present.
    func testStraightWall_isNotPunishedForItsCorners() {
        var m = MeshBuilder()
        // The wall under test: locally-straight band along Z at x≈400.
        m.addCurvedWall(radius: 400, startDeg: -0.3, endDeg: 0.3, height: 3)
        // A perpendicular wall crossing its band at one end: vertical, normal along Z, sitting at the
        // corner (z ≈ +2.1, spanning x from the wall inward — well inside the ±1 m fitness band).
        let base = m.verts.count
        for i in 0...16 {
            for j in 0...6 {
                m.verts.append(SIMD3(399.0 + Float(i) * 0.0625, Float(j) * 0.5, 2.1))
            }
        }
        for i in 0..<16 {
            for j in 0..<6 {
                let vid = { (a: Int, b: Int) in base + a * 7 + b }
                m.faces.append((vid(i, j), vid(i + 1, j), vid(i + 1, j + 1)))
                m.faces.append((vid(i, j), vid(i + 1, j + 1), vid(i, j + 1)))
                m.classes.append(1)
                m.classes.append(1)
            }
        }

        let wall = PlaneRegistration.Plane(
            center: SIMD3(400, 1.5, 0), normal: SIMD3(1, 0, 0),
            xAxis: SIMD3(0, 0, 1), yAxis: SIMD3(0, 1, 0),
            width: 4.2, height: 3, category: .wall)

        let fitness = ARCoverageView.quadModelFitness(planes: [wall], verts: m.verts,
                                                      faces: m.faces, faceClasses: m.classData)[0]
        XCTAssertGreaterThan(fitness, 0.9,
                             "the perpendicular wall at the corner must not count against this one, got \(fitness)")
    }

    /// The control: a straight wall quad on a straight (jittered) wall explains nearly all of it, and a
    /// PARTIAL scan of that wall must not lower the score — both sides of the ratio count only mesh
    /// that exists.
    func testStraightWall_scoresHighFitness_evenPartiallyScanned() {
        var m = MeshBuilder()
        // A vertical wall as a curved wall of enormous radius (locally straight), covering only 60%
        // of the quad's extent — the partial-scan case.
        m.addCurvedWall(radius: 400, startDeg: -0.36, endDeg: 0.36, height: 3)

        let wall = PlaneRegistration.Plane(
            center: SIMD3(400, 1.5, 0), normal: SIMD3(1, 0, 0),
            xAxis: SIMD3(0, 0, 1), yAxis: SIMD3(0, 1, 0),
            width: 8.4, height: 3, category: .wall)   // wider than the scanned 5 m stretch

        let fitness = ARCoverageView.quadModelFitness(planes: [wall], verts: m.verts,
                                                      faces: m.faces, faceClasses: m.classData)[0]
        XCTAssertGreaterThan(fitness, 0.9, "a straight wall explains its mesh, got \(fitness)")
    }

    /// The floor family's tolerance is 3° — a MEAN tolerance, as its own documentation says and as the
    /// support builder uses it. Graded per FACE it made a dead-flat floor's score a function of mesh
    /// resolution instead of geometry: at device-scale 5 cm faces with 1 cm reconstruction noise nearly
    /// every individual face tilts past 3°, so a perfectly level floor with no off-level mesh anywhere
    /// scored 4% and every RoomPlan floor quad was demoted. The cell mean is what noise cancels in.
    func testFloorQuadOnAJitteredFloor_scoresHighFitness() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-2)...2, z: (-2)...2, jitter: 0.01, cell: 0.05)

        let floor = PlaneRegistration.Plane(
            center: .zero, normal: SIMD3(0, 1, 0),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, 1),
            width: 4, height: 4, category: .floor)

        let fitness = ARCoverageView.quadModelFitness(planes: [floor], verts: m.verts,
                                                      faces: m.faces, faceClasses: m.classData)[0]
        XCTAssertGreaterThan(fitness, 0.9, "a flat floor explains its own mesh, got \(fitness)")
    }

    /// The other side of the same boundary: the cell mean must not launder a real slope. A floor quad
    /// laid over an 8° ramp explains none of it — every cell's mean normal is the ramp's, coherently
    /// off-level — so the quad is still demoted and the ramp survives as mesh.
    func testFloorQuadAcrossARamp_isStillDemoted() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-1.5)...1.5, z: 0...4, pitchDeg: 8, jitter: 0.01)

        let floor = PlaneRegistration.Plane(
            center: SIMD3(0, tan(8 * .pi / 180) * 2, 2), normal: SIMD3(0, 1, 0),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, 1),
            width: 3, height: 4, category: .floor)

        let fitness = ARCoverageView.quadModelFitness(planes: [floor], verts: m.verts,
                                                      faces: m.faces, faceClasses: m.classData)[0]
        XCTAssertLessThan(fitness, ARCoverageView.quadModelMinExplainedRatio,
                          "a floor quad over a ramp must be demoted, got \(fitness)")
    }

    /// The docstring's promise that thin scanning costs nothing has to survive per-cell grading. A cell
    /// holding one stray face has no orientation to speak of, so it leaves BOTH sides of the ratio;
    /// counting it as present-but-unexplained scored a decimated floor at 0.594 and demoted it for
    /// being sparsely scanned rather than for being the wrong shape.
    func testThinlyScannedFloor_isNotDemoted() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-3)...3, z: (-3)...3, jitter: 0.005, cell: 0.05)
        // Keep every 4th face — and its class byte, which runs parallel to `faces`.
        let kept = m.faces.indices.filter { $0 % 4 == 0 }
        let faces = kept.map { m.faces[$0] }
        let classes = Data(kept.map { m.classes[$0] })

        let floor = PlaneRegistration.Plane(
            center: .zero, normal: SIMD3(0, 1, 0),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, 1),
            width: 6, height: 6, category: .floor)

        let fitness = ARCoverageView.quadModelFitness(planes: [floor], verts: m.verts,
                                                      faces: faces, faceClasses: classes)[0]
        XCTAssertGreaterThan(fitness, 0.9, "a thinly scanned flat floor must not be demoted, got \(fitness)")
    }

    // MARK: - Per-cell quad support

    /// Two floor patches at the same height with a gap between them are two SURFACES, not one level
    /// with a spanning rectangle — the spanning box was observed on device as 6.3 m² of floor inside a
    /// 12.0×14.9 m quad reaching through walls and over a staircase. Contiguity now splits them at
    /// derivation, so each gets its own honest rectangle.
    func testDisconnectedPatches_becomeSeparateLevels() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-6)...(-3), z: (-1.5)...1.5)
        m.addSurface(y: 0, x: 3...6, z: (-1.5)...1.5)

        let out = levels(m)
        XCTAssertEqual(out.count, 2, "one component per patch, got \(out.map(\.width))")
        for level in out {
            XCTAssertEqual(level.width, 3.0, accuracy: 0.4, "each rectangle hugs its own patch")
            XCTAssertEqual(level.height, 3.0, accuracy: 0.4)
            XCTAssertEqual(level.center.y, 0, accuracy: 0.02)
        }
        // And nothing claims the gap: the point between the patches is off every rectangle.
        let masks = ARCoverageView.buildQuadSupport(planes: out, verts: m.verts,
                                                    faces: m.faces, faceClasses: m.classData)
        XCTAssertFalse(ARCoverageView.quadCovers(out, support: masks, SIMD3(0, 0, 0)),
                       "the gap between two separate levels was claimed")
    }

    /// The mask must not punch holes in a surface that really is continuous — that is what would make a
    /// thinly-scanned wall read patchy.
    func testContinuousSurface_isFullyBacked() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-2)...2, z: (-2)...2, jitter: 0.01)

        guard let level = levels(m).first else { return XCTFail("no level") }
        let mask = ARCoverageView.buildQuadSupport(planes: [level], verts: m.verts,
                                                   faces: m.faces, faceClasses: m.classData)[0]
        let (cols, rows) = ARCoverageView.quadSupportGrid(level)
        XCTAssertEqual(mask.keptCount, cols * rows, "a continuous floor must be backed everywhere")
    }

    /// Presence alone cannot decide support, and the reason is circular: a ramp crossing a level's height
    /// is itself floor-class and within the coverage distance, so it backs the very cells that then
    /// exclude it. This pins the orientation test directly — a cell whose only content is sloped must not
    /// count as part of a level.
    func testCellBackedOnlyBySlopedFaces_isNotPartOfALevel() {
        let level = PlaneRegistration.Plane(
            center: .zero, normal: SIMD3(0, 1, 0),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, 1),
            width: 4, height: 4, category: .floor)

        var flat = MeshBuilder()
        flat.addSurface(y: 0, x: (-2)...2, z: (-2)...2)
        let flatMask = ARCoverageView.buildQuadSupport(planes: [level], verts: flat.verts,
                                                       faces: flat.faces, faceClasses: flat.classData)[0]
        XCTAssertGreaterThan(flatMask.keptCount, 0, "a real floor must back its cells")

        // A ramp crossing y=0 inside the rectangle: same class, within the coverage distance, but sloped.
        var ramp = MeshBuilder()
        ramp.addSurface(y: -0.2, x: (-2)...2, z: (-2)...2, pitchDeg: 8)
        let rampMask = ARCoverageView.buildQuadSupport(planes: [level], verts: ramp.verts,
                                                       faces: ramp.faces, faceClasses: ramp.classData)[0]
        XCTAssertEqual(rampMask.keptCount, 0,
                       "sloped faces crossing the plane must not back it — that is what sliced the ramp")
    }

    /// The end-to-end consequence: a ramp crossing a level's height stays a ramp candidate instead of
    /// being absorbed. Without the orientation test the level's rectangle eats the ramp's band, which on a
    /// real scan (three such rectangles) left nothing fittable and reported no ramp at all.
    func testRampCrossingALevel_survivesAsACandidate() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-6)...(-3), z: (-2)...2)      // floor patch
        m.addSurface(y: 0, x: 3...6, z: (-2)...2)            // and another, far away
        // A ramp in the empty middle, climbing through y=0 well inside the spanning rectangle.
        m.addSurface(y: -0.35, x: (-1)...1, z: (-2)...2.5, pitchDeg: 8)

        let lv = levels(m)
        let support = ARCoverageView.buildQuadSupport(planes: lv, verts: m.verts, faces: m.faces,
                                                      faceClasses: m.classData)
        let fitted = ARCoverageView.deriveRampPlanes(verts: m.verts, faces: m.faces,
                                                     faceClasses: m.classData, explainedBy: lv,
                                                     support: support).ramps
        XCTAssertEqual(fitted.count, 1, "the ramp must survive the level's spanning rectangle")
        let tilt = acos(min(abs(fitted[0].normal.y), 1)) * 180 / .pi
        XCTAssertEqual(tilt, 8, accuracy: 1.5)
    }

    /// Where a ramp rises into a landing, their tolerance bands overlap for metres: at 2.8° the whole
    /// top 3 m of run sits within 15 cm of the landing plane, and the cell tilt gate cannot help (2.8°
    /// is under its 3° threshold). First-match assignment let the landing back those cells, square
    /// itself outward over the slope, and subtract mesh the ramp owned. Assignment must be competitive:
    /// the overlap belongs to whichever plane fits it best.
    func testRampRisingIntoALanding_belongsToTheRampNotTheLanding() {
        var m = MeshBuilder()
        m.addSurface(y: 0, x: (-1)...1, z: 0...6, pitchDeg: 2.8)   // ramp rising to y≈0.29

        let rise = tan(Float(2.8) * .pi / 180) * 6
        let ramp = PlaneRegistration.Plane(
            center: SIMD3(0, rise / 2, 3),
            normal: simd_normalize(SIMD3(0, cos(2.8 * Float.pi / 180), -sin(2.8 * Float.pi / 180))),
            xAxis: SIMD3(1, 0, 0),
            yAxis: simd_normalize(SIMD3(0, sin(2.8 * Float.pi / 180), cos(2.8 * Float.pi / 180))),
            width: 2, height: 6, category: .floor)
        // A landing plane at the ramp's top height whose rectangle over-reaches back over the slope —
        // the device geometry, deliberately.
        let landing = PlaneRegistration.Plane(
            center: SIMD3(0, rise, 4.5), normal: SIMD3(0, 1, 0),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, 1),
            width: 2, height: 5, category: .floor)

        let masks = ARCoverageView.buildQuadSupport(planes: [landing, ramp], verts: m.verts,
                                                    faces: m.faces, faceClasses: m.classData,
                                                    dilateBy: 0)
        XCTAssertEqual(masks[0].keptCount, 0,
                       "every face lies ON the ramp plane — the landing must win none of them")
        XCTAssertGreaterThan(masks[1].keptCount, 0)

        // And coverage follows the same rule: a point on the ramp's surface inside the landing's
        // over-reached rectangle is covered by the ramp, not swallowed by the landing.
        let onRamp = SIMD3<Float>(0, tan(2.8 * Float.pi / 180) * 4.5, 4.5)
        XCTAssertEqual(ARCoverageView.quadCoverage([landing, ramp], support: masks, onRamp), .covered)
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
