import Foundation
import SwiftData
import RoomPlan
import simd
import os
import UIKit   // jpegData for the regenerated model preview

/// DECISION 3 — the POST-PROCESS stage (see "★ DECISION 3" in `docs/fix-localization-plan.md`).
///
/// The save pipeline persists RAW artifacts only (mesh.obj, world map, frames/depth,
/// face_classes.bin); everything DERIVED is produced off the save path — the room by the deferred
/// post-save RoomBuilder, the rest here, user-triggered (the Post-process button, né Colorize) on
/// a cool device with no live session to starve and no timeouts to race. Why: the save-time chain
/// lost rooms on long/heavy scans (2026-07-13, 2026-07-16 — the stop flow deallocated the
/// RoomCaptureSession before its async didEndWith delivered) and blocked the save on RoomPlan
/// timing; the plane path's one irreplaceable input died exactly when the device was least able
/// to produce it.
///
/// THE ROOM ITSELF IS NOT BUILT HERE (revised 2026-07-16): `CapturedRoomData` is Codable in
/// signature only — both plist and JSON encoders throw at runtime — so it cannot be persisted for
/// a later build. RoomBuilder instead runs as a fire-and-forget POST-SAVE continuation in the
/// capture session (`DeferredRoomBuild`, armed with the scan directory only after saveScan so it
/// can't perturb the world-map export), writing `roomplan.json`/`_raw` when it finishes — usually
/// seconds after save. This postprocessor consumes that room from disk.
///
/// Pipeline per scan (steps skip when already done or unachievable):
///   1. REGISTRATION — plane-registration into the location's canonical (original-scan) frame;
///                     a trusted fit is baked into mesh.obj + roomplan.json (SaveRegistration,
///                     relocated from the save pipeline — same math, same artifacts)
///   2. PROXY        — ghost proxy (walls→RoomPlan quads, content→lumpy mesh) from mesh.obj +
///                     the face-aligned classification sidecar
///   3. COLORIZE     — photo-based vertex colors from the saved frames (governed by the
///                     "Colorize during post-process" setting; cosmetic — never gates)
///
/// Ordering contract: process a location's scans OLDEST-FIRST — the original's room must exist on
/// disk before later generations can register against it.
///
/// Terminal states (per-artifact completeness, not a boolean):
///   - COMPLETE      — every achievable artifact exists.
///   - LEGACY-CAPPED — some artifact's raw input was never persisted (e.g. pre-DECISION-3 scans
///                     have no classification sidecar → proxy unachievable). NOT bad; gates pass;
///                     the rescan ghost falls back to the full mesh.
///   - ROOM PENDING  — no roomplan yet but the deferred RoomBuilder is still in flight → gates
///                     hold, the bad-scan check re-schedules itself.
///   - BAD           — no roomplan, no build in flight (RoomPlan delivered nothing, the build
///                     failed, or the app died before it finished). The plane path is
///                     unrecoverable for this scan → warn the user to REDO it
///                     (`scheduleBadScanCheck` fires this shortly after save, while they're
///                     still standing in the room).
enum ScanPostprocessor {

    private static let log = Logger(subsystem: PerfDiag.subsystem, category: "postprocess")

    // MARK: - Steps + per-artifact status

    enum Step: String {
        case registration, proxy, colorize
    }

