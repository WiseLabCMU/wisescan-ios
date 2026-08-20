import SwiftUI

/// Rig-height editor with its OWN keypad — deliberately no `TextField`, so the system
/// keyboard is never involved.
///
/// Why: the system decimal pad crashed this flow repeatedly (360update1/2/3,
/// "_UIRemoteKeyboardPlaceholderView … no common ancestor"). Every mitigation for that
/// family is a mitigation, not a cure — SwiftUI installs keyboard-avoidance constraints
/// between the hosting view and a remote keyboard placeholder, and any teardown or
/// re-parent while the keyboard is up can trap. Contributing factors all stack here: a
/// sheet that can be swipe-dismissed mid-edit, a decimal pad with no return key, a
/// short detent competing with a 216 pt keyboard, and a live ARSession starving the
/// main thread so those animations run long (the logs show TextInputUI candidate
/// generation timing out at 3 s).
///
/// A twelve-button grid removes the mechanism outright: no first responder, no input
/// accessory, no keyboard-avoidance constraints, nothing to tear down. It is also
/// better in the field — large targets, usable with gloves, no animation.
///
/// This is the single rig-height editor for the app; Settings opens it too.
struct RigHeightSheet: View {
    @AppStorage(AppConstants.Key.rigMeasuredDyMeters) private var rigMeasuredDyMeters: Double = 0
    @AppStorage(AppConstants.Key.rigHeightUnitImperial) private var rigHeightUnitImperial: Bool = false

    @Environment(\.dismiss) private var dismiss

    /// Edit buffer in the DISPLAY unit. Committed to metres only on Set, so an
    /// abandoned edit (swipe-dismiss) leaves the stored value untouched.
    @State private var buffer: String = ""

    private static let maxDigits = 6

    /// Stored metric value rendered in the current display unit, trailing zeros trimmed.
    private func formatted() -> String {
        guard rigMeasuredDyMeters > 0 else { return "" }
        let display = rigHeightUnitImperial ? rigMeasuredDyMeters / 0.0254 : rigMeasuredDyMeters
        var out = String(format: "%.3f", display)
        while out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
        return out
    }

    private var parsed: Double? {
        guard let value = Double(buffer), value >= 0, value.isFinite else { return nil }
        return value
    }

    /// The buffer converted to metres — the value Set would store.
    private var previewMeters: Double? {
        parsed.map { rigHeightUnitImperial ? $0 * 0.0254 : $0 }
    }

    /// Mechanically plausible rig heights only; a fat-fingered 285 in should not
    /// silently become the solve's anchor.
    private var outOfRange: Bool {
        guard let meters = previewMeters else { return false }
        return meters > AppConstants.rigHeightMaxPlausibleMeters
            || meters < AppConstants.rigHeightMinPlausibleMeters
    }

    /// Names WHICH way it is wrong. "Out of range" on its own invites the user to retype
    /// the same digits; a unit hint is what actually gets corrected.
    private var rangeMessage: String {
        guard let meters = previewMeters else { return "Set" }
        if meters > AppConstants.rigHeightMaxPlausibleMeters { return "Too large — check the unit" }
        if meters < AppConstants.rigHeightMinPlausibleMeters { return "Too small — check the unit" }
        return "Set"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                valueRow
                Text("Tape-measured distance from the iPad's camera cluster to the 360° "
                     + "camera's lens center — the bootstrap anchor for each scan's "
                     + "calibration solve. Stored in meters regardless of entry unit.")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
                keypad
                setButton
            }
            .padding()
            .navigationTitle("360° Rig Height")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear { buffer = formatted() }
        .presentationDetents([.height(560)])
        .presentationDragIndicator(.visible)
    }

    private var valueRow: some View {
        HStack(spacing: 12) {
            Text(buffer.isEmpty ? "0" : buffer)
                .font(.system(size: 40, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(outOfRange ? .orange : .cyan)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("Rig height \(buffer.isEmpty ? "unset" : buffer)")

            Picker("", selection: Binding(
                get: { rigHeightUnitImperial },
                set: { imperial in
                    // Convert the in-progress buffer so switching units mid-entry does
                    // not silently reinterpret 28.5 inches as 28.5 metres.
                    if let value = parsed {
                        let meters = rigHeightUnitImperial ? value * 0.0254 : value
                        let shown = imperial ? meters / 0.0254 : meters
                        buffer = String(format: "%.3f", shown)
                        while buffer.hasSuffix("0") { buffer.removeLast() }
                        if buffer.hasSuffix(".") { buffer.removeLast() }
                    }
                    rigHeightUnitImperial = imperial
                }
            )) {
                Text("m").tag(false)
                Text("in").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
        }
    }

    private var keypad: some View {
        let keys = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], [".", "0", "⌫"]]
        return VStack(spacing: 10) {
            ForEach(keys, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { key in
                        Button(action: { press(key) }, label: {
                            Text(key)
                                .font(.title2.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 52)
                                .background(Color.white.opacity(0.10))
                                .foregroundColor(.white)
                                .cornerRadius(10)
                        })
                        .buttonStyle(.plain)
                        .accessibilityLabel(key == "⌫" ? "Delete" : key)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var setButton: some View {
        let disabled = parsed == nil || outOfRange
        Button(action: commit, label: {
            Text(rangeMessage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(disabled ? Color.gray.opacity(0.3) : Color.cyan.opacity(0.85))
                .foregroundColor(disabled ? .gray : .black)
                .cornerRadius(10)
        })
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func press(_ key: String) {
        switch key {
        case "⌫":
            if !buffer.isEmpty { buffer.removeLast() }
        case ".":
            if !buffer.contains(".") { buffer = buffer.isEmpty ? "0." : buffer + "." }
        default:
            guard buffer.filter(\.isNumber).count < Self.maxDigits else { return }
            if buffer == "0" { buffer = key } else { buffer += key }
        }
    }

    private func commit() {
        guard let meters = previewMeters, !outOfRange else { return }
        rigMeasuredDyMeters = meters
        // The measurement's AGE is part of the measurement: a stale entry once shipped
        // poses ~8 cm long for a day and a half. Record start nudges past rigHeightStaleDays.
        UserDefaults.standard.set(Int64(Date().timeIntervalSince1970 * 1000),
                                  forKey: AppConstants.Key.rigMeasuredDyDateMs)
        dismiss()
    }
}

#Preview {
    RigHeightSheet()
}
