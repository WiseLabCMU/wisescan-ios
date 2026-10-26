import SwiftUI

/// The Dashboard's to-do list: focus scans the lab asked this device for (control plane tasks;
/// scan4d-server README, "Tasks"). The device is a worker with a queue: requests wait here,
/// and only an urgent one also alerts, once (ContentView). Open takes the region into its
/// space's editor, the same way a region link does; Decline tells the lab it will not be done.
/// Shown whenever a control plane is set; the list is the phone's copy, so it stays while the
/// server can't be reached, and answers given meanwhile go with the next sync.
struct ControlPlaneTodoCard: View {
    @AppStorage(AppConstants.Key.controlPlaneHost) private var host = ""
    private var sync: ControlPlaneSync { ControlPlaneSync.shared }

    var body: some View {
        if ControlPlaneClient.baseURL(fromHost: host) != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "checklist")
                        .foregroundColor(.cyan)
                    Text("To do")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Text("\(sync.openTasks.count)")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                if sync.openTasks.isEmpty {
                    Text("No focus scans requested by the lab.")
                        .font(.caption)
                        .foregroundColor(.gray)
                } else {
                    ForEach(sync.openTasks) { task in
                        row(task)
                    }
                    if case .failed = sync.status {
                        Text("From the last sync: the control plane isn't answering now.")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(16)
            .padding(.horizontal)
        }
    }

    private func row(_ task: ControlPlaneClient.ScanTask) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: task.isUrgent ? "exclamationmark.circle.fill" : "scope")
                .foregroundColor(task.isUrgent ? .orange : .yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.region.label.isEmpty ? "A region" : task.region.label)
                    .font(.subheadline)
                    .foregroundColor(.white)
                Text("\(task.mapName) · \(task.region.detail.title)\(task.status == "accepted" ? " · opened" : "")")
                    .font(.caption)
                    .foregroundColor(.gray)
                if !task.reason.isEmpty {
                    Text(task.reason)
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
            Spacer()
            VStack(spacing: 6) {
                Button("Open") { sync.open(task) }
                    .font(.caption.bold())
                Button("Decline", role: .destructive) { sync.decline(task) }
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }
}
