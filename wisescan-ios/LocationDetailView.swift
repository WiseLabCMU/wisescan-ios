import SwiftUI
import SwiftData

struct LocationDetailView: View {
    let location: ScanLocation
    @Environment(\.modelContext) private var modelContext
    @Environment(ScanStore.self) private var scanStore
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedTab: Int // Pass through to allow "Extend Scan" to switch tabs
    @State private var isEditing = false
    @State private var showSettings = false
    @State private var newLocationName = ""
    @State private var showRenameAlert = false

    @AppStorage(AppConstants.Key.uploadURL) private var uploadURL = AppConstants.uploadURL
    @AppStorage(AppConstants.Key.selectedExportFormat) private var globalSelectedFormatStr: String = AppConstants.selectedExportFormat
    @State private var isBulkExporting = false
    @State private var exportItems: [ZipExportItem] = []
    @State private var showExportSheet = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            LinearGradient(colors: [Color(white: 0.1), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            ScrollView {
                let sortedScans = location.scans.sorted { $0.capturedAt > $1.capturedAt }
                VStack(spacing: 24) {
                    // MARK: - Header Actions
                    VStack(spacing: 16) {
                        // Rename Button (edit mode only)
                        if isEditing {
                            VStack(spacing: 12) {
                                Button(action: {
                                    newLocationName = location.name
                                    showRenameAlert = true
                                }) {
                                    HStack {
                                        Image(systemName: "pencil")
                                        Text("Rename Location")
                                    }
                                    .font(.subheadline)
                                    .foregroundColor(.orange)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.orange.opacity(0.1))
                                    .cornerRadius(12)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                                    )
                                }

                                Picker("Use Case", selection: Binding(
                                    get: { location.scanCase },
                                    set: { newValue in
                                        location.scanCase = newValue
                                        try? modelContext.save()
                                    }
                                )) {
                                    Text("Time-Series").tag(ScanCase.rescan)
                                    Text("Space Extension").tag(ScanCase.extend)
                                }
                                .pickerStyle(.segmented)
                                .colorScheme(.dark)
                            }
                        }

                        if !isEditing && !sortedScans.isEmpty {
                            // Extend Latest Scan
                            if let latestScan = sortedScans.first,
                               !latestScan.hardwareDeviceModel.localizedCaseInsensitiveContains("ray ban") &&
                               !latestScan.hardwareDeviceModel.localizedCaseInsensitiveContains("glass") {
                                Button(action: {
                                    scanStore.activeLocationForScan = location.id
                                    scanStore.activeRelocalizationMap = latestScan.worldMapURL
                                    scanStore.activeScanToExtend = latestScan.id
                                    selectedTab = 1 // Switch to Capture Tab
                                }) {
                                    HStack {
                                        Image(systemName: "plus.viewfinder")
                                        Text(location.scanCase == .rescan ? "Rescan Location" : "Extend Latest Scan")
                                            .font(.headline)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color.indigo.opacity(0.8))
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
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
                                        ForEach(ExportFormat.allCases, id: \.self) { format in
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

                                HStack(spacing: 10) {
                                    Button(action: { bulkSaveToFiles(scans: sortedScans) }) {
                                        HStack {
                                            if isBulkExporting {
                                                ProgressView().tint(.white)
                                            } else {
                                                Image(systemName: "square.and.arrow.down.on.square")
                                            }
                                            Text("Save All")
                                                .font(.subheadline).bold()
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(isBulkExporting ? Color.gray : Color.cyan.opacity(0.8))
                                        .foregroundColor(.white)
                                        .cornerRadius(10)
                                    }
                                    .disabled(isBulkExporting)

                                    Button(action: { bulkUpload(scans: sortedScans) }) {
                                        HStack {
                                            Image(systemName: "icloud.and.arrow.up")
                                            Text("Upload All")
                                                .font(.subheadline).bold()
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(uploadURL.isEmpty ? Color.gray.opacity(0.3) : Color.blue)
                                        .foregroundColor(uploadURL.isEmpty ? .gray : .white)
                                        .cornerRadius(10)
                                    }
                                    .disabled(uploadURL.isEmpty)
                                }
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
                                    onUpdate: { _ in try? modelContext.save() },
                                    onDelete: { scanToDelete in
                                        ScanFileManager.shared.deleteScan(scanToDelete, context: modelContext)
                                        // Auto-delete location if no scans remain
                                        if location.scans.isEmpty {
                                            modelContext.delete(location)
                                            try? modelContext.save()
                                            dismiss()
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
                                description: "Fast photogrammetry pipeline optimized for immediate preview. Lower resolution textures.",
                                time: "~5 mins",
                                buttonText: "Run Workflow",
                                isPrimary: true,
                                isDisabled: true
                            )

                            WorkflowCard(
                                icon: "camera.macro",
                                title: "Gaussian Splat",
                                description: "High-fidelity radiance field reconstruction for photo-realistic novel view synthesis.",
                                time: "~25 mins",
                                buttonText: "Run Workflow",
                                isDisabled: true
                            )

                            WorkflowCard(
                                icon: "map.fill",
                                title: "Spatial Indexing",
                                description: "OpenFLAME spatial indexing with automatic semantic labelling. Identifies and tags objects, surfaces, and regions for spatial queries and AR anchoring.",
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
        }
        .navigationTitle(location.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    if !location.scans.isEmpty {
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
                if !newLocationName.isEmpty {
                    location.name = newLocationName
                    try? modelContext.save()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Bulk Actions

    private func bulkSaveToFiles(scans: [CapturedScan]) {
        guard !scans.isEmpty else { return }
        isBulkExporting = true
        let format = ExportFormat(rawValue: globalSelectedFormatStr) ?? .scan4d

        DispatchQueue.global(qos: .userInitiated).async {
            var urls: [ZipExportItem] = []
            for scan in scans {
                DispatchQueue.main.async { scan.uploadStatus = .zipping }
                let filename = scan.makeExportFilename(format: format)
                if let url = ScanExportManager.prepareExport(filename: filename, scanDir: scan.scanDirectory, format: format) {
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

    private func bulkUpload(scans: [CapturedScan]) {
        guard !scans.isEmpty, !uploadURL.isEmpty else { return }
        let format = ExportFormat(rawValue: globalSelectedFormatStr) ?? .scan4d
        let baseURLString = uploadURL.hasSuffix("/") ? uploadURL : uploadURL + "/"

        // Process each scan concurrently to save time, but cap it?
        // Let's just spawn an async task for each one
        for scan in scans {
            guard let url = URL(string: baseURLString + scan.makeExportFilename(format: format)) else { continue }
            scan.uploadStatus = .zipping

            DispatchQueue.global(qos: .userInitiated).async {
                let filename = scan.makeExportFilename(format: format)
                guard let exportURL = ScanExportManager.prepareExport(filename: filename, scanDir: scan.scanDirectory, format: format) else {
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
                        } else if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                            scan.uploadStatus = .success
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

                    Button(action: {}) {
                        Text(buttonText)
                            .font(.caption).bold()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isDisabled ? Color.gray.opacity(0.3) : (isPrimary ? Color.blue : Color.white.opacity(0.2)))
                            .foregroundColor(isDisabled ? .gray : .white)
                            .cornerRadius(8)
                    }
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
    let container = try! ModelContainer(for: ScanLocation.self, CapturedScan.self, configurations: config)
    let sampleLocation = ScanLocation(name: "Sample Location")
    let sampleScan = CapturedScan(name: "Sample Scan 1", vertexCount: 1500, faceCount: 2000)
    sampleLocation.scans.append(sampleScan)
    container.mainContext.insert(sampleLocation)

    return LocationDetailView(location: sampleLocation, selectedTab: .constant(2))
        .modelContainer(container)
        .environment(ScanStore())
}
