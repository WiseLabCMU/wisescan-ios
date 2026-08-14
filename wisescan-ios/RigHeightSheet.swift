import SwiftUI

/// Compact rig-height editor, reachable by tapping the capture view's rig chip.
///
/// Why this exists rather than "open Settings": swapping rigs is a CAPTURE-time task,
/// but full Settings is a long List whose keyboard/layout work competes with a live
/// ARSession (360update1/2: multi-second main-thread stalls and a keyboard-teardown
/// trap). One field in a short sheet is a fraction of that layout pressure and two
/// taps instead of five.
///
/// Same lifecycle discipline as the Settings copy: the parsed value persists on every
/// keystroke and the bound text is NEVER rewritten during focus-loss or teardown —
/// rewriting a focused field's text forces a layout pass, and if the sheet is being
/// dismissed with the keyboard still up, UIKit activates the keyboard-avoidance
/// constraint against a detached hierarchy and traps.
struct RigHeightSheet: View {
    @AppStorage(AppConstants.Key.rigMeasuredDyMeters) private var rigMeasuredDyMeters: Double = 0
    @AppStorage(AppConstants.Key.rigHeightUnitImperial) private var rigHeightUnitImperial: Bool = false

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @FocusState private var focused: Bool

    /// Stored metric value rendered in the current display unit, trailing zeros trimmed.
    private func formatted() -> String {
        guard rigMeasuredDyMeters > 0 else { return "" }
        let display = rigHeightUnitImperial ? rigMeasuredDyMeters / 0.0254 : rigMeasuredDyMeters
        var out = String(format: "%.3f", display)
        while out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
        return out
    }

    /// Parse the edit buffer (decimal comma tolerated) and persist in METERS. Value
    /// only — see the type doc for why the text is never written back here.
    private func persist() {
        let cleaned = text
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value >= 0, value.isFinite else { return }
        rigMeasuredDyMeters = rigHeightUnitImperial ? value * 0.0254 : value
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    TextField("0.00", text: $text)
                        .keyboardType(.decimalPad)
                        .focused($focused)
                        .onChange(of: text) { _, _ in persist() }
                        .multilineTextAlignment(.trailing)
                        .font(.title2.monospacedDigit())
                        .foregroundColor(.cyan)
                        .frame(maxWidth: .infinity)

                    Picker("", selection: Binding(
                        get: { rigHeightUnitImperial },
                        set: { imperial in
                            persist()                      // parse pending text under the OLD unit
                            rigHeightUnitImperial = imperial
                            text = formatted()
                        }
                    )) {
                        Text("m").tag(false)
                        Text("in").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                }

                Text("Tape-measured distance from the iPad's camera cluster to the 360° "
                     + "camera's lens center. Used as the BOOTSTRAP anchor for each scan's "
                     + "calibration solve. Stored in meters regardless of entry unit.")
                    .font(.caption)
                    .foregroundColor(.gray)

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("360° Rig Height")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        focused = false               // never dismiss with the keyboard up
                        dismiss()
                    }
                }
                // The decimal pad has no return key — without this the only way out of
                // the field is to leave the screen, the exact keyboard-up teardown that
                // crashed in 360update1/2.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focused = false
                        text = formatted()
                    }
                }
            }
        }
        .onAppear {
            text = formatted()
            focused = true                            // straight to typing; this is a one-field sheet
        }
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
    }
}

#Preview {
    RigHeightSheet()
}
