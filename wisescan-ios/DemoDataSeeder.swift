import Foundation
import SwiftData

/// Discovers orphan scan files on disk (e.g. imported via xcappdata)
/// and creates matching SwiftData entries so they appear in the app.
///
/// Triggered by launch argument `--seed-demo-data`.
@MainActor
struct DemoDataSeeder {

    static func seedIfNeeded(context: ModelContext) {
        guard CommandLine.arguments.contains("--seed-demo-data") else { return }

        // Don't re-seed if data already exists
        let existing = (try? context.fetchCount(FetchDescriptor<ScanLocation>())) ?? 0
        if existing > 0 {
            print("[DemoDataSeeder] Database already has \(existing) locations, skipping seed.")
            return
        }

        print("[DemoDataSeeder] Seeding database from on-disk scan files...")

        let fm = FileManager.default
        guard let docsURL = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let scansRoot = docsURL.appendingPathComponent("Scans")

        guard fm.fileExists(atPath: scansRoot.path) else {
            print("[DemoDataSeeder] No Scans directory found at \(scansRoot.path)")
            return
        }

        // Iterate location directories: Scans/{locationUUID}/
        guard let locationDirs = try? fm.contentsOfDirectory(at: scansRoot, includingPropertiesForKeys: nil) else { return }

        var seededLocations = 0
        var seededScans = 0

        for locationDir in locationDirs {
            guard locationDir.hasDirectoryPath else { continue }
            guard let locationUUID = UUID(uuidString: locationDir.lastPathComponent) else { continue }

            // Check if this location directory has any scan subdirectories with mesh.obj
            guard let scanDirs = try? fm.contentsOfDirectory(at: locationDir, includingPropertiesForKeys: nil) else { continue }

            let validScanDirs = scanDirs.filter { dir in
                dir.hasDirectoryPath &&
                UUID(uuidString: dir.lastPathComponent) != nil &&
                fm.fileExists(atPath: dir.appendingPathComponent("mesh.obj").path)
            }

            guard !validScanDirs.isEmpty else { continue }

            // Create the ScanLocation with the original UUID so file paths match
            let location = ScanLocation(
                id: locationUUID,
                name: "Location \(seededLocations + 1)",
                updatedAt: Date()
            )
            context.insert(location)
            seededLocations += 1

            for scanDir in validScanDirs {
                guard let scanUUID = UUID(uuidString: scanDir.lastPathComponent) else { continue }

                // Count mesh geometry for display
                let meshURL = scanDir.appendingPathComponent("mesh.obj")
                let (vertices, faces) = countOBJGeometry(url: meshURL)

                let scan = CapturedScan(
                    id: scanUUID,
                    name: "Scan \(seededScans + 1)",
                    capturedAt: fileCreationDate(url: scanDir) ?? Date(),
                    vertexCount: vertices,
                    faceCount: faces
                )

                location.scans.append(scan)
                scan.location = location
                context.insert(scan)
                seededScans += 1

                print("[DemoDataSeeder] Seeded scan \(scanUUID.uuidString.prefix(8)) (\(vertices)v, \(faces)f)")
            }
        }

        try? context.save()
        print("[DemoDataSeeder] Done: \(seededLocations) locations, \(seededScans) scans")
    }

    // MARK: - Helpers

    private static func countOBJGeometry(url: URL) -> (vertices: Int, faces: Int) {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return (0, 0) }
        var vertices = 0
        var faces = 0
        for line in data.split(separator: "\n") {
            if line.hasPrefix("v ") { vertices += 1 }
            else if line.hasPrefix("f ") { faces += 1 }
        }
        return (vertices, faces)
    }

    private static func fileCreationDate(url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date
    }
}
