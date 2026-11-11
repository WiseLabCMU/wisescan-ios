import SwiftUI

// MARK: - User Guide: status icon troubleshooting
// What the sync and warning badges on locations and scan cards mean. Like UserGuideView, this
// is documentation that lives in SwiftUI: when a badge's look or rule changes, change its row
// here in the same change set. The rules live in LocationGridTile, ScanCard and CaptureIntegrity
// (ScansListView.swift), CompactLocationTile (StitchGraphView.swift), SyncBadge and SyncLine
// (SyncViews.swift), BundleSync.spaceState and line(for:) (ScanBundle.swift), UploadStatus
// (ScanStore.swift), InterruptedExports.message, and ControlPlaneSync.SpaceState
// (ControlPlaneSpaceSyncButton.swift). Badge symbols and colors, status labels and sync symbols
// are read from those types so the samples cannot drift; only the badge styling is copied.

/// The two troubleshooting sections of the User Guide, placed inside its List.
struct StatusIconsGuideSections: View {
    var body: some View {
        syncSection
        warningSection
    }

    private var syncSection: some View {
        Section {
            syncBadgeRow(.off, title: "No Cloud Badge",
                         text: "This location isn't synced with a lab server: none is set in Settings > " +
                               "Control plane, or the location hasn't been synced yet. Tap Sync to Lab " +
                               "Server in it, or let Settings > Auto sync add it.")
            syncBadgeRow(.map, title: "Outline Cloud: The Map",
                         text: "The lab server has this location's map: names, times, poses, links and the " +
                               "room layout. Some scans' bundles haven't reached it yet. They wait for " +
                               "processing, for Wi-Fi, or for you to select them in Settings > Control plane " +
                               "> Pending bundles. A new scan, or a scan whose files change (recoloring it, " +
                               "say), brings the outline back until its bundle goes up again.")
            syncBadgeRow(.everything, title: "Green Check: Everything",
                         text: "The server holds every scan's bundle, unpacked: photos, depth, meshes, the " +
                               "room layout and the world map.")
            syncBadgeRow(.uploading, title: "Arrow: Sending",
                         text: "A scan's bundle is going up, or the server is unpacking one. It keeps " +
                               "going if you lock the screen or switch apps.")
            syncBadgeRow(.failed, title: "Warning Cloud: A Bundle Failed",
                         text: "A bundle didn't reach the server, or the server couldn't unpack it. The " +
                               "scan card's sync line says why, and Settings > Control plane > Pending " +
                               "bundles has Retry. The app retries a failed upload on its own after a while.")

            syncLineRow("Map only · waiting for Wi-Fi", failed: false,
                        text: "Each scan card in a synced location has a sync line. Map only means the " +
                              "server has the scan's details but not its bundle yet, and the rest says " +
                              "what it waits for: Wi-Fi (Settings > Control plane, Upload data bundles " +
                              "only on Wi-Fi), its turn (waiting to upload), or your choice (not selected, " +
                              "in Pending bundles).")
            syncLineRow("Uploading 42%", failed: false,
                        text: "Its bundle is going up. Preparing its bundle and Coloring for sync come " +
                              "first: a bundle carries the colored mesh, so an uncolored scan is colored " +
                              "before it is sent.")
            syncLineRow("Everything · Nov 11, 2026 at 3:40 PM", failed: false,
                        text: "The server holds this scan's bundle, unpacked at that time.")
            syncLineRow("The server couldn't unpack it: the zip is damaged", failed: true,
                        text: "A sync failed, and the reason follows. Sync failed with a network message " +
                              "or a server error means the upload didn't arrive: check the server in " +
                              "Settings and your connection. The server couldn't unpack it means it " +
                              "arrived but was refused. Retry in Pending bundles sends it again.")

            statusRow(.zipping, fraction: 0.4,
                      text: "Share is building the export. While it runs, the label names the step " +
                            "(Privacy blur, Zipping and so on) and the bar shows its progress. Keep the " +
                            "app open until it finishes: the screen stays on, and closing the app stops " +
                            "the conversion.")
            statusRow(.savedLocally,
                      text: "The export was saved to Files or sent with AirDrop. Share sends files to " +
                            "other apps; it has nothing to do with the cloud badge.")
            statusRow(.failed(InterruptedExports.message),
                      text: "The export did not finish, and the reason follows Failed. Interrupted means " +
                            "the app closed before it finished. Export failed or No scan data means the " +
                            "scan could not be packaged or its files are missing. Tap Share to try again.")

            iconRow(icon: ControlPlaneSync.SpaceState.notSynced.symbol, color: .teal,
                    title: ControlPlaneSync.SpaceState.notSynced.title,
                    text: "With a lab server (control plane) set in Settings, each location has this " +
                          "button. It adds the location to the ones this phone keeps in sync: its map " +
                          "goes first, then each processed scan's bundle.")
            iconRow(icon: ControlPlaneSync.SpaceState.synced.symbol, color: .teal,
                    title: ControlPlaneSync.SpaceState.synced.title,
                    text: "The lab server has this space, and new scans in it sync on their own. Tap " +
                          "to sync right away.")
            iconRow(icon: ControlPlaneSync.SpaceState.failed.symbol, color: .teal,
                    title: ControlPlaneSync.SpaceState.failed.title,
                    text: "The last sync did not reach the lab server. Settings > Control Plane shows " +
                          "why (a wrong password, a server that can't be reached), so fix that there, " +
                          "then tap to retry. Bundles wait for Wi-Fi rather than fail.")
        } header: {
            Text("TROUBLESHOOTING: SYNC AND SHARE")
        } footer: {
            Text("The cloud badge sits in the top-right corner of each location, in the list and in " +
                 "the graph view. Each scan card shows its sync line under its details, and Share's " +
                 "status at its top right while an export runs or after it ends.")
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .listRowBackground(Color.white.opacity(0.05))
    }

    private var warningSection: some View {
        Section {
            badgeRow(icon: "exclamationmark.triangle.fill", color: .yellow, title: "Yellow: Map Problem",
                     text: "On a location, at least one scan's relocalization map is missing or may be " +
                           "unreliable. Rescan Space and Connect Adjacent Space use that map to line up " +
                           "with earlier scans. Open the location and tap the yellow badge on a scan " +
                           "card to see which problem it has.")
            badgeRow(icon: "exclamationmark.triangle.fill", color: .yellow, title: "Missing Data",
                     text: "The scan's relocalization map (arworldmap.map) is missing, so the scan can't " +
                           "be reliably extended or aligned later. If it is the location's latest scan, " +
                           "Rescan Space and Connect Adjacent Space stop with World Map Missing: capture " +
                           "a new scan of the space to make a new map.")
            badgeRow(icon: "exclamationmark.triangle.fill", color: .yellow, title: "Map May Be Unreliable",
                     text: "The device briefly lost track during the scan, and that stray piece was saved " +
                           "into the map. Rescan Space and Connect Adjacent Space warn before using it, " +
                           "and a rescan started from it usually inherits the problem. To clear it, " +
                           "delete the flagged scan so the most recent clean scan becomes the reference. " +
                           "The scan's own data is still usable, and Processing aligns it.")
            badgeRow(icon: "exclamationmark.triangle.fill", color: .orange, title: "Orange: Incomplete Capture",
                     text: "Depth or confidence data was saved for fewer than half of the scan's frames, " +
                           "usually because depth capture dropped out mid-scan. The scan is likely " +
                           "unusable for 3D reconstruction: scan the space again. On a location, it means " +
                           "at least one scan has this problem; tap the badge on a scan card for the " +
                           "counts. Checked only on LiDAR devices, for scans of 4 frames or more.")
        } header: {
            Text("TROUBLESHOOTING: WARNING ICONS")
        } footer: {
            Text("Warning badges sit in the top-left corner of locations and scan cards, and a " +
                 "location's badge sums up every scan in it. The graph view shows only the yellow " +
                 "badge. Focus scans have no map of their own and never show these warnings.")
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .listRowBackground(Color.white.opacity(0.05))
    }
}

// MARK: - Rows

private extension StatusIconsGuideSections {
    /// A location's sync badge, its symbol and color read from `SyncBadge`; no badge for `.off`.
    func syncBadgeRow(_ state: BundleSync.SpaceState, title: String, text: String) -> some View {
        let look = SyncBadge.look(state)
        return badgeRow(icon: look?.symbol, color: look?.color ?? .clear, title: title, text: text)
    }

    /// A corner badge drawn as the location tiles draw it; `icon: nil` is the empty slot (no badge).
    @ViewBuilder
    func badgeRow(icon: String?, color: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundColor(color)
                        .padding(6)
                        .background(Color.black.opacity(0.5))
                        .clipShape(Circle())
                } else {
                    Circle()
                        .strokeBorder(Color.gray.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .frame(width: 24, height: 24)
                }
            }
            .frame(width: 28)
            rowText(title: title, text: text)
        }
        .padding(.vertical, 4)
    }

