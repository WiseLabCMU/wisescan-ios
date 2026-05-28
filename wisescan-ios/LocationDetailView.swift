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
    @State private var showSettings = false
    @State private var newLocationName = ""
    @State private var showRenameAlert = false
    @State private var showNoWorldMapAlert = false
    @State private var hasStitchingLinks = false

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
                                    Text("Rescan Space").tag(ScanCase.rescanSpace)
                                    Text("Link Adjacent Space").tag(ScanCase.linkAdjacent)
                                }
                                .pickerStyle(.segmented)
                                .colorScheme(.dark)
                            }
                        }

                        if !isEditing && !sortedScans.isEmpty {
                            // Linked badge
                            if hasStitchingLinks {
                                HStack(spacing: 6) {
                                    Image(systemName: "link.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Linked to adjacent space")
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
                                        scanStore.activeLocationForScan = location.id
                                        scanStore.activeRelocalizationMap = latestScan.worldMapURL
                                        scanStore.activeScanToExtend = latestScan.id
                                        scanStore.activeScanCase = .rescanSpace
                                        selectedTab = 1
                                    }) {
                                        HStack {
                                            Image(systemName: "plus.viewfinder")
                                            Text("Rescan Space")
                                                .font(.subheadline).bold()
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .background(Color.indigo.opacity(0.8))
                                        .foregroundColor(.white)
                                        .cornerRadius(12)
                                    }

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
                                        selectedTab = 1
                                    }) {
                                        HStack {
                                            Image(systemName: "link.badge.plus")
                                            Text("Link Adjacent")
                                                .font(.subheadline).bold()
                                        }
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .background(Color.orange.opacity(0.8))
                                        .foregroundColor(.white)
                                        .cornerRadius(12)
                                    }
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
            
            if isEditing {
                VStack {
                    Spacer()
                    bottomActionToolbar(sortedScans: location.scans.sorted { $0.capturedAt > $1.capturedAt })
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
                    }) {
                        Text(selectedScans.count == location.scans.count ? "Deselect All" : "Select All")
                            .font(.subheadline)
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    if !location.scans.isEmpty {
                        Button(action: {
                            isEditing.toggle()
                            if !isEditing { selectedScans.removeAll() }
                        }) {
                            Text(isEditing ? "Done" : "Select")
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
        .alert("World Map Missing", isPresented: $showNoWorldMapAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The relocalization world map for this scan is missing. Try rescanning the space first — the world map is required for cross-session alignment.")
        }
        .confirmationDialog(
            "Delete Scans",
            isPresented: $showBulkDeleteConfirm
        ) {
            Button("Delete \(selectedScans.count) Scan\(selectedScans.count == 1 ? "" : "s")", role: .destructive) {
                bulkDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the selected scans and their data.")
        }
        .task {
            // Load stitching link status once asynchronously instead of
            // calling hasLinks() synchronously on every body evaluation.
            hasStitchingLinks = await StitchingMetadataManager.hasLinksAsync(locationId: location.id)
        }
    }

    // MARK: - Bulk Actions

    private func bulkDelete() {
        let scansToDelete = location.scans.filter { selectedScans.contains($0.id) }
        for scan in scansToDelete {
            ScanFileManager.shared.deleteScan(scan, context: modelContext)
        }
        
        selectedScans.removeAll()
        isEditing = false
        
        if location.scans.isEmpty {
            modelContext.delete(location)
            try? modelContext.save()
            dismiss()
        } else {
            try? modelContext.save()
        }
    }

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

    // MARK: - Bottom Action Toolbar
    @ViewBuilder
    private func bottomActionToolbar(sortedScans: [CapturedScan]) -> some View {
        HStack(spacing: 20) {
            Button(action: {
                showBulkDeleteConfirm = true
            }) {
                Image(systemName: "trash")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(selectedScans.isEmpty ? Color.gray.opacity(0.3) : Color.red.opacity(0.8))
                    .foregroundColor(selectedScans.isEmpty ? .gray : .white)
                    .cornerRadius(10)
            }
            .disabled(selectedScans.isEmpty)
            
            Button(action: {
                let scansToUpload = sortedScans.filter { selectedScans.contains($0.id) }
                bulkUpload(scans: scansToUpload)
                isEditing = false
                selectedScans.removeAll()
            }) {
                Text("Upload")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(selectedScans.isEmpty || uploadURL.isEmpty ? Color.gray.opacity(0.3) : Color.blue)
                    .foregroundColor(selectedScans.isEmpty || uploadURL.isEmpty ? .gray : .white)
                    .cornerRadius(10)
            }
            .disabled(selectedScans.isEmpty || uploadURL.isEmpty)
            
            Button(action: {
                let scansToSave = sortedScans.filter { selectedScans.contains($0.id) }
                bulkSaveToFiles(scans: scansToSave)
                isEditing = false
                selectedScans.removeAll()
            }) {
                Text("Save")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(selectedScans.isEmpty || isBulkExporting ? Color.gray.opacity(0.3) : Color.cyan.opacity(0.8))
                    .foregroundColor(selectedScans.isEmpty || isBulkExporting ? .gray : .white)
                    .cornerRadius(10)
            }
            .disabled(selectedScans.isEmpty || isBulkExporting)
        }
        .padding()
        .background(.ultraThinMaterial)
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
    // swiftlint:disable:next force_try
    let container = try! ModelContainer(for: ScanLocation.self, CapturedScan.self, configurations: config)
    let ctx = container.mainContext
    let sampleLocation = ScanLocation(name: "Sample Location")
    ctx.insert(sampleLocation)
    
    let scan1 = CapturedScan(name: "Morning Scan", capturedAt: Date().addingTimeInterval(-3600), vertexCount: 1500, faceCount: 2000)
    let scan2 = CapturedScan(name: "Afternoon Scan", capturedAt: Date().addingTimeInterval(-86400 * 3), vertexCount: 4200, faceCount: 8100)
    let scan3 = CapturedScan(name: "Evening Scan", capturedAt: Date().addingTimeInterval(-86400 * 45), vertexCount: 9800, faceCount: 19200)
    ctx.insert(scan1)
    ctx.insert(scan2)
    ctx.insert(scan3)
    sampleLocation.scans.append(contentsOf: [scan1, scan2, scan3])
    try? ctx.save()

    return LocationDetailView(location: sampleLocation, selectedTab: .constant(2))
        .modelContainer(container)
        .environment(ScanStore())
}
