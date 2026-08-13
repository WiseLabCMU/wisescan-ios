import Foundation
import simd

/// `derived_surfaces.json` — the walkable surfaces RoomPlan did not model, recovered from the
/// classified mesh at post-process (`ARCoverageView.deriveLevelPlanes` / `deriveRampPlanes`).
///
/// Why this is persisted rather than re-derived on demand: deriving needs `mesh.obj` parsed and
/// `face_classes.bin` walked, which is fine once at post-process and far too expensive per render or
/// per registration attempt. Consumers that only need the plane list — the semantic outline view, and
/// eventually the vertical-axis fit — read this instead.
///
/// **Frame.** Written in whatever frame `mesh.obj` is in at the time (raw, or canonical if a
/// registration has been baked), because it is generated in the same post-process step as
/// `mesh_proxy.obj` and from the same inputs. It is therefore co-framed with the mesh and the proxy by
/// construction — and, for the same reason, it must be REGENERATED rather than transformed whenever
/// they are. Its staleness rides `ARCoverageView.ghostProxyVersionHeader`.
///
/// **Categories are deliberately NOT "floor".** `PlaneRegistration.plane(category:…)` accepts only
/// "wall" and "floor", so a decoder pointed at this file drops these surfaces on the floor rather than
/// feeding them silently into a solve. A `ramp` is not interchangeable with a `level` there: the fit's
/// plane matcher admits pairs up to 25° apart, so a shallow ramp would happily correspond to a flat
/// floor and pull the vertical solution with it. Anything wiring these into registration has to opt in
/// per category.
struct DerivedSurfacesData: Codable {

    /// Schema version. Increment when the structure changes; readers should ignore what they do not
    /// understand rather than fail, since the file regenerates on the next Post-process anyway.
    static let schemaVersion = 1

    let version: Int
    let surfaces: [Surface]

    struct Surface: Codable {
        /// `"level"` (walkable horizontal surface at a distinct height) or `"ramp"` (coherently
        /// sloped walkable plane).
        let category: String
        /// Extent in the surface's own plane: `width` along the transform's first column, `height`
        /// along its second. `depth` is always 0 — these are planes, not volumes — and exists only so
        /// the shape matches `RoomPlanExportData.Dimensions` for the renderers that consume both.
        let dimensions: RoomPlanExportData.Dimensions
        /// Column-major 4×4, same convention as `roomplan.json` and
        /// `PlaneRegistration.plane(category:width:height:transform:)`: col0 = xAxis, col1 = yAxis,
        /// col2 = normal, col3 = center.
        let transform: [Float]
    }

    static let levelCategory = "level"
    static let rampCategory = "ramp"

    /// Artifact filename, alongside `mesh_proxy.obj` in the scan directory (and mirrored to
    /// `raw_data/`).
    static let filename = "derived_surfaces.json"

    init(levels: [PlaneRegistration.Plane], ramps: [PlaneRegistration.Plane]) {
        version = Self.schemaVersion
        surfaces = levels.map { Self.surface($0, category: Self.levelCategory) }
            + ramps.map { Self.surface($0, category: Self.rampCategory) }
    }

    private static func surface(_ p: PlaneRegistration.Plane, category: String) -> Surface {
        Surface(category: category,
                dimensions: RoomPlanExportData.Dimensions(width: p.width, height: p.height, depth: 0),
                transform: [p.xAxis.x, p.xAxis.y, p.xAxis.z, 0,
                            p.yAxis.x, p.yAxis.y, p.yAxis.z, 0,
                            p.normal.x, p.normal.y, p.normal.z, 0,
                            p.center.x, p.center.y, p.center.z, 1])
    }

    /// Decode the sidecar from a scan directory, preferring the top-level copy over the `raw_data/`
    /// mirror (which can lag during a registration frame rewrite) — same precedence as
    /// `roomplan.json`. Returns nil when the scan has none, which is the normal case for a flat
    /// single-level room: everything there was already modelled.
    static func load(scanDirectory: URL) -> DerivedSurfacesData? {
        for url in [scanDirectory.appendingPathComponent(filename),
                    scanDirectory.appendingPathComponent("raw_data").appendingPathComponent(filename)] {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(DerivedSurfacesData.self, from: data) {
                return decoded
            }
        }
        return nil
    }
}

extension DerivedSurfacesData.Surface {
    /// The surface's frame as a column-major matrix, for renderers that draw an oriented quad. Nil if
    /// the transform is malformed.
    var matrix: simd_float4x4? {
        guard transform.count == 16 else { return nil }
        return simd_float4x4(SIMD4(transform[0], transform[1], transform[2], transform[3]),
                             SIMD4(transform[4], transform[5], transform[6], transform[7]),
                             SIMD4(transform[8], transform[9], transform[10], transform[11]),
                             SIMD4(transform[12], transform[13], transform[14], transform[15]))
    }

    /// World-space height of the surface's center — the number that identifies a level.
    var centerY: Float? { transform.count == 16 ? transform[13] : nil }
}
