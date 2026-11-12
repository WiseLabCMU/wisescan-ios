import Foundation
import simd

/// On-disk format for the per-scan sweep coverage grid (`sweep_coverage.bin`).
///
/// **Layout.** A fixed 512-byte ASCII header followed by packed little-endian records of
/// exactly 18 bytes each: `i: Int32`, `j: Int32`, `k: Int32`, `free: UInt16`,
/// `surface: UInt16`, `visits: UInt16`. Packed means packed: no padding, no alignment, no
/// separators. Records are sorted by `(k, j, i)` so identical grids always produce identical
/// bytes. The header is seven lines, then space padding, with byte 512 being `\n`:
///
/// ```
/// SWEEPCOV 1
/// count <N>
/// cell <cellSize>
/// dtype i:i4,j:i4,k:i4,free:u2,surface:u2,visits:u2
/// frame raw
/// stats frames=<n> drop_busy=<n> drop_rate=<n> skip_tracking=<n> skip_nodepth=<n> depth=<0|1>
/// rays integrated=<n> truncated=<n> lowconf=<n> invalid=<n>
/// ```
///
/// `cell` is written with Swift's `Float` description (`"\(Float)"`), which is
/// locale-independent: `0.5`, never `0,5`.
///
/// **Header budget.** The seven lines' fixed text is 202 bytes, plus the terminating `\n`. With
/// every number at its type's maximum (19-digit `count`, 15-character `cell`, five 10-digit
/// `UInt32` and four 20-digit `UInt64` counters, one-digit `depth`) the header uses 368 bytes,
/// leaving 144 for keys later layers add — so with today's fields it cannot overflow. If a
/// header ever would anyway, the encoder writes every `stats`/`rays` counter as `-1` (withheld,
/// never a real count) instead of trapping: the counters are diagnostics and the grid is the
/// artifact, so a save must never die for the header. `count`, `cell` and `depth=` are never
/// withheld. The decoder reads a withheld counter as its field's maximum, i.e. saturated.
///
/// **Frame.** Cell `(i, j, k)` spans `[i*cell, (i+1)*cell)` on each axis, in metres, in the
/// scan's RAW capture frame: the same frame as `arkit_features.bin`, `cameras/` and
/// `relocalization.worldmap`, **not** `mesh.obj`'s canonical frame. `registration.json`
/// carries the raw→canonical transform; apply it before comparing cells to the mesh.
///
/// **Reading it.** One line of Python, no parser:
///
/// ```python
/// np.fromfile(p, dtype=np.dtype([('i','<i4'),('j','<i4'),('k','<i4'),('free','<u2'),('surface','<u2'),('visits','<u2')]), offset=512)
/// ```
///
/// **Why binary, not JSON.** It matches `arkit_features.bin`, so one reader idiom covers both
/// sidecars, and it loads with the single `np.fromfile` above. It is 18 bytes per cell against
/// roughly 150 per cell as JSON objects. A room at 0.5 m is a few thousand cells, which JSON
/// could afford, but the cell size is a constant that will change, and the cell count grows
/// with the cube of the inverse cell size: halving the cell multiplies the file by eight.
///
/// **Empty and absent are different claims.** An empty grid is written as a valid header-only
/// file with `count 0`, never as a missing file; consumers must not have to branch on
/// existence. The `depth=` flag together with the frame counters says *why* a grid is sparse:
///
/// - `depth=1`, `frames>0`: the sweep looked, and the cells are what it saw. With depth
///   delivered, `count 0` is impossible in practice (every ray marks at least its end cell).
/// - `depth=0`: the sweep *could not look*: a non-LiDAR or Lite capture, or depth was never
///   delivered. A consumer must treat this as "no claim", not as "observed empty".
///
/// Deliberately free of ARKit and RealityKit imports so it is testable in the Simulator.
enum SweepCoverageFile {

    /// Filename inside a scan directory / exported bundle.
    static let filename = "sweep_coverage.bin"

    /// Version stamped in the `SWEEPCOV` line.
    static let formatVersion = 1

    /// Header size in bytes. Records start at exactly this offset.
    static let headerByteCount = 512

    /// Bytes per record: three `Int32` cell indices + three `UInt16` counters, packed.
    static let recordByteCount = 18

    /// Written in place of every `stats`/`rays` counter when the header would otherwise overflow
    /// its budget. No real counter is negative, so it cannot be mistaken for a count.
    static let withheldCounter = "-1"

