import XCTest
import simd
@testable import wisescan_ios

/// Byte-level lock on `SweepCoverageFile`, the serializer behind `sweep_coverage.bin`.
///
/// Like `FeaturePointCloudFileTests`, the wire format is restated here rather than imported:
/// a 512-byte ASCII header whose last byte is `\n`, then packed 18-byte little-endian records
/// (`i,j,k: Int32`, `free,surface,visits: UInt16`) sorted by `(k, j, i)`. Every byte compared
/// below is synthesized in-process; no captured grid from a real room is committed.
final class SweepCoverageFileTests: XCTestCase {

    // MARK: - Format constants (restated, not imported)

    private let headerSize = 512
    private let recordStride = 18

    private func headerText(_ data: Data) -> String {
        String(decoding: data.prefix(headerSize), as: UTF8.self)
    }

    /// Every stats/rays counter at its type's maximum: the longest header today's fields allow.
    private func maxedStats() -> SweepCoverageStats {
        var stats = SweepCoverageStats()
        stats.framesProcessed = .max
        stats.framesDroppedBusy = .max
        stats.framesDroppedRate = .max
        stats.framesSkippedTracking = .max
        stats.framesSkippedNoDepth = .max
        stats.raysIntegrated = .max
        stats.raysTruncated = .max
        stats.raysLowConfidence = .max
        stats.raysInvalidDepth = .max
        stats.depthEverAvailable = true
        return stats
    }

    private func populated() -> SweepCoverageSnapshot {
        var cells: [SIMD3<Int32>: SweepCoverageCell] = [:]
        cells[SIMD3(0, 0, 0)] = SweepCoverageCell(free: 1, surface: 0, visits: 1)
        cells[SIMD3(-1, -2, -3)] = SweepCoverageCell(free: 0, surface: 7, visits: 7)
        cells[SIMD3(Int32.min, Int32.max, -1)] = SweepCoverageCell(free: 65535, surface: 65535, visits: 65535)
        cells[SIMD3(12, -40, 3)] = SweepCoverageCell(free: 300, surface: 2, visits: 301)
        cells[SIMD3(5, 5, 0)] = SweepCoverageCell(free: 0x1234, surface: 0xABCD, visits: 0xFFFE)
        var stats = SweepCoverageStats()
        stats.framesProcessed = 3000
        stats.framesDroppedBusy = 12
        stats.framesDroppedRate = 33000
        stats.framesSkippedTracking = 41
        stats.framesSkippedNoDepth = 2
        stats.raysIntegrated = 900_000
        stats.raysTruncated = 81_234
        stats.raysLowConfidence = 45_678
        stats.raysInvalidDepth = 9_876
        stats.depthEverAvailable = true
        return SweepCoverageSnapshot(cellSize: 0.5, cells: cells, stats: stats)
    }

    // MARK: - Round trip

    func testRoundTrip_populatedSnapshot() throws {
        let s = populated()
        let data = SweepCoverageFile.encode(s)
        XCTAssertEqual(data.count, headerSize + recordStride * s.cells.count)
        XCTAssertEqual(try SweepCoverageFile.decode(data), s)
    }

    func testRoundTrip_emptySnapshot_isHeaderOnly() throws {
        let s = SweepCoverageSnapshot.empty()
        let data = SweepCoverageFile.encode(s)
        XCTAssertEqual(data.count, headerSize)
        XCTAssertTrue(headerText(data).contains("count 0\n"), headerText(data).debugDescription)
        XCTAssertTrue(headerText(data).contains("depth=0"), headerText(data).debugDescription)
        XCTAssertEqual(try SweepCoverageFile.decode(data), s)
    }

    func testEncode_isDeterministic() {
        XCTAssertEqual(SweepCoverageFile.encode(populated()), SweepCoverageFile.encode(populated()))
    }

    // MARK: - Header

    func testHeader_isExactly512Bytes_withTheDocumentedFields() {
        let data = SweepCoverageFile.encode(populated())
        XCTAssertEqual(data.prefix(11), Data("SWEEPCOV 1\n".utf8))
        XCTAssertEqual(data[data.startIndex + headerSize - 1], UInt8(ascii: "\n"))

        let header = headerText(data)
        for line in ["count 5\n",
                     "cell 0.5\n",
                     "dtype i:i4,j:i4,k:i4,free:u2,surface:u2,visits:u2\n",
                     "frame raw\n",
                     "stats frames=3000 drop_busy=12 drop_rate=33000 skip_tracking=41 skip_nodepth=2 depth=1\n",
                     "rays integrated=900000 truncated=81234 lowconf=45678 invalid=9876\n"] {
            XCTAssertTrue(header.contains(line), "missing \(line.debugDescription) in \(header.debugDescription)")
        }
        // Everything after the last line is space padding up to the terminating newline.
        let body = header.dropLast()
        XCTAssertTrue(body.hasSuffix(" ") || body.hasSuffix("\n"))
    }

