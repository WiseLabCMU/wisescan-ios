import Foundation
import SwiftData
import simd

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

    /// The endpoint anchor pose expressed in `scan`'s own world frame, plus the *other*
    /// endpoint, for in-scan connector rendering. Returns nil if `scan` is not an endpoint.
    func localAnchor(for scan: CapturedScan) -> (transform: simd_float4x4, otherScan: CapturedScan?)? {
        if endpointAScan?.id == scan.id { return (anchorAMatrixValue, endpointBScan) }
        if endpointBScan?.id == scan.id { return (anchorBMatrixValue, endpointAScan) }
        return nil
    }

    /// Maps this link back to the on-the-wire `StitchingLink` DTO (export / schema format).
    /// Returns nil if an endpoint scan or its location no longer exists.
    func asDTO() -> StitchingLink? {
        guard let src = sourceScan, let tgt = targetScan,
              let srcLoc = src.location, let tgtLoc = tgt.location else { return nil }
        return StitchingLink(
            id: id,
            sourceLocationId: srcLoc.id,
            sourceScanId: src.id,
            sourceAnchorId: sourceAnchorId,
            sourceAnchorTransform: CodableMatrix4x4(sourceAnchorMatrix),
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
    static func incidentLinks(for scan: CapturedScan) -> [StitchLink] {
        var seen = Set<UUID>()
        return (scan.linksAsA + scan.linksAsB).filter { seen.insert($0.id).inserted }
    }

    /// Whether any scan in the location participates in a link.
    static func hasLinks(in location: ScanLocation) -> Bool {
        location.scans.contains { !$0.linksAsA.isEmpty || !$0.linksAsB.isEmpty }
    }

    /// Labeled connectors for an in-scan 3D render, in `scan`'s world frame (Track C).
    static func connectorAnchors(for scan: CapturedScan) -> [ConnectorAnchor] {
        incidentLinks(for: scan).compactMap { link in
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
            for link in (scan.linksAsA + scan.linksAsB) where seen.insert(link.id).inserted {
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
        if UserDefaults.standard.bool(forKey: flagKey) || migrationInFlight { return }
        migrationInFlight = true
        defer { migrationInFlight = false }

        guard let locations = try? context.fetch(FetchDescriptor<ScanLocation>()) else { return }
        let scanById: [UUID: CapturedScan] = Dictionary(
            locations.flatMap { $0.scans }.map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        var existing = Set((try? context.fetch(FetchDescriptor<StitchLink>()))?.map(\.id) ?? [])

        var imported = 0
        for loc in locations {
            guard let manifest = await StitchingMetadataManager.readAsync(locationId: loc.id) else { continue }
            for dto in manifest.links where !existing.contains(dto.id) {
                guard let src = scanById[dto.sourceScanId], let tgt = scanById[dto.targetScanId] else { continue }
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
        try? context.save()
        UserDefaults.standard.set(true, forKey: flagKey)
        if imported > 0 { print("[StitchLinkStore] Migrated \(imported) link(s) from stitching.json into SwiftData") }
    }
}
