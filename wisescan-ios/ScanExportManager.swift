import Foundation
import SwiftData
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct ScanExportManager {
    // `prepareExport` runs off the main actor with no injected ModelContext, so it fetches through
    // the app's shared container on a @MainActor hop (creating its own background ModelContext).
    // Reuse the SINGLE app container rather than opening a second one over the same SQLite store —
    // two persistent-store coordinators on one file risk stale reads / lock contention.
    @MainActor
    private static func exportModelContainer() -> ModelContainer? {
        Scan4DApp.sharedModelContainer
    }

    /// Holder for the two serialized export artifacts. `Data` is Sendable, so this can cross
    /// the actor boundary back to whatever queue `prepareExport` runs on. Either field is nil
    /// when there is nothing to write (no location, no incident links, or no component).
    fileprivate struct StitchExportArtifacts: Sendable {
        var stitching: Data?
        var graph: Data?
    }

    /// Reference box used to shuttle the `@MainActor`-built artifacts back to the waiting
    /// background queue across the semaphore boundary. `@unchecked Sendable` is sound here because
    /// the `DispatchSemaphore` establishes happens-before ordering: the background queue only reads
    /// `value` after `wait()` returns, which is after the Task's single write + `signal()`, so the
    /// write and read never overlap.
    private final class ArtifactsBox: @unchecked Sendable {
        var value = StitchExportArtifacts()
    }

    /// Pre-serialized stitch artifacts for a batch of locations, built ONCE (a single graph build)
    /// so a bulk export doesn't rebuild the connected-component graph per scan. Sendable (UUID +
    /// Data), so it can be captured into the background export queue and handed to each
    /// `prepareExport` call. Build via `makeBulkStitchArtifacts` on the main actor before the batch.
    struct BulkStitchArtifacts: Sendable {
        fileprivate let byLocationId: [UUID: StitchExportArtifacts]
    }

    private static func makeStitchEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// Assembles both serialized artifacts for one location from an ALREADY-BUILT graph — pure
    /// serialization, no fetch and no graph build, so it's cheap to call once per location in a
    /// batch. `graph` is nil only when the graph couldn't be built (then graph.json is skipped but
    /// the per-location stitching.json is still produced).
    @MainActor
    private static func makeArtifacts(for location: ScanLocation,
                                      graph: StitchGraph?,
                                      encoder: JSONEncoder) -> StitchExportArtifacts {
        var artifacts = StitchExportArtifacts()

        // A1: per-location stitching.json generated from the DB (every incident link, both
        // directions). Skip entirely when the location has no links.
        let manifest = StitchLinkStore.manifest(forLocation: location)
        if !manifest.links.isEmpty {
            artifacts.stitching = try? encoder.encode(manifest)
        }

        // A2: graph.json — the connected component this location belongs to.
        if let graph, let aggregate = buildGraphAggregate(for: location, graph: graph) {
            artifacts.graph = try? encoder.encode(aggregate)
        }

        return artifacts
    }

    /// SINGLE-scan export path: resolve the location, build the graph, assemble artifacts. Runs on
    /// the main actor (SwiftData models, `StitchLinkStore` and `StitchGraphBuilder.build` are all
    /// @MainActor); the returned `Data` is handed back to the (off-main) caller for file writing.
    @MainActor
    private static func makeStitchExportArtifacts(forLocationId locationId: UUID) async -> StitchExportArtifacts {
        guard let container = exportModelContainer() else { return StitchExportArtifacts() }
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<ScanLocation>(predicate: #Predicate { $0.id == locationId })
        guard let location = try? context.fetch(descriptor).first else { return StitchExportArtifacts() }
        let allLocations = (try? context.fetch(FetchDescriptor<ScanLocation>())) ?? []
        let graph = await StitchGraphBuilder.build(from: allLocations)
        return makeArtifacts(for: location, graph: graph, encoder: makeStitchEncoder())
    }

    /// BULK export path: build the connected-component graph ONCE, then assemble artifacts for
    /// every requested location off that single graph. Call once on the main actor before a bulk
    /// export and pass the result into each `prepareExport(…, bulkStitch:)` — replacing the
    /// per-scan graph rebuild (and per-scan main-thread hop). Locations with no links still get an
    /// entry (both fields nil) so the per-scan path knows there's nothing to write rather than
    /// falling back to a rebuild.
    @MainActor
    static func makeBulkStitchArtifacts(forLocationIds locationIds: Set<UUID>) async -> BulkStitchArtifacts {
        guard !locationIds.isEmpty, let container = exportModelContainer() else {
            return BulkStitchArtifacts(byLocationId: [:])
        }
        let context = ModelContext(container)
        let allLocations = (try? context.fetch(FetchDescriptor<ScanLocation>())) ?? []
        let graph = await StitchGraphBuilder.build(from: allLocations)
        let encoder = makeStitchEncoder()
        var byId: [UUID: StitchExportArtifacts] = [:]
        for location in allLocations where locationIds.contains(location.id) {
            byId[location.id] = makeArtifacts(for: location, graph: graph, encoder: encoder)
        }
        return BulkStitchArtifacts(byLocationId: byId)
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

    /// Finds the connected component containing `location` in the given (already-built) graph and
    /// assembles the `graph.json` aggregate (nodes + de-duped link DTOs). Returns nil if the
    /// location is in no component (i.e. participates in no links).
    @MainActor
    private static func buildGraphAggregate(for location: ScanLocation,
                                            graph: StitchGraph) -> GraphAggregate? {
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

    // MARK: - Export-Time Privacy Blur

    /// Runs every export-time privacy pass over a staged payload directory, upholding the
    /// PRIVACY.md guarantee — "no unblurred image or unmasked depth map is ever exported" —
    /// for EVERY export format that stages images:
    ///
    /// 1. Mask-based pass (`applyPrivacyBlurAtExport`): pixelates main images and zeros depth
    ///    using the ARKit stencils saved during capture.
    /// 2. Vision fallback on main frames that have NO saved mask (the stencil hadn't warmed up
    ///    yet — typically the first frames of a session). Capture used to run this fallback
    ///    inline; deferring blur to export moved it here.
    /// 3. Vision pass on proxy (glasses) images — a second camera the ARKit stencil never
    ///    covers, so every proxy frame needs the Vision path.
    ///
    /// Gate: privacy filter was enabled during capture, signalled by saved masks or by the
    /// `privacy_filter` flag in scan4d_metadata.json. Legacy scans (readable metadata that
    /// PREDATES the flag) skip all passes — they were already blurred at capture, or privacy
    /// was off by choice. Only genuinely indeterminate scans (metadata missing/corrupt, or a
    /// present-but-garbage flag) fail CLOSED into the Vision pass, which re-encodes frames
    /// visually unchanged when no person is detected.
    /// Frame names that have a capture-time segmentation mask (drives the mask-based pass,
    /// and doubles as the strongest "privacy was ON" signal — masks only exist when it was).
    private static func maskedFrameNames(rawDataDir: URL) -> Set<String> {
        let masksDir = rawDataDir.appendingPathComponent("masks")
        return ((try? FileManager.default.contentsOfDirectory(at: masksDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }
            .reduce(into: Set()) { $0.insert($1.deletingPathExtension().lastPathComponent) }
    }

    /// Resolves whether the privacy filter was ON for this capture — the ONE source of truth
    /// shared by the phone/proxy passes and the 360° still pass, so every export path reasons
    /// from the same state. Masks present ⇒ ON. Otherwise the metadata `privacy_filter` flag
    /// decides (a garbage value fails CLOSED to ON); readable metadata that PREDATES the flag
    /// ⇒ legacy scan, OFF (already blurred at capture or off by choice); unreadable metadata
    /// ⇒ ON (fail closed — the blur passes are no-ops on people-free frames).
    private static func privacyFilterWasOn(rawDataDir: URL, maskedFrames: Set<String>) -> Bool {
        if !maskedFrames.isEmpty { return true }
        guard let metaData = try? Data(contentsOf: rawDataDir.appendingPathComponent("scan4d_metadata.json")),
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] else {
            return true
        }
        guard let flag = meta["privacy_filter"] else { return false }
        return (flag as? Bool) ?? true
    }

    private static func applyExportPrivacyPasses(rawDataDir: URL, stagedDir: URL,
                                                 phase: ((ExportPhase) -> Void)? = nil) {
        let maskedFrames = maskedFrameNames(rawDataDir: rawDataDir)
        let privacyWasOn = privacyFilterWasOn(rawDataDir: rawDataDir, maskedFrames: maskedFrames)
        guard privacyWasOn else { return }

        if !maskedFrames.isEmpty {
            applyPrivacyBlurAtExport(
                masksDir: rawDataDir.appendingPathComponent("masks"),
                imagesDir: stagedDir.appendingPathComponent("images"),
                depthDir: stagedDir.appendingPathComponent("depth"),
                phase: phase
            )
        }
        applyVisionBlurAtExport(
            imagesDir: stagedDir.appendingPathComponent("images"),
            skippingFrames: maskedFrames,
            phase: phase
        )
        applyVisionBlurAtExport(imagesDir: stagedDir.appendingPathComponent("proxy_images"), phase: phase)
    }

    /// Vision-based person pixelation for staged JPEGs that have no capture-time segmentation
    /// mask. Slower than the mask-based pass (a Vision segmentation request per image), but it
    /// only runs on frames the stencil missed — plus proxy frames, which never have stencils.
    /// `pixelatePersonsAndGetFaceCenters` returns the original data on any failure, so a frame
    /// is never dropped from the export; frames with no detected person re-encode visually
    /// unchanged.
    private static func applyVisionBlurAtExport(imagesDir: URL, skippingFrames: Set<String> = [],
                                                phase: ((ExportPhase) -> Void)? = nil) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "jpg" && !skippingFrames.contains($0.deletingPathExtension().lastPathComponent) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }),
            !files.isEmpty else { return }

        print("[prepareExport] Vision privacy blur on \(files.count) unmasked images in \(imagesDir.lastPathComponent)/...")
        var written = 0
        for (index, url) in files.enumerated() {
            phase?(.counted("Privacy check", index + 1, of: files.count))
            // Per-frame pool for the same reason as applyPrivacyBlurAtExport: each Vision pass
            // decodes + re-renders a full-resolution frame through autoreleased CF transients.
            autoreleasepool {
                guard let data = try? Data(contentsOf: url) else { return }
                let (blurred, _) = PrivacyBlurUtil.pixelatePersonsAndGetFaceCenters(in: data)
                if let blurred {
                    try? blurred.write(to: url, options: .atomic)
                    written += 1
                }
            }
        }
        print("[prepareExport] ✓ vision-blurred \(written)/\(files.count) images in \(imagesDir.lastPathComponent)/")
    }

    // MARK: - 360° Still Staging (hard privacy invariant)

    /// Stages `raw_data/equirect_stills/` (equirect JPG + pose sidecar JSON pairs — any 360°
    /// camera source) into the export
    /// and enforces the still-source-360 HARD privacy invariant on every equirect: cube-face
    /// Vision person verification, pixelation where persons are found
    /// (`EquirectPrivacyBlur`, docs/design/still-source-360.md → Privacy).
    ///
    /// Toggle-governed like every other capture source (`privacyFilterWasOn` — one privacy
    /// state rules the whole scan): with the filter ON, every still is verified/blurred and
    /// the pass is fail-CLOSED per still — a still whose verification fails is EXCLUDED from
    /// the export (JPG and sidecar both), never shipped raw. With the filter OFF the stills
    /// stage unblurred by the user's informed, per-scan consent (the capture UI warns that a
    /// 360° camera captures ALL directions — including people behind the operator — and the
    /// scan's `privacy_filter` metadata records the choice for downstream consumers).
    private static func stageEquirectStills(rawDataDir: URL, stagingDir: URL,
                                            phase: ((ExportPhase) -> Void)? = nil) {
        let fileMgr = FileManager.default
        let srcDir = rawDataDir.appendingPathComponent("equirect_stills")
        guard fileMgr.fileExists(atPath: srcDir.path) else { return }
        let dstDir = stagingDir.appendingPathComponent("equirect_stills")
        do {
            try fileMgr.copyItem(at: srcDir, to: dstDir)
        } catch {
            print("[prepareExport] ✗ failed to stage equirect_stills: \(error.localizedDescription)")
            return
        }

        let stills = ((try? fileMgr.contentsOfDirectory(at: dstDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !stills.isEmpty else { return }
        if privacyFilterWasOn(rawDataDir: rawDataDir, maskedFrames: maskedFrameNames(rawDataDir: rawDataDir)) {
            runEquirectPrivacyPass(on: stills, phase: phase)
        } else {
            print("[prepareExport] 360° stills staged UNBLURRED (\(stills.count)) — privacy filter was OFF "
                + "for this scan (informed per-scan consent; recorded as privacy_filter in scan4d_metadata)")
        }

        // Cube-face emission AFTER the privacy pass — faces sample the staged (blurred or
        // consented) pixels, so they inherit the scan's privacy state by construction.
        emitCubeFaces(stagingDir: stagingDir, dstDir: dstDir, phase: phase)
    }

    /// Runs the fail-closed per-still verification/blur over the staged equirects (filter-ON path).
    private static func runEquirectPrivacyPass(on stills: [URL], phase: ((ExportPhase) -> Void)? = nil) {
        print("[prepareExport] 360° privacy pass on \(stills.count) equirect still(s)...")

        var cleanCount = 0, blurredCount = 0, excludedCount = 0
        for (index, url) in stills.enumerated() {
            phase?(.counted("360° privacy", index + 1, of: stills.count))
            // Per-still pool: each pass decodes a working copy + renders a full-res composite
            // through autoreleased CF/CI transients (same OOM lesson as the frame blur loops).
            autoreleasepool {
                let outcome: EquirectPrivacyBlur.Outcome
                if let data = try? Data(contentsOf: url) {
                    outcome = EquirectPrivacyBlur.process(equirectJPEG: data)
                } else {
                    outcome = .failed("could not read staged still")
                }
                switch outcome {
                case .clean:
                    cleanCount += 1
                case .blurred(let blurredData):
                    do {
                        try blurredData.write(to: url, options: .atomic)
                        blurredCount += 1
                    } catch {
                        excludeStill(url)   // couldn't persist the blurred version → never ship raw
                        excludedCount += 1
                    }
                case .failed(let reason):
                    print("[prepareExport] ✗ 360° still \(url.lastPathComponent) failed verification (\(reason)) — excluding from export")
                    excludeStill(url)
                    excludedCount += 1
                }
            }
        }
        print("[prepareExport] ✓ 360° privacy pass: \(cleanCount) clean, \(blurredCount) blurred, \(excludedCount) excluded")
    }

    /// Reprojects every surviving staged equirect into 5 pinhole cube faces (bottom face —
    /// operator/rod — dropped by construction) written as ordinary keyframe images into
    /// `images/` with Polycam camera JSONs in `cameras/`, poses from the mechanical-prior
    /// rig extrinsic (EquirectFaceExport). Non-fatal per still: a face-emission failure
    /// just leaves the archived equirect as the only carrier for that still.
    private static func emitCubeFaces(stagingDir: URL, dstDir: URL,
                                      phase: ((ExportPhase) -> Void)? = nil) {
        let fileMgr = FileManager.default
        let imagesDir = stagingDir.appendingPathComponent("images")
        let camerasDir = stagingDir.appendingPathComponent("cameras")
        guard fileMgr.fileExists(atPath: imagesDir.path), fileMgr.fileExists(atPath: camerasDir.path) else {
            print("[prepareExport] ✗ cube faces skipped — images/ or cameras/ not staged")
            return
        }
        let survivors = ((try? fileMgr.contentsOfDirectory(at: dstDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !survivors.isEmpty else { return }
        var facesWritten = 0
        for (index, url) in survivors.enumerated() {
            phase?(.counted("Cube faces", index + 1, of: survivors.count))
            autoreleasepool {
                let sidecar = url.deletingPathExtension().appendingPathExtension("json")
                facesWritten += EquirectFaceExport.emitFaces(
                    equirectURL: url, sidecarURL: sidecar,
                    imagesDir: imagesDir, camerasDir: camerasDir)
            }
        }
        print("[prepareExport] ✓ cube faces: \(facesWritten) emitted from \(survivors.count) still(s) (rig prior: rod \(AppConstants.rigRodHeightMeters)m, yaw \(AppConstants.rigYawOffsetDegrees)°)")
    }

    /// Fail-closed removal of one staged 360° still: the equirect AND its pose sidecar (an
    /// orphan sidecar would advertise a still the bundle doesn't contain).
    private static func excludeStill(_ jpgURL: URL) {
        let fileMgr = FileManager.default
        try? fileMgr.removeItem(at: jpgURL)
        try? fileMgr.removeItem(at: jpgURL.deletingPathExtension().appendingPathExtension("json"))
    }

    /// Applies person pixelation to staged images and zeros person regions in staged depth maps
    /// using saved segmentation masks. Called during export when a `masks/` directory exists,
    /// indicating privacy filter was enabled during capture.
    ///
    /// During capture, raw (unblurred) images and raw (unmasked) depth maps are saved for
    /// performance — the expensive privacy blur is deferred to this export-time pass where
    /// performance is not critical. The masks are saved alongside frames during capture as
    /// lightweight grayscale PNGs (~5-15KB each at 256×192).
    ///
    /// Privacy guarantee: no unblurred image or unmasked depth ever leaves the device.
    /// The masks/ directory itself is NOT included in the export archive.
    private static func applyPrivacyBlurAtExport(masksDir: URL, imagesDir: URL, depthDir: URL,
                                                 phase: ((ExportPhase) -> Void)? = nil) {
        let fm = FileManager.default
        guard let maskFiles = try? fm.contentsOfDirectory(at: masksDir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "png" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else { return }

        guard !maskFiles.isEmpty else { return }
        print("[prepareExport] Applying privacy blur to \(maskFiles.count) frames...")

        let ciContext = CIContext()
        var blurredCount = 0
        var maskedDepthCount = 0

        for (index, maskURL) in maskFiles.enumerated() {
            phase?(.counted("Privacy blur", index + 1, of: maskFiles.count))
            // Per-frame autoreleasepool: each iteration decodes a 4032×3024 JPEG plus a 16-bit
            // depth PNG through UIImage/CoreImage/ImageIO, whose CF transients are autoreleased —
            // without draining per frame they accumulate across the whole 70+ frame pass
            // (hundreds of MB peak; two concurrent passes OOM-killed the app — 2026-07-23
            // iPhone 17 Pro field report).
            autoreleasepool {
                let frameName = maskURL.deletingPathExtension().lastPathComponent // e.g. "frame_00042"

                // Load the mask once; it drives both the image blur and the depth zeroing.
                guard let maskData = try? Data(contentsOf: maskURL),
                      let maskUIImage = UIImage(data: maskData),
                      let maskCGImage = maskUIImage.cgImage else { return }

                if blurStagedImage(named: frameName, maskCGImage: maskCGImage,
                                   imagesDir: imagesDir, ciContext: ciContext) {
                    blurredCount += 1
                }
                if maskStagedDepth(named: frameName, maskCGImage: maskCGImage, depthDir: depthDir) {
                    maskedDepthCount += 1
                }
            }
        }

        print("[prepareExport] ✓ privacy-blurred \(blurredCount) images + \(maskedDepthCount) depth maps")
    }

    /// Pixelates person regions of one staged image in place. Returns true when a blurred
    /// JPEG was written. (Split from the per-frame loop so each frame's decode/render lives
    /// inside its own autoreleasepool — see applyPrivacyBlurAtExport.)
    private static func blurStagedImage(named frameName: String, maskCGImage: CGImage,
                                        imagesDir: URL, ciContext: CIContext) -> Bool {
        let fm = FileManager.default
        let maskCI = CIImage(cgImage: maskCGImage)

        // ── Blur the corresponding image ──
        let imageURL = imagesDir.appendingPathComponent("\(frameName).jpg")
        guard fm.fileExists(atPath: imageURL.path),
              let imageData = try? Data(contentsOf: imageURL),
              let imageUIImage = UIImage(data: imageData),
              let imageCGImage = imageUIImage.cgImage else { return false }
        let imageCI = CIImage(cgImage: imageCGImage)
        let imageSize = imageCI.extent

        // Scale mask up to image resolution
        let scaleX = imageSize.width / maskCI.extent.width
        let scaleY = imageSize.height / maskCI.extent.height
        var scaledMask = maskCI.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Dilate slightly to ensure full coverage (same as the old capture-time blur)
        let dilate = CIFilter.morphologyMaximum()
        dilate.inputImage = scaledMask
        dilate.radius = 12
        if let dilated = dilate.outputImage {
            scaledMask = dilated.cropped(to: imageSize)
        }

        // Pixelate person regions
        let pixelate = CIFilter.pixellate()
        pixelate.inputImage = imageCI
        pixelate.scale = 40.0

        guard let pixelatedCI = pixelate.outputImage else { return false }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = pixelatedCI
        blend.backgroundImage = imageCI
        blend.maskImage = scaledMask

        guard let outputCI = blend.outputImage,
              let outputCG = ciContext.createCGImage(outputCI, from: imageSize),
              let jpegData = UIImage(cgImage: outputCG)
                  .jpegData(compressionQuality: AppConstants.jpegCompressionQuality) else { return false }
        try? jpegData.write(to: imageURL, options: .atomic)
        return true
    }

    /// Zeros person regions of one staged 16-bit depth map in place. Returns true when the
    /// masked PNG was written. (Split from the per-frame loop for the same autoreleasepool
    /// reason as `blurStagedImage`.)
    private static func maskStagedDepth(named frameName: String, maskCGImage: CGImage,
                                        depthDir: URL) -> Bool {
        let fm = FileManager.default
        let depthURL = depthDir.appendingPathComponent("\(frameName).png")
        guard fm.fileExists(atPath: depthURL.path),
              let depthData = try? Data(contentsOf: depthURL),
              let depthUIImage = UIImage(data: depthData),
              let depthCGImage = depthUIImage.cgImage else { return false }

        let depthWidth = depthCGImage.width
        let depthHeight = depthCGImage.height
        let maskWidth = maskCGImage.width
        let maskHeight = maskCGImage.height

        // Read the 16-bit depth data. Anything but 16-bit single-channel means the
        // decode didn't round-trip the capture format — skip rather than corrupt.
        guard depthCGImage.bitsPerComponent == 16, depthCGImage.bitsPerPixel == 16,
              let depthProvider = depthCGImage.dataProvider,
              let depthCFData = depthProvider.data else { return false }
        let depthLength = CFDataGetLength(depthCFData)
        let expectedLength = depthWidth * depthHeight * 2
        guard depthLength >= expectedLength else { return false }

        // Read the mask data
        guard let maskProvider = maskCGImage.dataProvider,
              let maskCFData = maskProvider.data else { return false }
        let maskPtr = CFDataGetBytePtr(maskCFData)!
        let maskBytesPerRow = maskCGImage.bytesPerRow

        // Copy depth to mutable buffer and zero person regions
        var depthBytes = [UInt8](repeating: 0, count: expectedLength)
        CFDataGetBytes(depthCFData, CFRangeMake(0, expectedLength), &depthBytes)

        depthBytes.withUnsafeMutableBytes { rawBuf in
            let uint16Buf = rawBuf.bindMemory(to: UInt16.self)
            for y in 0..<depthHeight {
                for x in 0..<depthWidth {
                    let mx = x * maskWidth / max(depthWidth, 1)
                    let my = y * maskHeight / max(depthHeight, 1)
                    if mx < maskWidth, my < maskHeight {
                        let pixel = maskPtr[my * maskBytesPerRow + mx]
                        if pixel > 128 {
                            uint16Buf[y * depthWidth + x] = 0
                        }
                    }
                }
            }
        }

        let byteOrder = depthCGImage.bitmapInfo.intersection(.byteOrderMask)
        guard let maskedPNG = encodeDepthPNG16(bytes: depthBytes, width: depthWidth,
                                               height: depthHeight, byteOrder: byteOrder) else { return false }
        try? maskedPNG.write(to: depthURL, options: .atomic)
        return true
    }

    /// Re-encode zeroed 16-bit depth bytes as a grayscale PNG. The bitmapInfo must carry the
    /// DECODED image's byte order (ImageIO returns little-endian): zeroed pixels are
    /// endian-neutral, so labeling the untouched bytes with their true order makes the rewrite
    /// value-preserving. Labeling them big-endian (rawValue: 0) instead byte-swaps every
    /// surviving pixel — which un-did the swap depthMapToPNG16 has always baked into these
    /// files and turned exported depth near-black.
    private static func encodeDepthPNG16(bytes: [UInt8], width: Int, height: Int,
                                         byteOrder: CGBitmapInfo) -> Data? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 16,
                  bitsPerPixel: 16,
                  bytesPerRow: width * 2,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: byteOrder,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cgImage).pngData()
    }

    /// `bulkStitch`, when supplied, is a pre-built snapshot of every location's stitch artifacts
    /// for the whole export batch (see `makeBulkStitchArtifacts`); this scan's location is looked
    /// up in it instead of rebuilding the graph + hopping to the main actor per scan. nil for
    /// single-scan exports, which build on demand below.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    /// `phase`, when supplied, receives human-readable progress lines ("Copying frames…",
    /// "Privacy blur 12/41…", "Cube faces 1/2…", "Zipping…") from the export queue —
    /// callers hop to main and surface them (UploadStatus.zipping(phase:)). The pipeline
    /// has grown real phases (privacy blur, 360° verification, cube faces); a bare
    /// "Converting..." hides where the time goes.
    static func prepareExport(filename: String, scanDir: URL, format: ExportFormat,
                              bulkStitch: BulkStitchArtifacts? = nil,
                              phase: ((ExportPhase) -> Void)? = nil) -> URL? {
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
        // NOTE: masks/ is intentionally excluded — it's internal-only, used below for
        // export-time privacy blur but never shipped in the archive.
        func stagePolycamPayload(to dir: URL) {
            phase?(ExportPhase("Copying frames…"))
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

            // ── Export-time privacy blur ──
            // Runs off the critical capture path, so performance is not a concern
            // (export is already async). No-op unless privacy was on during capture.
            applyExportPrivacyPasses(rawDataDir: rawDataDir, stagedDir: dir, phase: phase)
        }

        // Zip a staging directory and return the zip URL
        func zipStaging(_ stagingDir: URL) -> URL? {
            phase?(ExportPhase("Zipping…"))
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
                    let captured: StitchExportArtifacts
                    if let bulkStitch {
                        // Batch path: artifacts were built once for the whole export (one graph
                        // build). No per-scan rebuild and no main-thread hop here. A missing entry
                        // means that location had nothing to write.
                        captured = bulkStitch.byLocationId[locationId] ?? StitchExportArtifacts()
                    } else {
                        // Single-scan path: prepareExport is synchronous on a background queue, so
                        // block on the async @MainActor build with a semaphore. Data is Sendable.
                        // Hard requirement: must NOT run on the main thread — the @MainActor build
                        // could never make progress while main is parked in semaphore.wait(), so a
                        // future main-thread caller would deadlock. Fail loudly instead.
                        dispatchPrecondition(condition: .notOnQueue(.main))
                        let semaphore = DispatchSemaphore(value: 0)
                        let box = ArtifactsBox()
                        Task { @MainActor in
                            box.value = await makeStitchExportArtifacts(forLocationId: locationId)
                            semaphore.signal()
                        }
                        semaphore.wait()
                        captured = box.value
                    }

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

                // Include roomplan.json + roomplan_raw.json if RoomPlan data was captured, and the
                // registration.json sidecar (save-time canonical registration: the raw→canonical
                // transform + fit stats a downstream consumer needs to relate mesh/roomplan — which
                // are canonical-frame — to the world map, which stays in the raw capture frame)
                for rpFile in ["roomplan.json", "roomplan_raw.json", "registration.json"] {
                    let rpURL = scanDir.appendingPathComponent(rpFile)
                    if fm.fileExists(atPath: rpURL.path) {
                        do {
                            try fm.copyItem(at: rpURL, to: stagingDir.appendingPathComponent(rpFile))
                            print("[prepareExport] ✓ included \(rpFile)")
                        } catch {
                            print("[prepareExport] ✗ failed to copy \(rpFile): \(error.localizedDescription)")
                        }
                    }
                }

                // 360° stills (any equirect camera): staged through the toggle-governed privacy
                // pass — stageEquirectStills enforces the invariant internally (filter ON ⇒
                // blur or exclude; OFF ⇒ informed per-scan consent).
                stageEquirectStills(rawDataDir: rawDataDir, stagingDir: stagingDir, phase: phase)

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
                applyExportPrivacyPasses(rawDataDir: rawDataDir, stagedDir: stagingDir, phase: phase)
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
