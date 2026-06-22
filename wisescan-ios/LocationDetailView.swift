import SwiftUI
import SwiftData

// swiftlint:disable type_body_length
struct LocationDetailView: View {
    let location: ScanLocation
    @Environment(\.modelContext) private var modelContext
    @Environment(ScanStore.self) private var scanStore
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedTab: Int // Pass through to allow scan continuation to switch tabs
    @State private var isEditing = false
    @State private var selectedScans: Set<PersistentIdentifier> = []
    @State private var showBulkDeleteConfirm = false
    /// Number of DISTINCT OTHER maps the about-to-be-deleted scans are linked to (computed when
    /// the user taps delete). > 0 means the cascade will silently remove those spatial links.
    @State private var bulkDeleteLinkedMapCount = 0
    @State private var showSettings = false
    @State private var newLocationName = ""
    @State private var showRenameAlert = false
    @State private var showNoWorldMapAlert = false
    @State private var isBulkColoring = false
    /// Shown when a bulk-color selection mixes already-colored and uncolored scans,
    /// so the user can choose to color only the uncolored ones or recolor everything.
    @State private var showBulkColorMixedPrompt = false
    /// Shown when a bulk-upload selection mixes already-uploaded and un-uploaded scans.
    @State private var showBulkUploadMixedPrompt = false
    /// Per-scan coloring progress during a bulk colorize, keyed by scan id. SwiftUI @State so the
    /// cards reliably re-render as it updates (a SwiftData @Transient model prop is not observed).
    @State private var bulkColoringMessages: [PersistentIdentifier: String] = [:]

    @AppStorage(AppConstants.Key.uploadURL) private var uploadURL = AppConstants.uploadURL
    @AppStorage(AppConstants.Key.selectedExportFormat)
    private var globalSelectedFormatStr: String = AppConstants.selectedExportFormat
    @State private var isBulkExporting = false
    @State private var exportItems: [ZipExportItem] = []
    @State private var showExportSheet = false