    /// Find an artifact at the scan dir top level or in raw_data/ — late-arriving sidecars
    /// (CapturedRoomData delivered after saveScan's promotion pass) live only in raw_data.
    static func artifactURL(_ name: String, in scan: CapturedScan) -> URL? {
        let candidates = [scan.scanDirectory.appendingPathComponent(name),
                          scan.rawDataPath.appendingPathComponent(name)]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The location's original scan — the canonical-frame owner (gen 0, authoritative forever).
    static func original(of scan: CapturedScan) -> CapturedScan? {
        scan.location?.scans.min(by: { $0.capturedAt < $1.capturedAt })
    }

    /// Whether this scan should register into its location's canonical frame. Rescans yes; the
    /// original itself no (it IS the frame); link-adjacent never (different physical room —
    /// force-matching walls there is a false-lock risk). Legacy scans (empty scanCaseRaw) fall
    /// back to "non-oldest ⇒ rescan" — the registration gates protect against a false match.
    static func wantsRegistration(_ scan: CapturedScan) -> Bool {
        guard let orig = original(of: scan), orig.id != scan.id else { return false }
        return scan.scanCaseRaw != ScanCase.linkAdjacent.rawValue
    }

    /// ROOM PENDING: no roomplan on disk yet, but the deferred post-save RoomBuilder is still
    /// running — gates hold, the bad-scan check waits.
    static func roomPending(_ scan: CapturedScan) -> Bool {
        artifactURL("roomplan.json", in: scan) == nil
            && DeferredRoomBuild.isBuildInFlight(scanDirectory: scan.scanDirectory)
    }

    /// BAD (terminal state): no room on disk and no build in flight to ever produce one. A scan
    /// younger than the post-save grace window is never bad — didEndWith + the deferred build may
    /// simply not have finished yet.
    static func isBad(_ scan: CapturedScan) -> Bool {
        guard Date().timeIntervalSince(scan.capturedAt) > AppConstants.roomDataBadScanGraceSeconds else {
            return false
        }
        return artifactURL("roomplan.json", in: scan) == nil && !roomPending(scan)
    }

    /// The achievable-but-not-done steps for a scan, in execution order. Empty = complete to the
    /// tier this scan's raw inputs allow (which for a roomless scan is "nothing room-derived").
    /// Room-derived steps become achievable only once the deferred build has landed roomplan.json.
    static func pendingSteps(for scan: CapturedScan, includeColorize: Bool) -> [Step] {
        var steps: [Step] = []
        let fm = FileManager.default
        let roomDone = artifactURL("roomplan.json", in: scan) != nil

        if wantsRegistration(scan), roomDone,
           artifactURL("registration.json", in: scan) == nil,
           let orig = original(of: scan),
           artifactURL("roomplan.json", in: orig) != nil {
            steps.append(.registration)
        }

        // Proxy is "done" only at the CURRENT builder version — an artifact from an older builder
        // (no/stale version header) regenerates on the next Process (e.g. v1's untessellated
        // quads, invisible as wireframe).
        let proxyCurrent = artifactURL("mesh_proxy.obj", in: scan).map(proxyIsCurrent) ?? false
        if !proxyCurrent, roomDone,
           artifactURL("face_classes.bin", in: scan) != nil {
            steps.append(.proxy)
        }

        if includeColorize, !scan.isColored,
           fm.fileExists(atPath: scan.rawDataPath.appendingPathComponent("images").path) {
            steps.append(.colorize)
        }
        return steps
    }

    /// The STRUCTURAL gate check (rescan / connect / upload): pending achievable structural work,
    /// or a room still being built (its registration/proxy work only becomes visible once the
    /// roomplan lands — hold the gate rather than let a half-finished scan through). Colorize is
    /// cosmetic and never gates.
    static func needsPostprocess(_ scan: CapturedScan) -> Bool {
        !pendingSteps(for: scan, includeColorize: false).isEmpty || roomPending(scan)
    }

    /// Location-level gate helper: the scans a rescan/connect flow depends on — the ORIGINAL
    /// (registration target + canonical roomplan) and the LATEST (ghost proxy + auto-align
    /// reference + world map) — plus anything else pending so one pass clears the location.
    /// Returns the scans with pending structural work, oldest-first (the required run order).
    static func scansNeedingPostprocess(in location: ScanLocation) -> [CapturedScan] {
        location.scans
            .sorted { $0.capturedAt < $1.capturedAt }
            .filter { needsPostprocess($0) }
    }

    /// The user's "Colorize during post-process" setting (production, default ON).
    static var colorizeEnabled: Bool {
        UserDefaults.standard.object(forKey: AppConstants.Key.colorizeOnPostprocess) == nil
            ? AppConstants.colorizeOnPostprocess
            : UserDefaults.standard.bool(forKey: AppConstants.Key.colorizeOnPostprocess)
    }

    // MARK: - The engine

    /// Run every achievable pending step for `scans`. Call from MAIN; the work runs on a utility
    /// queue and hops back to main for model mutations + callbacks. `scans` is re-sorted
    /// oldest-first per location internally (registration depends on the original's room existing
    /// on disk first). `progress` fires on main with a short per-scan status line (nil = done with
    /// that scan); `completion` fires on main after the whole batch.
    static func run(scans: [CapturedScan],
                    colorize: Bool = colorizeEnabled,
                    modelContext: ModelContext,
                    progress: ((CapturedScan, String?) -> Void)? = nil,
                    completion: (() -> Void)? = nil) {
        // Prerequisite expansion: a rescan's registration needs its location's ORIGINAL room on
        // disk first. A "latest only" selection may not include that original — pull in any
        // original with pending structural work so the batch is self-sufficient (the pulled-in
        // scan runs the same step set as the rest, colorize included per the toggle).
        var batch = scans
        var seen = Set(scans.map(\.id))
        for scan in scans {
            if let orig = original(of: scan), !seen.contains(orig.id), needsPostprocess(orig) {
                batch.append(orig)
                seen.insert(orig.id)
            }
        }
        let ordered = batch.sorted { $0.capturedAt < $1.capturedAt }
        DispatchQueue.global(qos: .utility).async {
            for scan in ordered {
                let report: (String?) -> Void = { msg in
                    DispatchQueue.main.async { progress?(scan, msg) }
                }
                let outcome = processOne(scan, colorize: colorize, report: report)
                DispatchQueue.main.async {
                    if outcome.didStructural || outcome.didColorize {
                        scan.postprocessedAt = Date()
                        if outcome.didColorize { scan.isColored = true }
                        scan.location?.updatedAt = Date()
                        try? modelContext.save()
                    }
                    progress?(scan, nil)
                }
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    private struct Outcome {
        var didStructural = false
        var didColorize = false
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func processOne(_ scan: CapturedScan, colorize: Bool,
                                   report: @escaping (String?) -> Void) -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default
        let dir = scan.scanDirectory
        let raw = scan.rawDataPath
        let steps = pendingSteps(for: scan, includeColorize: colorize)
        guard !steps.isEmpty else { return outcome }
        log.info("postprocess \(scan.name, privacy: .public): steps=\(steps.map(\.rawValue).joined(separator: "+"), privacy: .public)")

        // Writes derived artifacts to BOTH the scan dir top level (viewer / ghost loader / gates)
        // and raw_data/ (export staging parity with the old save-time pipeline).
        func writeBoth(_ data: Data, _ name: String) {
            try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
            try? data.write(to: raw.appendingPathComponent(name), options: .atomic)
        }
        func mirrorToRaw(_ name: String) {
            let src = dir.appendingPathComponent(name)
            let dst = raw.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { return }
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }

        // ── 1. REGISTRATION ──
        // The room is already on disk (written by the deferred post-save RoomBuilder, or by the
        // legacy save-time pipeline). Source planes come from the persisted roomplan in this
        // scan's RAW capture frame — rawFramePlanes undoes any applied registration (none here:
        // registration.json absent is what put us in this step).
        var appliedT: simd_float4x4?
        if steps.contains(.registration),
           let orig = original(of: scan),
           let targetURL = artifactURL("roomplan.json", in: orig) {
            report("Registering…")
            let sourcePlanes = SaveRegistration.rawFramePlanes(scanDirectory: dir)
            if let regOutcome = SaveRegistration.run(sourcePlanes: sourcePlanes,
                                                     canonicalRoomPlanURL: targetURL,
                                                     targetScanId: orig.id) {
                SaveRegistration.writeSidecar(regOutcome.sidecar, to: dir)
                mirrorToRaw("registration.json")
                appliedT = regOutcome.appliedTransform
                if let t = appliedT {
                    // Bake raw→canonical into the mesh (both copies; colors.bin is per-vertex
                    // ordered and unaffected) and premultiply the clean roomplan so the viewer's
                    // outlines stay glued to the transformed mesh.
                    if let mesh = try? Data(contentsOf: dir.appendingPathComponent("mesh.obj")) {
                        writeBoth(SaveRegistration.transformOBJ(mesh, by: t), "mesh.obj")
                    }
                    SaveRegistration.retransformRoomPlanJSON(
                        at: dir.appendingPathComponent("roomplan.json"), by: t)
                    mirrorToRaw("roomplan.json")
                }
                outcome.didStructural = true
            }
        }

        // ── 2. PROXY ──
        // Frame-consistent by construction: current mesh.obj + planes from the current clean
        // roomplan.json (both canonical if registration applied above / already applied at save;
        // both raw otherwise).
        if steps.contains(.proxy) {
            report("Building proxy…")
            if let classesURL = artifactURL("face_classes.bin", in: scan),
               let classes = try? Data(contentsOf: classesURL),
               let mesh = try? Data(contentsOf: dir.appendingPathComponent("mesh.obj")),
               let planes = currentFramePlanes(scanDirectory: dir), !planes.isEmpty {
                if let proxy = ARCoverageView.buildGhostProxyOBJ(objData: mesh, faceClasses: classes,
                                                                 roomPlanPlanes: planes) {
                    writeBoth(proxy.data, "mesh_proxy.obj")
                    outcome.didStructural = true
                    log.info("[GhostProxy] built at postprocess: \(proxy.faceCount) faces, \(proxy.data.count / 1024) KB")
                } else {
                    log.warning("[GhostProxy] skipped at postprocess: no RoomPlan walls or face/class mismatch")
                }
            }
        }

        // ── 3. COLORIZE ──
        if steps.contains(.colorize) {
            report("Coloring…")
            if let mesh = try? Data(contentsOf: dir.appendingPathComponent("mesh.obj")),
               let colors = VertexColorAccumulator.colorizeFromSavedFrames(
                   objData: mesh, rawDataDir: raw,
                   progress: { p in report("Coloring \(Int(p * 100))%") }) {
                try? colors.write(to: dir.appendingPathComponent("colors.bin"), options: .atomic)
                outcome.didColorize = true
            }
        }

        // ── Preview regen (mesh moved and/or got colors) ──
        if outcome.didStructural || outcome.didColorize {
            report("Rendering preview…")
            let pose = scan.location?.imagingPoseMatrix
            let frameCenter = MeshPreviewView.canonicalFrameCenter(for: scan.location)
            if let img = MeshPreviewView.generateSnapshot(
                meshURL: dir.appendingPathComponent("mesh.obj"),
                colorsURL: dir.appendingPathComponent("colors.bin"),
                poseMatrix: pose, frameCenter: frameCenter),
               let data = img.jpegData(compressionQuality: 0.8) {
                try? data.write(to: scan.modelPreviewURL)
            }
        }
        return outcome
    }

    /// Whether a proxy artifact was written by the CURRENT builder (version header starts line 1;
    /// the line may carry metadata after the version, e.g. ` quadFaces=N`). Reads only the first
    /// bytes — cheap enough for gate checks.
    private static func proxyIsCurrent(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let expected = ARCoverageView.ghostProxyVersionHeader
        guard let head = try? handle.read(upToCount: expected.utf8.count),
              let str = String(data: head, encoding: .utf8) else { return false }
        return str == expected
    }

    /// Planes from the scan's CURRENT clean roomplan.json — the same frame as the current
    /// mesh.obj (the save/postprocess pipelines always co-transform the two).
    private static func currentFramePlanes(scanDirectory: URL) -> [PlaneRegistration.Plane]? {
        let url = scanDirectory.appendingPathComponent("roomplan.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(RoomPlanExportData.self, from: data) else { return nil }
        return PlaneRegistration.planes(fromExportSurfaces: decoded.surfaces)
    }

    /// Offline RoomBuilder run with a (generous) backstop timeout — called by DeferredRoomBuild's
    /// post-save continuation (blocking a utility queue only; nothing user-facing waits on it).
    /// A wedged RoomBuilder must not hang that queue forever, hence the timeout. On timeout the
    /// result box is NOT read (the task may still be writing it — data race) and the task is
    /// cancelled so a runaway build can't keep burning CPU.
    static func buildRoom(from captured: CapturedRoomData, timeout: TimeInterval) -> CapturedRoom? {
        let done = DispatchSemaphore(value: 0)
        let result = RoomResultBox()
        let task = Task.detached {
            defer { done.signal() }
            result.value = try? await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: captured)
        }
        let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            task.cancel()
            log.warning("RoomBuilder exceeded \(Int(timeout))s at postprocess — cancelled")
            return nil
        }
        return result.value
    }

    /// Result hand-off for the detached RoomBuilder task. `nonisolated` (the project defaults
    /// types to MainActor) so the detached task can write it; the semaphore orders the read.
    private nonisolated final class RoomResultBox: @unchecked Sendable {
        nonisolated(unsafe) var value: CapturedRoom?
    }

    // MARK: - Bad-scan check (DECISION 3 terminal state 3)

    /// Schedule the post-save "this scan is bad — redo it" check. The room arrives asynchronously
    /// (didEndWith can land many seconds late on a hot device, and the deferred RoomBuilder then
    /// takes seconds-to-minutes), so the check waits out a grace window and RE-SCHEDULES itself
    /// while a build is still in flight; only "no room AND nothing running to produce one" — and
    /// RoomPlan was expected (semantic labeling on) — is terminal. Then the scan can never build a
    /// room, never be a registration target, never render a proxy ghost: warn NOW, while the user
    /// is still standing in the room, rather than at the next rescan's gate. Call on MAIN after a
    /// successful save.
    static func scheduleBadScanCheck(scan: CapturedScan, scanStore: ScanStore) {
        guard UserDefaults.standard.bool(forKey: AppConstants.Key.semanticLabeling) else { return }
        let grace = AppConstants.roomDataBadScanGraceSeconds
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak scanStore] in
            guard let scanStore else { return }
            // The scan may have been deleted in the meantime; artifact checks are file-based and
            // safe either way (a deleted scan's dir just reads as missing → skip via location nil).
            guard scan.location != nil else { return }
            if artifactURL("roomplan.json", in: scan) != nil { return }   // room landed — done
            if roomPending(scan) {
                // Deferred RoomBuilder still running — check again after another grace period.
                scheduleBadScanCheck(scan: scan, scanStore: scanStore)
                return
            }
            guard isBad(scan) else { return }
            log.warning("BAD SCAN: \(scan.name, privacy: .public) has no room and no build in flight after the grace window — RoomPlan produced nothing (or the build failed); prompting redo")
            scanStore.badScanWarning = scan.name
        }
    }
}
