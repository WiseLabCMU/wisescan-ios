import XCTest
import simd
@testable import wisescan_ios

/// Byte-level lock on `FeaturePointCloudFile.encode` — the serializer behind `arkit_features.bin`.
///
/// This is the only automated signal the feature-cloud export has. Everything upstream of `encode`
/// needs a real device: `ARSession.getCurrentWorldMap` never yields a map in the Simulator, so the
/// producer path (capture → world map → `rawFeaturePoints` → staged sidecar) cannot run here, and
/// nothing else in wisescan-iosTests touches export staging. What *is* checkable is the part a
/// consumer actually parses, and that part is pure: two parallel arrays in, bytes out.
///
/// So these tests pin the wire format itself, deliberately duplicating the spec rather than calling
/// any decoder the app owns:
///
///   * the header is a fixed-width 128-byte ASCII block — `ARKITFEAT 1\n`, `count <N>\n`,
///     `dtype id:u8,x:f4,y:f4,z:f4\n`, `frame raw\n` — with byte 128 a newline, so a reader can
///     `seek(128)` and start reading records without parsing anything it does not recognise;
///   * the record stride is exactly 20 bytes with no padding, which is what makes
///     `128 + 20 * N == filesize` a usable integrity check and what lets numpy read the body as a
///     single structured `fromfile`;
///   * every field round-trips **little-endian and bit-exact**. The ids are the sharp edge: ARKit
///     feature identifiers are `UInt64` and routinely occupy the high bits, so anything that casts
///     one through `Float` (53-bit mantissa) or `Int32` on the way out silently rewrites a point's
///     identity. That is invisible in a single scan and only shows up later as a failed
///     across-session id match, so `UInt64.max` and a value straddling `1 << 63` are checked here.
///
/// Every byte compared below is synthesized in-process. No captured `.features` fixture from a real
/// scan is committed — see `scripts/check-privacy.sh`; a real feature cloud is a spatial record of
/// someone's room.
final class FeaturePointCloudFileTests: XCTestCase {

    // MARK: - Format constants (restated, not imported)

    private let headerSize = 128
    private let recordStride = 20

    // MARK: - Byte readers
    //
    // Deliberately assembled a byte at a time rather than via `loadUnaligned`, so the assertions
    // prove little-endian ordering instead of inheriting whatever the host CPU happens to be. Also
    // sidesteps alignment: an id at offset 128 + 20*i is only 4-byte aligned on odd records.

    private func u64LE(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in (0..<8).reversed() {
            value = (value << 8) | UInt64(data[data.startIndex + offset + i])
        }
        return value
    }

    private func f32LE(_ data: Data, at offset: Int) -> Float {
        var bits: UInt32 = 0
        for i in (0..<4).reversed() {
            bits = (bits << 8) | UInt32(data[data.startIndex + offset + i])
        }
        return Float(bitPattern: bits)
    }

    private func record(_ data: Data, _ index: Int) -> (id: UInt64, point: SIMD3<Float>) {
        let base = headerSize + recordStride * index
        return (u64LE(data, at: base),
                SIMD3<Float>(f32LE(data, at: base + 8),
                             f32LE(data, at: base + 12),
                             f32LE(data, at: base + 16)))
    }

    /// The header as text. Any padding the writer uses (spaces, newlines, NULs) survives the
    /// decode, so `contains` checks stay valid whichever it picked.
    private func headerText(_ data: Data) -> String {
        String(decoding: data.prefix(headerSize), as: UTF8.self)
    }

    /// Synthetic cloud whose ids sweep the whole 64-bit range (odd golden-ratio multiplier, so the
    /// high bits are populated from the second record on) and whose coordinates are negative,
    /// fractional and exactly representable.
    private func synthetic(count: Int) -> (ids: [UInt64], points: [SIMD3<Float>]) {
        var ids: [UInt64] = []
        var points: [SIMD3<Float>] = []
        ids.reserveCapacity(count)
        points.reserveCapacity(count)
        for i in 0..<count {
            ids.append(UInt64(i) &* 0x9E37_79B9_7F4A_7C15 &+ 1)
            points.append(SIMD3<Float>(Float(i) * 0.5, Float(i) * -0.25, Float(i) + 0.125))
        }
        return (ids, points)
    }

