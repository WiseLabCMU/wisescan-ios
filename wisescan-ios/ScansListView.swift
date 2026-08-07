import SwiftUI
import SwiftData

enum LibraryViewMode {
    case grid
    case graph
}

/// Controls whether bulk actions target only the latest scan per selected location
/// or every scan within each selected location.
enum BulkScope: String, CaseIterable {
    case latest = "Latest"
    case allScans = "All Scans"
}

struct ScansListView: View {
    @Environment(ScanStore.self) private var scanStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScanLocation.updatedAt, order: .reverse) private var locations: [ScanLocation]

    @State private var showSettings = false
    @State private var selectedLocations: Set<PersistentIdentifier> = []
    @State private var showBulkDeleteConfirm = false
    /// Number of DISTINCT OTHER maps the about-to-be-deleted locations are linked to (computed
    /// when the user taps delete). > 0 means the cascade will silently remove those spatial links.
    @State private var bulkDeleteLinkedMapCount = 0
    @State private var isEditing = false
    @State private var viewMode: LibraryViewMode = .grid
    @State private var renderRequest: ComponentRenderRequest?
    /// The scan set the mixed-color prompt is deciding about (selection, graph cluster,
    /// or combined-render screen — whichever surface asked).
    @State private var pendingColorScans: [CapturedScan] = []
    @State private var graphVisibleLocationIds: Set<PersistentIdentifier> = []
    @State private var bulkScope: BulkScope = .latest
    @State private var isBulkColoring = false
    /// Shown when a bulk-color selection mixes already-colored and uncolored scans.
    @State private var showBulkColorMixedPrompt = false
    /// DECISION 3 hard gate: upload requires the selected scans post-processed.
    @State private var showPostprocessGate = false
    /// Shown when a bulk-upload selection mixes already-uploaded and un-uploaded scans.
    @State private var showBulkUploadMixedPrompt = false
    @State private var bulkProgressMessage: String?
    /// Per-location status during a bulk Post-process, keyed by location id — drives the small
    /// progress overlay on the grid/graph tiles so a long batch shows WHICH map it's working on
    /// (the banner alone is ambiguous when scans share names). Mirrors LocationDetailView's
    /// per-card `bulkColoringMessages` pattern at location granularity.
    @State private var bulkProcessingByLocation: [UUID: String] = [:]
    @State private var isBulkExporting = false
    @State private var exportItems: [ZipExportItem] = []
    @State private var showExportSheet = false
    @State private var isBulkUploading = false
    @State private var bulkUploadCompleted = 0
    @State private var bulkUploadTotal = 0
    @AppStorage(AppConstants.Key.uploadURL) private var uploadURL = AppConstants.uploadURL
    @AppStorage(AppConstants.Key.selectedExportFormat)
    private var globalSelectedFormatStr: String = AppConstants.selectedExportFormat
    @Binding var selectedTab: Int

    let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 16)
    ]

    var body: some View {
        @Bindable var store = scanStore
        NavigationStack(path: $store.navigationPath) {
            ZStack {
                Color.black.ignoresSafeArea()
                LinearGradient(colors: [Color(white: 0.1), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                if locations.isEmpty {
                    ScrollView {
                        VStack(spacing: 16) {
                            Image(systemName: "folder")
                                .font(.system(size: 48))
                                .foregroundColor(.gray)
                            Text("No scans yet")
                                .font(.headline)
                                .foregroundColor(.gray)
                            Text("Capture a scan to see it here")
                                .font(.caption)
                                .foregroundColor(.gray.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    }
                } else if viewMode == .graph {
                    StitchGraphView(locations: locations, renderRequest: $renderRequest, isEditing: $isEditing, selectedLocations: $selectedLocations, visibleLocationIds: $graphVisibleLocationIds, processingByLocation: bulkProcessingByLocation,
                                    onColorScans: { requestBulkColorize(scans: $0) })
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(locations) { location in
                                ZStack(alignment: .topTrailing) {
                                    NavigationLink(value: location) {
                                        LocationGridTile(location: location,
                                                         processingMessage: bulkProcessingByLocation[location.id])
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(isEditing)
                                    .opacity(isEditing ? 0.6 : 1.0)

                                    if isEditing {
                                        let selected = selectedLocations.contains(location.id)
                                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                            .font(.title2)
                                            .foregroundColor(selected ? .cyan : .gray)
                                            .background(Circle().fill(Color.white).padding(4))
                                            .offset(x: 8, y: -8)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard isEditing else { return }
                                    if selectedLocations.contains(location.id) {
                                        selectedLocations.remove(location.id)
                                    } else {
                                        selectedLocations.insert(location.id)
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }

                if isEditing {
                    VStack {
                        Spacer()
                        bulkActionToolbar
                    }
                }
            }
            .navigationTitle("SCANS")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ScanLocation.self) { loc in
                LocationDetailView(location: loc, selectedTab: $selectedTab)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isEditing {
                        Button(action: {
                            let visibleIds = selectableLocationIds
                            if visibleIds.isSubset(of: selectedLocations) {
                                selectedLocations.removeAll()
                            } else {
                                selectedLocations = visibleIds
                            }
                        }) {
                            let visibleIds = selectableLocationIds
                            Text(visibleIds.isSubset(of: selectedLocations) ? "Deselect All" : "Select All")
                                .font(.subheadline)
                        }
                    } else if !locations.isEmpty {
                        Button(action: {
                            withAnimation { viewMode = (viewMode == .grid) ? .graph : .grid }
                        }) {
                            Image(systemName: viewMode == .grid ? "point.3.connected.trianglepath.dotted" : "square.grid.2x2")
                                .foregroundColor(.cyan)
                        }
                        .accessibilityLabel(viewMode == .grid ? "Switch to graph view" : "Switch to grid view")
                    }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if !locations.isEmpty {
                        Button(action: {
                            isEditing.toggle()
                            if !isEditing { selectedLocations.removeAll() }
                        }) {
                            Text(isEditing ? "Done" : "Edit")
                                .bold(isEditing)
                                .foregroundColor(isEditing ? .red : .cyan)
                        }
                    }
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                    .disabled(isEditing)
                }
            }
            .onChange(of: selectedTab) {
                if selectedTab != 2 {
                    isEditing = false
                    selectedLocations.removeAll()
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showExportSheet, onDismiss: {
                // Safety net: if dismissed via swipe-down before the completion handler fires,
                // reset so the Save button isn't stuck disabled.
                isBulkExporting = false
            }) {
                ShareSheet(activityItems: exportItems.map { $0.url }) { _, _, _, _ in
                    isBulkExporting = false
                    exitEditModeWithBanner("✓ Saved \(exportItems.count) scan\(exportItems.count == 1 ? "" : "s")")
                }
            }
            .fullScreenCover(item: $renderRequest) { req in
                // Color from the render view: resolve item ids back to scans and run the
                // shared bulk path. The cover dismisses so the tile progress is visible.
                CombinedMeshScreen(request: req, onColor: { ids in
                    let idSet = Set(ids)
                    let scans = locations.flatMap(\.scans).filter { idSet.contains($0.id) }
                    requestBulkColorize(scans: scans)
                })
            }
            .confirmationDialog(
                "Delete \(bulkScope == .allScans ? "Locations" : "Scans")",
                isPresented: $showBulkDeleteConfirm
            ) {
                Button(bulkDeleteButtonLabel, role: .destructive) {
                    deleteSelectedLocations()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                if bulkDeleteLinkedMapCount > 0 {
                    Text("\(bulkDeleteLinkedMapCount == 1 ? "This map is" : "These maps are") connected to " +
                         "\(bulkDeleteLinkedMapCount) other map\(bulkDeleteLinkedMapCount == 1 ? "" : "s"). " +
                         "Deleting will remove those connections.\n\n" + bulkDeleteMessage)
                } else {
                    Text(bulkDeleteMessage)
                }
            }
            .confirmationDialog(
                "Color Scans",
                isPresented: $showBulkColorMixedPrompt,
                titleVisibility: .visible
            ) {
                let split = pendingColorSplit
                Button("Color \(split.uncolored.count) Uncolored Only") {
                    bulkPostprocess(scans: split.uncolored, colorize: true)
                }
                Button("Recolor All \(split.uncolored.count + split.colored.count)") {
                    bulkPostprocess(scans: split.uncolored + split.colored, colorize: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                let split = pendingColorSplit
                Text("\(split.colored.count) of these scans are already colored. " +
                     "Color only the uncolored scans, or recolor everything?")
            }
            .confirmationDialog(
                "Upload Scans",
                isPresented: $showBulkUploadMixedPrompt,
                titleVisibility: .visible
            ) {
                let split = targetUploadSplit
                Button("Upload \(split.notUploaded.count) Un-uploaded Only") {
                    bulkUpload(scans: split.notUploaded)
                }
                Button("Re-upload All \(split.notUploaded.count + split.uploaded.count)") {
                    bulkUpload(scans: split.notUploaded + split.uploaded)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                let split = targetUploadSplit
                Text("\(split.uploaded.count) of the selected scans have already been uploaded. " +
                     "Upload only the un-uploaded scans, or re-upload everything?")
            }
            .alert("Post-process Required", isPresented: $showPostprocessGate) {
                Button("Post-process Now") {
                    bulkPostprocess(scans: resolveTargetScans())
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You haven't post-processed these scans — do it now. Uploading and " +
                     "exporting need the processed room data (room model, registration, and " +
                     "rescan reference).")
            }
            .preferredColorScheme(.dark)
            .overlay {
                if scanStore.isProcessingScan {
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                        Text(scanStore.processingMessage ?? "Processing Scan...")
                            .foregroundColor(.white)
                            .font(.headline)
                    }
                    .padding(24)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(16)
                    .shadow(radius: 10)
                }
            }
        }
    }

    // MARK: - Bulk Action Toolbar

    @ViewBuilder
    private var bulkActionToolbar: some View {
        VStack(spacing: 0) {
            // Scope toggle: "Latest" | "All Scans"
            Picker("Scope", selection: $bulkScope) {
                ForEach(BulkScope.allCases, id: \.self) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Progress banner (visible only during bulk operations)
            if let msg = bulkProgressMessage {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                    Text(msg)
                        .font(.caption)
                        .foregroundColor(.white)
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
                .transition(.opacity)
            }

            // Action buttons: [Trash] [Upload] [Save] [Process] [Color]
            HStack(spacing: 20) {
                // Delete
                Button(action: {
                    bulkDeleteLinkedMapCount = linkedOtherMapCount(for: selectedLocations)
                    showBulkDeleteConfirm = true
                }) {
                    Image(systemName: "trash")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(selectedLocations.isEmpty ? Color.gray.opacity(0.3) : Color.red.opacity(0.8))
                        .foregroundColor(selectedLocations.isEmpty ? .gray : .white)
                        .cornerRadius(10)
                }
                .disabled(selectedLocations.isEmpty)

                // Upload
                Button(action: { requestBulkUpload() }) {
                    Text("Upload")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(uploadDisabled ? Color.gray.opacity(0.3) : Color.blue)
                        .foregroundColor(uploadDisabled ? .gray : .white)
                        .cornerRadius(10)
                }
                .disabled(uploadDisabled)

                // Save
                Button(action: { bulkSaveToFiles() }) {
                    Text("Save")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(selectedLocations.isEmpty || isBulkExporting ?
                                    Color.gray.opacity(0.3) : Color.cyan.opacity(0.8))
                        .foregroundColor(selectedLocations.isEmpty || isBulkExporting ? .gray : .white)
                        .cornerRadius(10)
                }
                .disabled(selectedLocations.isEmpty || isBulkExporting)

                // Post-process: structural steps only (room build + registration + proxy).
                Button(action: { requestBulkPostprocess() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                        Text("Process")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(bulkRunDisabled ? Color.gray.opacity(0.3) : Color.purple.opacity(0.8))
                    .foregroundColor(bulkRunDisabled ? .gray : .white)
                    .cornerRadius(10)
                }
                .disabled(bulkRunDisabled)

                // Color — orange paintbrush everywhere the verb appears (same as the card).
                Button(action: { requestBulkColorize(scans: resolveTargetScans()) }, label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paintbrush.fill")
                        Text("Color")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(bulkRunDisabled ? Color.gray.opacity(0.3) : Color.orange.opacity(0.8))
                    .foregroundColor(bulkRunDisabled ? .gray : .white)
                    .cornerRadius(10)
                })
                .disabled(bulkRunDisabled)
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
        .background(.ultraThinMaterial)
    }

    private var uploadDisabled: Bool {
        selectedLocations.isEmpty || uploadURL.isEmpty
    }

    private var bulkRunDisabled: Bool {
        // Enabled whenever there are target scans — already-colored scans can be recolored.
        resolveTargetScans().isEmpty || isBulkColoring
    }

    /// Returns the set of location PersistentIdentifiers that are visible in the current view mode.
    /// Grid mode shows all locations; graph mode shows only locations that participate in stitch links.
    private var selectableLocationIds: Set<PersistentIdentifier> {
        switch viewMode {
        case .grid:
            return Set(locations.map { $0.id })
        case .graph:
            return graphVisibleLocationIds
        }
    }

    // MARK: - Confirmation Dialog Helpers

    private var bulkDeleteButtonLabel: String {
        let count = selectedLocations.count
        switch bulkScope {
        case .allScans:
            return "Delete \(count) Location\(count == 1 ? "" : "s")"
        case .latest:
            return "Delete Latest Scan from \(count) Location\(count == 1 ? "" : "s")"
        }
    }

    private var bulkDeleteMessage: String {
        switch bulkScope {
        case .allScans:
            return "This will permanently delete the selected locations and every scan inside them."
        case .latest:
            return "This will permanently delete only the latest scan from each selected location. Locations with older scans will be preserved."
        }
    }

    // MARK: - Scan Resolution

    /// Resolves the target scans based on the current scope and selection.
    /// "Latest" returns only the newest scan per location; "All Scans" returns every scan.
    private func resolveTargetScans() -> [CapturedScan] {
        let selectedLocs = locations.filter { selectedLocations.contains($0.id) }
        switch bulkScope {
        case .latest:
            return selectedLocs.compactMap { loc in
                loc.scans.max(by: { $0.capturedAt < $1.capturedAt })
            }
        case .allScans:
            return selectedLocs.flatMap { $0.scans }
        }
    }

    // MARK: - Bulk Operations

    /// Scope-aware delete: "All Scans" deletes entire locations; "Latest" deletes only
    /// the newest scan per location (preserving the location if older scans remain).
    private func deleteSelectedLocations() {
        let selectedLocs = locations.filter { selectedLocations.contains($0.id) }

        switch bulkScope {
        case .allScans:
            // Delete entire locations + all scans (original behavior)
            let dirs = selectedLocs.flatMap { $0.scans.map(\.scanDirectory) }
            // Also remove each location's own directory (Documents/Scans/{locationId}) — it still
            // holds a legacy stitching.json and would be orphaned once the per-scan subdirs go.
            // Use the canonical helper rather than deriving the parent from a scan path, so cleanup
            // doesn't depend on the {locationId}/{scanId} layout and still covers scanless locations.
            let locationDirs = selectedLocs.compactMap { StitchingMetadataManager.locationDirectory(for: $0.id) }
            for loc in selectedLocs {
                for scan in loc.scans { modelContext.delete(scan) }
                modelContext.delete(loc)
            }
            try? modelContext.save()
            selectedLocations.removeAll()
            isEditing = false
            DispatchQueue.global(qos: .utility).async {
                for dir in dirs { try? FileManager.default.removeItem(at: dir) }
                for dir in locationDirs { try? FileManager.default.removeItem(at: dir) }
            }

        case .latest:
            // Delete only the latest scan per location; auto-delete location if empty
            var dirsToRemove: [URL] = []
            // Preserve stitches for rooms that keep an older generation (re-point off the latest);
            // a room whose latest IS its only scan has no survivor here → cascade bisects below.
            let latestScans = selectedLocs.compactMap { $0.scans.max(by: { $0.capturedAt < $1.capturedAt }) }
            StitchLinkStore.repointIncidentLinks(beforeDeleting: latestScans, in: modelContext)
            for loc in selectedLocs {
                guard let latest = loc.scans.max(by: { $0.capturedAt < $1.capturedAt }) else { continue }
                dirsToRemove.append(latest.scanDirectory)
                modelContext.delete(latest)
                if loc.scans.count <= 1 {
                    // This was the last scan — remove the location too, and its now-orphaned
                    // location directory (legacy stitching.json + empty dir). Resolve via the
                    // canonical helper (same as the .allScans path) so cleanup doesn't depend on
                    // scan-path arithmetic.
                    if let locDir = StitchingMetadataManager.locationDirectory(for: loc.id) {
                        dirsToRemove.append(locDir)
                    }
                    modelContext.delete(loc)
                }
            }
            try? modelContext.save()
            selectedLocations.removeAll()
            isEditing = false
            DispatchQueue.global(qos: .utility).async {
                for dir in dirsToRemove { try? FileManager.default.removeItem(at: dir) }
            }
        }
    }

    /// Count of DISTINCT OTHER locations (those NOT being deleted) that the given locations are
    /// linked to via incident stitch links. Used to warn that deleting them will cascade-remove the
    /// connections to those maps.
    private func linkedOtherMapCount(for locationIds: Set<PersistentIdentifier>) -> Int {
        let toDelete = locations.filter { locationIds.contains($0.id) }
        let deletedLocationIds = Set(toDelete.map { $0.id })
        var otherLocationIds = Set<ScanLocation.ID>()
        for loc in toDelete {
            for scan in loc.scans {
                for link in StitchLinkStore.incidentLinks(for: scan) {
                    guard let otherLoc = link.localAnchor(for: scan)?.otherScan?.location else { continue }
                    if !deletedLocationIds.contains(otherLoc.id) { otherLocationIds.insert(otherLoc.id) }
                }
            }
        }
        return otherLocationIds.count
    }

    /// Export selected scans to the share sheet. Runs export packaging on a background queue.
    /// Progress banner shows per-scan preparation status.
    private func bulkSaveToFiles() {
        guard !isBulkExporting else { return }   // re-entrancy: double-tap = concurrent exports (OOM class)
        let scans = resolveTargetScans()
        guard !scans.isEmpty else { return }
        // DECISION 3 hard gate: never export a scan with pending structural post-process work
        // (mirrors requestBulkUpload — the export zip is the same bundle upload sends).
        if scans.contains(where: { ScanPostprocessor.needsPostprocess($0) }) {
            showPostprocessGate = true
            return
        }
        isBulkExporting = true
        selectedLocations.removeAll()
        let format = ExportFormat(rawValue: globalSelectedFormatStr) ?? .scan4d
        let totalScans = scans.count

        bulkProgressMessage = "Preparing 1/\(totalScans)…"

        // Capture scan directories + the set of locations on main (SwiftData model access).
        let scanInfos = scans.map { (dir: $0.scanDirectory, filename: $0.makeExportFilename(format: format)) }
        let locationIds = Set(scans.compactMap { $0.location?.id })

        Task { @MainActor in
            // Build the stitch graph ONCE for the whole batch (was rebuilt per scan).
            let bulkStitch = await ScanExportManager.makeBulkStitchArtifacts(forLocationIds: locationIds)
            DispatchQueue.global(qos: .userInitiated).async {
                var urls: [ZipExportItem] = []
                for (idx, info) in scanInfos.enumerated() {
                    DispatchQueue.main.async {
                        self.bulkProgressMessage = "Preparing \(idx + 1)/\(totalScans)…"
                    }
                    if let url = ScanExportManager.prepareExport(
                        filename: info.filename, scanDir: info.dir, format: format, bulkStitch: bulkStitch
                    ) {
                        urls.append(ZipExportItem(url: url))
                    }
                }

                DispatchQueue.main.async {
                    self.bulkProgressMessage = nil
                    self.exportItems = urls
                    self.showExportSheet = !urls.isEmpty
                    if urls.isEmpty {
                        self.isBulkExporting = false
                        self.exitEditModeWithBanner("Export failed")
                    }
                    // isBulkExporting is cleared + edit mode exits in the share sheet completion handler
                }
            }
        }
    }

    /// Upload selected scans to the configured server. Each scan is exported and uploaded
    /// independently on a background queue. Banner tracks per-scan completion and upload progress.
    private func bulkUpload(scans: [CapturedScan]) {
        guard !isBulkUploading else { return }   // re-entrancy: double-tap = concurrent export+upload batches
        guard !scans.isEmpty, !uploadURL.isEmpty else { return }
        let format = ExportFormat(rawValue: globalSelectedFormatStr) ?? .scan4d
        let baseURLString = uploadURL.hasSuffix("/") ? uploadURL : uploadURL + "/"

        isBulkUploading = true
        bulkUploadCompleted = 0
        bulkUploadTotal = scans.count
        selectedLocations.removeAll()
        bulkProgressMessage = "Uploading 0/\(scans.count)…"

        let locationIds = Set(scans.compactMap { $0.location?.id })
        Task { @MainActor in
            // Build the stitch graph ONCE for the whole batch (was rebuilt per scan).
            let bulkStitch = await ScanExportManager.makeBulkStitchArtifacts(forLocationIds: locationIds)
            for scan in scans {
                let filename = scan.makeExportFilename(format: format)
                guard let url = URL(string: baseURLString + filename) else {
                    bulkUploadCompleted += 1
                    checkBulkUploadCompletion()
                    continue
                }
                scan.uploadStatus = .zipping
                let scanDir = scan.scanDirectory

                DispatchQueue.global(qos: .userInitiated).async {
                    guard let exportURL = ScanExportManager.prepareExport(
                        // No phase callback: this screen shows LOCATION tiles, not scan cards —
                        // there's no per-scan pill here to report into (LocationDetailView's
                        // bulk flows drive `bulkExportPhases`).
                        filename: filename, scanDir: scanDir, format: format, bulkStitch: bulkStitch
                    ) else {
                        DispatchQueue.main.async {
                            scan.uploadStatus = .failed("Export failed")
                            self.bulkUploadCompleted += 1
                            self.checkBulkUploadCompletion()
                        }
                        return
                    }

                    DispatchQueue.main.async { scan.uploadStatus = .uploading(progress: 0.0) }

                    var request = URLRequest(url: url)
                    request.httpMethod = "PUT"
                    request.setValue(format.contentType, forHTTPHeaderField: "Content-Type")

                    let task = URLSession.shared.uploadTask(with: request, fromFile: exportURL) { _, response, error in
                        try? FileManager.default.removeItem(at: exportURL)
                        DispatchQueue.main.async {
                            if let error = error {
                                scan.uploadStatus = .failed(error.localizedDescription)
                            } else if let httpResponse = response as? HTTPURLResponse,
                                      (200...299).contains(httpResponse.statusCode) {
                                scan.uploadStatus = .success
                                scan.lastUploadedAt = Date()
                            } else {
                                scan.uploadStatus = .failed("Server error")
                            }
                            self.bulkUploadCompleted += 1
                            self.checkBulkUploadCompletion()
                        }
                    }
                    task.resume()
                }
            }
        }
    }

    /// Called after each upload completes; when all are done, shows a completion banner and exits edit mode.
    private func checkBulkUploadCompletion() {
        let done = bulkUploadCompleted
        let total = bulkUploadTotal
        bulkProgressMessage = "Uploading \(done)/\(total)…"
        guard done >= total else { return }
        isBulkUploading = false
        exitEditModeWithBanner("✓ Uploaded \(total) scan\(total == 1 ? "" : "s")")
    }

    /// The scan set a Color request is acting on (selection, cluster, or render view),
    /// split into not-yet-colored and already-colored.
    private var pendingColorSplit: (uncolored: [CapturedScan], colored: [CapturedScan]) {
        (pendingColorScans.filter { !$0.isColored }, pendingColorScans.filter { $0.isColored })
    }

    /// Target scans split into already-uploaded and not-yet-uploaded.
    private var targetUploadSplit: (notUploaded: [CapturedScan], uploaded: [CapturedScan]) {
        let selected = resolveTargetScans()
        return (selected.filter { !$0.isUploaded }, selected.filter { $0.isUploaded })
    }

    /// Entry point for the bulk Upload button. Uploads directly when the selection is
    /// uniform (all uploaded or all un-uploaded); when it's mixed, prompts the user.
    private func requestBulkUpload() {
        let split = targetUploadSplit
        let selected = split.notUploaded + split.uploaded
        guard !selected.isEmpty else { return }
        // DECISION 3 hard gate: never upload a scan with pending structural post-process work
        // (its roomplan/registration/proxy artifacts would be missing from the export).
        if selected.contains(where: { ScanPostprocessor.needsPostprocess($0) }) {
            showPostprocessGate = true
            return
        }
        if split.notUploaded.isEmpty || split.uploaded.isEmpty {
            bulkUpload(scans: selected)
        } else {
            showBulkUploadMixedPrompt = true
        }
    }

    // MARK: - Post-process (DECISION 3)

    /// Entry point for the bulk Process button: run every achievable pending STRUCTURAL step
    /// (room / registration / proxy) over the scope-resolved scans ("Latest" = newest per
    /// selected location, "All Scans" = everything). Never colors — Color is its own button.
    private func requestBulkPostprocess() {
        let selected = resolveTargetScans()
        guard !selected.isEmpty else { return }
        let anyPending = selected.contains {
            !ScanPostprocessor.pendingSteps(for: $0, includeColorize: false).isEmpty
        }
        guard anyPending else {
            // Never degrade into coloring: one tap silently re-colouring a whole
            // selection is minutes of GPU work nobody asked for. Process means
            // structural, always — Color is its own button.
            bulkProgressMessage = "Nothing to process"
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if bulkProgressMessage == "Nothing to process" { bulkProgressMessage = nil }
            }
            return
        }
        bulkPostprocess(scans: selected)
    }

    /// Run the postprocessor over `scans` (oldest-first internally; prerequisite originals are
    /// pulled in automatically for registration). Reuses the bulk banner + coloring flag.
    private func bulkPostprocess(scans: [CapturedScan], colorize: Bool = false) {
        guard !isBulkColoring else { return }    // re-entrancy: the engine's claims make a 2nd batch a no-op, but don't churn the UI
        guard !scans.isEmpty else { return }
        isBulkColoring = true
        let total = scans.count
        var done = 0
        ScanPostprocessor.run(
            scans: scans,
            colorize: colorize,
            modelContext: modelContext,
            progress: { scan, msg in
                // Tile overlay: show the step on the scan's location while it works; clear when
                // that scan finishes (a same-location prerequisite original re-claims it on its
                // own next progress tick).
                if let locId = scan.location?.id {
                    if let msg {
                        bulkProcessingByLocation[locId] = msg
                    } else {
                        bulkProcessingByLocation.removeValue(forKey: locId)
                    }
                }
                if let msg {
                    bulkProgressMessage = "\(scan.name): \(msg)"
                } else {
                    done += 1
                    bulkProgressMessage = "\(colorize ? "Colored" : "Processed") \(done)/\(total)…"
                }
            },
            completion: {
                isBulkColoring = false
                bulkProcessingByLocation.removeAll()
                exitEditModeWithBanner("✓ \(colorize ? "Colored" : "Processed") \(total) scan\(total == 1 ? "" : "s")")
            }
        )
    }

    /// Entry point for every bulk Color surface — the toolbar button (selection), a
    /// graph cluster's Color capsule, and the combined-render screen. Colors directly
    /// when the set is uniform (all colored or all uncolored); when it's mixed, prompts
    /// to color only the uncolored scans or recolor everything.
    private func requestBulkColorize(scans: [CapturedScan]) {
        guard !scans.isEmpty else { return }
        pendingColorScans = scans
        let split = pendingColorSplit
        if split.uncolored.isEmpty || split.colored.isEmpty {
            bulkPostprocess(scans: scans, colorize: true)   // uniform — no need to ask
        } else {
            showBulkColorMixedPrompt = true
        }
    }


    // MARK: - Edit Mode Exit with Banner

    /// Shows a completion message in the progress banner for 2 seconds, then exits edit mode.
    /// This gives the user a clear signal that the operation completed, especially for fast ops.
    private func exitEditModeWithBanner(_ message: String) {
        bulkProgressMessage = message
        selectedLocations.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                self.bulkProgressMessage = nil
                self.isEditing = false
            }
        }
    }
}

// MARK: - Capture Integrity (shared rule)

/// Whether a scan's raw capture is grossly missing depth/confidence relative to its frame count.
/// Shared by the per-scan card badge (`ScanCard.dataIntegrityWarning`) and the location-tile
/// rollup so both apply the identical threshold. LiDAR-only: non-LiDAR ("lite mode") devices never
/// capture depth/confidence, so their absence is expected there, not a defect.
enum CaptureIntegrity {
    /// Modalities that fell below the floor (e.g. "depth (1/40)"), or `[]` if the capture is OK,
    /// too small to judge, or non-LiDAR. Counts come from the scan's raw_data subdirectories.
    static func deficiencies(images: Int, cameras: Int, depth: Int, confidence: Int) -> [String] {
        guard ARCoverageView.supportsLiDAR else { return [] }
        let frames = max(images, cameras)
        guard frames >= AppConstants.captureIntegrityMinFrames else { return [] } // too small to judge
        let floorCount = Int(Double(frames) * AppConstants.captureIntegrityMinFraction)
        var deficient: [String] = []
        if depth < floorCount { deficient.append("depth (\(depth)/\(frames))") }
        if confidence < floorCount { deficient.append("confidence (\(confidence)/\(frames))") }
        return deficient
    }
}

// MARK: - Location Grid Tile

struct LocationGridTile: View {
    let location: ScanLocation
    /// Non-nil while a bulk Post-process is working this location — shows the step overlay.
    var processingMessage: String?
    @State private var thumbnailImage: UIImage?
    // Resolved off the main thread in `.task` so the body performs no FileManager I/O.
    @State private var hasMissingWorldMap = false
    @State private var hasIncompleteCaptureScan = false

    var latestScan: CapturedScan? {
        // Single O(n) pass with no intermediate sorted-array allocation; this is read
        // multiple times per body evaluation.
        location.scans.max(by: { $0.capturedAt < $1.capturedAt })
    }

    /// Any scan's world map flagged suspect at save (tracking excursion baked into the
    /// feature cloud) — rolls into the yellow relocalization-concern badge.
    private var hasSuspectWorldMap: Bool {
        location.scans.contains { $0.worldMapSuspect }
    }

    /// Small corner indicator for the top-leading overlay (matches the per-scan card style).
    private func tileWarningBadge(_ color: Color) -> some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundColor(color)
            .padding(6)
            .background(Color.black.opacity(0.5))
            .clipShape(Circle())
    }

    var body: some View {
        VStack(spacing: 0) {
            // Thumbnail Area
            ZStack {
                Color.gray.opacity(0.2)

                if let uiImage = thumbnailImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 120)
                        .clipped()
                } else {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            .frame(height: 120)

            // Info Area
            VStack(alignment: .leading, spacing: 4) {
                Text(location.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack {
                    Text("\(location.scans.count) scan\(location.scans.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    if let latest = latestScan {
                        Text(latest.timeSinceCapture)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.05))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topLeading) {
            // Stacked rollup indicators (mirrors the per-scan card): yellow = a relocalization
            // concern on at least one scan (world map file missing, or the map was flagged
            // suspect — a tracking excursion baked in at capture); orange = at least one scan's
            // depth/confidence capture is grossly incomplete. File checks resolved off-main in
            // `.task`; the suspect flag is a plain model read.
            VStack(alignment: .leading, spacing: 6) {
                if hasMissingWorldMap || hasSuspectWorldMap { tileWarningBadge(.yellow) }
                if hasIncompleteCaptureScan { tileWarningBadge(.orange) }
            }
            .padding(8)
        }
        .overlay(alignment: .topTrailing) {
            // Three-state upload rollup (see the graph tile's identical badge in
            // StitchGraphView for the rationale): no icon = nothing uploaded; DIMMED
            // cloud-check = partial (1+ but not all); solid green = every scan uploaded.
            let uploadedCount = location.scans.filter(\.isUploaded).count
            if uploadedCount > 0 {
                Image(systemName: "checkmark.icloud.fill")
                    .font(.caption)
                    .foregroundColor(uploadedCount == location.scans.count
                                     ? .green : .green.opacity(0.4))
                    .padding(6)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
                    .padding(8)
            }
        }
        .overlay(alignment: .bottom) {
            // Bulk Post-process: which step is running on THIS map (long batch, look-alike tiles).
            if let processingMessage {
                HStack(spacing: 6) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.6)
                    Text(processingMessage)
                        .font(.caption2)
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .padding(.bottom, 8)
            }
        }
        .task(id: location.updatedAt) {
            // Resolve thumbnail + missing-worldmap + incomplete-capture state off the main thread
            // to avoid main-thread FileManager I/O during layout/scroll (#5/#7).
            guard let latest = latestScan else {
                thumbnailImage = nil
                hasMissingWorldMap = false
                hasIncompleteCaptureScan = false
                return
            }
            let previewURL = latest.modelPreviewURL
            let fallbackURL = latest.thumbnailURL
            let worldMapPaths = location.scans.map { $0.worldMapURL.path }
            let rawDirs = location.scans.map { $0.rawDataPath }

            // Missing-worldmap flag off-main.
            hasMissingWorldMap = await Task.detached(priority: .utility) {
                let fm = FileManager.default
                return worldMapPaths.contains(where: { !fm.fileExists(atPath: $0) })
            }.value

            // Incomplete-capture rollup off-main: true if ANY scan is grossly missing depth/
            // confidence vs its frame count (same CaptureIntegrity rule as the per-scan badge).
            hasIncompleteCaptureScan = await Task.detached(priority: .utility) {
                let fm = FileManager.default
                func count(_ dir: URL, _ sub: String) -> Int {
                    (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(sub).path))?.count ?? 0
                }
                return rawDirs.contains { dir in
                    !CaptureIntegrity.deficiencies(
                        images: count(dir, "images"), cameras: count(dir, "cameras"),
                        depth: count(dir, "depth"), confidence: count(dir, "confidence")
                    ).isEmpty
                }
            }.value

            // Downsampled, cached thumbnail (prefer the colored model preview).
            if let img = await ThumbnailCache.image(for: previewURL) {
                thumbnailImage = img
            } else {
                thumbnailImage = await ThumbnailCache.image(for: fallbackURL)
            }
        }
    }
}

// MARK: - Export Item Helper

struct ZipExportItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - Scan Card

struct ScanCard: View {
    @Bindable var scan: CapturedScan
    var isLatest: Bool
    var uploadURL: String
    var isEditing: Bool
    var onUpdate: (CapturedScan) -> Void
    var onDelete: (CapturedScan) -> Void

    @AppStorage(AppConstants.Key.selectedExportFormat) private var selectedFormatStr: String = AppConstants.selectedExportFormat
    @Environment(\.modelContext) private var modelContext
    @State private var exportItem: ZipExportItem?
    @State private var showExportError = false
    @State private var showDeleteConfirm = false
    @State private var itemCounts: (images: Int, proxy: Int, depth: Int, confidence: Int, cameras: Int, equirect: Int)?
    @State private var showDataIntegrityAlert = false
    @State private var showMeshPreview = false
    @State private var showMissingRelocAlert = false
    @State private var showSuspectMapAlert = false
    // Disk-derived values resolved off the main thread in `.task` (see below) so the
    // view body never performs synchronous FileManager I/O during layout/scroll.
    @State private var previewImage: UIImage?
    @State private var isRelocMissing = false
    @State private var sizeMB: Double = 0
    // Single-card coloring progress (SwiftUI @State — reliably observed, unlike a SwiftData
    // @Transient model prop). Bulk coloring drives `bulkColoringMessage` from the parent instead.
    @State private var coloringMessage: String?
    /// Single-card export progress, for the same reason coloringMessage is @State.
    @State private var exportPhase: ExportPhase?
    /// DECISION 3 hard gate: upload requires this scan post-processed.
    @State private var showPostprocessAlert = false

    private var selectedFormat: ExportFormat {
        get { ExportFormat(rawValue: selectedFormatStr) ?? .polycam }
        nonmutating set { selectedFormatStr = newValue.rawValue }
    }

    /// Effective coloring progress: single-card @State, or the parent's bulk message.
    private var activeColoringMessage: String? { coloringMessage ?? bulkColoringMessage }

    /// Live export-pipeline phase (privacy blur / 360° / cube faces / zip). Same ownership
    /// rule as coloring: single-card work drives the local @State, a bulk run drives the
    /// parent's dictionary — the model can't carry it (see UploadStatus.zipping).
    private var activeExportPhase: ExportPhase? { exportPhase ?? bulkExportPhase }

    var isSelected: Bool = false
    var onSelect: (() -> Void)?
    /// Coloring progress message driven by the parent during a BULK colorize (nil otherwise).
    /// Single-card colorize uses the local `coloringMessage` @State.
    var bulkColoringMessage: String?
    /// Export phase driven by the parent during a BULK save/upload (nil otherwise).
    /// Single-card save/upload uses the local `exportPhase` @State.
    var bulkExportPhase: ExportPhase?

    init(scan: CapturedScan, isLatest: Bool, uploadURL: String, isEditing: Bool, isSelected: Bool = false, bulkColoringMessage: String? = nil, bulkExportPhase: ExportPhase? = nil, onUpdate: @escaping (CapturedScan) -> Void, onDelete: @escaping (CapturedScan) -> Void, onSelect: (() -> Void)? = nil) {
        self.scan = scan
        self.isLatest = isLatest
        self.uploadURL = uploadURL
        self.isEditing = isEditing
        self.isSelected = isSelected
        self.bulkColoringMessage = bulkColoringMessage
        self.bulkExportPhase = bulkExportPhase
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: 0) {
            if isEditing {
                Button(action: {
                    onSelect?()
                }) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundColor(isSelected ? .cyan : .gray)
                        .padding(.leading, 12)
                        .padding(.trailing, 8)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .top, spacing: 0) {
                previewImageSection
                infoSection
            }
            .background(.ultraThinMaterial)
            .cornerRadius(16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
            .onTapGesture {
                if isEditing {
                    onSelect?()
                }
            }
        }
        .padding(.horizontal)
        .sheet(item: $exportItem, onDismiss: {
            // Safety net: if dismissed via swipe-down before completion handler fires, reset.
            if case .zipping = scan.uploadStatus {
                scan.uploadStatus = .pending
                onUpdate(scan)
            }
        }) { item in
            ShareSheet(activityItems: [item.url]) { _, completed, _, activityError in
                // Only process if we aren't currently streaming an upload
                if case .uploading = scan.uploadStatus { return }

                if let error = activityError {
                    scan.uploadStatus = .failed(error.localizedDescription)
                } else if completed {
                    scan.uploadStatus = .savedLocally
                } else {
                    // User canceled the share sheet
                    scan.uploadStatus = .pending
                }
                onUpdate(scan)
            }
        }
        .fullScreenCover(isPresented: $showMeshPreview) {
            NavigationView {
                // No .ignoresSafeArea() here — the container bleeds its 3D view/markers under
                // the safe area internally, while keeping the title/legend inside it (so the
                // title sits below the nav bar, not under the Dynamic Island).
                MeshPreviewContainer(location: scan.location, meshFileURL: scan.meshFileURL, colorsFileURL: scan.colorsFileURL, scanDirectoryURL: scan.scanDirectory, scanName: scan.name, isColored: scan.isColored)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") {
                                showMeshPreview = false
                            }
                        }
                    }
            }
        }
        .alert("Missing Data", isPresented: $showMissingRelocAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This scan is missing relocalization data (arworldmap.map). It cannot be reliably extended or aligned in the future.")
        }
        .alert("Incomplete Capture", isPresented: $showDataIntegrityAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(dataIntegrityWarning ?? "")
        }
        .alert("No Data Available", isPresented: $showExportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The scan data may have been deleted.")
        }
        .task(id: scan.id) {
            // Resolve all disk-derived values off the main thread in a single detached
            // pass, so the view body performs no synchronous FileManager I/O during
            // layout/scroll (previously: previewURL existence, reloc-warning existence,
            // and estimatedSizeMB's two attributesOfItem calls all ran inside body).
            let rawDir = scan.rawDataPath
            let meshPath = scan.meshFileURL.path
            let colorsPath = scan.colorsFileURL.path
            let worldMapPath = scan.worldMapURL.path
            let fallbackBytes = scan.vertexCount * 12 + scan.faceCount * 12
            let fm = FileManager.default

            let resolved = await Task.detached(priority: .utility) {
                () -> (counts: (Int, Int, Int, Int, Int, Int), relocMissing: Bool, sizeMB: Double) in
                let iCount = (try? fm.contentsOfDirectory(atPath: rawDir.appendingPathComponent("images").path))?.count ?? 0
                let pCount = (try? fm.contentsOfDirectory(atPath: rawDir.appendingPathComponent("proxy_images").path))?.count ?? 0
                let dCount = (try? fm.contentsOfDirectory(atPath: rawDir.appendingPathComponent("depth").path))?.count ?? 0
                let confCount = (try? fm.contentsOfDirectory(atPath: rawDir.appendingPathComponent("confidence").path))?.count ?? 0
                let cCount = (try? fm.contentsOfDirectory(atPath: rawDir.appendingPathComponent("cameras").path))?.count ?? 0
                let eCount = (try? fm.contentsOfDirectory(atPath: rawDir.appendingPathComponent("equirect_stills").path))?.filter { $0.lowercased().hasSuffix(".jpg") }.count ?? 0

                let relocMissing = !fm.fileExists(atPath: worldMapPath)

                var bytes: Int64 = 0
                if let attr = try? fm.attributesOfItem(atPath: meshPath) { bytes += attr[.size] as? Int64 ?? 0 }
                if let attr = try? fm.attributesOfItem(atPath: colorsPath) { bytes += attr[.size] as? Int64 ?? 0 }
                let sizeMB = (bytes > 0 ? Double(bytes) : Double(fallbackBytes)) / (1024.0 * 1024.0)

                return ((iCount, pCount, dCount, confCount, cCount, eCount), relocMissing, sizeMB)
            }.value

            itemCounts = resolved.counts
            isRelocMissing = resolved.relocMissing
            sizeMB = resolved.sizeMB
        }
        // Load the preview as a downsampled, cached thumbnail. Keyed on the location's
        // updatedAt so it refreshes after (re)coloring rewrites model_preview.jpg.
        .task(id: scan.location?.updatedAt) {
            let previewURL = scan.modelPreviewURL
            let thumbURL = scan.thumbnailURL
            if let img = await ThumbnailCache.image(for: previewURL) {
                previewImage = img
            } else {
                previewImage = await ThumbnailCache.image(for: thumbURL)
            }
        }
    }

    @ViewBuilder
    private var previewImageSection: some View {
        Button(action: { showMeshPreview = true }) {
            Group {
                if let image = previewImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.black.opacity(0.3)
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            .frame(minWidth: 120, maxWidth: .infinity, maxHeight: 180)
            .clipped()
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .overlay(editingOverlay)
        .overlay(alignment: .topLeading) { warningsOverlay }
        .overlay {
            if let msg = activeColoringMessage {
                ZStack {
                    Color.black.opacity(0.5)
                    VStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.2)
                        Text(msg)
                            .font(.caption2)
                            .foregroundColor(.white)
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete Scan",
            isPresented: $showDeleteConfirm
        ) {
            Button("Delete \"\(scan.name)\"", role: .destructive) {
                onDelete(scan)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete this scan and its data.")
        }
    }

    @ViewBuilder
    private var editingOverlay: some View {
        if isEditing {
            Color.black.opacity(0.2)
        }
    }

    @ViewBuilder
    private var warningsOverlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isRelocMissing {
                warningBadge(color: .yellow) { showMissingRelocAlert = true }
            }
            // Suspect map (tracking excursion baked in at save). Mutually exclusive with
            // isRelocMissing in practice — the flag only exists when a map file was saved.
            // The alert attaches to the badge itself so the card body's modifier chain (already
            // near the type-checker budget) doesn't grow.
            if scan.worldMapSuspect {
                warningBadge(color: .yellow) { showSuspectMapAlert = true }
                    .alert("Map May Be Unreliable", isPresented: $showSuspectMapAlert) {
                        Button("OK", role: .cancel) { }
                    } message: {
                        Text("Tracking was disrupted while this scan was recorded (for example by " +
                             "an interruption), so its relocalization map may be unreliable. " +
                             "Rescan and Connect Adjacent will warn before using it, and a rescan " +
                             "seeded from it usually inherits the problem. To clear it, delete this " +
                             "scan so the most recent clean scan becomes the reference. The scan's " +
                             "own captured data is still usable — Processing auto-aligns it.")
                    }
            }
            if dataIntegrityWarning != nil {
                warningBadge(color: .orange) { showDataIntegrityAlert = true }
            }
        }
        .padding(8)
    }

    private func warningBadge(color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(color)
                .padding(8)
                .background(Color.black.opacity(0.5))
                .clipShape(Circle())
        }
    }

    @ViewBuilder
    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            scanInfoBlock
            actionButtonsBlock
        }
        .padding(12)
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 260, alignment: .leading)
    }

    @ViewBuilder
    private var scanInfoBlock: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(scan.name)
                    .font(.subheadline).bold()
                    .foregroundColor(.white)
                HStack(spacing: 8) {
                    Text(String(format: "%.1f MB", sizeMB))
                    Text("\(formattedCount(scan.faceCount)) polys")
                }
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
                Text(scan.timeSinceCapture)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                Text(scan.hardwareDeviceModel)
                    .font(.caption2)
                    .foregroundColor(.cyan)

                if let uploadDate = scan.formattedUploadDate {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.icloud")
                        Text("Uploaded \(uploadDate)")
                    }
                    .font(.caption2)
                    .foregroundColor(.green.opacity(0.8))
                }

                if let counts = itemCounts {
                    itemCountsText(counts)
                }
            }
            Spacer()
            statusBadge
        }
    }

    @ViewBuilder
    private func itemCountsText(_ counts: (images: Int, proxy: Int, depth: Int, confidence: Int, cameras: Int, equirect: Int)) -> some View {
        let parts = buildItemCountParts(counts)
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption2)
                .foregroundColor(.white.opacity(0.65))
        }
    }

    private func buildItemCountParts(_ counts: (images: Int, proxy: Int, depth: Int, confidence: Int, cameras: Int, equirect: Int)) -> [String] {
        var parts: [String] = []
        if counts.images > 0 { parts.append("\(counts.images) images") }
        if counts.proxy > 0 { parts.append("\(counts.proxy) proxy") }
        if counts.depth > 0 { parts.append("\(counts.depth) depth") }
        if counts.confidence > 0 { parts.append("\(counts.confidence) confidence") }
        if counts.cameras > 0 { parts.append("\(counts.cameras) cameras") }
        if counts.equirect > 0 { parts.append("\(counts.equirect) equirects") }
        return parts
    }

    /// Flags a gross capture-modality disparity. Every captured frame writes an image + camera, but
    /// depth/confidence can silently fall out mid-scan (e.g. RoomPlan reconfiguring the session). A
    /// handful missing is tolerable; when depth or confidence is present in far fewer than the frame
    /// count, the capture is likely unusable for downstream reconstruction. Returns a user-facing
    /// message, or nil when the capture looks complete enough to judge.
    private var dataIntegrityWarning: String? {
        guard let c = itemCounts else { return nil }
        // Shared rule with the location-tile rollup (see CaptureIntegrity). Returns [] on
        // non-LiDAR / too-few-frames, so we never warn where depth absence is expected.
        let deficient = CaptureIntegrity.deficiencies(images: c.images, cameras: c.cameras, depth: c.depth, confidence: c.confidence)
        guard !deficient.isEmpty else { return nil }
        let frames = max(c.images, c.cameras)
        return "This scan recorded \(frames) frames but only \(deficient.joined(separator: " and ")). "
            + "The capture is grossly incomplete and is likely unusable for 3D reconstruction downstream — consider re-scanning."
    }

    @ViewBuilder
    private var actionButtonsBlock: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button(action: { saveToFiles() }) {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("Save")
                            .font(.subheadline).bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(isEditing ? Color.gray.opacity(0.3) : Color.cyan.opacity(0.8))
                    .foregroundColor(isEditing ? .gray : .white)
                    .cornerRadius(10)
                }
                .disabled(isEditing)

                Button(action: { uploadScan() }) {
                    HStack {
                        Image(systemName: "icloud.and.arrow.up")
                        Text("Upload")
                            .font(.subheadline).bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(uploadButtonDisabled ? Color.gray.opacity(0.3) : Color.blue)
                    .foregroundColor(isEditing ? .gray : .white)
                    .cornerRadius(10)
                }
                .disabled(uploadButtonDisabled)
            }

            // COLOR is the user's verb (field redesign 2026-08-06): post-processing is
            // AUTOMATED (save + landing), so the primary button just makes the scan
            // colored — silently finishing any structural stragglers first (the
            // deferred RoomBuilder often lands roomplan.json after auto-process ran,
            // leaving registration/proxy pending; that used to cost a mystery first
            // click). Manual re-runs live in the long-press menu for recovery cases.
            do {
                let processDisabled = isEditing || activeColoringMessage != nil
                Menu {
                    Button(action: { reRunProcessing() }, label: {
                        Label("Re-run Processing", systemImage: "wand.and.stars")
                    })
                    if (itemCounts?.equirect ?? 0) > 0 {
                        Button(action: { redoCalibration() }, label: {
                            Label("Redo 360° Calibration", systemImage: "arrow.triangle.2.circlepath")
                        })
                    }
                } label: {
                    processButtonLabel(disabled: processDisabled)
                } primaryAction: {
                    colorScan()
                }
                .disabled(processDisabled)
            }
        }
        .alert("Post-process Required", isPresented: $showPostprocessAlert) {
            Button("Post-process Now") { reRunProcessing() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You haven't post-processed this scan — do it now. Uploading and exporting " +
                 "need the processed room data (room model, registration, and rescan reference).")
        }
    }

    private func processButtonLabel(disabled: Bool) -> some View {
        HStack {
            Image(systemName: "paintbrush.fill")
            Text("Color")
                .font(.subheadline).bold()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(disabled ? Color.gray.opacity(0.3) : Color.orange.opacity(0.8))
        .foregroundColor(disabled ? .gray : .white)
        .cornerRadius(10)
    }

    /// The designed manual "Redo Processing" path: strip the calibration provenance
    /// stamps, then run the normal engine — which now sees the calibration step pending
    /// and re-solves against current Settings (rig height) + persisted geometry. The
    /// claim guards the strip against a concurrent batch rewriting the same sidecars.
    private func redoCalibration() {
        guard ScanPostprocessor.claimInFlight(scan.id) else { return }   // a batch owns it right now
        coloringMessage = "Resetting 360° calibration…"
        let raw = scan.rawDataPath
        DispatchQueue.global(qos: .utility).async {
            let cleared = ScanPostprocessor.resetEquirectCalibration(rawDataPath: raw)
            DispatchQueue.main.async {
                ScanPostprocessor.releaseInFlight(scan.id)
                coloringMessage = nil
                if cleared > 0 || !ScanPostprocessor.pendingSteps(for: scan, includeColorize: false).isEmpty {
                    reRunProcessing()
                }
            }
        }
    }

    /// The COLOR button: one tap makes the scan colored, whatever that takes — any
    /// pending structural steps run first (registration/proxy that became achievable
    /// after auto-process, calibration re-opened by a solver bump), then the (re)color.
    /// ONE path: the engine does both, exactly as the bulk Color buttons do.
    private func colorScan() {
        coloringMessage = "Processing…"
        ScanPostprocessor.run(
            scans: [scan],
            colorize: true,
            modelContext: modelContext,
            progress: { _, msg in coloringMessage = msg ?? coloringMessage },
            completion: {
                coloringMessage = nil
                onUpdate(scan)
            }
        )
    }

    /// Long-press menu: STRUCTURAL re-run only, no coloring — the recovery tool for
    /// camera-gone downloads, late roomplans, and pipeline upgrades.
    private func reRunProcessing() {
        guard !ScanPostprocessor.pendingSteps(for: scan, includeColorize: false).isEmpty else {
            coloringMessage = "Nothing to process"
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if coloringMessage == "Nothing to process" { coloringMessage = nil }
            }
            return
        }
        coloringMessage = "Processing…"
        ScanPostprocessor.run(
            scans: [scan],
            modelContext: modelContext,
            progress: { _, msg in coloringMessage = msg ?? coloringMessage },
            completion: {
                coloringMessage = nil
                onUpdate(scan)
            }
        )
    }

    private var uploadButtonDisabled: Bool {
        isEditing || uploadURL.isEmpty || scan.uploadStatus.isUploading
    }

    @ViewBuilder
    private var statusBadge: some View {
        let status = scan.uploadStatus
        // While the export pipeline runs, the phase (view state) names the step and supplies
        // the meter; upload uses its own numeric progress. A bare "Converting…" hid a
        // multi-minute privacy/cube-face pass behind one word.
        let phase = activeExportPhase
        let label: String = {
            if case .zipping = status, let phase { return phase.label }
            return status.label
        }()
        let fraction: Double? = {
            if case .uploading(let progress) = status { return progress }
            if case .zipping = status { return phase?.fraction }
            return nil
        }()
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.caption2)
                    .foregroundColor(statusColor)
            }
            if status.isInFlight {
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(statusColor)
                        .frame(height: 2)
                } else {
                    ProgressView()   // indeterminate: copy / zip / not-yet-reported
                        .progressViewStyle(.linear)
                        .tint(statusColor)
                        .frame(height: 2)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minWidth: status.isInFlight ? 150 : nil, alignment: .leading)
        .background(statusColor.opacity(0.15))
        .cornerRadius(8)
        .animation(.easeInOut(duration: 0.15), value: label)
    }

    private var statusColor: Color {
        switch scan.uploadStatus {
        case .pending: return .white.opacity(0.6)   // was .gray — unreadable on the badge's own gray tint
        case .zipping: return .cyan
        case .savedLocally: return .green
        case .uploading: return .blue
        case .success: return .green
        case .failed: return .red
        }
    }

    private func formattedCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000.0) }
        if count >= 1_000 { return String(format: "%.0fK", Double(count) / 1_000.0) }
        return "\(count)"
    }

    private func uploadScan() {
        guard !uploadURL.isEmpty else { return }
        // Re-entrancy: an export/upload for this scan is already running — a second concurrent
        // prepareExport doubles the privacy-blur working set (OOM on phones; see UploadStatus.isInFlight).
        guard !scan.uploadStatus.isInFlight else { return }
        // DECISION 3 hard gate: never upload a scan with pending structural post-process work
        // (its roomplan/registration/proxy artifacts would be missing from the export).
        guard !ScanPostprocessor.needsPostprocess(scan) else {
            showPostprocessAlert = true
            return
        }
        scan.uploadStatus = .zipping
        onUpdate(scan)

        let format = selectedFormat
        let filename = scan.makeExportFilename(format: format)

        let baseURLString = uploadURL.hasSuffix("/") ? uploadURL : uploadURL + "/"
        guard let url = URL(string: baseURLString + filename) else {
            scan.uploadStatus = .failed("Invalid URL")
            onUpdate(scan)
            return
        }

        // Capture scan directory on main thread (SwiftData models aren't thread-safe)
        let scanDir = scan.scanDirectory
        print("[Upload] scanDirectory: \(scanDir.path) exists=\(FileManager.default.fileExists(atPath: scanDir.path))")
        guard FileManager.default.fileExists(atPath: scanDir.path) else {
            scan.uploadStatus = .failed("No scan data")
            onUpdate(scan)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            guard let exportURL = ScanExportManager.prepareExport(
                filename: filename, scanDir: scanDir, format: format,
                phase: { step in DispatchQueue.main.async { self.exportPhase = step } }
            ) else {
                DispatchQueue.main.async {
                    self.exportPhase = nil
                    self.scan.selectedFormat = self.selectedFormat
                    self.scan.uploadStatus = .failed("Export failed")
                    self.onUpdate(self.scan)
                }
                return
            }

            DispatchQueue.main.async {
                self.exportPhase = nil
                self.scan.uploadStatus = .uploading(progress: 0.0)
                self.onUpdate(self.scan)
            }

            // Upload natively via streaming
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue(format.contentType, forHTTPHeaderField: "Content-Type")

            // Track upload progress using KVO
            class ObserverBox { var observer: NSKeyValueObservation? }
            let box = ObserverBox()

            let task = URLSession.shared.uploadTask(with: request, fromFile: exportURL) { _, response, uploadError in
                _ = box

                try? FileManager.default.removeItem(at: exportURL)
                DispatchQueue.main.async {
                    self.scan.selectedFormat = self.selectedFormat
                    if let uploadError = uploadError {
                        self.scan.uploadStatus = .failed(uploadError.localizedDescription)
                    } else if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                        self.scan.uploadStatus = .success
                        self.scan.lastUploadedAt = Date()
                    } else {
                        self.scan.uploadStatus = .failed("Server error")
                    }
                    self.onUpdate(self.scan)
                }
            }

            box.observer = task.progress.observe(\.fractionCompleted) { progress, _ in
                DispatchQueue.main.async {
                    if case .uploading = self.scan.uploadStatus {
                        self.scan.uploadStatus = .uploading(progress: progress.fractionCompleted)
                        self.onUpdate(self.scan)
                    }
                }
            }

            task.resume()
        }
    }

    private func saveToFiles() {
        // Re-entrancy: the zip build is long and silent — a second tap here started a second
        // CONCURRENT prepareExport whose doubled privacy-blur working set OOM-killed the app
        // (2026-07-23 iPhone 17 Pro field report; see UploadStatus.isInFlight).
        guard !scan.uploadStatus.isInFlight else { return }
        // DECISION 3 hard gate: never export a scan with pending structural post-process work —
        // the zip would ship without its roomplan/registration/proxy artifacts (export is the
        // offline copy of the exact bundle upload sends; same gate, same rationale).
        guard !ScanPostprocessor.needsPostprocess(scan) else {
            showPostprocessAlert = true
            return
        }
        scan.uploadStatus = .zipping
        onUpdate(scan)

        let format = selectedFormat
        let filename = scan.makeExportFilename(format: format)

        let scanDir = scan.scanDirectory
        print("[SaveToFiles] scanDirectory: \(scanDir.path) exists=\(FileManager.default.fileExists(atPath: scanDir.path))")
        print("[SaveToFiles] location?.id: \(scan.location?.id.uuidString ?? "nil")")
        print("[SaveToFiles] meshFileURL: \(scan.meshFileURL.path) exists=\(FileManager.default.fileExists(atPath: scan.meshFileURL.path))")
        print("[SaveToFiles] rawDataPath: \(scan.rawDataPath.path) exists=\(FileManager.default.fileExists(atPath: scan.rawDataPath.path))")

        guard FileManager.default.fileExists(atPath: scanDir.path) else {
            print("[SaveToFiles] ERROR: scanDirectory does not exist")
            self.scan.uploadStatus = .failed("No data")
            self.onUpdate(self.scan)
            self.showExportError = true
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            if let exportURL = ScanExportManager.prepareExport(
                filename: filename, scanDir: scanDir, format: format,
                phase: { step in DispatchQueue.main.async { self.exportPhase = step } }
            ) {
                DispatchQueue.main.async {
                    self.exportPhase = nil
                    self.exportItem = ZipExportItem(url: exportURL)
                }
            } else {
                DispatchQueue.main.async {
                    self.exportPhase = nil
                    self.scan.uploadStatus = .failed("Export failed")
                    self.onUpdate(self.scan)
                    self.showExportError = true
                }
            }
        }
    }

}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    var completion: UIActivityViewController.CompletionWithItemsHandler?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = completion
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview("ScansListView") {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: ScanLocation.self, CapturedScan.self, configurations: config)

    let loc1 = ScanLocation(name: "Living Room")
    loc1.scans.append(CapturedScan(name: "Scan A", capturedAt: Date().addingTimeInterval(-3600), vertexCount: 1500, faceCount: 2000))
    container.mainContext.insert(loc1)

    let loc2 = ScanLocation(name: "Kitchen")
    loc2.scans.append(CapturedScan(name: "Scan B", capturedAt: Date().addingTimeInterval(-86400 * 3), vertexCount: 4200, faceCount: 8100))
    container.mainContext.insert(loc2)

    let loc3 = ScanLocation(name: "Garage")
    loc3.scans.append(CapturedScan(name: "Scan C", capturedAt: Date().addingTimeInterval(-86400 * 45), vertexCount: 9800, faceCount: 19200))
    container.mainContext.insert(loc3)

    return ScansListView(selectedTab: .constant(2))
        .modelContainer(container)
        .environment(ScanStore())
}

#Preview("LocationGridTile") {
    let sampleLocation = ScanLocation(name: "Sample Location")
    let sampleScan = CapturedScan(name: "Sample Scan 1", vertexCount: 1500, faceCount: 2000)
    sampleLocation.scans.append(sampleScan)
    return LocationGridTile(location: sampleLocation)
        .frame(width: 160)
        .padding()
        .background(Color.black)
}

#Preview("ScanCard") {
    let sampleScan = CapturedScan(name: "Sample Scan 1", vertexCount: 1500, faceCount: 2000)
    ScanCard(
        scan: sampleScan,
        isLatest: true,
        uploadURL: "https://example.com/upload",
        isEditing: false,
        onUpdate: { _ in },
        onDelete: { _ in }
    )
    .padding()
    .background(Color.black)
}
