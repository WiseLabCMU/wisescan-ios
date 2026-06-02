import SwiftUI
import SwiftData

struct ScansListView: View {
    @Environment(ScanStore.self) private var scanStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScanLocation.updatedAt, order: .reverse) private var locations: [ScanLocation]

    @State private var showSettings = false
    @State private var locationToDelete: ScanLocation? = nil
    @State private var showDeleteLocationConfirm = false
    @State private var isEditing = false
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

                ScrollView {
                    if locations.isEmpty {
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
                    } else {
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
                                        Button(action: {
                                            locationToDelete = location
                                            showDeleteLocationConfirm = true
                                        }) {
                                            Image(systemName: "minus.circle.fill")
                                                .font(.title2)
                                                .foregroundColor(.red)
                                                .background(Circle().fill(Color.white).padding(4))
                                        }
                                        .offset(x: 8, y: -8)
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("SCANS")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ScanLocation.self) { loc in
                LocationDetailView(location: loc, selectedTab: $selectedTab)
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if !locations.isEmpty {
                        Button(action: { isEditing.toggle() }) {
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
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .confirmationDialog(
                "Delete Location",
                isPresented: $showDeleteLocationConfirm,
                presenting: locationToDelete
            ) { locToDelete in
                Button("Delete \(locToDelete.scans.count) Scan\(locToDelete.scans.count == 1 ? "" : "s")", role: .destructive) {
                    deleteLocation(locToDelete)
                    locationToDelete = nil
                    if locations.isEmpty { isEditing = false }
                }
                Button("Cancel", role: .cancel) { locationToDelete = nil }
            } message: { locToDelete in
                Text("This will permanently delete \"\(locToDelete.name)\" and all scans inside it.")
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

    private func deleteLocation(_ loc: ScanLocation) {
        for scan in loc.scans {
            ScanFileManager.shared.deleteScan(scan, context: modelContext)
        }
        modelContext.delete(loc)
        try? modelContext.save()
    }
}

// MARK: - Location Grid Tile

struct LocationGridTile: View {
    let location: ScanLocation
    @State private var thumbnailImage: UIImage? = nil
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
    @State private var exportItem: ZipExportItem? = nil
    @State private var showExportError = false
    @State private var showDeleteConfirm = false
    @State private var itemCounts: (images: Int, proxy: Int, depth: Int, cameras: Int)? = nil
    @State private var showMeshPreview = false
    @State private var showMissingRelocAlert = false
    @State private var isColoring = false
    @State private var coloringMessage: String? = nil
    // Disk-derived values resolved off the main thread in `.task` (see below) so the
    // view body never performs synchronous FileManager I/O during layout/scroll.
    @State private var previewImage: UIImage? = nil
    @State private var isRelocMissing = false
    @State private var sizeMB: Double = 0

    private var selectedFormat: ExportFormat {
        get { ExportFormat(rawValue: selectedFormatStr) ?? .polycam }
        nonmutating set { selectedFormatStr = newValue.rawValue }
    }

    var isSelected: Bool = false
    var onSelect: (() -> Void)? = nil

    init(scan: CapturedScan, isLatest: Bool, uploadURL: String, isEditing: Bool, isSelected: Bool = false, onUpdate: @escaping (CapturedScan) -> Void, onDelete: @escaping (CapturedScan) -> Void, onSelect: (() -> Void)? = nil) {
        self.scan = scan
        self.isLatest = isLatest
        self.uploadURL = uploadURL
        self.isEditing = isEditing
        self.isSelected = isSelected
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
            ShareSheet(activityItems: [item.url]) { activityType, completed, returnedItems, activityError in
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
            if isColoring {
                ZStack {
                    Color.black.opacity(0.5)
                    VStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.2)
                        Text(coloringMessage ?? "Coloring...")
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
                    .background(isEditing || isColoring ? Color.gray.opacity(0.3) : Color.orange.opacity(0.8))
                    .foregroundColor(isEditing || isColoring ? .gray : .white)
                    .cornerRadius(10)
                }
                .disabled(isEditing || isColoring)
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
        case .uploading(_): return .blue
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
        isColoring = true
        coloringMessage = "Coloring..."

        let meshURL = scan.meshFileURL
        let rawDataDir = scan.rawDataPath
        let colorsURL = scan.colorsFileURL
        let previewURL = scan.modelPreviewURL
        let pose = scan.location?.imagingPoseMatrix

        DispatchQueue.global(qos: .utility).async {
            guard let meshData = try? Data(contentsOf: meshURL) else {
                DispatchQueue.main.async {
                    self.isColoring = false
                    self.coloringMessage = nil
                }
                return
            }

            let vertexColors = VertexColorAccumulator.colorizeFromSavedFrames(
                objData: meshData,
                rawDataDir: rawDataDir
            )

            DispatchQueue.main.async {
                self.coloringMessage = "Updating preview..."
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
                self.isColoring = false
                self.coloringMessage = nil
            }
        }
    }


}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    var completion: UIActivityViewController.CompletionWithItemsHandler? = nil

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