    var body: some View {
        // Sort once per body evaluation and reuse for both the scroll content and the
        // bottom toolbar (which is a sibling of the ScrollView). Previously this sort ran
        // twice per redraw — and redraws are frequent during uploads/selection toggles.
        let sortedScans = location.scans.sorted { $0.capturedAt > $1.capturedAt }
        ZStack {
            Color.black.ignoresSafeArea()

            LinearGradient(colors: [Color(white: 0.1), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // MARK: - Header Actions
                    VStack(spacing: 16) {
                        // Rename Button (edit mode only)
                        if isEditing {
                            VStack(spacing: 12) {
                                Button(action: {
                                    newLocationName = location.name
                                    showRenameAlert = true
                                }, label: {
                                    HStack {
                                        Image(systemName: "pencil")
                                        Text("Rename Location")
                                    }
                                    .font(.subheadline)
                                })
                                .buttonStyle(FilledActionButtonStyle(
                                    background: Color.orange.opacity(0.1),
                                    foreground: .orange,
                                    verticalPadding: 12,
                                    border: Color.orange.opacity(0.3)
                                ))

                                Picker("Use Case", selection: Binding(
                                    get: { location.scanCase },
                                    set: { newValue in
                                        location.scanCase = newValue
                                        try? modelContext.save()
                                    }
                                )) {
                                    Text("Rescan Space").tag(ScanCase.rescanSpace)
                                    Text("Connect Adjacent Space").tag(ScanCase.linkAdjacent)
                                }
                                .pickerStyle(.segmented)
                                .colorScheme(.dark)
                            }
                        }

                        if !isEditing && !sortedScans.isEmpty {
                            // Linked badge. Read straight off the object graph in body — it's a
                            // cheap in-memory walk of `location.scans` relationships (no disk I/O),
                            // and accessing those relationships here registers them as observation
                            // dependencies, so the badge stays correct when a link is added/removed.
                            if StitchLinkStore.hasLinks(in: location) {
                                HStack(spacing: 6) {
                                    Image(systemName: "link.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Connected to adjacent space")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.green.opacity(0.1))
                                .cornerRadius(8)
                            }

                            // Extend / Rescan Latest Scan
                            if let latestScan = sortedScans.first,
                               !latestScan.hardwareDeviceModel.localizedCaseInsensitiveContains("ray ban") &&
                               !latestScan.hardwareDeviceModel.localizedCaseInsensitiveContains("glass") {
                                HStack(spacing: 12) {
                                    // Rescan Space button
                                    Button(action: {
                                        // Rescan relocalizes against the existing world map (ghost
                                        // overlay + shared frame). Without the file ARCoverageView
                                        // silently falls back to a mapless session, so guard first.
                                        guard FileManager.default.fileExists(atPath: latestScan.worldMapURL.path) else {
                                            showNoWorldMapAlert = true
                                            return
                                        }
                                        scanStore.activeLocationForScan = location.id
                                        scanStore.activeRelocalizationMap = latestScan.worldMapURL
                                        scanStore.activeScanToExtend = latestScan.id
                                        scanStore.activeScanCase = .rescanSpace
                                        selectedTab = 1
                                    }, label: {
                                        HStack {
                                            Image(systemName: "plus.viewfinder")
                                            Text("Rescan Space")
                                                .font(.subheadline).bold()
                                        }
                                    })
                                    .buttonStyle(FilledActionButtonStyle(background: Color.indigo.opacity(0.8)))

                                    // Link Adjacent Space button
                                    Button(action: {
                                        // Only require a valid world map — no boundary anchor needed.
                                        // The user relocalizes via the world map and chooses the
                                        // boundary point by walking there.
                                        guard FileManager.default.fileExists(atPath: latestScan.worldMapURL.path) else {
                                            showNoWorldMapAlert = true
                                            return
                                        }
                                        scanStore.activeLocationForScan = location.id
                                        scanStore.activeRelocalizationMap = latestScan.worldMapURL
                                        scanStore.activeScanToExtend = latestScan.id
                                        scanStore.activeScanCase = .linkAdjacent
                                        // Enter the alignment phase synchronously, BEFORE navigating to
                                        // capture, so the "align with previous scan" overlay is up on
                                        // first render. Otherwise the phase is only set in
                                        // ARCoverageView.onAppear (after first render), leaving a window
                                        // where the record button is live but capturePhase is still
                                        // .idle — a fast tap then starts an un-aligned scan (ghost ~90°
                                        // off). CaptureView.onDisappear → resetCaptureState clears this
                                        // if the user backs out.
                                        scanStore.capturePhase = .loadingWorldMap
                                        selectedTab = 1
                                    }, label: {
                                        HStack {
                                            Image(systemName: "link.badge.plus")
                                            Text("Connect Adjacent")
                                                .font(.subheadline).bold()
                                        }
                                    })
                                    .buttonStyle(FilledActionButtonStyle(background: Color.orange.opacity(0.8)))
                                }
                            }

                            // Global Export Settings
                            VStack(spacing: 12) {
                                HStack {
                                    Text("Global Export Format")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                    Spacer()
                                    Picker("Format", selection: $globalSelectedFormatStr) {
                                        ForEach(ExportFormat.allCases, id: \.self) { (format: ExportFormat) in
                                            Text(format.rawValue).tag(format.rawValue)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .tint(.cyan)
                                    .onChange(of: globalSelectedFormatStr) { _, newValue in
                                        for scan in location.scans {
                                            scan.selectedFormat = ExportFormat(rawValue: newValue) ?? .scan4d
                                        }
                                        try? modelContext.save()
                                    }
                                }

                                // Bulk actions moved to bottom toolbar in edit mode
                            }
                            .padding()
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 16)

                    // MARK: - Scan Cards
                    if sortedScans.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "tray")
                                .font(.system(size: 48))
                                .foregroundColor(.gray)
                            Text("No scans found in this location.")
                                .foregroundColor(.gray)
                        }
                        .padding(.top, 60)
                    } else {
                        // LazyVStack defers mesh preview creation until cards scroll into view.
                        // Most recent scan is first (sorted descending) so it renders immediately.
                        LazyVStack(spacing: 16) {
                            ForEach(Array(sortedScans.enumerated()), id: \.element.id) { index, scan in
                                ScanCard(
                                    scan: scan,
                                    isLatest: index == 0,
                                    uploadURL: uploadURL,
                                    isEditing: isEditing,
                                    isSelected: selectedScans.contains(scan.id),
                                    bulkColoringMessage: bulkColoringMessages[scan.id],
                                    onUpdate: { _ in try? modelContext.save() },
                                    onDelete: { scanToDelete in
                                        ScanFileManager.shared.deleteScan(scanToDelete, context: modelContext)
                                        // Auto-delete location if no scans remain
                                        if location.scans.isEmpty {
                                            modelContext.delete(location)
                                            try? modelContext.save()
                                            dismiss()
                                        }
                                    },
                                    onSelect: {
                                        if selectedScans.contains(scan.id) {
                                            selectedScans.remove(scan.id)
                                        } else {
                                            selectedScans.insert(scan.id)
                                        }
                                    }
                                )
                                .padding(.horizontal)
                            }
                        }
                    }

                    // MARK: - Server Workflows
                    VStack(alignment: .leading, spacing: 16) {
                        Text("SERVER WORKFLOWS (COMING SOON)")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                            .padding(.horizontal)

                        VStack(spacing: 16) {
                            WorkflowCard(
                                icon: "arrow.triangle.2.circlepath.camera.fill",
                                title: "Quick Mesh",
                                description: "Fast photogrammetry pipeline optimized for immediate preview. " +
                                             "Lower resolution textures.",
                                time: "~5 mins",
                                buttonText: "Run Workflow",
                                isPrimary: true,
                                isDisabled: true
                            )

                            WorkflowCard(
                                icon: "camera.macro",
                                title: "Gaussian Splat",
                                description: "High-fidelity radiance field reconstruction for " +
                                             "photo-realistic novel view synthesis.",
                                time: "~25 mins",
                                buttonText: "Run Workflow",
                                isDisabled: true
                            )

                            WorkflowCard(
                                icon: "map.fill",
                                title: "Spatial Indexing",
                                description: "OpenFLAME spatial indexing with automatic semantic labelling. " +
                                             "Identifies and tags objects, surfaces, and regions for " +
                                             "spatial queries and AR anchoring.",
                                time: "~10 mins",
                                buttonText: "Run Workflow",
                                isDisabled: true
                            )
                        }
                        .padding(.horizontal)
                    }
                    .padding(.top, 16)
                    .opacity(isEditing ? 0.3 : 1.0)

                    Spacer().frame(height: 100)
                }
            }

            if isEditing {
                VStack {
                    Spacer()
                    bottomActionToolbar(sortedScans: sortedScans)
                }
            }
        }
        .navigationTitle(location.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if isEditing {
                    Button(action: {
                        if selectedScans.count == location.scans.count {
                            selectedScans.removeAll()
                        } else {
                            selectedScans = Set(location.scans.map { $0.id })
                        }
                    }, label: {
                        Text(selectedScans.count == location.scans.count ? "Deselect All" : "Select All")
                            .font(.subheadline)
                    })
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    if !location.scans.isEmpty {
                        Button(action: {
                            isEditing.toggle()
                            if !isEditing { selectedScans.removeAll() }
                        }, label: {
                            Text(isEditing ? "Done" : "Edit")
                                .bold(isEditing)
                                .foregroundColor(isEditing ? .red : .cyan)
                        })
                    }
                    Button(action: { showSettings = true }, label: {
                        Image(systemName: "gearshape")
                    })
                    .disabled(isEditing)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showExportSheet) {
            ShareSheet(activityItems: exportItems.map { $0.url }) { _, _, _, _ in
                // Cleanup
                isBulkExporting = false
            }
        }
        .alert("Rename Location", isPresented: $showRenameAlert) {
            TextField("New Name", text: $newLocationName)
            Button("Save") {
                let trimmedName = newLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedName.isEmpty {
                    location.name = trimmedName
                    try? modelContext.save()
                }
            }
            .disabled(newLocationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("World Map Missing", isPresented: $showNoWorldMapAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The relocalization world map for this scan is missing, so it can't be rescanned " +
                 "or connected to an adjacent space — both relocalize against the saved world map. " +
                 "Capture a new scan of this space to create one.")
        }
        .modifier(BulkColorMixedDialog(
            isPresented: $showBulkColorMixedPrompt,
            uncolored: selectedColorSplit.uncolored,
            colored: selectedColorSplit.colored,
            colorize: { bulkColorize(scans: $0) }
        ))
        .modifier(BulkUploadMixedDialog(
            isPresented: $showBulkUploadMixedPrompt,
            notUploaded: selectedUploadSplit.notUploaded,
            uploaded: selectedUploadSplit.uploaded,
            upload: { scans in
                bulkUpload(scans: scans)
                isEditing = false
                selectedScans.removeAll()
            }
        ))
        .confirmationDialog(
            "Delete Scans",
            isPresented: $showBulkDeleteConfirm
        ) {
            Button("Delete \(selectedScans.count) Scan\(selectedScans.count == 1 ? "" : "s")", role: .destructive) {
                bulkDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if bulkDeleteLinkedMapCount > 0 {
                Text("This map is connected to \(bulkDeleteLinkedMapCount) other " +
                     "map\(bulkDeleteLinkedMapCount == 1 ? "" : "s"). Deleting these scans will " +
                     "remove those connections.\n\nThis will permanently delete the selected " +
                     "scans and their data.")
            } else {
                Text("This will permanently delete the selected scans and their data.")
            }
        }
    }

    // MARK: - Bulk Actions

    /// Count of DISTINCT OTHER locations the given scans are linked to via incident stitch links.
    /// Used to warn that deleting them will cascade-remove the connections to those maps.
    private func linkedOtherMapCount(for scanIds: Set<PersistentIdentifier>) -> Int {
        let scans = location.scans.filter { scanIds.contains($0.id) }
        let thisLocationId = location.id
        var otherLocationIds = Set<ScanLocation.ID>()
        for scan in scans {
            for link in StitchLinkStore.incidentLinks(for: scan) {
                guard let otherId = link.localAnchor(for: scan)?.otherScan?.location?.id else { continue }
                if otherId != thisLocationId { otherLocationIds.insert(otherId) }
            }
        }
        return otherLocationIds.count
    }

    private func bulkDelete() {
        let scansToDelete = location.scans.filter { selectedScans.contains($0.id) }
        // Determine if the location will be empty BEFORE mutating — SwiftData's inverse
        // relationship array isn't updated until save(), so checking .isEmpty after delete()
        // would incorrectly report non-empty.
        let willBeEmpty = scansToDelete.count >= location.scans.count
        // Capture file URLs on main (SwiftData model access must stay on the context's thread).
        // Delete the records + save once on main (fast, in-memory), then remove the scan
        // directories (images/depth/cameras — the slow part) OFF main so bulk delete of many
        // scans doesn't freeze the UI.
        let dirs = scansToDelete.map(\.scanDirectory)
        for scan in scansToDelete {
            modelContext.delete(scan)
        }

        selectedScans.removeAll()
        isEditing = false

        if willBeEmpty {
            modelContext.delete(location)
        }
        try? modelContext.save()

        DispatchQueue.global(qos: .utility).async {
            for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        }

        if willBeEmpty { dismiss() }
    }

    private func bulkSaveToFiles(scans: [CapturedScan]) {
        guard !scans.isEmpty else { return }
        isBulkExporting = true
        let format = ExportFormat(rawValue: globalSelectedFormatStr) ?? .scan4d
        let locationIds = Set(scans.compactMap { $0.location?.id })

        Task { @MainActor in
            // Build the stitch graph ONCE for the whole batch (was rebuilt per scan).
            let bulkStitch = await ScanExportManager.makeBulkStitchArtifacts(forLocationIds: locationIds)
            DispatchQueue.global(qos: .userInitiated).async {
                var urls: [ZipExportItem] = []
                for scan in scans {
                    DispatchQueue.main.async { scan.uploadStatus = .zipping }
                    let filename = scan.makeExportFilename(format: format)
                    if let url = ScanExportManager.prepareExport(
                        filename: filename, scanDir: scan.scanDirectory, format: format, bulkStitch: bulkStitch
                    ) {
                        urls.append(ZipExportItem(url: url))
                        DispatchQueue.main.async { scan.uploadStatus = .savedLocally }
                    } else {
                        DispatchQueue.main.async { scan.uploadStatus = .failed("Export failed") }
                    }
                }

                DispatchQueue.main.async {
                    self.exportItems = urls
                    self.showExportSheet = true
                    self.isBulkExporting = false
                }
            }
        }
    }

    private func bulkUpload(scans: [CapturedScan]) {
        guard !scans.isEmpty, !uploadURL.isEmpty else { return }
        let format = ExportFormat(rawValue: globalSelectedFormatStr) ?? .scan4d
        let baseURLString = uploadURL.hasSuffix("/") ? uploadURL : uploadURL + "/"
        let locationIds = Set(scans.compactMap { $0.location?.id })

        Task { @MainActor in
            // Build the stitch graph ONCE for the whole batch (was rebuilt per scan).
            let bulkStitch = await ScanExportManager.makeBulkStitchArtifacts(forLocationIds: locationIds)
            for scan in scans {
                guard let url = URL(string: baseURLString + scan.makeExportFilename(format: format)) else { continue }
                scan.uploadStatus = .zipping

                DispatchQueue.global(qos: .userInitiated).async {
                    let filename = scan.makeExportFilename(format: format)
                    guard let exportURL = ScanExportManager.prepareExport(
                        filename: filename, scanDir: scan.scanDirectory, format: format, bulkStitch: bulkStitch
                    ) else {
                        DispatchQueue.main.async { scan.uploadStatus = .failed("Export failed") }
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
                        }
                    }
                    task.resume()
                }
            }
        }
    }

    // MARK: - Bottom Action Toolbar
    @ViewBuilder
    private func bottomActionToolbar(sortedScans: [CapturedScan]) -> some View {
        HStack(spacing: 20) {
            Button(action: {
                bulkDeleteLinkedMapCount = linkedOtherMapCount(for: selectedScans)
                showBulkDeleteConfirm = true
            }, label: {
                Image(systemName: "trash")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(selectedScans.isEmpty ? Color.gray.opacity(0.3) : Color.red.opacity(0.8))
                    .foregroundColor(selectedScans.isEmpty ? .gray : .white)
                    .cornerRadius(10)
            })
            .disabled(selectedScans.isEmpty)

            Button(action: {
                requestBulkUpload(sortedScans: sortedScans)
            }, label: {
                Text("Upload")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(selectedScans.isEmpty || uploadURL.isEmpty ? Color.gray.opacity(0.3) : Color.blue)
                    .foregroundColor(selectedScans.isEmpty || uploadURL.isEmpty ? .gray : .white)
                    .cornerRadius(10)
            })
            .disabled(selectedScans.isEmpty || uploadURL.isEmpty)

            Button(action: {
                let scansToSave = sortedScans.filter { selectedScans.contains($0.id) }
                bulkSaveToFiles(scans: scansToSave)
                isEditing = false
                selectedScans.removeAll()
            }, label: {
                Text("Save")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(selectedScans.isEmpty || isBulkExporting ?
                                Color.gray.opacity(0.3) : Color.cyan.opacity(0.8))
                    .foregroundColor(selectedScans.isEmpty || isBulkExporting ? .gray : .white)
                    .cornerRadius(10)
            })
            .disabled(selectedScans.isEmpty || isBulkExporting)

            Button(action: { requestBulkColorize() }, label: {
                HStack(spacing: 4) {
                    Image(systemName: "paintbrush.fill")
                    Text("Color")
                }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(bulkColorDisabled ? Color.gray.opacity(0.3) : Color.orange.opacity(0.8))
                    .foregroundColor(bulkColorDisabled ? .gray : .white)
                    .cornerRadius(10)
            })
            .disabled(bulkColorDisabled)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var bulkColorDisabled: Bool {
        // Enabled whenever any scan is selected — already-colored scans can be recolored.
        selectedScans.isEmpty || isBulkColoring
    }

    /// Selected scans, split into already-colored and not-yet-colored.
    private var selectedColorSplit: (uncolored: [CapturedScan], colored: [CapturedScan]) {
        let selected = location.scans.filter { selectedScans.contains($0.id) }
        return (selected.filter { !$0.isColored }, selected.filter { $0.isColored })
    }

    /// Selected scans, split into already-uploaded and not-yet-uploaded.
    private var selectedUploadSplit: (notUploaded: [CapturedScan], uploaded: [CapturedScan]) {
        let selected = location.scans.filter { selectedScans.contains($0.id) }
        return (selected.filter { !$0.isUploaded }, selected.filter { $0.isUploaded })
    }

    /// Entry point for the bulk Upload button. Uploads directly when the selection is
    /// uniform (all uploaded or all un-uploaded); when it's mixed, prompts the user.
    private func requestBulkUpload(sortedScans: [CapturedScan]) {
        let scansToUpload = sortedScans.filter { selectedScans.contains($0.id) }
        let split = (notUploaded: scansToUpload.filter { !$0.isUploaded },
                     uploaded: scansToUpload.filter { $0.isUploaded })
        guard !scansToUpload.isEmpty else { return }
        if split.notUploaded.isEmpty || split.uploaded.isEmpty {
            bulkUpload(scans: scansToUpload)
            isEditing = false
            selectedScans.removeAll()
        } else {
            showBulkUploadMixedPrompt = true
        }
    }

    /// Entry point for the bulk Color button. Colors directly when the selection is
    /// uniform (all colored or all uncolored); when it's mixed, prompts the user to
    /// choose between coloring only the uncolored scans or recoloring everything.
    private func requestBulkColorize() {
        let split = selectedColorSplit
        let selected = split.uncolored + split.colored
        guard !selected.isEmpty else { return }
        if split.uncolored.isEmpty || split.colored.isEmpty {
            bulkColorize(scans: selected)   // uniform selection — no need to ask
        } else {
            showBulkColorMixedPrompt = true
        }
    }

    private func bulkColorize(scans: [CapturedScan]) {
        guard !scans.isEmpty else { return }
        isBulkColoring = true

        DispatchQueue.global(qos: .utility).async {
            for scan in scans {
                // Per-card progress: each card shows its own "Coloring NN%" as the batch reaches it
                // (mirrors how per-card upload status is shown). Same model property the single-card
                // Color button uses, so only one card animates at a time as the loop advances.
                DispatchQueue.main.async { self.bulkColoringMessages[scan.id] = "Coloring…" }
                guard let meshData = try? Data(contentsOf: scan.meshFileURL) else {
                    DispatchQueue.main.async { self.bulkColoringMessages[scan.id] = nil }
                    continue
                }

                var lastPct = -1
                let vertexColors = VertexColorAccumulator.colorizeFromSavedFrames(
                    objData: meshData,
                    rawDataDir: scan.rawDataPath,
                    progress: { p in
                        let pct = Int(p * 100)
                        guard pct != lastPct else { return } // throttle to whole-percent changes
                        lastPct = pct
                        DispatchQueue.main.async { self.bulkColoringMessages[scan.id] = "Coloring \(pct)%" }
                    }
                )

                if let colors = vertexColors {
                    try? colors.write(to: scan.colorsFileURL)
                }

                let pose = scan.location?.imagingPoseMatrix
                if let img = MeshPreviewView.generateSnapshot(
                    meshURL: scan.meshFileURL, colorsURL: scan.colorsFileURL, poseMatrix: pose
                ),
                   let data = img.jpegData(compressionQuality: 0.8) {
                    try? data.write(to: scan.modelPreviewURL)
                }

                DispatchQueue.main.async {
                    scan.isColored = true
                    scan.location?.updatedAt = Date()
                    self.bulkColoringMessages[scan.id] = nil
                    try? self.modelContext.save()
                }
            }

            DispatchQueue.main.async {
                self.isBulkColoring = false
                self.isEditing = false
                self.selectedScans.removeAll()
            }
        }
    }
}

// MARK: - Bulk Color Mixed-Selection Dialog

/// Prompt shown when a bulk-color selection mixes already-colored and uncolored
/// scans. Hosted as a `ViewModifier` so its dialog content type-checks in its own
/// `body` rather than inflating LocationDetailView's already-large `body`.
private struct BulkColorMixedDialog: ViewModifier {
    @Binding var isPresented: Bool
    let uncolored: [CapturedScan]
    let colored: [CapturedScan]
    let colorize: ([CapturedScan]) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Color Scans",
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button("Color \(uncolored.count) Uncolored Only") { colorize(uncolored) }
            Button("Recolor All \(uncolored.count + colored.count)") { colorize(uncolored + colored) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(colored.count) of the selected scans are already colored. " +
                 "Color only the uncolored scans, or recolor everything?")
        }
    }
}

private struct BulkUploadMixedDialog: ViewModifier {
    @Binding var isPresented: Bool
    let notUploaded: [CapturedScan]
    let uploaded: [CapturedScan]
    let upload: ([CapturedScan]) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Upload Scans",
            isPresented: $isPresented,
            titleVisibility: .visible
        ) {
            Button("Upload \(notUploaded.count) Un-uploaded Only") { upload(notUploaded) }
            Button("Re-upload All \(notUploaded.count + uploaded.count)") { upload(notUploaded + uploaded) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(uploaded.count) of the selected scans have already been uploaded. " +
                 "Upload only the un-uploaded scans, or re-upload everything?")
        }
    }
}

