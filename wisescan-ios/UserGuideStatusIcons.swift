import SwiftUI

// MARK: - User Guide: status icon troubleshooting
// What the upload and warning badges on locations and scan cards mean. Like UserGuideView, this
// is documentation that lives in SwiftUI: when a badge's look or rule changes, change its row
// here in the same change set. The rules live in LocationGridTile, ScanCard and CaptureIntegrity
// (ScansListView.swift), CompactLocationTile (StitchGraphView.swift), UploadStatus
// (ScanStore.swift), ExportUploader.interruptedMessage, and ControlPlaneSync.SpaceState
// (ControlPlaneSpaceSyncButton.swift). Status labels, colors and sync symbols are read from those
// types so the samples cannot drift; only the badge styling is copied.

/// The two troubleshooting sections of the User Guide, placed inside its List.
struct StatusIconsGuideSections: View {
    var body: some View {
        uploadSection
        warningSection
    }

    private var uploadSection: some View {
        Section {
            badgeRow(icon: nil, color: .clear, title: "No Cloud Badge",
                     text: "No scan in this location has been uploaded yet.")
            badgeRow(icon: "checkmark.icloud.fill", color: .green.opacity(0.4), title: "Dimmed Cloud Badge",
                     text: "Some of this location's scans are uploaded, but not all. A new rescan or focus " +
                           "scan dims a fully uploaded location until it is uploaded too, and a bulk Upload " +
                           "with the Latest scope (the default) sends only the newest scan of each location. " +
                           "Open the location to see which scans show an Uploaded date.")
            badgeRow(icon: "checkmark.icloud.fill", color: .green, title: "Green Cloud Badge",
                     text: "Every scan in this location, focus scans included, has been uploaded.")

            statusRow(.pending,
                      text: "Nothing is running for this scan. New scans start here, and canceling a Save " +
                            "comes back to it.")
            statusRow(.zipping, fraction: 0.4,
                      text: "Building the export. While it runs, the label names the step (Privacy blur, " +
                            "Zipping and so on) and the bar shows its progress. Keep the app open until it " +
                            "finishes: closing the app stops the conversion.")
            statusRow(.uploading(progress: 0.42), fraction: 0.42,
                      text: "Sending the export to the upload server. It keeps going if you lock the " +
                            "screen or switch apps.")
            statusRow(.success,
                      text: "The server accepted the upload. The card also shows Uploaded with the date " +
                            "and time, and the scan counts toward the location's cloud badge.")
            statusRow(.savedLocally,
                      text: "The export was saved to Files or sent with AirDrop. That is not an upload, " +
                            "so the cloud badge does not count it.")
            statusRow(.failed(ExportUploader.interruptedMessage),
                      text: "The export or upload did not finish, and the reason follows Failed. " +
                            "Interrupted means the app closed before it finished. Server error with a " +
                            "number, or a network message, means the server or the network refused it: " +
                            "check the upload server in Settings and your connection. Export failed or " +
                            "No scan data means the scan could not be packaged or its files are missing. " +
                            "Tap Upload to try again.")
            iconRow(icon: "clock.arrow.circlepath", color: .cyan, title: "The Label Shows the Last Try",
                    text: "The status label shows only the most recent attempt. Saving an uploaded scan " +
                          "to Files changes it to Saved Locally, and a failed re-upload shows Failed, " +
                          "but the Uploaded date stays and the cloud badge still counts the scan.")

            iconRow(icon: ControlPlaneSync.SpaceState.notSynced.symbol, color: .teal,
                    title: "Sync Is Not Upload",
                    text: "With a lab server (control plane) set in Settings, each location also has " +
                          "a Sync to Lab Server button. Sync keeps the lab's list of your spaces up to " +
                          "date and sends no photos, so a synced location can still have no cloud " +
                          "badge. Use Upload to send the scan itself.")
            iconRow(icon: ControlPlaneSync.SpaceState.synced.symbol, color: .teal,
                    title: ControlPlaneSync.SpaceState.synced.title,
                    text: "The lab server has this space, and new scans in it sync on their own. Tap " +
                          "to sync right away.")
            iconRow(icon: ControlPlaneSync.SpaceState.failed.symbol, color: .teal,
                    title: ControlPlaneSync.SpaceState.failed.title,
                    text: "The last sync did not reach the lab server. Settings > Control Plane shows " +
                          "why (a wrong password, a server that can't be reached), so fix that there, " +
                          "then tap to retry. Large files wait for Wi-Fi rather than fail.")
        } header: {
            Text("TROUBLESHOOTING: UPLOAD STATUS")
        } footer: {
            Text("The cloud badge sits in the top-right corner of each location, in the list and in " +
                 "the graph view. The status label is at the top right of each scan card inside a " +
                 "location.")
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
