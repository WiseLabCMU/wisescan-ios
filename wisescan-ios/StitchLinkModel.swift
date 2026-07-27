import Foundation
import SwiftData
import simd
import os

/// Structured logging for the stitch-link subsystem (migration, link queries). Uses `os.Logger`
/// (same subsystem as `PerfDiag`) instead of `print` so it costs nothing in release, never spams
/// stdout, and is filterable in Console.app. `.info` for once-per-launch outcomes worth keeping;
/// `.debug` for verbose per-item detail (not persisted in release).
let stitchLog = Logger(subsystem: PerfDiag.subsystem, category: "stitch")

// MARK: - Stitch Link Model (SwiftData)
//
// First-class, bidirectional representation of a spatial link between two scans.
// This is the SOURCE OF TRUTH (replacing the per-location `stitching.json` files,
// which are now produced only as an export serialization — see `StitchLinkStore`).
//
// A link is geometrically symmetric: it stores both endpoints' anchor poses (the same
// physical pin expressed in each scan's world frame), so the relative transform can be
// computed in either direction. `sourceIsA` records only *creation provenance* (which
// map existed first / where Pin A was dropped); it is NOT a traversal constraint.
//
// Referential integrity: the cascade rules live on `CapturedScan.linksAsA/linksAsB`
// (see ScanStore.swift), so deleting EITHER endpoint scan — or a whole location, which
// cascades to its scans — removes the link automatically.

@Model
final class StitchLink {
    // Persisted identity (de-dup + graph edges depend on it). Declared with a default so
    // SwiftData can synthesize it; the single construction site supplies an explicit UUID.
    // `.unique` upserts on id collision, so re-import / re-entrant migration can't create
    // duplicate rows for the same logical link — a store-level backstop for the code-side de-dup.
    @Attribute(.unique) var id: UUID = UUID()

    // Endpoint scans. Symmetric — neither is privileged for traversal.
    var endpointAScan: CapturedScan?
    var endpointBScan: CapturedScan?

    // Anchor poses (camera-to-world) at the shared physical pin, each in its own scan's
    // world frame. Stored column-major as 16 floats — mirrors `ScanLocation.imagingPoseMatrix`.
    var anchorAMatrix: [Float] = []
    var anchorBMatrix: [Float] = []
    var anchorAId: UUID = UUID()
    var anchorBId: UUID = UUID()
    var anchorACompassHeading: Double?
    var anchorBCompassHeading: Double?

    // Creation provenance only (Pin A / pre-existing map = endpoint A when true).
    var sourceIsA: Bool = true

    // Manual fine-tune of THIS join (Step 2c) — the user's remedy in place of "rescan" for a
    // *placement* error: the residual after Op-2 auto-correct, or a stitch Op-2 gated off. A
    // gravity-locked yaw about the pin + a 3-axis translation, expressed in the SOURCE scan's
    // canonical frame (same frame/pivot family as the auto yaw), composed into the stitch edge as
    // `r' = nudge · C_auto · r` so it rides both BFS traversal directions like the auto correction.
    // Stored as 4 scalars (not a matrix) so they round-trip to the adjuster's sliders and can't
    // encode a non-conforming transform. Additive with defaults ⇒ lightweight SwiftData migration
    // (mirrors the compass-heading adds).
    var manualYawDeg: Double = 0
    var manualDX: Double = 0
    var manualDY: Double = 0
    var manualDZ: Double = 0

    var linkedAt: Date = Date()
    var linkTypeStr: String = StitchingLink.LinkType.midSession.rawValue

