import SwiftUI

/// Filled, full-width action button whose ENTIRE rounded-rect area is tappable.
///
/// SwiftUI's default button style only hit-tests the label's content, so the common
/// `Button { Text(...) }.frame(maxWidth: .infinity).padding().background().cornerRadius()`
/// shape draws a big colored rectangle but leaves everything except the text/icon dead —
/// taps in the surrounding padding go nowhere. Applying the frame/padding/background to
/// `configuration.label` here makes the whole rectangle the button's content, and
/// `.contentShape(Rectangle())` guarantees the padded area hit-tests. The pressed-state
/// dim also gives immediate "tap registered" feedback.
///
/// Usage: `.buttonStyle(FilledActionButtonStyle(background: Color.indigo.opacity(0.8)))`
struct FilledActionButtonStyle: ButtonStyle {
    var background: Color
    var foreground: Color = .white
    var cornerRadius: CGFloat = 12
    var verticalPadding: CGFloat = 14
    /// Optional stroke (e.g. the outlined "Rename" variant). nil = no border.
    var border: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity)
            .padding(.vertical, verticalPadding)
            .foregroundColor(foreground)
            .background(background)
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(border ?? .clear, lineWidth: border == nil ? 0 : 1)
            )
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
