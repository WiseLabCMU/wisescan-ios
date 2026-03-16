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

    var latestScan: CapturedScan? {
        location.scans.sorted(by: { $0.capturedAt > $1.capturedAt }).first
    }

    var thumbnailImage: UIImage? {
        guard let latest = latestScan else { return nil }
        let thumbURL = latest.thumbnailURL
        if FileManager.default.fileExists(atPath: thumbURL.path),
           let data = try? Data(contentsOf: thumbURL) {
            return UIImage(data: data)
        }
        return nil
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
    var uploadURL: String
    var isEditing: Bool
    var onUpdate: (CapturedScan) -> Void
    var onDelete: (CapturedScan) -> Void

    @AppStorage(AppDefaults.Key.selectedExportFormat) private var selectedFormatStr: String = AppDefaults.selectedExportFormat
    @State private var exportItem: ZipExportItem? = nil
    @State private var showExportError = false
    @State private var showDeleteConfirm = false

    private var selectedFormat: ExportFormat {
        get { ExportFormat(rawValue: selectedFormatStr) ?? .polycam }
        nonmutating set { selectedFormatStr = newValue.rawValue }
    }

    init(scan: CapturedScan, uploadURL: String, isEditing: Bool, onUpdate: @escaping (CapturedScan) -> Void, onDelete: @escaping (CapturedScan) -> Void) {
        self.scan = scan
        self.uploadURL = uploadURL
        self.isEditing = isEditing
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 3D mesh preview (interactive: rotate/zoom)
            MeshPreviewView(meshFileURL: scan.meshFileURL, colorsFileURL: scan.colorsFileURL)
                .frame(height: 200)
                .clipped()
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
                    }
                    Spacer()
                    statusBadge
                }

                // Format picker
                HStack {
                    Text("Export Format")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Spacer()
                    Picker("Format", selection: $selectedFormatStr) {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Text(format.rawValue).tag(format.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(.cyan)
                    .disabled(isEditing)
                    .onChange(of: selectedFormatStr) { _, newValue in
                        scan.selectedFormat = ExportFormat(rawValue: newValue) ?? .scan4d
                        onUpdate(scan)
                    }
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
                        .background(isEditing || scan.uploadStatus.isUploading ? Color.gray.opacity(0.3) : Color.blue)
                        .foregroundColor(isEditing ? .gray : .white)
                        .cornerRadius(10)
                    }
                    .disabled(isEditing || scan.uploadStatus.isUploading)
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
        scan.uploadStatus = .zipping
        onUpdate(scan)

        let locationName = scan.location?.name.replacingOccurrences(of: " ", with: "_") ?? "Unknown_Location"
        let scanName = scan.name.replacingOccurrences(of: " ", with: "_")
        let formatStr = selectedFormat.rawValue.lowercased()
        
        let timestamp = Int(scan.capturedAt.timeIntervalSince1970)
        let filename = "scan4d_\(locationName)_\(scanName)_\(formatStr)_\(timestamp)_\(scan.id.uuidString.prefix(8)).zip"

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
            guard let zipURL = self.prepareZip(filename: filename, scanDir: scanDir, formatStr: formatStr) else {
                DispatchQueue.main.async {
                    self.scan.selectedFormat = self.selectedFormat
                    self.scan.uploadStatus = .failed("Zip failed")
                    self.onUpdate(self.scan)
                }
                return
            }
            
            DispatchQueue.main.async {
                self.scan.uploadStatus = .uploading(progress: 0.0)
                self.onUpdate(self.scan)
            }

            // Upload the ZIP natively via streaming
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/zip", forHTTPHeaderField: "Content-Type")

            // Track upload progress using KVO
            // Use a reference type to hold the observer so we don't mutate a captured var in a sendable closure
            class ObserverBox { var observer: NSKeyValueObservation? }
            let box = ObserverBox()
            
            let task = URLSession.shared.uploadTask(with: request, fromFile: zipURL) { _, response, uploadError in
                // Explicitly capture the box so the observer lives until the task completes
                _ = box
                
                try? FileManager.default.removeItem(at: zipURL)
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

        let locationName = scan.location?.name.replacingOccurrences(of: " ", with: "_") ?? "Unknown_Location"
        let scanName = scan.name.replacingOccurrences(of: " ", with: "_")
        let formatStr = selectedFormat.rawValue.lowercased()
        
        let timestamp = Int(scan.capturedAt.timeIntervalSince1970)
        let filename = "scan4d_\(locationName)_\(scanName)_\(formatStr)_\(timestamp)_\(scan.id.uuidString.prefix(8)).zip"

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
            if let zipURL = self.prepareZip(filename: filename, scanDir: scanDir, formatStr: formatStr) {
                DispatchQueue.main.async {
                    self.exportItem = ZipExportItem(url: zipURL)
                    
                    // We don't mark as Saved Locally here anymore.
                    // The ShareSheet completion handler will do it.
                }
            } else {
                DispatchQueue.main.async {
                    self.scan.uploadStatus = .failed("Zip failed")
                    self.onUpdate(self.scan)
                    self.showExportError = true
                }
            }
        }
    }

    private func prepareZip(filename: String, scanDir: URL, formatStr: String) -> URL? {
        // Inject the selected export format into scan4d_metadata.json if it exists
        // Check raw_data/ first (where FrameCaptureSession writes it), then scanDir root
        let rawDataDir = scanDir.appendingPathComponent("raw_data")
        let metadataCandidates = [
            rawDataDir.appendingPathComponent("scan4d_metadata.json"),
            scanDir.appendingPathComponent("scan4d_metadata.json")
        ]
        
        var selectedMetadataURL: URL? = nil
        for metadataURL in metadataCandidates {
            if let data = try? Data(contentsOf: metadataURL),
               var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json["export_format"] = formatStr
                if let newData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
                    try? newData.write(to: metadataURL)
                }
                selectedMetadataURL = metadataURL
                break
            }
        }

        let fm = FileManager.default
        let zipURL = fm.temporaryDirectory.appendingPathComponent(filename)
        try? fm.removeItem(at: zipURL) // clean up existing

        // Create staging directory
        let stagingID = UUID().uuidString
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("staging_\(stagingID)")
        try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true, attributes: nil)
        
        // Clean up staging dir when function returns (whether success or fail)
        defer {
            try? fm.removeItem(at: stagingDir)
        }
        
        // 1. Universal Base Payload
        if let metadataPath = selectedMetadataURL {
            try? fm.copyItem(at: metadataPath, to: stagingDir.appendingPathComponent("scan4d_metadata.json"))
        }
        try? fm.copyItem(at: scanDir.appendingPathComponent("mesh.obj"), to: stagingDir.appendingPathComponent("mesh.obj"))
        try? fm.copyItem(at: scanDir.appendingPathComponent("colors.bin"), to: stagingDir.appendingPathComponent("colors.bin"))
        try? fm.copyItem(at: scanDir.appendingPathComponent("arworldmap.map"), to: stagingDir.appendingPathComponent("relocalization.worldmap"))
        
        // 2. Format-Specific Addbacks
        // Both Polycam and others include images and depth
        try? fm.copyItem(at: rawDataDir.appendingPathComponent("images"), to: stagingDir.appendingPathComponent("images"))
        try? fm.copyItem(at: rawDataDir.appendingPathComponent("depth"), to: stagingDir.appendingPathComponent("depth"))
        
        if formatStr == "polycam" {
            try? fm.copyItem(at: rawDataDir.appendingPathComponent("cameras"), to: stagingDir.appendingPathComponent("cameras"))
            try? fm.copyItem(at: rawDataDir.appendingPathComponent("mesh_info.json"), to: stagingDir.appendingPathComponent("mesh_info.json"))
        } else {
            // RAW, OBJ, PLY, USDZ all use transforms.json
            try? fm.copyItem(at: rawDataDir.appendingPathComponent("transforms.json"), to: stagingDir.appendingPathComponent("transforms.json"))
        }

        // Zip the properly structured staging directory
        var error: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: stagingDir, options: .forUploading, error: &error) { zipTempURL in
            try? fm.copyItem(at: zipTempURL, to: zipURL)
        }

        if let zipAttr = try? fm.attributesOfItem(atPath: zipURL.path),
           let zipSize = zipAttr[.size] as? Int64 {
            print("[prepareZip] zipSize=\(zipSize) bytes error=\(error?.localizedDescription ?? "none")")
        } else {
            print("[prepareZip] error=\(error?.localizedDescription ?? "none") zipExists=\(fm.fileExists(atPath: zipURL.path))")
        }
        return error == nil ? zipURL : nil
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
    return ScanCard(
        scan: sampleScan,
        uploadURL: "https://example.com/upload",
        isEditing: false,
        onUpdate: { _ in },
        onDelete: { _ in }
    )
    .padding()
    .background(Color.black)
}
