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

    @AppStorage(AppDefaults.Key.uploadURL) private var uploadURL = AppDefaults.uploadURL

    var body: some View {
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
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 16)

                    // MARK: - Scan Cards
                    let sortedScans = location.scans.sorted { $0.capturedAt > $1.capturedAt }
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
                            ForEach(sortedScans) { scan in
                                ScanCard(
                                    scan: scan,
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
                                    },
                                    onExtend: { scanToExtend in
                                        scanStore.activeLocationForScan = location.id
                                        scanStore.activeRelocalizationMap = scanToExtend.worldMapURL
                                        scanStore.activeScanToExtend = scanToExtend.id
                                        selectedTab = 1 // Switch to Capture Tab
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
