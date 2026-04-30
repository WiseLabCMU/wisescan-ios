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
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
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

    var latestScan: CapturedScan? {
        location.scans.sorted(by: { $0.capturedAt > $1.capturedAt }).first
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
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .task(id: latestScan?.id) {
            // Load thumbnail asynchronously to avoid main-thread I/O (#7)
            guard let latest = latestScan else { thumbnailImage = nil; return }
            let url = latest.thumbnailURL
            thumbnailImage = await Task.detached(priority: .utility) {
                guard FileManager.default.fileExists(atPath: url.path),
                      let data = try? Data(contentsOf: url) else { return nil as UIImage? }
                return UIImage(data: data)
            }.value
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
    @State private var exportItem: ZipExportItem? = nil
    @State private var showExportError = false
    @State private var showDeleteConfirm = false
    @State private var itemCounts: (images: Int, proxy: Int, depth: Int, cameras: Int)? = nil

    private var selectedFormat: ExportFormat {
        get { ExportFormat(rawValue: selectedFormatStr) ?? .polycam }
        nonmutating set { selectedFormatStr = newValue.rawValue }
    }

    init(scan: CapturedScan, isLatest: Bool, uploadURL: String, isEditing: Bool, onUpdate: @escaping (CapturedScan) -> Void, onDelete: @escaping (CapturedScan) -> Void) {
        self.scan = scan
        self.isLatest = isLatest
        self.uploadURL = uploadURL
        self.isEditing = isEditing
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Conditionally load the 3D mesh preview for performance
            Group {
                if isLatest {
                    MeshPreviewContainer(meshFileURL: scan.meshFileURL, colorsFileURL: scan.colorsFileURL, scanDirectoryURL: scan.scanDirectory)
                        .frame(height: 200)
                        .clipped()
                } else {
                    AsyncImage(url: scan.thumbnailURL) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(height: 200)
                                .clipped()
                        } else {
                            ZStack {
                                Color.black.opacity(0.3)
                                Image(systemName: "photo")
                                    .font(.largeTitle)
                                    .foregroundColor(.gray.opacity(0.5))
                            }
                            .frame(height: 200)
                        }
                    }
                }
            }
            .overlay(
                    Group {
                        if isEditing {
                            ZStack {
                                Color.black.opacity(0.6)
                                Button(action: { showDeleteConfirm = true }) {
                                    VStack(spacing: 8) {
                                        Image(systemName: "trash.circle.fill")
                                            .font(.system(size: 44))
                                        Text("Delete Scan")
                                            .font(.headline)
                                    }
                                    .foregroundColor(.red)
                                }
                            }
                        }
                    }
                )
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

            VStack(alignment: .leading, spacing: 12) {
                // Scan info
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scan.name)
                            .font(.subheadline).bold()
                            .foregroundColor(.white)
                        HStack(spacing: 12) {
                            Text(String(format: "%.1f MB", scan.estimatedSizeMB))
                            Text("\(formattedCount(scan.faceCount)) polys")
                            Text(scan.timeSinceCapture)
                        }
                        .font(.caption)
                        .foregroundColor(.gray)
                        Text(scan.hardwareDeviceModel)
                            .font(.caption2)
                            .foregroundColor(.cyan)
                        
                        if let counts = itemCounts {
                            Text("\(counts.images) images · \(counts.proxy) proxy · \(counts.depth) depth · \(counts.cameras) cameras")
                                .font(.caption2)
                                .foregroundColor(.gray.opacity(0.8))
                        }
                    }
                    Spacer()
                    statusBadge
                }

                // Action buttons

                    HStack(spacing: 10) {
                        // Save to Files button
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

                        // Upload button
                        Button(action: { uploadScan() }) {
                            HStack {
                                Image(systemName: "icloud.and.arrow.up")
                                Text("Upload")
                                    .font(.subheadline).bold()
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(isEditing || uploadURL.isEmpty || scan.uploadStatus.isUploading ? Color.gray.opacity(0.3) : Color.blue)
                            .foregroundColor(isEditing ? .gray : .white)
                            .cornerRadius(10)
                        }
                        .disabled(isEditing || uploadURL.isEmpty || scan.uploadStatus.isUploading)
                    }
            }
            .padding()
        }
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
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
        .alert("No Data Available", isPresented: $showExportError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The scan data may have been deleted.")
        }
        .task(id: scan.id) {
            let rawDir = scan.rawDataPath
            let fm = FileManager.default
            // Use detached task for I/O to avoid main thread stutter
            itemCounts = await Task.detached(priority: .utility) {
                let iCount = (try? fm.contentsOfDirectory(atPath: rawDir.appendingPathComponent("images").path))?.count ?? 0
                let pCount = (try? fm.contentsOfDirectory(atPath: rawDir.appendingPathComponent("proxy_images").path))?.count ?? 0
                let dCount = (try? fm.contentsOfDirectory(atPath: rawDir.appendingPathComponent("depth").path))?.count ?? 0
                let cCount = (try? fm.contentsOfDirectory(atPath: rawDir.appendingPathComponent("cameras").path))?.count ?? 0
                return (iCount, pCount, dCount, cCount)
            }.value
        }
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
    let sampleLocation = ScanLocation(name: "Sample Location")
    let sampleScan = CapturedScan(name: "Sample Scan 1", vertexCount: 1500, faceCount: 2000)
    sampleLocation.scans.append(sampleScan)
    container.mainContext.insert(sampleLocation)
    
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