    // swiftlint:disable:next function_parameter_count
    init(id: UUID = UUID(),
         endpointAScan: CapturedScan?,
         endpointBScan: CapturedScan?,
         anchorA: simd_float4x4,
         anchorB: simd_float4x4,
         anchorAId: UUID,
         anchorBId: UUID,
         anchorACompassHeading: Double?,
         anchorBCompassHeading: Double?,
         sourceIsA: Bool,
         linkedAt: Date = Date(),
         linkType: StitchingLink.LinkType) {
        self.id = id
        self.endpointAScan = endpointAScan
        self.endpointBScan = endpointBScan
        self.anchorAMatrix = StitchLink.flatten(anchorA)
        self.anchorBMatrix = StitchLink.flatten(anchorB)
        self.anchorAId = anchorAId
        self.anchorBId = anchorBId
        self.anchorACompassHeading = anchorACompassHeading
        self.anchorBCompassHeading = anchorBCompassHeading
        self.sourceIsA = sourceIsA
        self.linkedAt = linkedAt
        self.linkTypeStr = linkType.rawValue
    }
}

// MARK: - Matrix <-> [Float] (column-major, matches stitching.json convention)

extension StitchLink {
    static func flatten(_ m: simd_float4x4) -> [Float] {
        [m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
         m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
         m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
         m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w]
    }

    static func unflatten(_ a: [Float]) -> simd_float4x4 {
        guard a.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(columns: (
            SIMD4<Float>(a[0], a[1], a[2], a[3]),
            SIMD4<Float>(a[4], a[5], a[6], a[7]),
            SIMD4<Float>(a[8], a[9], a[10], a[11]),
            SIMD4<Float>(a[12], a[13], a[14], a[15])
        ))
    }
}

// MARK: - Manual nudge (Step 2c adjuster)

/// A user's manual fine-tune of one stitch join: a gravity-locked yaw about the pin + a 3-axis
/// translation, in the source scan's canonical frame. Backs the adjuster's sliders (the values ARE
/// the slider positions) and composes into the stitch edge as `r' = matrix · C_auto · r` — the same
/// frame and pivot family as the Op-2 auto yaw, so a manual tweak layers cleanly on the auto seat.
struct ManualNudge: Equatable {
    var yawDeg: Float = 0
    var dx: Float = 0      // source-canonical X (m)
    var dy: Float = 0      // vertical (m)
    var dz: Float = 0      // source-canonical Z (m)

    static let zero = ManualNudge()
    var isZero: Bool { yawDeg == 0 && dx == 0 && dy == 0 && dz == 0 }

    /// Correction matrix: yaw about `pivot` (world-up Y), then translate. `pivot` is the join's pin
    /// (in source-canonical, after the auto correction) so a manual rotation spins the piece about
    /// the doorway rather than about a far origin.
    func matrix(pivot: SIMD3<Float>) -> simd_float4x4 {
        let a = yawDeg * Float.pi / 180, c = cos(a), s = sin(a)
        let R = simd_float4x4(SIMD4<Float>(c, 0, -s, 0), SIMD4<Float>(0, 1, 0, 0),
                              SIMD4<Float>(s, 0, c, 0), SIMD4<Float>(0, 0, 0, 1))
        var tp = matrix_identity_float4x4; tp.columns.3 = SIMD4<Float>(pivot, 1)
        var tn = matrix_identity_float4x4; tn.columns.3 = SIMD4<Float>(-pivot, 1)
        var tt = matrix_identity_float4x4; tt.columns.3 = SIMD4<Float>(dx, dy, dz, 1)
        return tt * (tp * R * tn)
    }
}

// MARK: - Stitch UX preferences

/// App-wide stitch-correction preferences (UserDefaults-backed). When `alwaysAutocorrect` is on, an
/// untouched join's correction is seeded from the solver's auto fix (transferred INTO its single
/// nudge) at render-open and honored at export. The key is shared with the render's `@AppStorage`.
enum StitchPrefs {
    static let alwaysAutocorrectKey = "stitchAlwaysAutocorrect"
    static var alwaysAutocorrect: Bool {
        get { UserDefaults.standard.bool(forKey: alwaysAutocorrectKey) }
        set { UserDefaults.standard.set(newValue, forKey: alwaysAutocorrectKey) }
    }
}

// MARK: - Provenance-resolved accessors

extension StitchLink {
    var anchorAMatrixValue: simd_float4x4 { StitchLink.unflatten(anchorAMatrix) }
    var anchorBMatrixValue: simd_float4x4 { StitchLink.unflatten(anchorBMatrix) }
    var linkType: StitchingLink.LinkType { StitchingLink.LinkType(rawValue: linkTypeStr) ?? .midSession }