    private func assertRoundTrips(_ ids: [UInt64], _ points: [SIMD3<Float>],
                                  file: StaticString = #filePath, line: UInt = #line) {
        let data = FeaturePointCloudFile.encode(ids: ids, points: points)
        let expected = min(ids.count, points.count)
        XCTAssertEqual(data.count, headerSize + recordStride * expected,
                       "record body must be a bare 20-byte stride", file: file, line: line)
        for i in 0..<expected {
            let got = record(data, i)
            XCTAssertEqual(got.id, ids[i], "id \(i) did not survive the round trip",
                           file: file, line: line)
            for axis in 0..<3 {
                XCTAssertEqual(got.point[axis].bitPattern, points[i][axis].bitPattern,
                               "coordinate \(axis) of point \(i) is not bit-exact",
                               file: file, line: line)
            }
        }
    }

    // MARK: - Header

    func testHeader_isExactly128Bytes_withTheDocumentedFields() {
        let (ids, points) = synthetic(count: 3)
        let data = FeaturePointCloudFile.encode(ids: ids, points: points)

        XCTAssertGreaterThanOrEqual(data.count, headerSize)
        // Magic + version first, byte for byte: a consumer sniffs these 12 bytes before anything else.
        XCTAssertEqual(data.prefix(12), Data("ARKITFEAT 1\n".utf8))

        let header = headerText(data)
        XCTAssertTrue(header.contains("count 3\n"), "header was: \(header.debugDescription)")
        XCTAssertTrue(header.contains("dtype id:u8,x:f4,y:f4,z:f4\n"),
                      "header was: \(header.debugDescription)")
        XCTAssertTrue(header.contains("frame raw\n"), "header was: \(header.debugDescription)")

        // Byte 128 (index 127) is a newline, so the fixed-width block always ends on a line break
        // and a text-oriented reader never runs into the binary body mid-line.
        XCTAssertEqual(data[data.startIndex + headerSize - 1], UInt8(ascii: "\n"))
    }

    func testHeader_countTracksTheRecordsActuallyWritten() {
        for n in [0, 1, 2, 7, 64, 1000] {
            let (ids, points) = synthetic(count: n)
            let data = FeaturePointCloudFile.encode(ids: ids, points: points)
            XCTAssertTrue(headerText(data).contains("count \(n)\n"),
                          "count \(n) missing from header: \(headerText(data).debugDescription)")
        }
    }

    // MARK: - Layout

    func testTotalSize_is128PlusTwentyPerRecord() {
        // No per-record padding and no trailing block: the whole point of the fixed header is that
        // (filesize - 128) / 20 is the record count, checkable without reading the body.
        for n in [0, 1, 2, 3, 7, 64, 1000] {
            let (ids, points) = synthetic(count: n)
            let data = FeaturePointCloudFile.encode(ids: ids, points: points)
            XCTAssertEqual(data.count, 128 + 20 * n, "size wrong for \(n) records")
        }
    }

    func testEmptyInput_isHeaderOnly() {
        let data = FeaturePointCloudFile.encode(ids: [], points: [])
        XCTAssertEqual(data.count, headerSize)
        XCTAssertEqual(data.prefix(12), Data("ARKITFEAT 1\n".utf8))
        XCTAssertTrue(headerText(data).contains("count 0\n"),
                      "header was: \(headerText(data).debugDescription)")
        XCTAssertEqual(data[data.startIndex + headerSize - 1], UInt8(ascii: "\n"))
    }

    // MARK: - Round trip

