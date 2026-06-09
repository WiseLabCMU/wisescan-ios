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
    @State private var isEditing = false
    @State private var viewMode: LibraryViewMode = .grid
    @State private var renderRequest: ComponentRenderRequest?
    @State private var graphVisibleLocationIds: Set<PersistentIdentifier> = []
    @State private var bulkScope: BulkScope = .latest
    @State private var isBulkColoring = false
    @State private var bulkProgressMessage: String?
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
                    StitchGraphView(locations: locations, renderRequest: $renderRequest, isEditing: $isEditing, selectedLocations: $selectedLocations, visibleLocationIds: $graphVisibleLocationIds)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(locations) { location in
                                ZStack(alignment: .topTrailing) {
                                    NavigationLink(value: location) {
                                        LocationGridTile(location: location)
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
            .sheet(isPresented: $showExportSheet) {
                ShareSheet(activityItems: exportItems.map { $0.url }) { _, _, _, _ in
                    isBulkExporting = false
                    exitEditModeWithBanner("✓ Saved \(exportItems.count) scan\(exportItems.count == 1 ? "" : "s")")
                }
            }
            .fullScreenCover(item: $renderRequest) { req in
                CombinedMeshScreen(title: req.title, items: req.items)
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
                Text(bulkDeleteMessage)
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

            // Action buttons: [Trash] [Upload] [Save] [Color]
            HStack(spacing: 20) {
                // Delete
                Button(action: { showBulkDeleteConfirm = true }) {
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
                Button(action: { bulkUpload() }) {
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

                // Color
                Button(action: { bulkColorize() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "paintbrush.fill")
                        Text("Color")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(colorDisabled ? Color.gray.opacity(0.3) : Color.orange.opacity(0.8))
                    .foregroundColor(colorDisabled ? .gray : .white)
                    .cornerRadius(10)
                }
                .disabled(colorDisabled)
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
        .background(.ultraThinMaterial)
    }

    private var uploadDisabled: Bool {
        selectedLocations.isEmpty || uploadURL.isEmpty
    }

    private var colorDisabled: Bool {
        resolveTargetScans().filter({ !$0.isColored }).isEmpty || isBulkColoring
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
            for loc in selectedLocs {
                for scan in loc.scans { modelContext.delete(scan) }
                modelContext.delete(loc)
            }
            try? modelContext.save()
            selectedLocations.removeAll()
            isEditing = false
            DispatchQueue.global(qos: .utility).async {
                for dir in dirs { try? FileManager.default.removeItem(at: dir) }
            }

        case .latest:
            // Delete only the latest scan per location; auto-delete location if empty
            var dirsToRemove: [URL] = []
            for loc in selectedLocs {
                guard let latest = loc.scans.max(by: { $0.capturedAt < $1.capturedAt }) else { continue }
                dirsToRemove.append(latest.scanDirectory)
                modelContext.delete(latest)
                if loc.scans.count <= 1 {
                    // This was the last scan — remove the location too
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

    /// Export selected scans to the share sheet. Runs export packaging on a background queue.
    /// Progress banner shows per-scan preparation status.
    private func bulkSaveToFiles() {
        let scans = resolveTargetScans()
        guard !scans.isEmpty else { return }
        isBulkExporting = true
        selectedLocations.removeAll()
        let format = ExportFormat(rawValue: globalSelectedFormatStr) ?? .scan4d
        let totalScans = scans.count

        bulkProgressMessage = "Preparing 1/\(totalScans)…"

        // Capture scan directories on main (SwiftData model access).
        let scanInfos = scans.map { (dir: $0.scanDirectory, filename: $0.makeExportFilename(format: format)) }

        DispatchQueue.global(qos: .userInitiated).async {
            var urls: [ZipExportItem] = []
            for (idx, info) in scanInfos.enumerated() {
                DispatchQueue.main.async {
                    self.bulkProgressMessage = "Preparing \(idx + 1)/\(totalScans)…"
                }
                if let url = ScanExportManager.prepareExport(
                    filename: info.filename, scanDir: info.dir, format: format
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

    /// Upload selected scans to the configured server. Each scan is exported and uploaded
    /// independently on a background queue. Banner tracks per-scan completion and upload progress.
    private func bulkUpload() {
        let scans = resolveTargetScans()
        guard !scans.isEmpty, !uploadURL.isEmpty else { return }
        let format = ExportFormat(rawValue: globalSelectedFormatStr) ?? .scan4d
        let baseURLString = uploadURL.hasSuffix("/") ? uploadURL : uploadURL + "/"

        isBulkUploading = true
        bulkUploadCompleted = 0
        bulkUploadTotal = scans.count
        selectedLocations.removeAll()
        bulkProgressMessage = "Uploading 0/\(scans.count)…"

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
                    filename: filename, scanDir: scanDir, format: format
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

    /// Called after each upload completes; when all are done, shows a completion banner and exits edit mode.
    private func checkBulkUploadCompletion() {
        let done = bulkUploadCompleted
        let total = bulkUploadTotal
        bulkProgressMessage = "Uploading \(done)/\(total)…"
        guard done >= total else { return }
        isBulkUploading = false
        exitEditModeWithBanner("✓ Uploaded \(total) scan\(total == 1 ? "" : "s")")
    }

    /// Serial colorize of selected uncolored scans on a utility queue.
    /// Progress is throttled to whole-percent updates to avoid flooding the main thread.
    private func bulkColorize() {
        let scans = resolveTargetScans().filter { !$0.isColored }
        guard !scans.isEmpty else { return }
        isBulkColoring = true

        let totalScans = scans.count
        // Capture all needed properties on main before dispatching (SwiftData models aren't
        // thread-safe). Each tuple carries the values needed for the background colorize loop.
        struct ScanColorizeInfo {
            let meshURL: URL
            let rawDataDir: URL
            let colorsURL: URL
            let previewURL: URL
            let pose: [Float]?
        }
        let infos: [(scan: CapturedScan, info: ScanColorizeInfo)] = scans.map { scan in
            (scan, ScanColorizeInfo(
                meshURL: scan.meshFileURL,
                rawDataDir: scan.rawDataPath,
                colorsURL: scan.colorsFileURL,
                previewURL: scan.modelPreviewURL,
                pose: scan.location?.imagingPoseMatrix
            ))
        }

        DispatchQueue.global(qos: .utility).async {
            for (idx, entry) in infos.enumerated() {
                let scanName = "Scan \(idx + 1)"
                DispatchQueue.main.async {
                    self.bulkProgressMessage = "Coloring \(idx + 1)/\(totalScans) — \(scanName)"
                }

                guard let meshData = try? Data(contentsOf: entry.info.meshURL) else { continue }

                var lastPct = -1
                let vertexColors = VertexColorAccumulator.colorizeFromSavedFrames(
                    objData: meshData,
                    rawDataDir: entry.info.rawDataDir,
                    progress: { progress in
                        let pct = Int(progress * 100)
                        guard pct != lastPct else { return } // throttle to whole-percent changes
                        lastPct = pct
                        DispatchQueue.main.async {
                            self.bulkProgressMessage = "Coloring \(idx + 1)/\(totalScans) — \(scanName): \(pct)%"
                        }
                    }
                )

                if let colors = vertexColors {
                    try? colors.write(to: entry.info.colorsURL)
                }

                if let img = MeshPreviewView.generateSnapshot(
                    meshURL: entry.info.meshURL, colorsURL: entry.info.colorsURL, poseMatrix: entry.info.pose
                ),
                   let data = img.jpegData(compressionQuality: 0.8) {
                    try? data.write(to: entry.info.previewURL)
                }

                DispatchQueue.main.async {
                    entry.scan.isColored = true
                    entry.scan.location?.updatedAt = Date()
                    try? self.modelContext.save()
                }
            }

            DispatchQueue.main.async {
                self.isBulkColoring = false
                self.exitEditModeWithBanner("✓ Colored \(totalScans) scan\(totalScans == 1 ? "" : "s")")
            }
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

// MARK: - Location Grid Tile

struct LocationGridTile: View {
    let location: ScanLocation
    @State private var thumbnailImage: UIImage?
    // Resolved off the main thread in `.task` so the body performs no FileManager I/O.
    @State private var hasMissingWorldMap = false

    var latestScan: CapturedScan? {
        // Single O(n) pass with no intermediate sorted-array allocation; this is read
        // multiple times per body evaluation.
        location.scans.max(by: { $0.capturedAt < $1.capturedAt })
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
                        .foregroundColor(.gray.opacity(0.5))
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
                        .foregroundColor(.gray)
                    Spacer()
                    if let latest = latestScan {
                        Text(latest.timeSinceCapture)
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.05))
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topLeading) {
            if hasMissingWorldMap {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.yellow)
                    .padding(6)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
                    .padding(8)
            }
        }
        .task(id: location.updatedAt) {
            // Resolve thumbnail + missing-worldmap state off the main thread to avoid
            // main-thread FileManager I/O during layout/scroll (#5/#7).
            guard let latest = latestScan else {
                thumbnailImage = nil
                hasMissingWorldMap = false
                return
            }
            let previewURL = latest.modelPreviewURL
            let fallbackURL = latest.thumbnailURL
            let worldMapPaths = location.scans.map { $0.worldMapURL.path }

            // Missing-worldmap flag off-main.
            hasMissingWorldMap = await Task.detached(priority: .utility) {
                let fm = FileManager.default
                return worldMapPaths.contains(where: { !fm.fileExists(atPath: $0) })
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
    @State private var itemCounts: (images: Int, proxy: Int, depth: Int, cameras: Int)?
    @State private var showMeshPreview = false
    @State private var showMissingRelocAlert = false
    // Disk-derived values resolved off the main thread in `.task` (see below) so the
    // view body never performs synchronous FileManager I/O during layout/scroll.
    @State private var previewImage: UIImage?
    @State private var isRelocMissing = false
    @State private var sizeMB: Double = 0
    // Single-card coloring progress (SwiftUI @State — reliably observed, unlike a SwiftData
    // @Transient model prop). Bulk coloring drives `bulkColoringMessage` from the parent instead.
    @State private var coloringMessage: String?

    private var selectedFormat: ExportFormat {
        get { ExportFormat(rawValue: selectedFormatStr) ?? .polycam }
        nonmutating set { selectedFormatStr = newValue.rawValue }
    }

    /// Effective coloring progress: single-card @State, or the parent's bulk message.
    private var activeColoringMessage: String? { coloringMessage ?? bulkColoringMessage }

    var isSelected: Bool = false
    var onSelect: (() -> Void)?
    /// Coloring progress message driven by the parent during a BULK colorize (nil otherwise).
    /// Single-card colorize uses the local `coloringMessage` @State.
    var bulkColoringMessage: String?

    init(scan: CapturedScan, isLatest: Bool, uploadURL: String, isEditing: Bool, isSelected: Bool = false, bulkColoringMessage: String? = nil, onUpdate: @escaping (CapturedScan) -> Void, onDelete: @escaping (CapturedScan) -> Void, onSelect: (() -> Void)? = nil) {
        self.scan = scan
        self.isLatest = isLatest
        self.uploadURL = uploadURL
        self.isEditing = isEditing
        self.isSelected = isSelected
        self.bulkColoringMessage = bulkColoringMessage
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
            if scan.uploadStatus == .zipping {
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
                MeshPreviewContainer(location: scan.location, meshFileURL: scan.meshFileURL, colorsFileURL: scan.colorsFileURL, scanDirectoryURL: scan.scanDirectory)
                    .ignoresSafeArea()
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
                () -> (counts: (Int, Int, Int, Int), relocMissing: Bool, sizeMB: Double) in
                let iCount = (try? fm.contentsOfDirectory(atPath: rawDir.appendingPathComponent("images").path))?.count ?? 0
                let pCount = (try? fm.contentsOfDirectory(atPath: rawDir.appendingPathComponent("proxy_images").path))?.count ?? 0
                let dCount = (try? fm.contentsOfDirectory(atPath: rawDir.appendingPathComponent("depth").path))?.count ?? 0
                let cCount = (try? fm.contentsOfDirectory(atPath: rawDir.appendingPathComponent("cameras").path))?.count ?? 0

                let relocMissing = !fm.fileExists(atPath: worldMapPath)

                var bytes: Int64 = 0
                if let attr = try? fm.attributesOfItem(atPath: meshPath) { bytes += attr[.size] as? Int64 ?? 0 }
                if let attr = try? fm.attributesOfItem(atPath: colorsPath) { bytes += attr[.size] as? Int64 ?? 0 }
                let sizeMB = (bytes > 0 ? Double(bytes) : Double(fallbackBytes)) / (1024.0 * 1024.0)

                return ((iCount, pCount, dCount, cCount), relocMissing, sizeMB)
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
                            .foregroundColor(.gray.opacity(0.5))
                    }
                }
            }
            .frame(minWidth: 120, maxWidth: .infinity, maxHeight: 180)
            .clipped()
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .overlay(editingOverlay)
        .overlay(alignment: .topLeading) { relocWarningOverlay }
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
    private var relocWarningOverlay: some View {
        if isRelocMissing {
            Button(action: { showMissingRelocAlert = true }) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundColor(.yellow)
                    .padding(8)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Circle())
            }
            .padding(8)
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
                .foregroundColor(.gray)
                Text(scan.timeSinceCapture)
                    .font(.caption)
                    .foregroundColor(.gray)
                Text(scan.hardwareDeviceModel)
                    .font(.caption2)
                    .foregroundColor(.cyan)

                if let counts = itemCounts {
                    itemCountsText(counts)
                }
            }
            Spacer()
            statusBadge
        }
    }

    @ViewBuilder
    private func itemCountsText(_ counts: (images: Int, proxy: Int, depth: Int, cameras: Int)) -> some View {
        let parts = buildItemCountParts(counts)
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.caption2)
                .foregroundColor(.gray.opacity(0.8))
        }
    }

    private func buildItemCountParts(_ counts: (images: Int, proxy: Int, depth: Int, cameras: Int)) -> [String] {
        var parts: [String] = []
        if counts.images > 0 { parts.append("\(counts.images) images") }
        if counts.proxy > 0 { parts.append("\(counts.proxy) proxy") }
        if counts.depth > 0 { parts.append("\(counts.depth) depth") }
        if counts.cameras > 0 { parts.append("\(counts.cameras) cameras") }
        return parts
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

            if !scan.isColored {
                Button(action: { colorizeScan() }) {
                    HStack {
                        Image(systemName: "paintbrush.fill")
                        Text("Color")
                            .font(.subheadline).bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(isEditing || activeColoringMessage != nil ? Color.gray.opacity(0.3) : Color.orange.opacity(0.8))
                    .foregroundColor(isEditing || activeColoringMessage != nil ? .gray : .white)
                    .cornerRadius(10)
                }
                .disabled(isEditing || activeColoringMessage != nil)
            }
        }
    }

    private var uploadButtonDisabled: Bool {
        isEditing || uploadURL.isEmpty || scan.uploadStatus.isUploading
    }

    @ViewBuilder
    private var statusBadge: some View {
        let status = scan.uploadStatus
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(status.label)
                .font(.caption2)
                .foregroundColor(statusColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.15))
        .cornerRadius(8)
    }

    private var statusColor: Color {
        switch scan.uploadStatus {
        case .pending: return .gray
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
            guard let exportURL = ScanExportManager.prepareExport(filename: filename, scanDir: scanDir, format: format) else {
                DispatchQueue.main.async {
                    self.scan.selectedFormat = self.selectedFormat
                    self.scan.uploadStatus = .failed("Export failed")
                    self.onUpdate(self.scan)
                }
                return
            }

            DispatchQueue.main.async {
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
            if let exportURL = ScanExportManager.prepareExport(filename: filename, scanDir: scanDir, format: format) {
                DispatchQueue.main.async {
                    self.exportItem = ZipExportItem(url: exportURL)
                }
            } else {
                DispatchQueue.main.async {
                    self.scan.uploadStatus = .failed("Export failed")
                    self.onUpdate(self.scan)
                    self.showExportError = true
                }
            }
        }
    }

    private func colorizeScan() {
        coloringMessage = "Coloring…"

        let meshURL = scan.meshFileURL
        let rawDataDir = scan.rawDataPath
        let colorsURL = scan.colorsFileURL
        let previewURL = scan.modelPreviewURL
        let pose = scan.location?.imagingPoseMatrix

        DispatchQueue.global(qos: .utility).async {
            guard let meshData = try? Data(contentsOf: meshURL) else {
                DispatchQueue.main.async {
                    self.coloringMessage = nil
                }
                return
            }

            var lastPct = -1
            let vertexColors = VertexColorAccumulator.colorizeFromSavedFrames(
                objData: meshData,
                rawDataDir: rawDataDir,
                progress: { p in
                    let pct = Int(p * 100)
                    guard pct != lastPct else { return } // throttle to whole-percent changes
                    lastPct = pct
                    DispatchQueue.main.async { self.coloringMessage = "Coloring \(pct)%" }
                }
            )

            DispatchQueue.main.async {
                self.coloringMessage = "Updating preview…"
            }

            // Write updated colors
            if let colors = vertexColors {
                try? colors.write(to: colorsURL)
            }

            // Regenerate 3D model preview
            if let img = MeshPreviewView.generateSnapshot(meshURL: meshURL, colorsURL: colorsURL, poseMatrix: pose),
               let data = img.jpegData(compressionQuality: 0.8) {
                try? data.write(to: previewURL)
            }

            DispatchQueue.main.async {
                self.scan.isColored = true
                self.scan.location?.updatedAt = Date() // Trigger preview image reload
                try? self.modelContext.save()
                self.coloringMessage = nil
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
