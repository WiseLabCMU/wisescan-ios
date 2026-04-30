import Foundation
import SwiftData

struct ScanExportManager {
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