    var sourceScan: CapturedScan? { sourceIsA ? endpointAScan : endpointBScan }
    var targetScan: CapturedScan? { sourceIsA ? endpointBScan : endpointAScan }
    var sourceAnchorMatrix: simd_float4x4 { sourceIsA ? anchorAMatrixValue : anchorBMatrixValue }
    var targetAnchorMatrix: simd_float4x4 { sourceIsA ? anchorBMatrixValue : anchorAMatrixValue }
    var sourceAnchorId: UUID { sourceIsA ? anchorAId : anchorBId }
    var targetAnchorId: UUID { sourceIsA ? anchorBId : anchorAId }
    var sourceAnchorCompassHeading: Double? { sourceIsA ? anchorACompassHeading : anchorBCompassHeading }
    var targetAnchorCompassHeading: Double? { sourceIsA ? anchorBCompassHeading : anchorACompassHeading }

    /// The user's manual fine-tune for this join (Step 2c). Get/set proxies the 4 stored scalars.
    var manualNudge: ManualNudge {
        get { ManualNudge(yawDeg: Float(manualYawDeg), dx: Float(manualDX), dy: Float(manualDY), dz: Float(manualDZ)) }
        set { manualYawDeg = Double(newValue.yawDeg); manualDX = Double(newValue.dx)
              manualDY = Double(newValue.dy); manualDZ = Double(newValue.dz) }
    }
    var hasManualCorrection: Bool { !manualNudge.isZero }

    /// The endpoint anchor pose expressed in `scan`'s own world frame, plus the *other*
    /// endpoint, for in-scan connector rendering. Returns nil if `scan` is not an endpoint.
    func localAnchor(for scan: CapturedScan) -> (transform: simd_float4x4, otherScan: CapturedScan?)? {
        if endpointAScan?.id == scan.id { return (anchorAMatrixValue, endpointBScan) }
        if endpointBScan?.id == scan.id { return (anchorBMatrixValue, endpointAScan) }
        return nil
    }

    /// Maps this link back to the on-the-wire `StitchingLink` DTO (export / schema format).
    /// Returns nil if an endpoint scan or its location no longer exists.
    ///
    /// The exported SOURCE anchor carries the effective Op-2 + manual correction baked in (see
    /// `StitchGraphBuilder.bakedSourceAnchor`) so the wire edge reproduces the corrected
    /// combined-render placement — the correction is authoritative downstream, not render-only. The
    /// model's stored anchors stay raw/as-measured (non-destructive); only this exported copy moves.
    @MainActor
    func asDTO() -> StitchingLink? {
        guard let src = sourceScan, let tgt = targetScan,
              let srcLoc = src.location, let tgtLoc = tgt.location else { return nil }
        let bakedSource = StitchGraphBuilder.bakedSourceAnchor(for: self)
        return StitchingLink(
            id: id,
            sourceLocationId: srcLoc.id,
            sourceScanId: src.id,
            sourceAnchorId: sourceAnchorId,
            sourceAnchorTransform: CodableMatrix4x4(bakedSource),
            sourceAnchorCompassHeading: sourceAnchorCompassHeading,
            targetLocationId: tgtLoc.id,
            targetScanId: tgt.id,
            targetAnchorId: targetAnchorId,
            targetAnchorTransform: CodableMatrix4x4(targetAnchorMatrix),
            targetAnchorCompassHeading: targetAnchorCompassHeading,
            linkedAt: linkedAt,
            linkType: linkType
        )
    }
}

// MARK: - Connector anchor (for in-scan 3D rendering — Track C contract)

/// One labeled connector incident to a scan, positioned in that scan's world frame.
struct ConnectorAnchor: Identifiable {
    let id: UUID            // link id
    let transform: simd_float4x4
    let otherLocationName: String
}

// MARK: - Store (create / query / serialize / migrate)

@MainActor
enum StitchLinkStore {

