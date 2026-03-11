import SwiftUI
import SwiftData

struct WorkflowsView: View {
    @Environment(ScanStore.self) private var scanStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScanLocation.name) private var locations: [ScanLocation]

    @AppStorage("uploadURL") private var uploadURL = "https://wiselambda4.lan.cmu.edu/wisescan-uploads/"
    @State private var showSettings = false
    @State private var locationToDelete: ScanLocation? = nil
    @State private var showDeleteLocationConfirm = false
    @State private var isEditing = false
    @Binding var selectedTab: Int

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                LinearGradient(colors: [Color(white: 0.1), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {

                        // Captured Scans
                        if locations.allSatisfy({ $0.scans.isEmpty }) {
                            VStack(spacing: 16) {
                                Image(systemName: "viewfinder")
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
                            .padding(.vertical, 40)
                        } else {
                            ForEach(locations) { location in
                                if !location.scans.isEmpty {
                                    VStack(alignment: .leading, spacing: 16) {
                                        HStack {
                                            Text(location.name.uppercased())
                                                .font(.caption).bold()
                                                .foregroundColor(.gray)
                                            Spacer()

                                            // Delete Location Action (Only visible in Edit Mode)
                                            if isEditing {
                                                Button(role: .destructive, action: {
                                                    locationToDelete = location
                                                    showDeleteLocationConfirm = true
                                                }) {
                                                    Image(systemName: "trash")
                                                        .foregroundColor(.red)
                                                }
                                                .padding(.trailing, 8)
                                                .confirmationDialog(
                                                    "Delete Location",
                                                    isPresented: $showDeleteLocationConfirm,
                                                    presenting: locationToDelete
                                                ) { locToDelete in
                                                    // Ensure we only process if it matches the current row
                                                    if locToDelete == location {
                                                        Button("Delete \(locToDelete.scans.count) Scan\(locToDelete.scans.count == 1 ? "" : "s")", role: .destructive) {
                                                            deleteLocation(locToDelete)
                                                            locationToDelete = nil
                                                        }
                                                        Button("Cancel", role: .cancel) {
                                                            locationToDelete = nil
                                                        }
                                                    }
                                                } message: { locToDelete in
                                                    Text("This will permanently delete \"\(locToDelete.name)\" and all \(locToDelete.scans.count) scan\(locToDelete.scans.count == 1 ? "" : "s") inside it.")
                                                }
                                            }

                                            // Scan4D action: initiate a new scan for this location
                                            Button(action: {
                                                scanStore.activeLocationForScan = location.id
                                                // Grab the most recent world map for this location if available
                                                let sortedScans = location.scans.sorted { $0.capturedAt > $1.capturedAt }
                                                scanStore.activeRelocalizationMap = sortedScans.first?.worldMapURL
                                                selectedTab = 1 // Switch to Capture View
                                            }) {
                                                Label("Scan Again", systemImage: "plus.viewfinder")
                                                    .font(.caption).bold()
                                                    .foregroundColor(.cyan)
                                            }
                                        }
                                        .padding(.horizontal)
                                        .padding(.top, 8)

                                        let sortedScans = location.scans.sorted { $0.capturedAt > $1.capturedAt }
                                        ForEach(sortedScans) { scan in
                                            ScanCard(scan: scan, uploadURL: uploadURL, isEditing: isEditing) { updatedScan in
                                                // trigger UI update not strictly needed for SwiftData Model observation if nested right,
                                                // but we can save context just in case.
                                                try? modelContext.save()
                                            } onDelete: { scanToDelete in
                                                ScanFileManager.shared.deleteScan(scanToDelete, context: modelContext)
                                            }
                                        }
                                    }
                                    .padding(.bottom, 16)
                                }
                            }
                        }

                        // Workflows — not yet implemented
                        VStack(spacing: 12) {
                            Image(systemName: "hammer.fill")
                                .font(.title2)
                                .foregroundColor(.gray)
                            Text("Server Workflows Coming Soon")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                            Text("Automated processing pipelines (Quick Mesh, Gaussian Splat, Spatial Indexing) will appear here once server orchestration is connected.")
                                .font(.caption)
                                .foregroundColor(.gray.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .padding(.horizontal)

                        /*
                        VStack(spacing: 16) {
                            WorkflowCard(
                                icon: "icloud.and.arrow.up",
                                title: "STATIC UPLOAD",
                                description: "Upload scan directly to storage. No processing pipeline, just raw file storage at your configured URL.",
                                time: "~1m",
                                buttonText: "Upload Raw",
                                isPrimary: false
                            )
                            WorkflowCard(
                                icon: "bolt.fill",
                                title: "QUICK MESH",
                                description: "Fast processing for low-poly mesh & textures. Ideal for preview, AR, game assets.",
                                time: "~5m",
                                buttonText: "Start Quick Mesh"
                            )
                            WorkflowCard(
                                icon: "sparkles",
                                title: "HIGH-QUALITY SPLAT",
                                description: "Maximum density 3D Gaussian splat. Photorealistic detail, radiance fields, cinematic export.",
                                time: "~15m",
                                buttonText: "Process Splat",
                                isPrimary: true
                            )
                            WorkflowCard(
                                icon: "arkit",
                                title: "SPATIAL INDEXING",
                                description: "Optimized index for large environments. Efficient retrieval, spatial queries, cloud storage.",
                                time: "~10m",
                                buttonText: "Index Space"
                            )
                        }
                        .padding(.horizontal)
                        */
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("WORKFLOWS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button(action: { isEditing.toggle() }) {
                            Text(isEditing ? "Done" : "Edit")
                                .bold(isEditing)
                                .foregroundColor(isEditing ? .red : .cyan)
                        }
                        Button(action: { showSettings = true }) {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .preferredColorScheme(.dark)
        }
    }

    private func deleteLocation(_ loc: ScanLocation) {
        // Find all scans first to delete files
        for scan in loc.scans {
            ScanFileManager.shared.deleteScan(scan, context: modelContext)
        }
        modelContext.delete(loc)
        try? modelContext.save()
    }
}

// MARK: - Scan Card

struct ScanCard: View {
    @Bindable var scan: CapturedScan
    var uploadURL: String
    var isEditing: Bool
    var onUpdate: (CapturedScan) -> Void
    var onDelete: (CapturedScan) -> Void

    @AppStorage("selectedExportFormat") private var selectedFormatStr: String = ExportFormat.polycam.rawValue
    @State private var showShareSheet = false
    @State private var exportFileURL: URL? = nil
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Export Format")
                        .font(.caption)
                        .foregroundColor(.gray)
                    Picker("Format", selection: $selectedFormatStr) {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Text(format.rawValue).tag(format.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedFormatStr) { _, newValue in
                        scan.selectedFormat = ExportFormat(rawValue: newValue) ?? .polycam
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
                        .background(Color.cyan.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }

                    // Upload button
                    Button(action: { uploadScan() }) {
                        HStack {
                            Image(systemName: "icloud.and.arrow.up")
                            Text("Upload")
                                .font(.subheadline).bold()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(scan.uploadStatus.isUploading ? Color.gray : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(scan.uploadStatus.isUploading || scan.uploadStatus.isSuccess)
                }
            }
            .padding()
        }
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .padding(.horizontal)
        .sheet(isPresented: $showShareSheet) {
            if let fileURL = exportFileURL {
                ShareSheet(activityItems: [fileURL])
            }
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
        scan.uploadStatus = .uploading(progress: 0.0)
        onUpdate(scan)


        let scanName = scan.name.replacingOccurrences(of: " ", with: "_")
        let formatStr = selectedFormat.rawValue.lowercased()
        let filename = "scan4d_\(formatStr)_\(scanName)_\(scan.id.uuidString.prefix(8)).zip"

        let baseURLString = uploadURL.hasSuffix("/") ? uploadURL : uploadURL + "/"
        guard let url = URL(string: baseURLString + filename) else {
            scan.uploadStatus = .failed("Invalid URL")
            onUpdate(scan)
            return
        }

        let rawPath = scan.rawDataPath
        guard FileManager.default.fileExists(atPath: rawPath.path) else {
            scan.uploadStatus = .failed("No raw data")
            onUpdate(scan)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let zipURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(filename)

            // Inject the selected format into scan4d_metadata.json before zipping
            let metadataURL = rawPath.appendingPathComponent("scan4d_metadata.json")
            if let data = try? Data(contentsOf: metadataURL),
               var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json["export_format"] = formatStr
                if let newData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
                    try? newData.write(to: metadataURL)
                }
            }

            // Use NSFileCoordinator to create a ZIP
            var error: NSError?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: rawPath, options: .forUploading, error: &error) { zipTempURL in
                try? FileManager.default.copyItem(at: zipTempURL, to: zipURL)
            }

            guard error == nil else {
                DispatchQueue.main.async {
                    scan.selectedFormat = selectedFormat
                    scan.uploadStatus = .failed("Zip failed")
                    onUpdate(scan)
                }
                return
            }

            // Upload the ZIP natively via streaming
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/zip", forHTTPHeaderField: "Content-Type")

            let task = URLSession.shared.uploadTask(with: request, fromFile: zipURL) { _, response, uploadError in
                try? FileManager.default.removeItem(at: zipURL)
                DispatchQueue.main.async {
                    scan.selectedFormat = selectedFormat
                    if let uploadError = uploadError {
                        scan.uploadStatus = .failed(uploadError.localizedDescription)
                    } else if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                        scan.uploadStatus = .success
                    } else {
                        scan.uploadStatus = .failed("Server error")
                    }
                    onUpdate(scan)
                }
            }
            task.resume()
        }
    }

    private func saveToFiles() {
        let scanName = scan.name.replacingOccurrences(of: " ", with: "_")
        let formatStr = selectedFormat.rawValue.lowercased()
        let filename = "scan4d_\(formatStr)_\(scanName)_\(scan.id.uuidString.prefix(8)).zip"

        let rawPath = scan.rawDataPath
        guard FileManager.default.fileExists(atPath: rawPath.path) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let zipURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: zipURL) // clean up existing

            // Inject the selected format into scan4d_metadata.json before zipping
            let metadataURL = rawPath.appendingPathComponent("scan4d_metadata.json")
            if let data = try? Data(contentsOf: metadataURL),
               var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                json["export_format"] = formatStr
                if let newData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
                    try? newData.write(to: metadataURL)
                }
            }

            var error: NSError?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: rawPath, options: .forUploading, error: &error) { zipTempURL in
                try? FileManager.default.copyItem(at: zipTempURL, to: zipURL)
            }

            if error == nil {
                DispatchQueue.main.async {
                    self.exportFileURL = zipURL
                    self.showShareSheet = true
                }
            }
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Workflow Card

struct WorkflowCard: View {
    var icon: String
    var title: String
    var description: String
    var time: String
    var buttonText: String
    var isPrimary: Bool = false

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

                    Button(action: {}) {
                        Text(buttonText)
                            .font(.caption).bold()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isPrimary ? Color.blue : Color.white.opacity(0.2))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
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
    }
}

#Preview {
    WorkflowsView(selectedTab: .constant(2))
        .environment(ScanStore())
}
