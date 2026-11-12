import Foundation
import SwiftData
import simd
@testable import wisescan_ios

// MARK: - Shared test helpers for the stitch-link tests.

enum StitchTestSupport {
    /// A fresh, in-memory SwiftData container holding the app's full schema. No disk I/O,
    /// so each test starts from an empty, isolated store.
    @MainActor
    static func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([ScanLocation.self, CapturedScan.self, StitchLink.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    /// Inserts a location with a single scan and returns both. The scan is wired to the
    /// location via the relationship so `location.scans` and `scan.location` resolve.
    @MainActor
    @discardableResult
    static func makeLocation(id: UUID,
                             name: String,
                             scanId: UUID,
                             in context: ModelContext) -> (location: ScanLocation, scan: CapturedScan) {
        let location = ScanLocation(id: id, name: name)
        let scan = CapturedScan(id: scanId, name: "\(name)-scan", vertexCount: 0, faceCount: 0)
        context.insert(location)
        context.insert(scan)
        scan.location = location
        return (location, scan)
    }

    /// A pure translation matrix — handy for asserting transform propagation.
    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    /// Approximate equality for two matrices, column by column.
    static func matricesEqual(_ a: simd_float4x4, _ b: simd_float4x4, accuracy: Float = 1e-4) -> Bool {
        for col in 0..<4 {
            let d = a[col] - b[col]
            if simd_length(d) > accuracy { return false }
        }
        return true
    }
}
