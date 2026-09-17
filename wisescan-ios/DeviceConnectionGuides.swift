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

/// Shared background + list chrome so both guides match the main User Guide.
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

// MARK: - Ricoh Theta

struct ThetaConnectionGuideView: View {
    var body: some View {
        ConnectionGuideScaffold(title: "Connect Ricoh Theta") {
            Section {
                GuideStepRow(number: 1, title: "Power on & enable Wi‑Fi",
                             text: "Turn on the Theta and press its Wi‑Fi button to enter wireless (direct) mode. "
                                 + "The Wi‑Fi lamp lights up when the camera is broadcasting its own network.")
                GuideStepRow(number: 2, title: "Find the camera's network",
                             text: "The Wi‑Fi name (SSID) starts with \"THETA\". The default password is the camera's serial "
                                 + "number digits, printed on the label on the underside of the camera.")
                GuideStepRow(number: 3, title: "Join it in iOS Settings",
                             text: "Open Settings → Wi‑Fi and join the THETA… network. While connected, your phone uses the "
                                 + "camera's network instead of your usual Wi‑Fi (that's expected).")
                GuideStepRow(number: 4, title: "Check Connection",
                             text: "In Scan4D → Dashboard → 360° Camera, tap \"Check Connection\". Approve the Local Network "
                                 + "prompt the first time. The card then shows the camera model, firmware, and battery level.")
                GuideStepRow(number: 5, title: "Test Shutter",
                             text: "Tap \"Test Shutter\" to fire a photo. The card reports the round-trip time and the file the "
                                 + "camera saved — confirming Scan4D can trigger the camera.")
            } header: {
                Text("STEPS")
            } footer: {
                Text("Supported over the Open Spherical Camera (OSC) Web API — Ricoh Theta X and other OSC-compatible Theta models.")
                    .font(.caption2).foregroundColor(.gray)
            }
            .listRowBackground(Color.white.opacity(0.05))

            Section {
                GuideNoteRow(icon: "wrench.and.screwdriver.fill",
                             text: "Early access: this version connects over the camera's direct Wi‑Fi and triggers a still to validate the link. "
                                 + "Automatic Wi‑Fi join, Bluetooth trigger, image download, and 360° rig calibration are coming later.",
                             color: .cyan)
            } header: {
                Text("WHAT WORKS TODAY")
            }
            .listRowBackground(Color.white.opacity(0.05))

            Section {
                GuideNoteRow(icon: "wifi.exclamationmark",
                             text: "\"Can't reach the camera\"? Re-join the THETA Wi‑Fi in Settings — iOS may auto-switch back to a known "
                                 + "network — make sure the camera is awake, then tap Check Connection again.",
                             color: .orange)
                GuideNoteRow(icon: "battery.25",
                             text: "The camera sleeps its Wi‑Fi to save power. Wake the camera (press a button) before reconnecting.",
                             color: .orange)
            } header: {
                Text("TROUBLESHOOTING")
            }
            .listRowBackground(Color.white.opacity(0.05))
        }
    }
}

struct Insta360DeferredImportGuideView: View {
    var body: some View {
        ConnectionGuideScaffold(title: "Use Insta360 X6 (Deferred Import)") {
            Section {
                GuideStepRow(number: 1, title: "Choose Deferred Import",
                             text: "In Scan4D → Dashboard → 360° Camera, switch the source to Deferred External Import and choose INSTA360 X6.")
                GuideStepRow(number: 2, title: "Record normally",
                             text: "Scan as usual. Each accepted stillness tap records a 360° ticket with the phone pose and timestamp, but does not trigger the camera.")
                GuideStepRow(number: 3, title: "Capture on the X6",
                             text: "Capture matching stitched equirect stills on the Insta360 X6 during the scan. Hold the rig still while you trigger each shot, and export stitched equirect JPEGs from the Insta360 app or Studio — not the camera-native dual-fisheye originals.")
                GuideStepRow(number: 4, title: "Import into the scan",
                             text: "Open the scan card, long-press Color, and choose Import Deferred 360° Stills. Select the stitched JPEGs; Scan4D matches them to the recorded tickets by timestamp and warns if the timing no longer lines up.")
                GuideStepRow(number: 5, title: "Process and export",
                             text: "After import, Scan4D runs the normal 360° calibration, privacy, face-export, and export pipeline on the imported equirects. Insta360 faces currently ship with assumed leveling provenance until field validation is completed.")
            } header: {
                Text("STEPS")
            } footer: {
                Text("This is the pre-SDK path: no live trigger, wake, or download. It exists so Insta360 X6 rigs can be used before SDK approval.")
                    .font(.caption2).foregroundColor(.gray)
            }
            .listRowBackground(Color.white.opacity(0.05))

            Section {
                GuideNoteRow(icon: "person.crop.rectangle",
                             text: "Imported originals remain in Photos or Files exactly as exported by Insta360. Scan4D's privacy blur applies only to the copies it stages and exports from the scan bundle.",
                             color: .orange)
                GuideNoteRow(icon: "exclamationmark.triangle.fill",
                             text: "If Scan4D warns about a large time mismatch after import, check that you picked the same stitched shots you captured during the scan and remove extras before re-importing.",
                             color: .orange)
            } header: {
                Text("IMPORTANT NOTES")
            }
            .listRowBackground(Color.white.opacity(0.05))
        }
    }
}

#Preview("Meta") {
    NavigationStack { MetaConnectionGuideView() }
}

#Preview("Theta") {
    NavigationStack { ThetaConnectionGuideView() }
}

#Preview("Insta360 Deferred") {
    NavigationStack { Insta360DeferredImportGuideView() }
}
