import Foundation
import SwiftData

struct ScanExportManager {
    // Lazily-opened container pointing at the SAME on-disk store the app uses (default
    // Application Support location, default `ModelConfiguration`, identical Schema —
    // mirrors AppDelegate.sharedModelContainer). `prepareExport` runs off the main actor
    // and has no injected ModelContext, so stitching/graph serialization fetches through
    // this shared store on a @MainActor hop. Cached so we don't reopen the SQLite file per
    // export. Marked unsafe because ModelContainer is Sendable-by-convention here and this
    // is only ever assigned once under the @MainActor accessor below.
    nonisolated(unsafe) private static var cachedContainer: ModelContainer?

    @MainActor
    private static func exportModelContainer() -> ModelContainer? {
        if let cachedContainer { return cachedContainer }
        let schema = Schema([ScanLocation.self, CapturedScan.self, StitchLink.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        guard let container = try? ModelContainer(for: schema, configurations: [config]) else {
            print("[prepareExport] ✗ could not open model store for stitching export")
            return nil
        }
        cachedContainer = container
        return container
    }

    /// Holder for the two serialized export artifacts. `Data` is Sendable, so this can cross
    /// the actor boundary back to whatever queue `prepareExport` runs on. Either field is nil
    /// when there is nothing to write (no location, no incident links, or no component).
    private struct StitchExportArtifacts: Sendable {
        var stitching: Data?
        var graph: Data?
    }

    /// Resolves the `ScanLocation` for the given id and builds the JSON `Data` for both
    /// serialized artifacts. Runs on the main actor because SwiftData models, `StitchLinkStore`
    /// and `StitchGraphBuilder.build` are all @MainActor; the returned `Data` is handed back to
    /// the (off-main) caller for file writing.
    @MainActor
    private static func makeStitchExportArtifacts(forLocationId locationId: UUID) async -> StitchExportArtifacts {
        guard let container = exportModelContainer() else { return StitchExportArtifacts() }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ScanLocation>(predicate: #Predicate { $0.id == locationId })
        guard let location = try? context.fetch(descriptor).first else { return StitchExportArtifacts() }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        var artifacts = StitchExportArtifacts()

        // A1: per-location stitching.json generated from the DB (every incident link, both
        // directions). Skip entirely when the location has no links.
        let manifest = StitchLinkStore.manifest(forLocation: location)
        if !manifest.links.isEmpty {
            artifacts.stitching = try? encoder.encode(manifest)
        }

        // A2: graph.json — the connected component this location belongs to.
        if let aggregate = await buildGraphAggregate(for: location, in: context) {
            artifacts.graph = try? encoder.encode(aggregate)
        }

        return artifacts
    }

    // MARK: Graph aggregate (graph.json)

    /// Wire shape for `graph.json`: the whole connected map (nodes + dedup'd links) so the
    /// backend can ingest a linked cluster from one file. Local to export — the per-link
    /// payload reuses the canonical `StitchingLink` DTO.
    private struct GraphAggregateNode: Encodable {
        let locationId: UUID
        let name: String
        let scanIds: [UUID]
    }
    private struct GraphAggregate: Encodable {
        let version: Int
        let nodes: [GraphAggregateNode]
        let links: [StitchingLink]
    }

    /// Builds the full stitch graph, finds the connected component containing `location`, and
    /// assembles the `graph.json` aggregate (nodes + de-duped link DTOs). Returns nil if the
    /// location is in no component (i.e. participates in no links).
    @MainActor
    private static func buildGraphAggregate(for location: ScanLocation,
                                            in context: ModelContext) async -> GraphAggregate? {
        // Need every location so cross-location links resolve both endpoints.
        guard let allLocations = try? context.fetch(FetchDescriptor<ScanLocation>()) else { return nil }
        let graph = await StitchGraphBuilder.build(from: allLocations)

        // Find the component this location sits in; bail if it's isolated (no links).
        guard let component = graph.components.first(where: { $0.contains(location.id) }) else { return nil }
        let componentSet = Set(component)
        let nodesById = graph.nodesById

        // Nodes: one per location in the component, with the scans an incident link references.
        let nodes: [GraphAggregateNode] = component.compactMap { locId in
            guard let node = nodesById[locId] else { return nil }
            return GraphAggregateNode(
                locationId: locId,
                name: node.location.name,
                scanIds: node.scanIds.sorted { $0.uuidString < $1.uuidString }
            )
        }

        // Links: every edge whose endpoints are both inside this component, mapped to the wire
        // DTO and de-duped by link id (an edge appears once per StitchLink already, but guard).
        var seen = Set<UUID>()
        let links: [StitchingLink] = graph.edges
            .filter { componentSet.contains($0.from) && componentSet.contains($0.to) }
            .compactMap { edge in
                guard seen.insert(edge.link.id).inserted else { return nil }
                return edge.link.asDTO()
            }

        guard !links.isEmpty else { return nil }
        return GraphAggregate(version: 1, nodes: nodes, links: links)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func prepareExport(filename: String, scanDir: URL, format: ExportFormat) -> URL? {
        let fm = FileManager.default
        let rawDataDir = scanDir.appendingPathComponent("raw_data")

        // Locate scan4d_metadata.json
        func findMetadata() -> URL? {
            let candidates = [
                rawDataDir.appendingPathComponent("scan4d_metadata.json"),
                scanDir.appendingPathComponent("scan4d_metadata.json")
            ]
            for url in candidates {
                if fm.fileExists(atPath: url.path) {
                    return url
                }
            }
            return nil
        }

        // Stage Polycam payload: images/, depth/, confidence/, cameras/, mesh_info.json, proxy_images/
        func stagePolycamPayload(to dir: URL) {
            let items = ["images", "proxy_images", "depth", "confidence", "cameras", "mesh_info.json"]
            for item in items {
                let src = rawDataDir.appendingPathComponent(item)
                let dst = dir.appendingPathComponent(item)
                if fm.fileExists(atPath: src.path) {
                    do {
                        try fm.copyItem(at: src, to: dst)
                        print("[prepareExport] ✓ copied \(item)")
                    } catch {
                        print("[prepareExport] ✗ failed to copy \(item): \(error.localizedDescription)")
                    }
                } else {
                    print("[prepareExport] ✗ missing \(item) at \(src.path)")
                }
            }
        }

        // Zip a staging directory and return the zip URL
        func zipStaging(_ stagingDir: URL) -> URL? {
            let zipURL = fm.temporaryDirectory.appendingPathComponent(filename)
            try? fm.removeItem(at: zipURL)

            var error: NSError?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: stagingDir, options: .forUploading, error: &error) { zipTempURL in
                try? fm.copyItem(at: zipTempURL, to: zipURL)
            }

            if let zipAttr = try? fm.attributesOfItem(atPath: zipURL.path),
               let zipSize = zipAttr[.size] as? Int64 {
                print("[prepareExport] \(format.rawValue) zipSize=\(zipSize) bytes")
            } else {
                print("[prepareExport] \(format.rawValue) error=\(error?.localizedDescription ?? "none")")
            }
            return error == nil ? zipURL : nil
        }

        // Create and auto-clean staging directory
        func withStagingDir(_ block: (URL) -> URL?) -> URL? {
            let stagingDir = fm.temporaryDirectory.appendingPathComponent("staging_\(UUID().uuidString)")
            try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stagingDir) }
            return block(stagingDir)
        }

        switch format {
        case .scan4d:
            // scan4d_metadata.json + relocalization.worldmap + full Polycam payload
            return withStagingDir { stagingDir in
                if let metaURL = findMetadata() {
                    do {
                        try fm.copyItem(at: metaURL, to: stagingDir.appendingPathComponent("scan4d_metadata.json"))
                    } catch {
                        print("[prepareExport] Failed to copy metadata: \(error.localizedDescription)")
                    }
                }
                do {
                    try fm.copyItem(
                        at: scanDir.appendingPathComponent("arworldmap.map"),
                        to: stagingDir.appendingPathComponent("relocalization.worldmap")
                    )
                } catch {
                    print("[prepareExport] Failed to copy worldmap: \(error.localizedDescription)")
                }
                stagePolycamPayload(to: stagingDir)

                // Generate stitching.json (and the graph.json aggregate) FROM the DB rather
                // than copying the now-legacy on-disk file. Links live in SwiftData, so we
                // fetch the location and build the manifest on the main actor (everything
                // there is @MainActor), then write the resulting Data here. scanDir layout is
                // Documents/Scans/{locationId}/{scanId}/, so the parent dir name is the id.
                let locationDirName = scanDir.deletingLastPathComponent().lastPathComponent
                if let locationId = UUID(uuidString: locationDirName) {
                    // prepareExport is a synchronous function called from a background queue, so
                    // block on the async @MainActor build with a semaphore. Data is Sendable.
                    let semaphore = DispatchSemaphore(value: 0)
                    nonisolated(unsafe) var captured = StitchExportArtifacts()
                    Task { @MainActor in
                        captured = await makeStitchExportArtifacts(forLocationId: locationId)
                        semaphore.signal()
                    }
                    semaphore.wait()

                    if let stitchingData = captured.stitching {
                        let destURL = stagingDir.appendingPathComponent(StitchingMetadataManager.filename)
                        do {
                            try stitchingData.write(to: destURL, options: .atomic)
                            print("[prepareExport] ✓ generated stitching.json")
                        } catch {
                            print("[prepareExport] ✗ failed to write stitching.json: \(error.localizedDescription)")
                        }
                    }
                    if let graphData = captured.graph {
                        let destURL = stagingDir.appendingPathComponent("graph.json")
                        do {
                            try graphData.write(to: destURL, options: .atomic)
                            print("[prepareExport] ✓ generated graph.json")
                        } catch {
                            print("[prepareExport] ✗ failed to write graph.json: \(error.localizedDescription)")
                        }
                    }
                }

                return zipStaging(stagingDir)
            }

        case .polycam:
            // Polycam raw data import: images/, depth/, cameras/, mesh_info.json
            return withStagingDir { stagingDir in
                stagePolycamPayload(to: stagingDir)
                return zipStaging(stagingDir)
            }

        case .raw:
            // Nerfstudio format: images/, proxy_images/, depth/, confidence/, transforms.json
            return withStagingDir { stagingDir in
                let copyItems = [("images", "images"), ("proxy_images", "proxy_images"), ("depth", "depth"), ("confidence", "confidence"), ("transforms.json", "transforms.json")]
                for (src, dst) in copyItems {
                    do {
                        try fm.copyItem(
                            at: rawDataDir.appendingPathComponent(src),
                            to: stagingDir.appendingPathComponent(dst)
                        )
                    } catch {
                        print("[prepareExport] RAW: failed to copy \(src): \(error.localizedDescription)")
                    }
                }
                return zipStaging(stagingDir)
            }

        case .obj:
            // Single mesh file
            let outputURL = fm.temporaryDirectory.appendingPathComponent(filename)
            try? fm.removeItem(at: outputURL)
            do {
                try fm.copyItem(at: scanDir.appendingPathComponent("mesh.obj"), to: outputURL)
                print("[prepareExport] OBJ copied to \(outputURL.lastPathComponent)")
                return outputURL
            } catch {
                print("[prepareExport] OBJ copy failed: \(error)")
                return nil
            }

        case .ply:
            // Convert OBJ + colors.bin → PLY
            let outputURL = fm.temporaryDirectory.appendingPathComponent(filename)
            try? fm.removeItem(at: outputURL)
            if MeshConverter.objToPLY(
                objURL: scanDir.appendingPathComponent("mesh.obj"),
                colorsURL: scanDir.appendingPathComponent("colors.bin"),
                outputURL: outputURL
            ) {
                return outputURL
            }
            return nil

        case .usdz:
            // Convert OBJ → USDZ via ModelIO
            let outputURL = fm.temporaryDirectory.appendingPathComponent(filename)
            try? fm.removeItem(at: outputURL)
            if MeshConverter.objToUSDZ(
                objURL: scanDir.appendingPathComponent("mesh.obj"),
                outputURL: outputURL
            ) {
                return outputURL
            }
            return nil
        }
    }
}

extension CapturedScan {
    func makeExportFilename(format: ExportFormat) -> String {
        let locationName = self.location?.name.replacingOccurrences(of: " ", with: "_") ?? "Unknown_Location"
        let scanName = self.name.replacingOccurrences(of: " ", with: "_")
        let formatStr = format.rawValue.lowercased()
        let timestamp = Int(self.capturedAt.timeIntervalSince1970)
        let fileExt = format.fileExtension
        return "scan4d_\(locationName)_\(scanName)_\(formatStr)_\(timestamp)_\(self.id.uuidString.prefix(8)).\(fileExt)"
    }
}