    // MARK: - Header budget (a save must never trap on the header)

    func testRoundTrip_everyCounterAtItsTypeMaximum_staysInTheHeaderAndDecodes() throws {
        var s = populated()
        s.stats = maxedStats()
        let data = SweepCoverageFile.encode(s)
        XCTAssertEqual(data.count, headerSize + recordStride * s.cells.count)
        XCTAssertEqual(data[data.startIndex + headerSize - 1], UInt8(ascii: "\n"))

        // Real values, not the withheld sentinel (which would also decode to .max).
        let u32 = "4294967295", u64 = "18446744073709551615"
        let header = headerText(data)
        for line in ["stats frames=\(u32) drop_busy=\(u32) drop_rate=\(u32) skip_tracking=\(u32)"
                        + " skip_nodepth=\(u32) depth=1\n",
                     "rays integrated=\(u64) truncated=\(u64) lowconf=\(u64) invalid=\(u64)\n"] {
            XCTAssertTrue(header.contains(line), "missing \(line.debugDescription) in \(header.debugDescription)")
        }
        XCTAssertEqual(try SweepCoverageFile.decode(data), s)
    }

    func testHeader_worstCaseFitsTheBudgetWithoutWithholding() {
        // The longest values each header field can take: Int.max cells, a 15-character Float
        // description (the longest Swift produces), and every counter at its type's maximum.
        let cell: Float = -1.01779427e+12
        XCTAssertEqual("\(cell)".count, 15)
        let header = SweepCoverageFile.header(count: .max, cellSize: cell, stats: maxedStats())
        XCTAssertEqual(header.count, headerSize)

        let text = String(decoding: header, as: UTF8.self)
        XCTAssertTrue(text.contains("count 9223372036854775807\n"), text.debugDescription)
        XCTAssertTrue(text.contains("cell -1.01779427e+12\n"), text.debugDescription)
        XCTAssertFalse(text.contains("=-1"), text.debugDescription)

        // Bytes in use: the seven lines, then the terminating newline. Pinned so a new header key
        // forces the "Header budget" arithmetic in SweepCoverageFile's doc comment to be redone.
        let bytes = [UInt8](header)
        let linesEnd = bytes.dropLast().lastIndex { $0 != UInt8(ascii: " ") }! + 1
        XCTAssertEqual(linesEnd + 1, 368)
    }

    func testHeader_overBudget_withholdsCountersInsteadOfTrapping() {
        // At a 300-byte budget these values need 338 bytes; withheld they need 226.
        let header = SweepCoverageFile.header(count: 5, cellSize: 0.5, stats: maxedStats(), byteCount: 300)
        XCTAssertEqual(header.count, 300)
        XCTAssertEqual(header.last, UInt8(ascii: "\n"))

        let text = String(decoding: header, as: UTF8.self)
        for line in ["SWEEPCOV 1\n",
                     "count 5\n",
                     "cell 0.5\n",
                     "stats frames=-1 drop_busy=-1 drop_rate=-1 skip_tracking=-1 skip_nodepth=-1 depth=1\n",
                     "rays integrated=-1 truncated=-1 lowconf=-1 invalid=-1\n"] {
            XCTAssertTrue(text.contains(line), "missing \(line.debugDescription) in \(text.debugDescription)")
        }
    }

    func testHeader_fixedTextOverBudget_truncatesInsteadOfTrapping() {
        let header = SweepCoverageFile.header(count: 5, cellSize: 0.5, stats: maxedStats(), byteCount: 64)
        XCTAssertEqual(header.count, 64)
        XCTAssertEqual(header.last, UInt8(ascii: "\n"))
        XCTAssertEqual(header.prefix(11), Data("SWEEPCOV 1\n".utf8))
    }