    /// Creates a link between two scans (source = Pin A / pre-existing map) and saves.
    /// Throws if the save fails so the caller can surface it — a silently-dropped link would
    /// leave the maps visually stitched but with no persisted connection.
    // swiftlint:disable:next function_parameter_count
    static func create(sourceScan: CapturedScan,
                       targetScan: CapturedScan,
                       sourceAnchor: simd_float4x4,
                       targetAnchor: simd_float4x4,
                       sourceAnchorId: UUID,
                       targetAnchorId: UUID,
                       sourceCompassHeading: Double?,
                       targetCompassHeading: Double?,
                       linkType: StitchingLink.LinkType,
                       in context: ModelContext) throws -> StitchLink {
        let link = StitchLink(
            endpointAScan: sourceScan,
            endpointBScan: targetScan,
            anchorA: sourceAnchor,
            anchorB: targetAnchor,
            anchorAId: sourceAnchorId,
            anchorBId: targetAnchorId,
            anchorACompassHeading: sourceCompassHeading,
            anchorBCompassHeading: targetCompassHeading,
            sourceIsA: true,
            linkType: linkType
        )
        context.insert(link)
        try context.save()
        return link
    }

    /// All links incident to a scan (as either endpoint), de-duped by id.
    ///
    /// Resolved via an explicit fetch filtered on the *forward* relationships
    /// (`StitchLink.endpointAScan`/`endpointBScan` — the side `create(...)` actually sets), NOT the
    /// cached inverse collections (`scan.linksAsA`/`linksAsB`). SwiftData's inverse maintenance for a
    /// model with TWO relationships to the SAME destination type (both endpoints are `CapturedScan?`)
    /// is unreliable and asymmetric: one inverse array can come back empty even though the forward
    /// link is set. That made a *source* map's outgoing connectors silently vanish on rescan while a
    /// *target* map's incoming connector still showed — the "only appears backwards" bug. Filtering
    /// fetched links by endpoint id surfaces BOTH directions. Falls back to the inverse arrays only
    /// when the scan has no associated context (e.g. not yet inserted).
    static func incidentLinks(for scan: CapturedScan) -> [StitchLink] {
        let scanId = scan.id
        if let context = scan.modelContext,
           let all = try? context.fetch(FetchDescriptor<StitchLink>()) {
            return all.filter { $0.endpointAScan?.id == scanId || $0.endpointBScan?.id == scanId }
        }
        var seen = Set<UUID>()
        return (scan.linksAsA + scan.linksAsB).filter { seen.insert($0.id).inserted }
    }

    /// Every `StitchLink` fetched ONCE and grouped by each incident scan's id. Use this when
    /// resolving links for MANY scans (a location's whole connector set, the graph build) so the
    /// full-table fetch in `incidentLinks(for:)` runs a single time instead of once per scan.
    /// Returns an empty index if the context can't be fetched (callers then resolve nothing — the
    /// same outcome as `incidentLinks`' fetch failing).
    static func incidentLinksByScanId(in context: ModelContext) -> [UUID: [StitchLink]] {
        guard let all = try? context.fetch(FetchDescriptor<StitchLink>()) else { return [:] }
        var index: [UUID: [StitchLink]] = [:]
        for link in all {
            let a = link.endpointAScan?.id
            let b = link.endpointBScan?.id
            if let a { index[a, default: []].append(link) }
            if let b, b != a { index[b, default: []].append(link) }
        }
        return index
    }

    /// Whether any scan in the location participates in a link.
    ///
    /// Deliberately reads the inverse arrays (`linksAsA`/`linksAsB`) directly rather than routing
    /// through the fetch-based `incidentLinks`. This is the badge's data source and is read inside a
    /// SwiftUI `body` (LocationDetailView): touching the relationship properties registers them as
    /// observation dependencies, so the badge updates reactively when a link is added/removed — a
    /// `context.fetch` would not. It also stays cheap (no per-render store fetch). The asymmetric
    /// inverse-maintenance quirk that `incidentLinks` works around can drop a *specific* direction,
    /// but a scan being unaware of EVERY link it participates in (which is all the badge needs to
    /// detect) is a degenerate state that shouldn't occur. Where correctness of each individual edge
    /// matters (render, graph), use `incidentLinks`/`connectorAnchors` instead.
    static func hasLinks(in location: ScanLocation) -> Bool {
        location.scans.contains { !$0.linksAsA.isEmpty || !$0.linksAsB.isEmpty }
    }

