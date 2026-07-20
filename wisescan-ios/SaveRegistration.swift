import Foundation
import simd
#if canImport(RoomPlan)
import RoomPlan
#endif

/// DECISION 1 — save-time registration into the location's canonical frame (see "★ PRIMARY
/// registration approach" in `docs/fix-localization-plan.md`).
///
/// At save, a rescan's freshly-built `RoomBuilder` room is registered (plane-to-plane,
/// `PlaneRegistration`) against the location's ORIGINAL scan's persisted `roomplan.json` —
/// gen-0's frame is authoritative forever. A trusted fit yields the rigid transform raw→canonical,
/// which is baked into the saved artifacts so every generation shares one coordinate space
/// (the 4D contract: (0,0,0) is the same physical point in every scan of a location).
///
/// What gets transformed vs. what stays raw:
/// - `mesh.obj` — TRANSFORMED (vertices rewritten into the canonical frame).
/// - `roomplan.json` (clean schema) — TRANSFORMED (surface/object transforms premultiplied),
///   so the viewer's semantic outlines stay glued to the transformed mesh.
/// - `relocalization.worldmap` — RAW. An `ARWorldMap` is opaque and can't be re-based; it stays
///   a bootstrap in the scan's own capture frame. The NEXT rescan relocalizes into that raw
///   frame while its ghost mesh is canonical — the ghost loader undoes this scan's transform
///   (`inverseForGhost`) so ghost + live stay co-framed (visual overlay, manual nudge, ICP probe).
/// - `roomplan_raw.json` — RAW (Apple's opaque Codable, kept for round-tripping).
/// - `registration.json` — the sidecar written here: the transform + fit stats + whether it was
///   applied, so every consumer (ghost loader, future stitch/pose-graph work) can recover the
///   raw↔canonical relationship per scan.
///
/// Runs ONLY for `.rescanSpace` saves with an existing original-room target. Never for
/// link-adjacent (a different physical room — forcing a wall match there would be a false lock;
/// the matching gates would likely refuse, but similar rooms could false-positive).
enum SaveRegistration {

    // MARK: - Sidecar

    /// `registration.json` — written for every rescan save that had a registration target,
    /// applied or not (the not-applied record is the diagnostic for gate tuning).
    struct Sidecar: Codable {
        let version: Int
        let applied: Bool
        let reason: String        // "applied" | "already aligned …" | "gate refused …" | "no correspondence"
        let transform: [Float]?   // column-major raw→canonical; present iff applied
        let transM: Float
        let yawDeg: Float
        let initialRMSmm: Float
        let finalRMSmm: Float
        let matchedWalls: Int
        let matchedFloors: Int
        let weakAxisFrac: Float
        let converged: Bool
        let targetScanId: String  // the location's original scan (canonical frame owner)
        let note: String

