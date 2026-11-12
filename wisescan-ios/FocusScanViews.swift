import SwiftData
import SwiftUI

// MARK: - Focus scan presentation (docs/design/capture-modes.md)

/// A focus scan's stills, upright (they are stored in the sensor's landscape orientation; the
/// capture view is portrait-locked, so upright is `.right`). A grid with the region's summary;
/// tap a still to page through them full screen.
struct FocusScanPhotosView: View {
    let scan: CapturedScan

    @State private var stills: [URL] = []
    @State private var selected: FocusStillItem?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: AppConstants.focusPhotoGridMinCell), spacing: AppConstants.focusPhotoGridSpacing)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                summary
                LazyVGrid(columns: columns, spacing: AppConstants.focusPhotoGridSpacing) {
                    ForEach(stills, id: \.self) { url in
                        Button { selected = FocusStillItem(url: url) } label: {
                            FocusStillThumbnail(url: url, maxPixel: AppConstants.focusPhotoGridMaxPixel)
                                .aspectRatio(AppConstants.focusStillUprightAspect, contentMode: .fill)
                                .clipped()
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(scan.name)
        .task(id: scan.id) {
            let photos = scan.focusCaptureURL.appendingPathComponent("photos")
            stills = await Task.detached(priority: .utility) {
                ((try? FileManager.default.contentsOfDirectory(at: photos, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension.lowercased() == "jpg" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            }.value
        }
        .fullScreenCover(item: $selected) { item in
            FocusStillPager(stills: stills, start: item.url) { selected = nil }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let region = scan.focusRegion {
                Label(region.displayName, systemImage: region.detail.systemImage)
                    .font(.headline)
                Text(String(format: "%@ · %.2f x %.2f x %.2f m", region.detail.title, region.size.x, region.size.y, region.size.z))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
            Text("\(stills.count) photos · \(scan.timeSinceCapture)")
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
            Text("Partial scan: photos of one region, no mesh of its own.")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
        }
        .foregroundColor(.white)
    }
}

/// One still, downsampled and upright.
struct FocusStillThumbnail: View {
    let url: URL
    let maxPixel: CGFloat
    var fit = false
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.06)
            if let image {
                if fit {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: url) {
            guard let loaded = await ThumbnailCache.image(for: url, maxPixel: maxPixel), let cg = loaded.cgImage else { return }
            image = UIImage(cgImage: cg, scale: 1, orientation: .right)
        }
    }
}

/// Full-screen paging through a focus scan's stills.
struct FocusStillPager: View {
    let stills: [URL]
    let start: URL
    let onDone: () -> Void
    @State private var current: URL?

    var body: some View {
        NavigationView {
            TabView(selection: $current) {
                ForEach(stills, id: \.self) { url in
                    FocusStillThumbnail(url: url, maxPixel: AppConstants.focusPhotoPagerMaxPixel, fit: true)
                        .tag(Optional(url))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(current.map { $0.deletingPathExtension().lastPathComponent } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Done", action: onDone) }
            }
        }
        .onAppear { current = start }
    }
}

/// A still to open full screen (fullScreenCover needs an Identifiable item).
struct FocusStillItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

#Preview("Focus scan photos (empty folder)") {
    let container = try! ModelContainer(for: ScanLocation.self, CapturedScan.self, StitchLink.self,
                                        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let scan = CapturedScan(name: "Focus 1", vertexCount: 0, faceCount: 0)
    scan.scanKind = .focus
    scan.focusRegion = FocusRegion(center: .zero, size: SIMD3(1.2, 0.5, 0.8), label: "work table", detail: .check)
    container.mainContext.insert(scan)
    return NavigationView { FocusScanPhotosView(scan: scan) }
        .modelContainer(container)
}
