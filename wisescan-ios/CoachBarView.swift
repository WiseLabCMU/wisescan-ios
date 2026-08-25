import SwiftUI

/// A single-line coach bar that slides in from the top to display scan coaching tips.
/// Color-coded by priority tier with an SF Symbol icon and swipe-to-dismiss gesture.
struct CoachBarView: View {
    let tip: CoachTip?
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0

    var body: some View {
        if let tip = tip {
            HStack(spacing: 8) {
                Image(systemName: tip.icon)
                    .foregroundColor(.white)
                    .font(.subheadline.weight(.semibold))
                Text(tip.message)
                    .font(.caption2).bold()
                    .foregroundColor(.white)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(tipColor(for: tip.priority).opacity(0.9))
            .cornerRadius(12)
            .padding(.horizontal)
            .offset(y: dragOffset)
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        // Only allow upward swipe
                        if value.translation.height < 0 {
                            dragOffset = value.translation.height
                        }
                    }
                    .onEnded { value in
                        if value.translation.height < -30 {
                            // Swipe up threshold met — dismiss
                            withAnimation(.easeOut(duration: 0.2)) {
                                dragOffset = -100
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                onDismiss()
                                dragOffset = 0
                            }
                        } else {
                            // Snap back
                            withAnimation(.spring()) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: tip.id)
        }
    }

    private func tipColor(for priority: TipPriority) -> Color {
        let c = priority.color
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 12) {
            CoachBarView(
                tip: CoachTip(id: "guidance.pauseForPhoto",
                              message: "Hold still on amber areas, then tap for a photo",
                              icon: "camera.fill", priority: .guidance),
                onDismiss: {}
            )
            CoachBarView(
                tip: CoachTip(id: "warning.nearCapacity",
                              message: "Approaching session capacity — save soon",
                              icon: "exclamationmark.triangle.fill", priority: .warning),
                onDismiss: {}
            )
            CoachBarView(
                tip: CoachTip(id: "critical.trackingLost",
                              message: "Tracking lost — hold still to recover",
                              icon: "exclamationmark.triangle.fill", priority: .critical),
                onDismiss: {}
            )
        }
        .padding()
    }
}


/// Label with a tinted SF Symbol and untinted title — the replacement for emoji in
/// rendered UI (CONTRIBUTING: no emoji in UI text; the icon is where the colour lives).
struct TintedIconLabelStyle: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundColor(tint)
            configuration.title
        }
    }
}

extension LabelStyle where Self == TintedIconLabelStyle {
    static func tintedIcon(_ tint: Color) -> TintedIconLabelStyle { TintedIconLabelStyle(tint: tint) }
}