    /// A scan card's sync line as `SyncLine` draws it, with the explanation under it.
    @ViewBuilder
    func syncLineRow(_ line: String, failed: Bool, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: failed ? "exclamationmark.icloud" : "icloud")
                Text(line).lineLimit(2)
            }
            .font(.caption2)
            .foregroundColor(failed ? .yellow : .green.opacity(0.8))
            Text(text)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(.vertical, 4)
    }

    /// A plain icon row (the User Guide's guideRow, in a chosen color).
    @ViewBuilder
    func iconRow(icon: String, color: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.title3)
                .frame(width: 28)
            rowText(title: title, text: text)
        }
        .padding(.vertical, 4)
    }

    /// A scan card's status label as the card draws it, with the explanation under it.
    @ViewBuilder
    func statusRow(_ status: UploadStatus, fraction: Double? = nil, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(status.tint)
                        .frame(width: 8, height: 8)
                    Text(status.label)
                        .font(.caption2)
                        .foregroundColor(status.tint)
                }
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(status.tint)
                        .frame(height: 2)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: fraction == nil ? nil : 150, alignment: .leading)
            .background(status.tint.opacity(0.15))
            .cornerRadius(8)
            Text(text)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(.vertical, 4)
    }

    func rowText(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .foregroundColor(.white)
                .font(.subheadline).bold()
            Text(text)
                .font(.caption)
                .foregroundColor(.gray)
        }
    }
}

#Preview {
    NavigationStack {
        List { StatusIconsGuideSections() }
            .scrollContentBackground(.hidden)
            .background(Color.black)
    }
}