    func testDecode_readsWithheldCountersAsSaturated() throws {
        var text = "SWEEPCOV 1\ncount 5\ncell 0.5\n"
        text += "dtype i:i4,j:i4,k:i4,free:u2,surface:u2,visits:u2\nframe raw\n"
        text += "stats frames=-1 drop_busy=-1 drop_rate=-1 skip_tracking=-1 skip_nodepth=-1 depth=1\n"
        text += "rays integrated=-1 truncated=-1 lowconf=-1 invalid=-1\n"
        var data = Data(text.utf8)
        data.append(Data(repeating: UInt8(ascii: " "), count: headerSize - data.count - 1))
        data.append(UInt8(ascii: "\n"))
        let full = SweepCoverageFile.encode(populated())
        data.append(full.suffix(from: full.startIndex + headerSize))

        let decoded = try SweepCoverageFile.decode(data)
        XCTAssertEqual(decoded.cellSize, 0.5)
        XCTAssertEqual(decoded.cells, populated().cells)
        XCTAssertEqual(decoded.stats, maxedStats())
    }

    // MARK: - Layout

    func testRecords_areLittleEndianSortedByKJI_atOffset512() {
        var cells: [SIMD3<Int32>: SweepCoverageCell] = [:]
        // Inserted out of (k, j, i) order; the expected order is spelled out below.
        cells[SIMD3(2, 0, 1)] = SweepCoverageCell(free: 0x0102, surface: 0x0304, visits: 0xFFFF)
        cells[SIMD3(-1, 0, 0)] = SweepCoverageCell(free: 1, surface: 2, visits: 3)
        cells[SIMD3(0, -1, 1)] = SweepCoverageCell(free: 0, surface: 0x8000, visits: 0x8000)
        let s = SweepCoverageSnapshot(cellSize: 0.5, cells: cells, stats: SweepCoverageStats())
        let data = SweepCoverageFile.encode(s)

        func le32(_ v: Int32) -> [UInt8] {
            let u = UInt32(bitPattern: v)
            return [UInt8(u & 0xFF), UInt8((u >> 8) & 0xFF), UInt8((u >> 16) & 0xFF), UInt8(u >> 24)]
        }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

        // Sorted by k, then j, then i: (-1,0,0) [k0], (0,-1,1) [k1,j-1], (2,0,1) [k1,j0].
        var expected: [UInt8] = []
        expected += le32(-1) + le32(0) + le32(0) + le16(1) + le16(2) + le16(3)
        expected += le32(0) + le32(-1) + le32(1) + le16(0) + le16(0x8000) + le16(0x8000)
        expected += le32(2) + le32(0) + le32(1) + le16(0x0102) + le16(0x0304) + le16(0xFFFF)

        // Spot-check the hand synthesis itself so a broken helper cannot hide a broken encoder.
        XCTAssertEqual(Array(expected.prefix(4)), [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertEqual(Array(expected[recordStride * 2 + 12..<recordStride * 2 + 14]), [0x02, 0x01])

        XCTAssertEqual(data.count, headerSize + recordStride * 3)
        XCTAssertEqual(Array(data.suffix(from: data.startIndex + headerSize)), expected)
    }

    // MARK: - Decoder rejections

    func testDecode_rejectsBadMagic() {
        var data = SweepCoverageFile.encode(populated())
        data.replaceSubrange(data.startIndex..<(data.startIndex + 8), with: Data("ARKITFEA".utf8))
        XCTAssertThrowsError(try SweepCoverageFile.decode(data)) {
            XCTAssertEqual($0 as? SweepCoverageFile.DecodeError, .badMagic)
        }
    }

    func testDecode_rejectsTruncatedPayload() {
        let full = SweepCoverageFile.encode(populated())
        let data = full.prefix(full.count - 1)
        XCTAssertThrowsError(try SweepCoverageFile.decode(data)) {
            XCTAssertEqual($0 as? SweepCoverageFile.DecodeError,
                           .payloadSizeMismatch(expected: 5 * recordStride, actual: 5 * recordStride - 1))
        }
    }

    func testDecode_rejectsTruncatedHeader() {
        let data = SweepCoverageFile.encode(populated()).prefix(100)
        XCTAssertThrowsError(try SweepCoverageFile.decode(data)) {
            XCTAssertEqual($0 as? SweepCoverageFile.DecodeError, .truncatedHeader)
        }
    }

    func testDecode_rejectsUnsupportedVersion() {
        var data = SweepCoverageFile.encode(populated())
        // "SWEEPCOV 1" -> "SWEEPCOV 2": byte 9 is the version digit.
        data[data.startIndex + 9] = UInt8(ascii: "2")
        XCTAssertThrowsError(try SweepCoverageFile.decode(data)) {
            XCTAssertEqual($0 as? SweepCoverageFile.DecodeError, .unsupportedVersion(2))
        }
    }
}
