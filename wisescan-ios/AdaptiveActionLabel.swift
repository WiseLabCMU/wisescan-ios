import SwiftUI

/// Action-button label that carries its icon on iPad and drops it on iPhone.
///
/// The toolbars were designed on iPad, where a row of icon+text buttons is comfortable.
/// The same row on an iPhone is cramped: the width is roughly half, the buttons compete
/// with each other, and labels truncate — at which point the icon is decoration sitting
/// where the word should be. Text alone survives the squeeze, and the words are the part
/// that disambiguates ("Process" vs "Color" read identically as wand vs brush to anyone
/// who has not learned them yet).
///
/// Idiom, not size class: an iPad in a narrow split view is still an iPad, still held at
/// iPad distance, and its buttons should not change identity when the user drags the
/// divider.
struct AdaptiveActionLabel: View {
    let systemImage: String
    let title: String
    /// Spacing between icon and title when both show.
    var spacing: CGFloat = 4

    /// True on iPad. `UIDevice.userInterfaceIdiom` is stable for the process lifetime,
    /// so this is a constant, not a layout-dependent value.
    static var showsIcon: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        HStack(spacing: spacing) {
            if Self.showsIcon {
                Image(systemName: systemImage)
            }
            Text(title)
        }
    }
}
