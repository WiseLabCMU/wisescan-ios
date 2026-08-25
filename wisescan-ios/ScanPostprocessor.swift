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
///   3. COLORIZE     — photo-based vertex colors from the saved frames, run only when the
///                     caller asks (the "Color" verb); cosmetic — never gates
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
        case equirectDownloads, equirectMasks, equirectCalibration, registration, proxy, colorize
    }

    /// Find an artifact at the scan dir top level or in raw_data/ — late-arriving sidecars
    /// (CapturedRoomData delivered after saveScan's promotion pass) live only in raw_data.
    static func artifactURL(_ name: String, in scan: CapturedScan) -> URL? {
        let candidates = [scan.scanDirectory.appendingPathComponent(name),
                          scan.rawDataPath.appendingPathComponent(name)]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The location's original scan — the canonical-frame owner (gen 0, authoritative forever).
    /// Tie-break on id so two scans sharing a capturedAt can't flip the canonical owner between
    /// launches (the SwiftData relationship array is unordered); MeshPreviewView.canonicalFrameCenter
    /// uses the identical comparator so the two never disagree.
    static func original(of scan: CapturedScan) -> CapturedScan? {
        scan.location?.scans.min(by: CapturedScan.canonicalOrder)
    }

    /// Whether this scan should register into its location's canonical frame. Rescans yes; the
    /// original itself no (it IS the frame); link-adjacent never (different physical room —
    /// force-matching walls there is a false-lock risk).
    ///
    /// Legacy scans (empty scanCaseRaw — saved before the case was persisted) are SKIPPED by
    /// default, for the merge-to-main blast radius: on an existing install every non-oldest
    /// legacy scan would otherwise light up "needs postprocess" (hard-gating every old location
    /// the moment the app updates), and a legacy adjacent-link is indistinguishable from a
    /// legacy rescan — a *similar* adjacent room could false-positive the fit gates and be
    /// collapsed onto the original. The dev-gated "Register Legacy Scans" toggle re-enables
    /// them (the validation path for retroactive registration); even then, scans of
    /// link-adjacent-typed LOCATIONS stay excluded via the location-level scanCase, which
    /// predates the per-scan field.
    static func wantsRegistration(_ scan: CapturedScan) -> Bool {
        guard let orig = original(of: scan), orig.id != scan.id else { return false }
        switch scan.scanCaseRaw {
        case ScanCase.rescanSpace.rawValue:
            return true
        case "":
            return UserDefaults.standard.bool(forKey: AppConstants.Key.registerLegacyScans)
                && scan.location?.scanCase != .linkAdjacent
        default:
            return false
        }
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
    ///
    /// Legacy scans (empty scanCaseRaw) are never BAD: their roomlessness is history (the
    /// RoomCaptureSession retain-bug era), not a failed deferred build, and flagging them would
    /// hard-block Rescan/Connect on old locations the moment an existing install updates — with
    /// no in-app redo short of deleting the scan. They behave exactly as they did pre-merge:
    /// rescans on top of them work raw-only (no registration target, no auto-align reference).
    static func isBad(_ scan: CapturedScan) -> Bool {
        // Lite devices (no LiDAR) can never run RoomPlan: roomless is the NORM there, not a
        // failure — flagging it would false-warn every Lite scan and block Lite rescans.
        guard RoomCaptureSession.isSupported else { return false }
        guard !scan.scanCaseRaw.isEmpty else { return false }
        guard Date().timeIntervalSince(scan.capturedAt) > AppConstants.roomDataBadScanGraceSeconds else {
            return false
        }
        return artifactURL("roomplan.json", in: scan) == nil && !roomPending(scan)
    }

    /// The achievable-but-not-done steps for a scan, in execution order. Empty = complete to the
    /// tier this scan's raw inputs allow (which for a roomless scan is "nothing room-derived").
    /// Room-derived steps become achievable only once the deferred build has landed roomplan.json.
    /// `forceRebuild` bypasses the "already at the current builder version" shortcuts, so a step whose
    /// output is up to date runs anyway. This is a DEVELOPER affordance: the derived-artifact builders
    /// compute their diagnostics during the build, so a scan already at the current version prints
    /// nothing and there is otherwise no way to re-examine it short of bumping a version header. It
    /// deliberately does NOT force registration — that bakes a transform into mesh.obj in place, and
    /// re-running it against already-canonical artifacts would double-bake.
    static func pendingSteps(for scan: CapturedScan, includeColorize: Bool,
                             forceRebuild: Bool = false) -> [Step] {
        var steps: [Step] = []
        let fm = FileManager.default
        let roomDone = artifactURL("roomplan.json", in: scan) != nil

        // Equirect JPGs the capture-time queue didn't finish (post-process pivot: download
        // state is derived from disk — sidecar present + JPG missing). Pending downloads
        // gate save/upload via needsPostprocess: exports need the bytes for the privacy
        // pass, and the calibration solve needs them for poses.
        if !pendingEquirectDownloads(rawDataPath: scan.rawDataPath).isEmpty {
            steps.append(.equirectDownloads)
        }

        // Operator/rig masks: one per still, on disk beside it. Generated HERE rather
        // than at export because the solver is the other consumer — it currently masks
        // everything below −45° to keep the rod and operator out of its cost function,
        // and about half the operator sits ABOVE that line. Export reuses these.
        if equirectMasksPending(rawDataPath: scan.rawDataPath) {
            steps.append(.equirectMasks)
        }

        // Rig calibration + pose baking, pending until every sidecar carries provenance
        // (rig_calibration_source). Solved OR prior-stamped both count as done — a
        // failed solve must not gate the scan forever; the sweep step above keeps this
        // one waiting while JPGs are still on the camera.
        if equirectCalibrationPending(rawDataPath: scan.rawDataPath) {
            steps.append(.equirectCalibration)
        }

        // Registration is pending when never attempted, or when a REFUSED attempt predates the
        // current solver (`SaveRegistration.sidecarVersion` bump ⇒ refused scans retry with the
        // upgraded solver — e.g. v2's trim rescue). APPLIED sidecars are final regardless of
        // version: their mesh is already transformed, and re-fitting would need an un-apply first.
        if wantsRegistration(scan), roomDone,
           let orig = original(of: scan),
           artifactURL("roomplan.json", in: orig) != nil {
            if artifactURL("registration.json", in: scan) == nil {
                steps.append(.registration)
            } else if let sidecar = SaveRegistration.loadSidecar(scanDirectory: scan.scanDirectory) {
                // Retry an unapplied sidecar when a newer solver might now pass it, or when the
                // refusal was an artifact-write failure ("bake failed …") rather than a fit
                // verdict — the artifacts stayed raw, so the identical fit just re-applies.
                if !sidecar.applied,
                   sidecar.version < SaveRegistration.sidecarVersion
                    || sidecar.reason.hasPrefix("bake failed") {
                    steps.append(.registration)
                }
            } else {
                steps.append(.registration)   // sidecar file present but unreadable → retry
            }
        }

        // Proxy is "done" only at the CURRENT builder version — an artifact from an older builder
        // (no/stale version header) regenerates on the next Process (e.g. v1's untessellated
        // quads, invisible as wireframe).
        let proxyCurrent = artifactURL("mesh_proxy.obj", in: scan).map(proxyIsCurrent) ?? false
        let dynamicCurrent = artifactURL("mesh_dynamic.obj", in: scan).map(dynamicIsCurrent) ?? false
        if (forceRebuild || !proxyCurrent || !dynamicCurrent), roomDone,
           artifactURL("face_classes.bin", in: scan) != nil {
            steps.append(.proxy)
        }

        // When colorize is explicitly requested it always RE-colors: "Color" is a
        // user verb meaning "make this colored now", not "color it if it never was"
        // (an isColored guard here made re-color impossible through the engine and
        // forced every view to hand-roll its own colorize loop).
        if includeColorize,
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
        // Operator/rig masks are excluded for the same reason colorize is: they are a
        // DERIVED artifact, not scan integrity. Export rebuilds any that are missing, so
        // a scan whose masks have not been built yet is still complete — blocking Save
        // on them (as this did when the step was introduced) stops the user for
        // something the export can do itself.
        let blocking = pendingSteps(for: scan, includeColorize: false)
            .filter { $0 != .equirectMasks }
        return !blocking.isEmpty || roomPending(scan)
    }

    /// Location-level gate helper: the scans a rescan/connect flow depends on — the ORIGINAL
    /// (registration target + canonical roomplan) and the LATEST (ghost proxy + auto-align
    /// reference + world map) — plus anything else pending so one pass clears the location.
    /// Returns the scans with pending structural work, oldest-first (the required run order).
    static func scansNeedingPostprocess(in location: ScanLocation) -> [CapturedScan] {
        location.scans
            .sorted(by: CapturedScan.canonicalOrder)
            .filter { needsPostprocess($0) }
    }

    /// Sidecar-present / JPG-missing stills under raw_data/equirect_stills, in sequence
    /// order — the shared definition of "download pending" (the live capture queue and
    /// this sweep both derive state from disk, never from memory).
    nonisolated static func pendingEquirectDownloads(rawDataPath: URL) -> [(sequence: Int, url: String)] {
        let dir = rawDataPath.appendingPathComponent("equirect_stills")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var out: [(sequence: Int, url: String)] = []
        for file in files where file.hasPrefix("still_") && file.hasSuffix(".json") {
            let base = String(file.dropLast(5))
            guard !FileManager.default.fileExists(atPath: dir.appendingPathComponent(base + ".JPG").path),
                  let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let urlStr = obj["camera_file_url"] as? String,
                  let seq = obj["sequence"] as? Int else { continue }
            out.append((seq, urlStr))
        }
        return out.sorted { $0.sequence < $1.sequence }
    }

    /// True while any still sidecar lacks `rig_calibration_source` — or carries a stamp
    /// from an older solver version (bumps force a re-solve on the next Process; this is
    /// how the poisoned-anchor scans from 360post1, including pre-pivot capture-baked
    /// ones, heal themselves).
    /// Disk-derived, like every other step's state: a still with a JPG but no mask is
    /// pending. No queue to desync, and a constants change plus a wipe of the mask
    /// directory re-runs them.
    nonisolated static func equirectMasksPending(rawDataPath: URL) -> Bool {
        let dir = rawDataPath.appendingPathComponent("equirect_stills")
        let masks = rawDataPath.appendingPathComponent("equirect_masks")
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return false }
        for file in files where file.hasSuffix(".JPG") {
            let name = String(file.dropLast(4)) + ".png"
            if !fileManager.fileExists(atPath: masks.appendingPathComponent(name).path) { return true }
        }
        return false
    }

    /// Builds and stores the operator/rig mask for every still that lacks one.
    /// Returns how many were written.
    nonisolated static func writeOperatorRigMasks(rawDataPath: URL) -> Int {
        let dir = rawDataPath.appendingPathComponent("equirect_stills")
        let masks = rawDataPath.appendingPathComponent("equirect_masks")
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: masks, withIntermediateDirectories: true)
        guard let files = try? fileManager.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var written = 0
        for file in files.sorted() where file.hasSuffix(".JPG") {
            let target = masks.appendingPathComponent(String(file.dropLast(4)) + ".png")
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            // Per-still pool: each mask decodes a 60 MP equirect and runs six Vision
            // passes through autoreleased CF transients.
            autoreleasepool {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)) else { return }
                let mask = OperatorRigMask.build(equirectJPEG: data)
                guard let png = OperatorRigMask.encodePNG(mask) else { return }
                if (try? png.write(to: target, options: .atomic)) != nil { written += 1 }
            }
        }
        return written
    }

    nonisolated static func equirectCalibrationPending(rawDataPath: URL) -> Bool {
        let dir = rawDataPath.appendingPathComponent("equirect_stills")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return false }
        for file in files where file.hasPrefix("still_") && file.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            if obj["rig_calibration_source"] == nil { return true }
            if (obj["rig_calibration_solver_version"] as? Int ?? 0) < EquirectPostCalibration.solverVersion {
                return true
            }
        }
        return false
    }

    /// Manual "Redo 360° Calibration" (ScanCard long-press menu): strip the calibration
    /// provenance stamps from every still sidecar so `equirectCalibrationPending` turns
    /// true and the next Process re-runs the solve — the user-initiated redo the
    /// solver-version bump can't cover (remeasured rig height, remounted camera, solver
    /// doubts). `cam_transform` and the rest of the baked pose stay in place: the scan
    /// remains fully usable if the redo never runs, and the solve rewrites them
    /// wholesale when it does. Returns the number of sidecars stripped.
    nonisolated static func resetEquirectCalibration(rawDataPath: URL) -> Int {
        let dir = rawDataPath.appendingPathComponent("equirect_stills")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var cleared = 0
        for file in files where file.hasPrefix("still_") && file.hasSuffix(".json") {
            let url = dir.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url),
                  var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  obj["rig_calibration_source"] != nil else { continue }
            obj.removeValue(forKey: "rig_calibration_source")
            obj.removeValue(forKey: "rig_calibration_solver_version")
            guard let out = try? JSONSerialization.data(withJSONObject: obj,
                                                        options: [.prettyPrinted, .sortedKeys]),
                  (try? out.write(to: url, options: .atomic)) != nil else { continue }
            cleared += 1
        }
        return cleared
    }

    /// Security P1 (post-transfer auto-delete): remove camera-side originals whose bytes
    /// are VERIFIED on disk — sidecar carries `camera_file_url`, the JPG sits next to it,
    /// and no `camera_file_deleted` stamp yet. Stamps each sidecar after the camera
    /// confirms, so the sweep is disk-derived and crash-safe like the download queue; a
    /// bad-fileUrl OSC error also stamps (the file is already gone — retrying forever
    /// would be worse). A transport failure aborts the sweep (camera unreachable — every
    /// later call would just eat its timeout). Never gates anything: pure hygiene,
    /// re-attempted on every drain/Process pass. The Developer Mode "Keep 360° Originals
    /// on Camera" toggle turns it off for debugging.
    nonisolated static func sweepCameraOriginals(rawDataPath: URL) -> Int {
        guard !UserDefaults.standard.bool(forKey: AppConstants.Key.keepCameraOriginals) else { return 0 }
        let dir = rawDataPath.appendingPathComponent("equirect_stills")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var deleted = 0
        for file in files.sorted() where file.hasPrefix("still_") && file.hasSuffix(".json") {
            let sidecarURL = dir.appendingPathComponent(file)
            let jpgPath = dir.appendingPathComponent(String(file.dropLast(5)) + ".JPG").path
            guard let data = try? Data(contentsOf: sidecarURL),
                  var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let fileUrl = obj["camera_file_url"] as? String,
                  obj["camera_file_deleted"] == nil,
                  FileManager.default.fileExists(atPath: jpgPath)
            else { continue }
            switch syncCameraDelete(fileUrl: ThetaCameraManager.absoluteCameraURLString(fileUrl)) {
            case .unreachable:
                log.info("camera delete sweep: camera unreachable — \(deleted) deleted, rest deferred")
                return deleted
            case .kept:
                continue   // camera answered but refused (e.g. busy mid-trigger) — next sweep retries
            case .deleted, .alreadyGone:
                obj["camera_file_deleted"] = true
                if let out = try? JSONSerialization.data(withJSONObject: obj,
                                                         options: [.prettyPrinted, .sortedKeys]) {
                    try? out.write(to: sidecarURL, options: .atomic)
                }
                deleted += 1
            }
        }
        return deleted
    }

    private enum CameraDeleteResult { case deleted, alreadyGone, kept, unreachable }

    /// One synchronous `camera.delete` POST against the camera that owns `fileUrl` (base
    /// URL derived from the file URL itself — no manager state, callable from any queue).
    /// Short timeout: the sweep runs on utility queues where a vanished camera must fail
    /// fast, and per-file calls keep the stamps exact.
    private nonisolated static func syncCameraDelete(fileUrl: String,
                                                     timeout: TimeInterval = 5) -> CameraDeleteResult {
        guard let url = URL(string: fileUrl), let host = url.host,
              var comps = URLComponents(string: "http://\(host)/osc/commands/execute")
        else { return .kept }
        if let port = url.port { comps.port = port }
        guard let endpoint = comps.url,
              let body = try? JSONSerialization.data(withJSONObject: [
                  "name": "camera.delete", "parameters": ["fileUrls": [fileUrl]]
              ])
        else { return .kept }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = timeout
        var outcome = CameraDeleteResult.unreachable
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { sem.signal() }
            guard let http = response as? HTTPURLResponse else { return }   // transport failure
            let obj = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let state = obj?["state"] as? String
            if (200...299).contains(http.statusCode), state == "done" || state == "inProgress" {
                outcome = .deleted
                return
            }
            // Camera answered but refused. A rejected fileUrl means the file is already
            // gone (manual delete, SD swap) — stamp it; anything else retries next sweep.
            let code = (obj?["error"] as? [String: Any])?["code"] as? String ?? ""
            outcome = code == "invalidParameterValue" ? .alreadyGone : .kept
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 5)
        return outcome
    }

    /// Synchronous GET against the camera's HTTP server (processOne runs on a background
    /// queue, not in an async context). nil on any failure — the step stays pending and
    /// the next Process retries.
    private nonisolated static func syncDownload(_ url: URL, timeout: TimeInterval = 30) -> Data? {
        var result: Data?
        let sem = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { result = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 5)
        return result
    }

    // MARK: - The engine

    /// Everything the background pass needs, snapshotted on the MAIN actor before dispatch —
    /// SwiftData `@Model` objects and their faulted relationships are NOT thread-safe off the main
    /// actor. `scan` is a bare reference kept only for the main-thread progress callback + model
    /// writeback in `run()`; the background pass reads exclusively the snapshot + the filesystem.
    private struct ScanWork {
        let scan: CapturedScan
        let id: UUID
        let dir: URL
        let raw: URL
        let name: String
        let previewURL: URL
        let steps: [Step]
        let origRoomPlanURL: URL?
        let origId: UUID?
        let pose: [Float]?
        let frameCenter: SIMD3<Float>?
        let thetaReachable: Bool
    }

    /// Guards two Process/Color passes from touching the SAME scan concurrently. Registration
    /// bakes the raw→canonical transform INTO mesh.obj in place, so an interleaved second pass
    /// could double-bake or tear the file — and a colorize that reads a fresh sidecar against a
    /// pre-bake mesh would misproject every frame by the applied transform. Claimed on main when
    /// a batch/colorize is armed; released on main after that scan's model writeback (so a
    /// subsequent arm can't snapshot stale model state). The colorize entry points
    /// (bulkColorize / single-card Color) claim through the same set — internal, not private.
    nonisolated private static let inFlightLock = NSLock()
    nonisolated(unsafe) private static var inFlight: Set<UUID> = []

    nonisolated static func claimInFlight(_ id: UUID) -> Bool {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        return inFlight.insert(id).inserted
    }
    nonisolated static func releaseInFlight(_ id: UUID) {
        inFlightLock.lock(); defer { inFlightLock.unlock() }
        inFlight.remove(id)
    }

    /// Run every achievable pending step for `scans`. Call from MAIN; the work runs on a utility
    /// queue and hops back to main for model mutations + callbacks. `scans` is re-sorted
    /// oldest-first per location internally (registration depends on the original's room existing
    /// on disk first). `progress` fires on main with a short per-scan status line (nil = done with
    /// that scan); `completion` fires on main after the whole batch.
    static func run(scans: [CapturedScan],
                    colorize: Bool = false,
                    forceRebuild: Bool = false,
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
        let ordered = batch.sorted(by: CapturedScan.canonicalOrder)

        // Snapshot every @Model-derived value on MAIN before dispatching (SwiftData objects and
        // their faulted relationships aren't thread-safe off the main actor); the background pass
        // reads only the snapshot + the filesystem. A scan already claimed by another in-flight
        // batch is skipped — still reported done so callers' progress counters stay in sync.
        // Steps are FROZEN here: a roomplan landing mid-batch (deferred RoomBuilder) is picked up
        // by the NEXT Process tap, not this one — determinism over mid-batch opportunism.
        var frameCenters: [UUID: SIMD3<Float>?] = [:]   // per-location memo — canonicalFrameCenter decodes the original's roomplan JSON
        let work: [ScanWork] = ordered.compactMap { scan in
            guard claimInFlight(scan.id) else {
                progress?(scan, nil)
                return nil
            }
            let orig = original(of: scan)
            let frameCenter: SIMD3<Float>?
            if let locId = scan.location?.id, let memo = frameCenters[locId] {
                frameCenter = memo
            } else {
                frameCenter = MeshPreviewView.canonicalFrameCenter(for: scan.location)
                // updateValue, not subscript-assign: the value type is optional, so `dict[k] = nil`
                // would DROP the key — a nil-frame location would then re-decode the roomplan for
                // every scan instead of memoizing the nil.
                if let locId = scan.location?.id { frameCenters.updateValue(frameCenter, forKey: locId) }
            }
            return ScanWork(
                scan: scan,
                id: scan.id,
                dir: scan.scanDirectory,
                raw: scan.rawDataPath,
                name: scan.name,
                previewURL: scan.modelPreviewURL,
                steps: pendingSteps(for: scan, includeColorize: colorize, forceRebuild: forceRebuild),
                origRoomPlanURL: orig.flatMap { artifactURL("roomplan.json", in: $0) },
                origId: orig?.id,
                pose: scan.location?.imagingPoseMatrix,
                frameCenter: frameCenter,
                thetaReachable: ThetaCameraManager.shared.isConnected
            )
        }

        DispatchQueue.global(qos: .utility).async {
            for w in work {
                let report: (String?) -> Void = { msg in
                    DispatchQueue.main.async { progress?(w.scan, msg) }
                }
                let outcome = processOne(w, report: report)
                DispatchQueue.main.async {
                    if outcome.didStructural || outcome.didColorize {
                        w.scan.postprocessedAt = Date()
                        if outcome.didColorize { w.scan.isColored = true }
                        w.scan.location?.updatedAt = Date()
                        try? modelContext.save()
                    }
                    progress?(w.scan, nil)
                    // Release on MAIN, strictly after the model writeback — a subsequent arm
                    // (also main) can then never claim this scan and snapshot a stale isColored.
                    releaseInFlight(w.id)
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
    private static func processOne(_ w: ScanWork,
                                   report: @escaping (String?) -> Void) -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default
        let dir = w.dir
        let raw = w.raw
        let steps = w.steps   // computed on main (SwiftData reads) before dispatch
        guard !steps.isEmpty else { return outcome }
        log.notice("postprocess \(w.name, privacy: .public): steps=\(steps.map(\.rawValue).joined(separator: "+"), privacy: .public)")

        // ONE read and ONE parse of mesh.obj for the whole pass. A scan that registers,
        // rebuilds its proxy, colorizes and re-renders its preview used to read the same
        // 16-45 MB file four times and parse it twice — including a write-then-read-back
        // round trip inside the registration bake. See MeshCache: stages that need bytes
        // (registration, proxy) share the Data, stages that need geometry (colorize,
        // preview) share one OBJData, and the bake hands its new bytes straight to the
        // cache instead of going through the filesystem.
        let meshCache = MeshCache(url: dir.appendingPathComponent("mesh.obj"), name: w.name)
        defer { meshCache.logSavings() }

        // Writes derived artifacts to BOTH the scan dir top level (viewer / ghost loader / gates)
        // and raw_data/ (export staging parity with the old save-time pipeline).
        func writeBoth(_ data: Data, _ name: String) {
            try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
            try? data.write(to: raw.appendingPathComponent(name), options: .atomic)
        }
        func removeBoth(_ name: String) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
            try? fm.removeItem(at: raw.appendingPathComponent(name))
        }
        func mirrorToRaw(_ name: String) {
            let src = dir.appendingPathComponent(name)
            let dst = raw.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { return }
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
        // Off-main-safe artifact lookup (scan-dir top level then raw_data/), resolving against the
        // snapshotted dirs — the @Model-based artifactURL(_:in:) would fault the scan off-main.
        func artifact(_ name: String) -> URL? {
            [dir.appendingPathComponent(name), raw.appendingPathComponent(name)]
                .first { fm.fileExists(atPath: $0.path) }
        }

        // ── 0. EQUIRECT DOWNLOADS ──
        // Finish whatever the live capture queue didn't: the camera must be reachable
        // (its Wi-Fi joined). Per-still failures leave the step pending — gates hold and
        // the next Process retries; the scan itself is never failed by absent bytes.
        if steps.contains(.equirectDownloads) {
            let pending = pendingEquirectDownloads(rawDataPath: raw)
            let stillsDir = raw.appendingPathComponent("equirect_stills")
            var fetched = 0
            for (idx, item) in pending.enumerated() {
                report("360° still \(idx + 1)/\(pending.count)…")
                // Sidecars written before 2026-08-25 from a Z1 BLE shutter hold a bare path.
                guard let url = URL(string: ThetaCameraManager.absoluteCameraURLString(item.url)),
                      let data = syncDownload(url) else { continue }
                let dst = stillsDir.appendingPathComponent(String(format: "still_%04d.JPG", item.sequence))
                if (try? data.write(to: dst, options: .atomic)) != nil {
                    fetched += 1
                    ThetaCameraManager.annotateExifExposure(
                        jpegData: data,
                        sidecarURL: stillsDir.appendingPathComponent(String(format: "still_%04d.json", item.sequence)))
                }
            }
            log.notice("postprocess \(w.name, privacy: .public): equirect sweep \(fetched)/\(pending.count) downloaded")
            if fetched < pending.count {
                report("360° camera needed for \(pending.count - fetched) still(s)")
            }
        }

        // ── 0.5 CAMERA-SIDE DELETE (security P1) ── best-effort, never gates: originals
        // whose bytes are verified on disk come off the weakly-secured camera. Gated on
        // the connection snapshot so a disconnected pass doesn't eat the HTTP timeout,
        // and ordered BEFORE calibration so the sidecar stamps can't race its pose bake.
        if w.thetaReachable {
            let swept = sweepCameraOriginals(rawDataPath: raw)
            if swept > 0 {
                log.notice("postprocess \(w.name, privacy: .public): deleted \(swept) transferred still(s) from camera")
            }
        }

        // ── 0.55 OPERATOR/RIG MASKS ── (before calibration, which is the point:
        // the solver's blunt elevation cutoff is what these are meant to replace.)
        if steps.contains(.equirectMasks) {
            report("Masking operator and rig…")
            let made = writeOperatorRigMasks(rawDataPath: raw)
            log.notice("postprocess \(w.name, privacy: .public): operator/rig masks — \(made, privacy: .public) written")
        }

        // ── 0.6 EQUIRECT CALIBRATION ── (RAW frame: must precede registration's bake;
        // waits for a complete still set — the sweep above may have just finished it.)
        if steps.contains(.equirectCalibration) {
            if pendingEquirectDownloads(rawDataPath: raw).isEmpty {
                report("Calibrating 360° rig…")
                let status = EquirectPostCalibration.run(scanDir: dir, rawDataDir: raw, report: report)
                log.notice("postprocess \(w.name, privacy: .public): equirect calibration — \(status, privacy: .public)")
            } else {
                log.notice("postprocess \(w.name, privacy: .public): equirect calibration deferred — downloads incomplete")
            }
        }

        // ── 1. REGISTRATION ──
        // The room is already on disk (written by the deferred post-save RoomBuilder, or by the
        // legacy save-time pipeline). Source planes come from the persisted roomplan in this
        // scan's RAW capture frame — rawFramePlanes undoes an APPLIED registration; here the
        // sidecar is absent or an unapplied refusal (applied ones never re-enter this step), so
        // the planes are already raw.
        var appliedT: simd_float4x4?
        if steps.contains(.registration),
           let targetURL = w.origRoomPlanURL,
           let origId = w.origId {
            report("Registering…")
            let sourcePlanes = SaveRegistration.rawFramePlanes(scanDirectory: dir)
            if let regOutcome = SaveRegistration.run(sourcePlanes: sourcePlanes,
                                                     canonicalRoomPlanURL: targetURL,
                                                     targetScanId: origId) {
                // TRANSACTIONAL ORDER: bake the artifacts FIRST, write the sidecar LAST — the
                // sidecar is the commit record every consumer trusts (ghost de-registration,
                // colorize un-apply, retry gating). The old order wrote `applied: true` before
                // the mesh bake; a failed/interrupted write then left a raw mesh under an
                // "applied" sidecar — silent, permanent misalignment (applied sidecars never
                // retry). Now any bake failure downgrades the sidecar to an unapplied refusal,
                // which the version-gated retry can re-attempt, and a partial roomplan failure
                // rolls the mesh back so the scan stays consistently RAW.
                var sidecar = regOutcome.sidecar
                appliedT = regOutcome.appliedTransform
                if let t = appliedT {
                    let meshURL = dir.appendingPathComponent("mesh.obj")
                    var baked = false
                    if let mesh = meshCache.data() {
                        let transformed = SaveRegistration.transformOBJ(mesh, by: t)
                        if (try? transformed.write(to: meshURL, options: .atomic)) != nil {
                            // The bake replaced the file — hand the new bytes straight to the
                            // cache instead of letting the next stage read them back off disk.
                            meshCache.replace(with: transformed)
                            // Mesh is canonical; the clean roomplan must follow or roll back.
                            if SaveRegistration.retransformRoomPlanJSON(
                                at: dir.appendingPathComponent("roomplan.json"), by: t) {
                                baked = true
                                // Export-staging mirrors are best-effort copies of the now-
                                // consistent top-level artifacts (top level is authoritative).
                                try? transformed.write(to: raw.appendingPathComponent("mesh.obj"),
                                                       options: .atomic)
                                mirrorToRaw("roomplan.json")
                            } else if (try? mesh.write(to: meshURL, options: .atomic)) == nil {
                                // Roomplan failed AND the mesh rollback failed: mesh is canonical,
                                // roomplan raw. Keep applied=true (matches the mesh — the ghost/
                                // colorize contract) and log loudly; only the outlines are stale.
                                // The cache already holds those canonical bytes.
                                log.error("registration bake: roomplan retransform failed and mesh rollback failed for \(w.name, privacy: .public) — mesh canonical, roomplan RAW (outlines stale)")
                                baked = true
                            } else {
                                // Rollback SUCCEEDED — the file is raw again, so the cache must
                                // revert with it or every later stage would read canonical
                                // geometry from a scan the sidecar calls raw.
                                meshCache.replace(with: mesh)
                            }
                        }
                    }
                    if !baked {
                        log.warning("registration bake failed (io) for \(w.name, privacy: .public) — reverting to unapplied so the next Process retries")
                        appliedT = nil
                        sidecar = SaveRegistration.unappliedCopy(of: sidecar, reason: "bake failed (io)")
                    }
                }
                if SaveRegistration.writeSidecar(sidecar, to: dir) {
                    mirrorToRaw("registration.json")
                    outcome.didStructural = true
                } else {
                    log.error("registration sidecar write failed for \(w.name, privacy: .public) — artifacts \(appliedT != nil ? "CANONICAL without a commit record (next Process will re-fit ≈identity and record it)" : "raw; will retry")")
                }
            }
        }

        // ── 2. PROXY ──
        // Frame-consistent by construction: current mesh.obj + planes from the current clean
        // roomplan.json (both canonical if registration applied above / already applied at save;
        // both raw otherwise). A late-applied registration (version-gated retry) moves mesh.obj
        // out from under a version-current proxy — rebuild it even though its header says current.
        if steps.contains(.proxy) || appliedT != nil {
            report("Building proxy…")
            // A registration was just baked into mesh.obj, so every derived artifact sitting on disk
            // describes the OLD raw frame — and the ghost loader would de-register it a second time.
            // Delete first: an interrupted or failing rebuild then leaves ABSENCE, which consumers
            // handle (fall back to the full mesh, and pendingSteps re-offers .proxy), rather than a
            // version-current artifact in the wrong frame, which nothing detects. Only on a bake —
            // a .proxy-only run's artifacts are already frame-correct and must survive a failure.
            if appliedT != nil {
                removeBoth("mesh_proxy.obj")
                removeBoth("mesh_dynamic.obj")
                removeBoth(DerivedSurfacesData.filename)
                log.notice("[GhostProxy] cleared raw-frame artifacts before re-framed rebuild for \(w.name, privacy: .public)")
            }
            if let classesURL = artifact("face_classes.bin"),
               let classes = try? Data(contentsOf: classesURL),
               let mesh = meshCache.data(),
               let planes = currentFramePlanes(scanDirectory: dir), !planes.isEmpty {
                if let result = ARCoverageView.buildGhostProxyOBJ(objData: mesh, faceClasses: classes,
                                                                 roomPlanPlanes: planes) {
                    writeBoth(result.proxy.data, "mesh_proxy.obj")
                    writeBoth(result.dynamic.data, "mesh_dynamic.obj")
                    // The levels/ramps the proxy just recovered, as data for the consumers that need
                    // the plane list without re-parsing the mesh. A rebuild that finds NOTHING must
                    // clear the file rather than leave the previous run's answer standing: coverage
                    // changes between generations, so a level found once can legitimately disappear.
                    if result.levels.isEmpty && result.ramps.isEmpty {
                        removeBoth(DerivedSurfacesData.filename)
                        log.info("[GhostProxy] derived surfaces: none found — sidecar cleared")
                    } else if let json = try? JSONEncoder().encode(
                                  DerivedSurfacesData(levels: result.levels, ramps: result.ramps)) {
                        writeBoth(json, DerivedSurfacesData.filename)
                        log.info("[GhostProxy] derived surfaces: \(result.levels.count) level(s), \(result.ramps.count) ramp(s)")
                    } else {
                        removeBoth(DerivedSurfacesData.filename)
                        log.warning("[GhostProxy] derived surfaces ENCODE FAILED (\(result.levels.count) level(s), \(result.ramps.count) ramp(s)) — sidecar cleared")
                    }
                    outcome.didStructural = true
                    log.info("[GhostProxy] built at postprocess: proxy \(result.proxy.faceCount) faces (\(result.proxy.data.count / 1024) KB), dynamic \(result.dynamic.faceCount) faces (\(result.dynamic.data.count / 1024) KB)")
                } else {
                    log.warning("[GhostProxy] skipped at postprocess: no RoomPlan walls or face/class mismatch")
                }
            } else {
                // Which input was missing. Diagnosed with existence checks rather than by hoisting the
                // reads into eager locals — that would pull the whole mesh.obj off disk on every run
                // where face_classes.bin is the piece that is absent. A plane count of -1 means the
                // planes could not be decoded at all, which zero does not distinguish.
                let planeCount = currentFramePlanes(scanDirectory: dir)?.count ?? -1
                let hasClasses = artifact("face_classes.bin") != nil
                let hasMesh = fm.fileExists(atPath: dir.appendingPathComponent("mesh.obj").path)
                log.warning("[GhostProxy] no proxy build for \(w.name, privacy: .public): face_classes.bin=\(hasClasses, privacy: .public) mesh.obj=\(hasMesh, privacy: .public) planes=\(planeCount, privacy: .public) (-1 = undecodable)")
            }
        }

        // ── 3. COLORIZE ──
        if steps.contains(.colorize) {
            report("Coloring…")
            if let parsed = meshCache.parsed(),
               let colors = VertexColorAccumulator.colorizeFromSavedFrames(
                   parsed: parsed, rawDataDir: raw,
                   progress: { p in report("Coloring \(Int(p * 100))%") },
                   phase: { step in report(step) }) {
                try? colors.write(to: dir.appendingPathComponent("colors.bin"), options: .atomic)
                outcome.didColorize = true
            }
        }

        // ── Preview regen (mesh moved and/or got colors) ──
        if outcome.didStructural || outcome.didColorize {
            report("Rendering preview…")
            if let parsed = meshCache.parsed(),
               let img = MeshPreviewView.generateSnapshot(
                parsed: parsed,
                colorsURL: dir.appendingPathComponent("colors.bin"),
                poseMatrix: w.pose, frameCenter: w.frameCenter),
               let data = img.jpegData(compressionQuality: 0.8) {
                try? data.write(to: w.previewURL)
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

    /// Whether a dynamic-mesh artifact was written by the CURRENT builder (same staleness pattern
    /// as `proxyIsCurrent`). Reads only the first bytes.
    private static func dynamicIsCurrent(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let expected = ARCoverageView.dynamicMeshVersionHeader
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
        // minArea: 0 — the proxy visualizes every decoded plane (the sliver guard is a fit concern,
        // not a rendering one; keeping slivers here avoids gaps in the ghost).
        return PlaneRegistration.planes(fromExportSurfaces: decoded.surfaces, minArea: 0)
    }

    /// Offline RoomBuilder run with a (generous) backstop timeout — called by DeferredRoomBuild's
    /// post-save continuation (blocking a utility queue only; nothing user-facing waits on it).
    /// A wedged RoomBuilder must not hang that queue forever, hence the timeout. On timeout the
    /// result box is NOT read (the task may still be writing it — data race) and the task is
    /// cancelled — best-effort only: RoomBuilder.capturedRoom is a single async call that does not
    /// check Task.isCancelled, so a genuinely wedged build keeps running (and holding memory) until
    /// the OS-level work completes; cancellation just stops us from waiting on / reading it.
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
    ///
    /// Captures the scan's UUID, NOT the `@Model` object: the timer chain can span minutes
    /// (grace window × re-schedules while a 120 s RoomBuilder runs), and touching a SwiftData
    /// model deleted in the meantime is undefined (has crashed on faulted relationships on some
    /// OS versions). The scan is re-fetched on main at fire time; fetch-miss = deleted = done.
    static func scheduleBadScanCheck(scanId: UUID, modelContext: ModelContext, scanStore: ScanStore) {
        // No RoomPlan on this device (Lite/no-LiDAR) → no room is ever coming; warning the
        // user to "redo" the scan would be wrong on every save.
        guard RoomCaptureSession.isSupported else { return }
        guard UserDefaults.standard.bool(forKey: AppConstants.Key.semanticLabeling) else { return }
        let grace = AppConstants.roomDataBadScanGraceSeconds
        DispatchQueue.main.asyncAfter(deadline: .now() + grace) { [weak scanStore] in
            guard let scanStore else { return }
            let descriptor = FetchDescriptor<CapturedScan>(predicate: #Predicate { $0.id == scanId })
            guard let scan = try? modelContext.fetch(descriptor).first, scan.location != nil else {
                return   // deleted (or orphaned) in the meantime — nothing to warn about
            }
            if artifactURL("roomplan.json", in: scan) != nil { return }   // room landed — done
            if roomPending(scan) {
                // Deferred RoomBuilder still running — check again after another grace period.
                scheduleBadScanCheck(scanId: scanId, modelContext: modelContext, scanStore: scanStore)
                return
            }
            guard isBad(scan) else { return }
            log.warning("BAD SCAN: \(scan.name, privacy: .public) has no room and no build in flight after the grace window — RoomPlan produced nothing (or the build failed); prompting redo")
            scanStore.badScanWarning = scan.name
        }
    }
}

/// One read and one parse of a scan's `mesh.obj` for a whole `processOne` pass.
///
/// The postprocess stages each used to fetch the mesh independently: the registration bake
/// read it, transformed it, wrote it, and the proxy builder read those same bytes back off
/// disk seventeen lines later; colorize read it a third time and the preview render a
/// fourth. On a 16-45 MB OBJ that is ~65-180 MB of redundant reads plus two independent
/// full parses, all serial, once per scan.
///
/// Not thread-safe by design — `processOne` is one serial pass on one queue, and making it
/// safe would mean a lock on the hot path for no benefit. Bytes and geometry are cached
/// separately because the two parsers are not interchangeable: the registration bake and
/// the ghost-proxy builder need the raw text (the proxy builder pairs faces positionally
/// with `face_classes.bin`, which `MeshParser.parseOBJ` would break by filtering malformed
/// faces), while colorize and the preview need `OBJData`.
private final class MeshCache {
    private let url: URL
    private let name: String
    private var cachedData: Data?
    private var cachedParsed: MeshParser.OBJData?
    private var reads = 0
    private var parses = 0
    private var hits = 0

    init(url: URL, name: String) {
        self.url = url
        self.name = name
    }

    /// The mesh bytes, read at most once.
    func data() -> Data? {
        if let cachedData { hits += 1; return cachedData }
        guard let loaded = try? Data(contentsOf: url) else { return nil }
        reads += 1
        cachedData = loaded
        return loaded
    }

    /// The parsed geometry, parsed at most once.
    func parsed() -> MeshParser.OBJData? {
        if let cachedParsed { hits += 1; return cachedParsed }
        guard let bytes = data() else { return nil }
        let result = PerfDiag.timed("pp_obj_parse") { MeshParser.parseOBJ(from: bytes) }
        parses += 1
        cachedParsed = result
        return result
    }

    /// The file was rewritten in place (registration bake, or its rollback) — adopt the new
    /// bytes directly rather than re-reading them, and drop the stale geometry.
    func replace(with newData: Data) {
        cachedData = newData
        cachedParsed = nil
    }

    func logSavings() {
        guard reads > 0 || parses > 0 else { return }
        PerfDiag.log("[Postprocess] mesh.obj: \(reads) read(s), \(parses) parse(s), "
            + "\(hits) cache hit(s) — \(String(format: "%.1f", Double(cachedData?.count ?? 0) / 1_048_576)) MB")
    }
}