        var transformMatrix: simd_float4x4? {
            guard let t = transform, t.count == 16 else { return nil }
            return simd_float4x4(SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]),
                                 SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15]))
        }
    }

    struct Outcome {
        let sidecar: Sidecar
        /// Non-nil iff the fit passed the gate AND cleared the minTransM skip floor — the
        /// transform actually baked into mesh.obj / roomplan.json.
        let appliedTransform: simd_float4x4?
    }

    private static let sidecarName = "registration.json"
    private static let artifactNote =
        "mesh.obj and roomplan.json are in the location's canonical (original-scan) frame; "
        + "relocalization.worldmap and roomplan_raw.json remain in this scan's raw capture frame"

    // MARK: - The save-time registration

    #if canImport(RoomPlan)
    /// Register this rescan's built room against the original scan's persisted clean roomplan.
    /// Pure + background-safe (call on the save pipeline's utility queue; no SwiftData access —
    /// resolve the target URL/id on main first). Returns nil only if the target file can't be
    /// decoded (missing/corrupt) — there is then nothing to register against.
    static func run(room: CapturedRoom, canonicalRoomPlanURL: URL, targetScanId: UUID) -> Outcome? {
        run(sourcePlanes: PlaneRegistration.planes(from: room),
            canonicalRoomPlanURL: canonicalRoomPlanURL, targetScanId: targetScanId)
    }
    #endif

    /// Plane-source variant (DECISION 3): ScanPostprocessor registers legacy scans whose room
    /// already exists on disk (no in-memory CapturedRoom) — it passes raw-frame planes decoded
    /// from the persisted roomplan instead. Same math, gates, and sidecar as the room variant.
    static func run(sourcePlanes source: [PlaneRegistration.Plane],
                    canonicalRoomPlanURL: URL, targetScanId: UUID) -> Outcome? {
        guard let data = try? Data(contentsOf: canonicalRoomPlanURL),
              let decoded = try? JSONDecoder().decode(RoomPlanExportData.self, from: data) else {
            print("[PlaneReg] no usable canonical roomplan at \(canonicalRoomPlanURL.lastPathComponent) — saving raw")
            return nil
        }
        let target = PlaneRegistration.planes(fromExportSurfaces: decoded.surfaces)

        guard let report = PlaneRegistration.register(source: source, target: target) else {
            print("[PlaneReg] REFUSED: no wall correspondence formed (src walls=\(source.filter { $0.category == .wall }.count) tgt walls=\(target.filter { $0.category == .wall }.count)) — saving raw")
            return Outcome(sidecar: Sidecar(
                version: 1, applied: false, reason: "no correspondence", transform: nil,
                transM: 0, yawDeg: 0, initialRMSmm: 0, finalRMSmm: 0,
                matchedWalls: 0, matchedFloors: 0, weakAxisFrac: 0, converged: false,
                targetScanId: targetScanId.uuidString, note: artifactNote), appliedTransform: nil)
        }

        let stats = String(format: "trans=%.1fcm (yaw=%.2f°) finalRMS=%.1fmm walls=%d floors=%d weakFrac=%.3f converged=%@",
                           report.transM * 100, report.yawDeg, report.finalRMS * 1000,
                           report.matchedWalls, report.matchedFloors, report.weakAxisFrac,
                           report.converged ? "yes" : "NO")

        let applied: Bool
        let reason: String
        if PlaneRegistration.exportTransform(from: report) == nil {
            applied = false
            reason = "gate refused"
            print("[PlaneReg] GATE REFUSED — saving raw. \(stats)")
        } else if report.transM < PlaneRegistration.Gate.minTransM {
            applied = false
            reason = String(format: "already aligned (below %.0fcm floor)", PlaneRegistration.Gate.minTransM * 100)
            print("[PlaneReg] already aligned — no correction needed. \(stats)")
        } else {
            applied = true
            reason = "applied"
            print("[PlaneReg] APPLIED canonical correction. \(stats)")
        }

        let m = report.transform
        return Outcome(sidecar: Sidecar(
            version: 1, applied: applied, reason: reason,
            transform: applied ? [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
                                  m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
                                  m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
                                  m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w] : nil,
            transM: report.transM, yawDeg: report.yawDeg,
            initialRMSmm: report.initialRMS * 1000, finalRMSmm: report.finalRMS * 1000,
            matchedWalls: report.matchedWalls, matchedFloors: report.matchedFloors,
            weakAxisFrac: report.weakAxisFrac, converged: report.converged,
            targetScanId: targetScanId.uuidString, note: artifactNote),
            appliedTransform: applied ? report.transform : nil)
    }

    /// DECISION 3 — legacy retroactive registration: premultiply an EXISTING clean roomplan.json's
    /// surface/object transforms by the applied raw→canonical correction, so the viewer's semantic
    /// outlines stay glued to the just-transformed mesh. (Fresh rooms take the transform at write
    /// time via `RoomPlanExporter.writeRoomPlan(_:to:applying:)`; this path is for scans whose
    /// roomplan was written before their registration ran.)
    static func retransformRoomPlanJSON(at url: URL, by t: simd_float4x4) {
        guard let data = try? Data(contentsOf: url),
              var decoded = try? JSONDecoder().decode(RoomPlanExportData.self, from: data) else { return }
        func premultiply(_ flat: [Float]) -> [Float] {
            guard flat.count == 16 else { return flat }
            let m = simd_float4x4(SIMD4(flat[0], flat[1], flat[2], flat[3]),
                                  SIMD4(flat[4], flat[5], flat[6], flat[7]),
                                  SIMD4(flat[8], flat[9], flat[10], flat[11]),
                                  SIMD4(flat[12], flat[13], flat[14], flat[15]))
            let r = t * m
            return [r.columns.0.x, r.columns.0.y, r.columns.0.z, r.columns.0.w,
                    r.columns.1.x, r.columns.1.y, r.columns.1.z, r.columns.1.w,
                    r.columns.2.x, r.columns.2.y, r.columns.2.z, r.columns.2.w,
                    r.columns.3.x, r.columns.3.y, r.columns.3.z, r.columns.3.w]
        }
        decoded = RoomPlanExportData(
            version: decoded.version, source: decoded.source,
            surfaces: decoded.surfaces.map {
                RoomPlanExportData.ExportSurface(id: $0.id, category: $0.category,
                                                 dimensions: $0.dimensions,
                                                 transform: premultiply($0.transform),
                                                 confidence: $0.confidence)
            },
            objects: decoded.objects.map {
                RoomPlanExportData.ExportObject(id: $0.id, category: $0.category,
                                                dimensions: $0.dimensions,
                                                transform: premultiply($0.transform),
                                                confidence: $0.confidence)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let out = try? encoder.encode(decoded) {
            try? out.write(to: url, options: .atomic)
        }
    }

    // MARK: - Sidecar IO

    static func writeSidecar(_ sidecar: Sidecar, to directory: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(sidecar) {
            try? data.write(to: directory.appendingPathComponent(sidecarName), options: .atomic)
        }
    }

    /// Read a scan's registration sidecar (top level first — the save promotes it there — then
    /// raw_data/, mirroring the roomplan.json lookup convention).
    static func loadSidecar(scanDirectory: URL) -> Sidecar? {
        let candidates = [
            scanDirectory.appendingPathComponent(sidecarName),
            scanDirectory.appendingPathComponent("raw_data").appendingPathComponent(sidecarName)
        ]
        for url in candidates {
            if let data = try? Data(contentsOf: url),
               let sidecar = try? JSONDecoder().decode(Sidecar.self, from: data) {
                return sidecar
            }
        }
        return nil
    }

    /// The transform the GHOST loader must apply to a scan's (canonical-frame) mesh so it lands
    /// back in that scan's RAW capture frame — the frame the live session relocalizes into via
    /// the scan's world map. nil when the scan saved raw (nothing to undo).
    static func inverseForGhost(scanDirectory: URL) -> simd_float4x4? {
        guard let sidecar = loadSidecar(scanDirectory: scanDirectory), sidecar.applied,
              let t = sidecar.transformMatrix else { return nil }
        return t.inverse
    }

    #if canImport(RoomPlan)
    /// The ghost scan's room planes in its RAW capture frame — the frame the de-registered ghost
    /// mesh, the world map, and hence the relocalized live session all share. Reference side of
    /// the live ghost auto-align. [] when unavailable (auto-align then stays off; callers log).
    ///
    /// Source: the CLEAN `roomplan.json` (`RoomPlanExportData` — the schema we own; its decode is
    /// exercised by the viewer daily). It's CANONICAL for registered scans, so the applied
    /// registration is undone to land back in the raw frame (identity for unregistered scans).
    /// (Originally decoded Apple's `CapturedRoom` back from `roomplan_raw.json` — an off-device-
    /// untestable round-trip that could fail silently and disable auto-align; 2026-07-15 field
    /// regression.)
    static func rawFramePlanes(scanDirectory: URL) -> [PlaneRegistration.Plane] {
        let candidates = [
            scanDirectory.appendingPathComponent("roomplan.json"),
            scanDirectory.appendingPathComponent("raw_data").appendingPathComponent("roomplan.json")
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(RoomPlanExportData.self, from: data) else { continue }
            var planes = PlaneRegistration.planes(fromExportSurfaces: decoded.surfaces)
            if let undo = inverseForGhost(scanDirectory: scanDirectory) {
                planes = planes.map { PlaneRegistration.applying(undo, to: $0) }
            }
            return planes
        }
        return []
    }
    #endif

    // MARK: - OBJ transform

    /// Rewrite an OBJ's `v x y z` lines through a rigid transform; every other line passes
    /// through verbatim (faces, comments — the save's OBJ carries no normals; extra vertex
    /// components like colors are preserved untransformed). One O(n) text pass — runs on the
    /// save pipeline's background queue (and at ghost load, to undo).
    static func transformOBJ(_ data: Data, by m: simd_float4x4) -> Data {
        guard let text = String(data: data, encoding: .utf8) else { return data }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out = [String]()
        out.reserveCapacity(lines.count)
        for line in lines {
            if line.hasPrefix("v ") {
                let c = line.dropFirst(2).split(separator: " ")
                if c.count >= 3, let x = Float(c[0]), let y = Float(c[1]), let z = Float(c[2]) {
                    let p = m * SIMD4<Float>(x, y, z, 1)
                    var v = "v \(p.x) \(p.y) \(p.z)"
                    for extra in c.dropFirst(3) { v += " \(extra)" }
                    out.append(v)
                    continue
                }
            }
            out.append(String(line))
        }
        return Data(out.joined(separator: "\n").utf8)
    }
}