    /// Labeled connectors for an in-scan 3D render, in `scan`'s world frame (Track C).
    static func connectorAnchors(for scan: CapturedScan) -> [ConnectorAnchor] {
        connectorAnchors(for: scan, from: incidentLinks(for: scan))
    }

    /// Labeled connectors for `scan` resolved from a PRE-FETCHED link set (e.g. one entry of
    /// `incidentLinksByScanId`). Use this when resolving many scans to avoid a per-scan fetch; the
    /// no-argument overload is the single-scan convenience.
    static func connectorAnchors(for scan: CapturedScan, from links: [StitchLink]) -> [ConnectorAnchor] {
        links.compactMap { link in
            guard let local = link.localAnchor(for: scan) else { return nil }
            let name = local.otherScan?.location?.name ?? "Linked map"
            return ConnectorAnchor(id: link.id, transform: local.transform, otherLocationName: name)
        }
    }

    /// Builds the per-location `stitching.json` DTO (every link the location participates in,
    /// either direction) for export (Track A).
    static func manifest(forLocation location: ScanLocation) -> StitchingManifest {
        var seen = Set<UUID>()
        var dtos: [StitchingLink] = []
        for scan in location.scans {
            for link in incidentLinks(for: scan) where seen.insert(link.id).inserted {
                if let dto = link.asDTO() { dtos.append(dto) }
            }
        }
        return StitchingManifest(links: dtos)
    }

    // MARK: Migration

    /// One-time import of legacy per-location `stitching.json` files into SwiftData.
    /// Idempotent (de-dups by link id) and guarded by a UserDefaults flag so it runs once.
    /// Legacy files are left on disk (the builder ignores them); they are now dead weight only.
    /// Must run AFTER any demo-data seeding so source/target scans exist to resolve against.
    /// Re-entrancy guard: `migrateFromFilesIfNeeded` yields the main actor at every `await`
    /// (readAsync per location), so a second invocation — e.g. `onAppear` firing twice — could
    /// interleave, see the UserDefaults flag still unset, and import the same files again. The flag
    /// is only persisted at the very end, so this synchronous in-flight bool (set before any await)
    /// is what actually serializes concurrent runs within a single launch.
    private static var migrationInFlight = false

