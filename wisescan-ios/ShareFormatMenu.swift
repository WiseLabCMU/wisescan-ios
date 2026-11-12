import SwiftUI

// MARK: - Share's format, asked at each Share

/// Share's format choice: tapping Share lists the formats, and picking one runs the export in it.
/// Nothing is kept between shares. What to hand another app is a per-share question, so the
/// space screen's persistent Global Export Format picker is gone (CONTRIBUTING, fewest controls).
/// Scan4D, the bundle that holds everything, comes first.
struct ShareFormatMenu<Label: View>: View {
    let share: (ExportFormat) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            ForEach(ExportFormat.allCases, id: \.self) { format in
                Button {
                    share(format)
                } label: {
                    Text(format.rawValue)
                    Text(format.shareSummary)
                }
            }
        } label: {
            label()
        }
    }
}

extension ExportFormat {
    /// The line Share's menu shows under each format.
    var shareSummary: String {
        switch self {
        case .scan4d: return "Everything the scan holds, as a zip"
        case .usdz: return "The mesh, for AR Quick Look and Reality Composer"
        case .ply: return "The mesh, for point-cloud and mesh tools"
        case .obj: return "The mesh, for 3D editors"
        }
    }
}

#Preview {
    ShareFormatMenu(share: { format in print("Share as \(format.rawValue)") }) {
        HStack {
            Image(systemName: "square.and.arrow.up")
            Text("Share")
                .font(.subheadline).bold()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.cyan.opacity(0.8))
        .foregroundColor(.white)
        .cornerRadius(10)
    }
    .padding()
    .background(Color.black)
}
