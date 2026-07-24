import SwiftUI

// Device connection walkthroughs, pushed from the main User Guide's "DEVICE CONNECTION"
// section. Kept as separate pages so the main guide stays scannable and each device gets
// room for step-by-step setup + troubleshooting.

// MARK: - Shared rows

/// Numbered step row (filled cyan badge + title + body), shared by the connection guides.
private struct GuideStepRow: View {
    let number: Int
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption).bold()
                .foregroundColor(.black)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.cyan))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .foregroundColor(.white)
                    .font(.subheadline).bold()
                Text(text)
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Icon + text note row for tips / troubleshooting / scope callouts.
private struct GuideNoteRow: View {
    let icon: String
    let text: String
    var color: Color = .gray

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.subheadline)
                .frame(width: 24)
            Text(text)
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(.vertical, 4)
    }
}

/// Shared background + list chrome so the guides match the main User Guide.
private struct ConnectionGuideScaffold<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LinearGradient(colors: [Color(white: 0.1), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            List {
                content
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Meta Ray-Ban

struct MetaConnectionGuideView: View {
    var body: some View {
        ConnectionGuideScaffold(title: "Connect Meta Ray-Ban") {
            Section {
                GuideStepRow(number: 1, title: "Set up in the Meta AI app",
                             text: "Pair your Ray-Ban Meta glasses with the Meta AI app (formerly Meta View) "
                                 + "and finish setup there first. Scan4D discovers glasses that are already paired to this phone.")
                GuideStepRow(number: 2, title: "Enable Device Access",
                             text: "In the Meta AI app, turn on developer / Device Access Toolkit (DAT) access for your glasses "
                                 + "so third-party apps like Scan4D can receive the camera stream.")
                GuideStepRow(number: 3, title: "Grant camera permission",
                             text: "Camera access must be granted in the Meta AI companion app. If it's missing, Scan4D shows a "
                                 + "\"Grant Permission in Meta AI\" banner on the Dashboard — tap it to jump to the app.")
                GuideStepRow(number: 4, title: "Add glasses in Scan4D",
                             text: "On the Dashboard, under Wearable Devices, tap \"Add Meta Smart Glasses\". "
                                 + "Scan4D discovers paired glasses over Bluetooth — keep Bluetooth on.")
                GuideStepRow(number: 5, title: "Connect",
                             text: "Tap your glasses' card to connect. If a \"Firmware Update Required\" banner appears, tap "
                                 + "\"Update in Meta View App\", finish the update, then return and retry.")
                GuideStepRow(number: 6, title: "Capture",
                             text: "Once connected, the glasses stream proxy frames during a scan. Start a scan as usual — "
                                 + "the glasses feed is used as the capture source.")
            } header: {
                Text("STEPS")
            } footer: {
                Text("Requires the Meta AI app installed and your glasses paired to this phone. "
                     + "Scan4D never bypasses Meta's permission or firmware requirements.")
                    .font(.caption2).foregroundColor(.gray)
            }
            .listRowBackground(Color.white.opacity(0.05))

            Section {
                GuideNoteRow(icon: "antenna.radiowaves.left.and.right", text: "Keep Bluetooth enabled — discovery and the control link run over it.", color: .cyan)
                GuideNoteRow(icon: "exclamationmark.triangle.fill",
                             text: "No devices found? Confirm the glasses are paired in the Meta AI app and not connected to another app, then tap Add again.",
                             color: .orange)
                GuideNoteRow(icon: "arrow.clockwise",
                             text: "Streaming won't start until camera permission is granted in Meta AI — grant it, and Scan4D picks it up automatically.",
                             color: .cyan)
            } header: {
                Text("TROUBLESHOOTING")
            }
            .listRowBackground(Color.white.opacity(0.05))
        }
    }
}

#Preview("Meta") {
    NavigationStack { MetaConnectionGuideView() }
}