    static func migrateFromFilesIfNeeded(context: ModelContext) async {
        let flagKey = "stitchLinkMigrationV1Done"
        let flagSet = UserDefaults.standard.bool(forKey: flagKey)
        let existingRows = (try? context.fetchCount(FetchDescriptor<StitchLink>())) ?? 0

        // Self-heal: a prior run could have persisted the done-flag while importing ZERO rows (a
        // save that silently failed, or scans not yet resolvable), permanently orphaning every
        // legacy link. So the flag alone isn't trusted — we also require that StitchLink rows
        // actually exist. If the flag is set AND rows exist, the migration genuinely ran; skip.
        // If the flag is set but there are NO rows, re-scan the disk: legacy files may still hold
        // links we can import now.
        if (flagSet && existingRows > 0) || migrationInFlight {
            stitchLog.debug("migration skip (flagSet=\(flagSet) existingRows=\(existingRows) inFlight=\(migrationInFlight))")
            return
        }
        migrationInFlight = true
        defer { migrationInFlight = false }
        stitchLog.debug("migration START flagSet=\(flagSet) existingRows=\(existingRows)")

        guard let locations = try? context.fetch(FetchDescriptor<ScanLocation>()) else {
            stitchLog.error("migration ABORT — could not fetch locations")
            return
        }
        let scanById: [UUID: CapturedScan] = Dictionary(
            locations.flatMap { $0.scans }.map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        var existing = Set((try? context.fetch(FetchDescriptor<StitchLink>()))?.map(\.id) ?? [])

        var imported = 0
        var filesFound = 0
        var fileLinks = 0
        var unresolved = 0
        for loc in locations {
            guard let manifest = await StitchingMetadataManager.readAsync(locationId: loc.id) else { continue }
            filesFound += 1
            stitchLog.debug("migration file for '\(loc.name, privacy: .public)': \(manifest.links.count) link(s)")
            for dto in manifest.links {
                fileLinks += 1
                if existing.contains(dto.id) { continue }
                guard let src = scanById[dto.sourceScanId], let tgt = scanById[dto.targetScanId] else {
                    unresolved += 1
                    stitchLog.error("migration UNRESOLVED link \(dto.id.uuidString.prefix(8), privacy: .public) src=\(dto.sourceScanId.uuidString.prefix(8), privacy: .public) tgt=\(dto.targetScanId.uuidString.prefix(8), privacy: .public)")
                    continue
                }
                let link = StitchLink(
                    id: dto.id,
                    endpointAScan: src,
                    endpointBScan: tgt,
                    anchorA: dto.sourceAnchorTransform.matrix,
                    anchorB: dto.targetAnchorTransform.matrix,
                    anchorAId: dto.sourceAnchorId,
                    anchorBId: dto.targetAnchorId,
                    anchorACompassHeading: dto.sourceAnchorCompassHeading,
                    anchorBCompassHeading: dto.targetAnchorCompassHeading,
                    sourceIsA: true,
                    linkedAt: dto.linkedAt,
                    linkType: dto.linkType
                )
                context.insert(link)
                existing.insert(dto.id)
                imported += 1
            }
        }
        // Persist the done-flag ONLY when nothing is left unimported. If links failed to resolve,
        // leave the flag UNSET so a later launch (e.g. once scans fully load) retries — and the
        // UNRESOLVED logs above tell us why. A clean run (no unresolved) sets the flag so we don't
        // re-scan the disk every launch. (Note: a library with zero links keeps `existingRows == 0`,
        // so the self-heal guard re-scans the disk each launch — cheap and async, but intentional.)
        do {
            try context.save()
            if unresolved == 0 {
                UserDefaults.standard.set(true, forKey: flagKey)
            }
            stitchLog.info("""
                migration done: locations=\(locations.count) filesFound=\(filesFound) \
                fileLinks=\(fileLinks) imported=\(imported) unresolved=\(unresolved) \
                flagPersisted=\(unresolved == 0)
                """)
        } catch {
            stitchLog.error("migration save FAILED; will retry next launch: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Orphan cleanup

    /// Sweep orphaned adjacent-space locations. The mid-session (`pinAndExtend`) and cross-session
    /// (`confirmAlignment`) extend flows create the "Adjacent to …" `ScanLocation` and persist it
    /// BEFORE the new scan records (recording resolves `activeLocationForScan`, so the location must
    /// already exist). Their abort `defer`s only cover the stabilization task; a freeze or crash
    /// during the subsequent record→save leaves the location behind with **zero scans** — and it has
    /// no UI affordance to delete. A `.linkAdjacent` location with no scans can never become useful
    /// (0 scans ⇒ no incident links either, since links reference scans), so delete it.
    ///
    /// Runs once at launch, after migration — no capture is in flight then, so `scans.isEmpty` can't
    /// be a legitimate mid-recording transient. Scoped to `.linkAdjacent` so a user-created normal
    /// location that's simply not scanned yet is never touched.
    static func reconcileOrphanedAdjacentLocations(context: ModelContext) {
        guard let locations = try? context.fetch(FetchDescriptor<ScanLocation>()) else { return }
        let orphans = locations.filter { $0.scanCase == .linkAdjacent && $0.scans.isEmpty }
        guard !orphans.isEmpty else { return }
        for loc in orphans {
            stitchLog.info("reconcile: deleting orphaned adjacent location '\(loc.name, privacy: .public)' (0 scans)")
            context.delete(loc)
        }
        do {
            try context.save()
            stitchLog.info("reconcile: swept \(orphans.count) orphaned adjacent location(s)")
        } catch {
            stitchLog.error("reconcile: save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
