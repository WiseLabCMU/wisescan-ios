import SwiftUI

struct WorkflowsView: View {
    @Environment(ScanStore.self) private var scanStore
    @AppStorage("uploadURL") private var uploadURL = "https://wiselambda4.lan.cmu.edu/wisescan-uploads/"

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                LinearGradient(colors: [Color(white: 0.1), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {

                        // Captured Scans
                        if scanStore.scans.isEmpty {
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
                            ForEach(Array(scanStore.scans.enumerated()), id: \.element.id) { index, scan in
                                ScanCard(scan: scan, uploadURL: uploadURL) { updatedScan in
                                    scanStore.scans[index] = updatedScan
                                }
                            }
                        }

                        // Workflows List
                        HStack {
                            Text("WORKFLOWS")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                            Spacer()
                        }
                        .padding(.horizontal)

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
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("WORKFLOWS")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Scan Card

struct ScanCard: View {
    var scan: CapturedScan
    var uploadURL: String
    var onUpdate: (CapturedScan) -> Void

    @State private var selectedFormat: ExportFormat

    init(scan: CapturedScan, uploadURL: String, onUpdate: @escaping (CapturedScan) -> Void) {
        self.scan = scan
        self.uploadURL = uploadURL
        self.onUpdate = onUpdate
        self._selectedFormat = State(initialValue: scan.selectedFormat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 3D mesh preview (interactive: rotate/zoom)
            MeshPreviewView(meshData: scan.meshData)
                .frame(height: 200)
                .clipped()

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
                    Picker("Format", selection: $selectedFormat) {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedFormat) { _, newValue in
                        var updated = scan
                        updated.selectedFormat = newValue
                        onUpdate(updated)
                    }
                }

                // Upload button
                Button(action: { uploadScan() }) {
                    HStack {
                        Image(systemName: "icloud.and.arrow.up")
                        Text("Upload \(selectedFormat.rawValue)")
                            .font(.subheadline).bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(scan.uploadStatus == .uploading ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(scan.uploadStatus == .uploading || scan.uploadStatus == .success)
            }
            .padding()
        }
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .padding(.horizontal)
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
        var updated = scan
        updated.uploadStatus = .uploading
        onUpdate(updated)

        let ext = selectedFormat.rawValue.lowercased()
        let filename = "wisescan_\(scan.name.replacingOccurrences(of: " ", with: "_"))_\(scan.id.uuidString.prefix(8)).\(ext)"

        let baseURLString = uploadURL.hasSuffix("/") ? uploadURL : uploadURL + "/"
        guard let url = URL(string: baseURLString + filename) else {
            updated.uploadStatus = .failed("Invalid URL")
            onUpdate(updated)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let task = URLSession.shared.uploadTask(with: request, from: scan.meshData) { _, response, error in
            DispatchQueue.main.async {
                var result = scan
                result.selectedFormat = selectedFormat
                if let error = error {
                    result.uploadStatus = .failed(error.localizedDescription)
                } else if let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) {
                    result.uploadStatus = .success
                } else {
                    result.uploadStatus = .failed("Server error")
                }
                onUpdate(result)
            }
        }
        task.resume()
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
    WorkflowsView()
        .environment(ScanStore())
}