    private static let magic = "SWEEPCOV"
    private static let dtypeLine = "dtype i:i4,j:i4,k:i4,free:u2,surface:u2,visits:u2"

    enum DecodeError: Error, Equatable {
        case truncatedHeader
        case badMagic
        case unsupportedVersion(Int)
        case missingField(String)
        case payloadSizeMismatch(expected: Int, actual: Int)
    }

    // MARK: - Encoding

    /// Encodes a snapshot into the 512-byte-header + packed-record format, records sorted by
    /// `(k, j, i)`. An empty snapshot produces a valid 512-byte file with `count 0`.
    static func encode(_ s: SweepCoverageSnapshot) -> Data {
        let keys = s.cells.keys.sorted { a, b in
            if a.z != b.z { return a.z < b.z }
            if a.y != b.y { return a.y < b.y }
            return a.x < b.x
        }

        var out = Data()
        out.reserveCapacity(headerByteCount + keys.count * recordByteCount)
        out.append(header(count: keys.count, cellSize: s.cellSize, stats: s.stats))

        // Append a value's little-endian bytes (correct on any host endianness).
        func putInt32(_ v: Int32) {
            var le = v.littleEndian
            Swift.withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        func putUInt16(_ v: UInt16) {
            var le = v.littleEndian
            Swift.withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }

        for key in keys {
            let cell = s.cells[key]!
            putInt32(key.x); putInt32(key.y); putInt32(key.z)
            putUInt16(cell.free); putUInt16(cell.surface); putUInt16(cell.visits)
        }
        return out
    }

    /// The fixed-size ASCII header: always exactly `byteCount` bytes, and it never traps. This
    /// runs inside the save, where a trap kills the save and `bestEffort` cannot catch it — a
    /// 256-byte budget guarded by a `precondition` would have done exactly that once a long
    /// session's counters outgrew it. `byteCount` is a parameter only so tests can force the
    /// over-budget paths; `encode` always passes `headerByteCount`. Callers pass at least 1.
    static func header(count: Int, cellSize: Float, stats st: SweepCoverageStats,
                       byteCount: Int = headerByteCount) -> Data {
        var bytes = [UInt8](headerText(count: count, cellSize: cellSize, stats: st,
                                       withholdCounters: false).utf8)
        if bytes.count >= byteCount {
            // Unreachable with today's fields (see "Header budget"): degrade the diagnostics,
            // never the save.
            bytes = [UInt8](headerText(count: count, cellSize: cellSize, stats: st,
                                       withholdCounters: true).utf8)
        }
        if bytes.count >= byteCount {
            // Only if the fixed text alone outgrew the budget — a format edit that
            // testHeader_worstCaseFitsTheBudgetWithoutWithholding exists to catch. Truncate
            // rather than trap: the file may then fail to decode, but the save survives.
            bytes = Array(bytes.prefix(byteCount - 1))
        }
        bytes.append(contentsOf: repeatElement(UInt8(ascii: " "),
                                               count: byteCount - bytes.count - 1))
        bytes.append(UInt8(ascii: "\n"))
        return Data(bytes)
    }

    /// The seven header lines, unpadded. With `withholdCounters` every `stats`/`rays` counter is
    /// written as `withheldCounter`; `count`, `cell` and `depth=` are always real.
    private static func headerText(count: Int, cellSize: Float, stats st: SweepCoverageStats,
                                   withholdCounters withhold: Bool) -> String {
        func n<T: BinaryInteger>(_ v: T) -> String { withhold ? withheldCounter : "\(v)" }
        var text = "\(magic) \(formatVersion)\n"
        text += "count \(count)\n"
        text += "cell \(cellSize)\n"
        text += "\(dtypeLine)\n"
        text += "frame raw\n"
        text += "stats frames=\(n(st.framesProcessed)) drop_busy=\(n(st.framesDroppedBusy))"
            + " drop_rate=\(n(st.framesDroppedRate)) skip_tracking=\(n(st.framesSkippedTracking))"
            + " skip_nodepth=\(n(st.framesSkippedNoDepth)) depth=\(st.depthEverAvailable ? 1 : 0)\n"
        text += "rays integrated=\(n(st.raysIntegrated)) truncated=\(n(st.raysTruncated))"
            + " lowconf=\(n(st.raysLowConfidence)) invalid=\(n(st.raysInvalidDepth))\n"
        return text
    }

    // MARK: - Decoding

    /// Decodes a file written by `encode`. Header lines are parsed by key, so their order does
    /// not matter; the payload must be exactly `count * recordByteCount` bytes.
    static func decode(_ data: Data) throws -> SweepCoverageSnapshot {
        guard data.count >= headerByteCount else { throw DecodeError.truncatedHeader }
        let base = data.startIndex
        let headerText = String(decoding: data[base..<(base + headerByteCount)], as: UTF8.self)

        // key -> rest-of-line
        var fields: [String: String] = [:]
        var firstLine: String?
        for raw in headerText.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if firstLine == nil { firstLine = line }
            let parts = line.split(separator: " ", maxSplits: 1)
            let key = String(parts[0])
            if fields[key] == nil { fields[key] = parts.count > 1 ? String(parts[1]) : "" }
        }

        guard let first = firstLine, first.hasPrefix(magic + " ") else { throw DecodeError.badMagic }
        guard let version = Int(first.dropFirst(magic.count + 1)) else { throw DecodeError.badMagic }
        guard version == formatVersion else { throw DecodeError.unsupportedVersion(version) }

        guard let countText = fields["count"], let count = Int(countText), count >= 0 else {
            throw DecodeError.missingField("count")
        }
        guard let cellText = fields["cell"], let cellSize = Float(cellText) else {
            throw DecodeError.missingField("cell")
        }

        // "a=1 b=2" -> [a: "1", b: "2"]
        func pairs(_ key: String) throws -> [String: String] {
            guard let rest = fields[key] else { throw DecodeError.missingField(key) }
            var out: [String: String] = [:]
            for tok in rest.split(separator: " ") {
                let kv = tok.split(separator: "=", maxSplits: 1)
                if kv.count == 2 { out[String(kv[0])] = String(kv[1]) }
            }
            return out
        }
        func num<T: FixedWidthInteger>(_ dict: [String: String], _ line: String, _ name: String) throws -> T {
            guard let s = dict[name] else { throw DecodeError.missingField("\(line).\(name)") }
            if let v = T(s) { return v }
            // A counter withheld to keep the header in budget reads as saturated.
            if s == withheldCounter { return T.max }
            throw DecodeError.missingField("\(line).\(name)")
        }

        let sp = try pairs("stats")
        let rp = try pairs("rays")
        var stats = SweepCoverageStats()
        stats.framesProcessed = try num(sp, "stats", "frames")
        stats.framesDroppedBusy = try num(sp, "stats", "drop_busy")
        stats.framesDroppedRate = try num(sp, "stats", "drop_rate")
        stats.framesSkippedTracking = try num(sp, "stats", "skip_tracking")
        stats.framesSkippedNoDepth = try num(sp, "stats", "skip_nodepth")
        let depthFlag: Int = try num(sp, "stats", "depth")
        stats.depthEverAvailable = depthFlag != 0
        stats.raysIntegrated = try num(rp, "rays", "integrated")
        stats.raysTruncated = try num(rp, "rays", "truncated")
        stats.raysLowConfidence = try num(rp, "rays", "lowconf")
        stats.raysInvalidDepth = try num(rp, "rays", "invalid")

        let (expected, overflow) = count.multipliedReportingOverflow(by: recordByteCount)
        let actual = data.count - headerByteCount
        guard !overflow, actual == expected else {
            throw DecodeError.payloadSizeMismatch(expected: overflow ? Int.max : expected, actual: actual)
        }

        // Assembled a byte at a time: little-endian regardless of host, no alignment demands.
        func u16(_ o: Int) -> UInt16 {
            UInt16(data[base + o]) | (UInt16(data[base + o + 1]) << 8)
        }
        func i32(_ o: Int) -> Int32 {
            var bits: UInt32 = 0
            for b in (0..<4).reversed() { bits = (bits << 8) | UInt32(data[base + o + b]) }
            return Int32(bitPattern: bits)
        }

        var cells: [SIMD3<Int32>: SweepCoverageCell] = [:]
        cells.reserveCapacity(count)
        for r in 0..<count {
            let o = headerByteCount + r * recordByteCount
            let key = SIMD3<Int32>(i32(o), i32(o + 4), i32(o + 8))
            cells[key] = SweepCoverageCell(free: u16(o + 12), surface: u16(o + 14), visits: u16(o + 16))
        }
        return SweepCoverageSnapshot(cellSize: cellSize, cells: cells, stats: stats)
    }
}
