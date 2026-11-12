import SwiftUI

// MARK: - Asking for the control plane password before a tapped Sync

/// A tapped Sync held while Settings asks for the control plane password. It runs when Settings
/// closes, with a password or without: without one the sync reports that the server wants its
/// password, as before the prompt existed.
///
/// The prompt comes only when the server has refused a request for want of a password
/// (`ControlPlaneSecret.isMissing`), so an open development server never asks. Background syncs
/// never prompt; they wait for the password like before.
struct ControlPlanePendingAction: Identifiable {
    let id = UUID()
    let run: () -> Void

    /// Runs `action` now, or, when the server at `host` wants a password this phone has not got,
    /// returns it to hold for the prompt (`controlPlanePasswordPrompt`).
    static func runOrHold(host: String, password: String = ControlPlaneSecret.password,
                          _ action: @escaping () -> Void) -> ControlPlanePendingAction? {
        guard ControlPlaneSecret.isMissing(forHost: host, password: password) else {
            action()
            return nil
        }
        return ControlPlanePendingAction(run: action)
    }
}

extension View {
    /// Shows the lab server's connection settings at the password while `pending` holds an
    /// action, and runs the action once the sheet closes.
    func controlPlanePasswordPrompt(_ pending: Binding<ControlPlanePendingAction?>) -> some View {
        modifier(ControlPlanePasswordPrompt(pending: pending))
    }
}

private struct ControlPlanePasswordPrompt: ViewModifier {
    @Binding var pending: ControlPlanePendingAction?
    /// The action on screen, kept past the binding, which SwiftUI clears before `onDismiss`.
    @State private var shown: ControlPlanePendingAction?

    func body(content: Content) -> some View {
        content.sheet(item: $pending, onDismiss: {
            let action = shown
            shown = nil
            action?.run()
        }, content: { action in
            ControlPlanePasswordSheet()
                .onAppear { shown = action }
        })
    }
}

/// The Server tab's connection settings in a sheet, the cursor in the password field (the same
/// section the tab shows): Done closes it and the held action runs.
struct ControlPlanePasswordSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List { ControlPlaneSettingsSection(focusPassword: true) }
                .scrollContentBackground(.hidden)
                .background(Color.black)
                .navigationTitle("Lab Server")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ControlPlanePasswordSheet()
}
