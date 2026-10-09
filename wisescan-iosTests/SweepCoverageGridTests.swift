import XCTest
import simd
@testable import wisescan_ios

/// Locks the sweep-coverage grid's binning, voxel traversal, and free/surface integration.
/// Pure Foundation + simd, so it runs in the Simulator.
final class SweepCoverageGridTests: XCTestCase {
    private let cell: Float = 0.5

    private func walk(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> [SIMD3<Int32>] {
        var out: [SIMD3<Int32>] = []
        SweepCoverageGrid.traverse(from: a, to: b, cellSize: cell) { out.append($0) }
        return out
    }

    // MARK: - Traversal

    func testAxisAlignedTraversal() {
        let cells = walk(SIMD3(0.1, 0.1, 0.1), SIMD3(1.3, 0.1, 0.1))
        XCTAssertEqual(cells, [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(2, 0, 0)])
    }

    func testDiagonalTraversalStepsOneAxisAtATime() {
        let cells = walk(SIMD3(0.25, 0.25, 0.25), SIMD3(1.25, 1.25, 1.25))
        XCTAssertEqual(cells.first, SIMD3(0, 0, 0))
        XCTAssertEqual(cells.last, SIMD3(2, 2, 2))
        XCTAssertEqual(cells.count, 7)
        for (p, q) in zip(cells, cells.dropFirst()) {
            let d = q &- p
            XCTAssertEqual(abs(d.x) + abs(d.y) + abs(d.z), 1, "\(p) -> \(q)")
        }
    }

    func testStartOnBoundary() {
        XCTAssertEqual(walk(SIMD3(0.5, 0.1, 0.1), SIMD3(0.9, 0.1, 0.1)).first, SIMD3(1, 0, 0))
        XCTAssertEqual(walk(SIMD3(0.5, 0.1, 0.1), SIMD3(0.2, 0.1, 0.1)),
                       [SIMD3(1, 0, 0), SIMD3(0, 0, 0)])
    }

    func testZeroLengthRayVisitsOneCell() {
        let p = SIMD3<Float>(0.3, -0.7, 1.1)
        XCTAssertEqual(walk(p, p).count, 1)
    }

    func testNegativeCoordinatesFloorBin() {
        XCTAssertEqual(SweepCoverageGrid.cellKey(SIMD3(-0.1, 0.1, -0.6), cellSize: cell),
                       SIMD3(-1, 0, -2))
    }

    // MARK: - Integration

    func testFreeThenSurfaceAlongRay() {
        var grid = SweepCoverageGrid(cellSize: cell)
        let r = grid.integrate(origin: SIMD3(0.1, 0.1, 0.1),
                               rays: [SweepRay(direction: SIMD3(1, 0, 0), depth: 1.2)])
        XCTAssertEqual(r.raysIntegrated, 1)
        XCTAssertEqual(r.cellsTouched, 3)
        XCTAssertEqual(grid.cells[SIMD3(0, 0, 0)], SweepCoverageCell(free: 1, surface: 0, visits: 1))
        XCTAssertEqual(grid.cells[SIMD3(1, 0, 0)], SweepCoverageCell(free: 1, surface: 0, visits: 1))
        XCTAssertEqual(grid.cells[SIMD3(2, 0, 0)], SweepCoverageCell(free: 0, surface: 1, visits: 1))
    }

    func testTwoRaysCrossingSameCellIncrementOnce() {
        var grid = SweepCoverageGrid(cellSize: cell)
        let dir = SIMD3<Float>(1, 0, 0)
        grid.integrate(origin: SIMD3(0.1, 0.1, 0.1),
                       rays: [SweepRay(direction: dir, depth: 1.2), SweepRay(direction: dir, depth: 1.3)])
        XCTAssertEqual(grid.cells[SIMD3(0, 0, 0)]?.free, 1)
        XCTAssertEqual(grid.cells[SIMD3(1, 0, 0)]?.free, 1)
        XCTAssertEqual(grid.cells[SIMD3(2, 0, 0)]?.surface, 1)
    }

    func testCellCanBeBothFreeAndSurface() {
        var grid = SweepCoverageGrid(cellSize: cell)
        let dir = SIMD3<Float>(1, 0, 0)
        // Short ray ends in x=1; long ray passes through x=1 to end in x=2.
        grid.integrate(origin: SIMD3(0.1, 0.1, 0.1),
                       rays: [SweepRay(direction: dir, depth: 0.6), SweepRay(direction: dir, depth: 1.2)])
        XCTAssertEqual(grid.cells[SIMD3(1, 0, 0)], SweepCoverageCell(free: 1, surface: 1, visits: 1))
    }

    func testMaxRangeTruncation() {
        var grid = SweepCoverageGrid(cellSize: cell)
        let r = grid.integrate(origin: SIMD3(0.1, 0.1, 0.1),
                               rays: [SweepRay(direction: SIMD3(1, 0, 0), depth: 9)],
                               maxRange: 2)
        XCTAssertEqual(r.raysTruncated, 1)
        XCTAssertEqual(r.raysIntegrated, 1)
        XCTAssertTrue(grid.cells.values.allSatisfy { $0.surface == 0 })
        // Cap endpoint x = 2.1 → cell 4; free on 0...4, nothing beyond.
        for x: Int32 in 0...4 { XCTAssertEqual(grid.cells[SIMD3(x, 0, 0)]?.free, 1, "x=\(x)") }
        XCTAssertNil(grid.cells[SIMD3(5, 0, 0)])
        XCTAssertEqual(grid.cells.count, 5)
    }

    func testInvalidDepthsMarkNothing() {
        var grid = SweepCoverageGrid(cellSize: cell)
        let dir = SIMD3<Float>(1, 0, 0)
        let r = grid.integrate(origin: .zero, rays: [
            SweepRay(direction: dir, depth: .nan),
            SweepRay(direction: dir, depth: 0),
            SweepRay(direction: dir, depth: -1),
        ])
        XCTAssertEqual(r.raysInvalid, 3)
        XCTAssertEqual(r.raysIntegrated, 0)
        XCTAssertEqual(r.raysTruncated, 0)
        XCTAssertEqual(r.cellsTouched, 0)
        XCTAssertTrue(grid.cells.isEmpty)
    }

    func testSaturatingIncrementDoesNotWrap() {
        var v: UInt16 = 65534
        SweepCoverageCell.saturatingIncrement(&v)
        XCTAssertEqual(v, 65535)
        SweepCoverageCell.saturatingIncrement(&v)
        XCTAssertEqual(v, 65535)
    }

    func testVisitsCountUpdatesNotRays() {
        var grid = SweepCoverageGrid(cellSize: cell)
        let dir = SIMD3<Float>(1, 0, 0)
        let rays = Array(repeating: SweepRay(direction: dir, depth: 1.2), count: 10)
        grid.integrate(origin: SIMD3(0.1, 0.1, 0.1), rays: rays)
        grid.integrate(origin: SIMD3(0.1, 0.1, 0.1), rays: rays)
        XCTAssertEqual(grid.cells[SIMD3(0, 0, 0)]?.visits, 2)
        XCTAssertEqual(grid.cells[SIMD3(2, 0, 0)]?.visits, 2)
        XCTAssertEqual(grid.cells[SIMD3(2, 0, 0)]?.surface, 2)
    }

    func testResetAndSnapshot() {
        var grid = SweepCoverageGrid(cellSize: cell)
        grid.integrate(origin: .zero, rays: [SweepRay(direction: SIMD3(0, 1, 0), depth: 1)])
        let snap = grid.snapshot(stats: SweepCoverageStats())
        XCTAssertEqual(snap.cellSize, cell)
        XCTAssertEqual(snap.cells, grid.cells)
        grid.reset()
        XCTAssertTrue(grid.cells.isEmpty)
        XCTAssertEqual(SweepCoverageSnapshot.empty(cellSize: cell).cells.count, 0)
    }

    // MARK: - Incremental cell counts (the live readout's source; never a walk of `cells`)

    private func recount(_ grid: SweepCoverageGrid) -> (free: Int, surface: Int) {
        (grid.cells.values.filter { $0.free > 0 }.count, grid.cells.values.filter { $0.surface > 0 }.count)
    }

    func testCellCountsCountFirstObservationOnly() {
        var grid = SweepCoverageGrid(cellSize: cell)
        XCTAssertEqual(grid.freeCellCount, 0)
        XCTAssertEqual(grid.surfaceCellCount, 0)
        let dir = SIMD3<Float>(1, 0, 0)
        // Free x=0,1; surface x=2.
        grid.integrate(origin: SIMD3(0.1, 0.1, 0.1), rays: [SweepRay(direction: dir, depth: 1.2)])
        XCTAssertEqual(grid.freeCellCount, 2)
        XCTAssertEqual(grid.surfaceCellCount, 1)
        // Re-observing adds nothing; a shorter ray makes free cell x=1 a surface cell as well.
        grid.integrate(origin: SIMD3(0.1, 0.1, 0.1), rays: [SweepRay(direction: dir, depth: 1.2)])
        grid.integrate(origin: SIMD3(0.1, 0.1, 0.1), rays: [SweepRay(direction: dir, depth: 0.7)])
        XCTAssertEqual(grid.freeCellCount, 2)
        XCTAssertEqual(grid.surfaceCellCount, 2)
        grid.reset()
        XCTAssertEqual(grid.freeCellCount, 0)
        XCTAssertEqual(grid.surfaceCellCount, 0)
    }

    func testCellCountsMatchRecountOverManyUpdates() {
        var grid = SweepCoverageGrid(cellSize: cell)
        // Fixed-seed LCG: deterministic rays in all directions, including truncated ones.
        var state: UInt64 = 0x5EED
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24)
        }
        for _ in 0..<40 {
            let origin = SIMD3<Float>(next(), next(), next()) * 4 - 2
            let rays = (0..<25).map { _ in
                SweepRay(direction: simd_normalize(SIMD3<Float>(next(), next(), next()) - 0.5),
                         depth: 0.2 + next() * 7)
            }
            grid.integrate(origin: origin, rays: rays)
            let expected = recount(grid)
            XCTAssertEqual(grid.freeCellCount, expected.free)
            XCTAssertEqual(grid.surfaceCellCount, expected.surface)
        }
        XCTAssertGreaterThan(grid.surfaceCellCount, 0)
    }
}