// MARK: - Workflow Card

struct WorkflowCard: View {
    var icon: String
    var title: String
    var description: String
    var time: String
    var buttonText: String
    var isPrimary: Bool = false
    var isDisabled: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(isPrimary ? .cyan : .white)
                .frame(width: 40)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Label("Time: \(time)", systemImage: "clock")
                        .font(.caption)
                        .foregroundColor(.green)

                    Spacer()

                    Button(action: {}, label: {
                        Text(buttonText)
                            .font(.caption).bold()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isDisabled ? Color.gray.opacity(0.3) :
                                        (isPrimary ? Color.blue : Color.white.opacity(0.2)))
                            .foregroundColor(isDisabled ? .gray : .white)
                            .cornerRadius(8)
                    })
                    .disabled(isDisabled)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isPrimary ? Color.cyan.opacity(0.3) : Color.white.opacity(0.1), lineWidth: 1)
        )
        .cornerRadius(16)
        .opacity(isDisabled ? 0.6 : 1.0)
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    // swiftlint:disable:next force_try
    let container = try! ModelContainer(for: ScanLocation.self, CapturedScan.self, configurations: config)
    let ctx = container.mainContext
    let sampleLocation = ScanLocation(name: "Sample Location")
    ctx.insert(sampleLocation)

    let scan1 = CapturedScan(
        name: "Morning Scan", capturedAt: Date().addingTimeInterval(-3600),
        vertexCount: 1500, faceCount: 2000)
    let scan2 = CapturedScan(
        name: "Afternoon Scan", capturedAt: Date().addingTimeInterval(-86400 * 3),
        vertexCount: 4200, faceCount: 8100)
    let scan3 = CapturedScan(
        name: "Evening Scan", capturedAt: Date().addingTimeInterval(-86400 * 45),
        vertexCount: 9800, faceCount: 19200)
    ctx.insert(scan1)
    ctx.insert(scan2)
    ctx.insert(scan3)
    sampleLocation.scans.append(contentsOf: [scan1, scan2, scan3])
    try? ctx.save()

    return LocationDetailView(location: sampleLocation, selectedTab: .constant(2))
        .modelContainer(container)
        .environment(ScanStore())
}