    func testRecords_roundTripLittleEndian() {
        let (ids, points) = synthetic(count: 32)
        assertRoundTrips(ids, points)
    }

    /// The regression this file exists for. Every id here is destroyed by a cast that is otherwise
    /// easy to write without noticing: `Float`/`Float32` loses everything past 24 bits of mantissa,
    /// `Double` past 53, `Int32`/`UInt32` past 32, and `Int64` flips the sign on anything at or
    /// above `1 << 63`. Only a straight 8-byte little-endian store gets all of them back.
    func testIdentifiers_survivePastTheFloatAndInt32Cliffs() {
        let ids: [UInt64] = [
            0,
            1,
            (1 << 24) + 1,              // first integer a Float32 cannot represent exactly
            (1 << 32) - 1,              // last UInt32
            1 << 32,                    // first value an Int32/UInt32 cast truncates to 0
            (1 << 53) + 1,              // first integer a Double cannot represent exactly
            (1 << 63) - 1,              // last positive Int64
            1 << 63,                    // negative as Int64
            (1 << 63) + 1,
            UInt64.max
        ]
        let points = (0..<ids.count).map { SIMD3<Float>(Float($0), Float($0) * -1, 0.5) }
        assertRoundTrips(ids, points)

        // Stated again without the helper, so a broken helper cannot hide the headline case.
        let data = FeaturePointCloudFile.encode(ids: ids, points: points)
        XCTAssertEqual(record(data, ids.count - 1).id, UInt64.max)
        XCTAssertEqual(record(data, 7).id, 1 << 63)
    }

    func testCoordinates_areBitExactForNegativeAndFractionalValues() {
        let points: [SIMD3<Float>] = [
            SIMD3<Float>(-1.5, 0.1, 1.0 / 3.0),
            SIMD3<Float>(-0.0, Float.leastNormalMagnitude, -123.456),
            SIMD3<Float>(Float.pi, -Float.ulpOfOne, 16_777_216.0)
        ]
        let ids: [UInt64] = [7, 8, UInt64.max - 1]
        assertRoundTrips(ids, points)

        // -0.0 is the one case `==` would wave through: it compares equal to 0.0. Pin the sign bit.
        let data = FeaturePointCloudFile.encode(ids: ids, points: points)
        XCTAssertEqual(record(data, 1).point.x.bitPattern, Float(-0.0).bitPattern)
    }

    // MARK: - Mismatched inputs

    func testMismatchedLengths_writeMinCountAndSaySoInTheHeader() {
        // `ARPointCloud.identifiers` and `.points` are separate bridged arrays; a short read of
        // either must truncate, never write a garbage or zero-filled tail.
        let (longIDs, shortPoints) = (synthetic(count: 9).ids, synthetic(count: 4).points)
        let a = FeaturePointCloudFile.encode(ids: longIDs, points: shortPoints)
        XCTAssertEqual(a.count, headerSize + recordStride * 4)
        XCTAssertTrue(headerText(a).contains("count 4\n"),
                      "header was: \(headerText(a).debugDescription)")
        assertRoundTrips(longIDs, shortPoints)

        let (shortIDs, longPoints) = (synthetic(count: 2).ids, synthetic(count: 6).points)
        let b = FeaturePointCloudFile.encode(ids: shortIDs, points: longPoints)
        XCTAssertEqual(b.count, headerSize + recordStride * 2)
        XCTAssertTrue(headerText(b).contains("count 2\n"),
                      "header was: \(headerText(b).debugDescription)")
        assertRoundTrips(shortIDs, longPoints)

        // One empty side is the degenerate case of the same rule, and the one most likely to be
        // hit for real: a world map whose feature cloud came back empty.
        let c = FeaturePointCloudFile.encode(ids: synthetic(count: 5).ids, points: [])
        XCTAssertEqual(c.count, headerSize)
        XCTAssertTrue(headerText(c).contains("count 0\n"),
                      "header was: \(headerText(c).debugDescription)")
    }
}
