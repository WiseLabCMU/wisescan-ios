import SwiftUI

/// Modal report showing the results of a pre-scan space analysis. Each check is displayed as a
/// card with a status icon, title, and actionable recommendation. Presented as a sheet after the
/// 360° analysis sweep completes; the Record button stays disabled until this is dismissed.
struct ScanAnalysisReportView: View {
    let result: SpaceAnalysisResult
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.shield")
                            .font(.system(size: 44))
                            .foregroundStyle(.cyan)
                        Text("Space Analysis")
                            .font(.title2.bold())
                            .foregroundColor(.primary)
                        Text("Review these staging tips before scanning.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 8)

                    // Check cards
                    checkCard(
                        icon: "lightbulb.fill",
                        title: "Lighting",
                        status: result.lighting
                    )

                    checkCard(
                        icon: "tv.fill",
                        title: "Screens",
                        status: result.screens
                    )

                    checkCard(
                        icon: "door.left.hand.open",
                        title: "Doors",
                        status: result.doors
                    )

                    checkCard(
                        icon: "person.fill",
                        title: "People / Pets",
                        status: result.people
                    )
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.headline)
                }
            }
        }
    }

    // MARK: - Check Card

    @ViewBuilder
    private func checkCard(icon: String, title: String, status: SpaceAnalysisResult.CheckStatus) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Status indicator
            statusIcon(for: status)
                .font(.system(size: 28))
                .frame(width: 36, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: icon)
                        .foregroundColor(.secondary)
                    Text(title)
                        .font(.headline)
                }

                Text(statusMessage(for: status))
                    .font(.subheadline)
                    .foregroundColor(statusTextColor(for: status))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding()
        .background(statusBackground(for: status))
        .cornerRadius(14)
    }

    // MARK: - Status Styling

    private func statusIcon(for status: SpaceAnalysisResult.CheckStatus) -> some View {
        switch status {
        case .pass:
            return Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .warn:
            return Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
        case .skipped:
            return Image(systemName: "questionmark.circle.fill")
                .foregroundColor(.gray)
        }
    }

    private func statusMessage(for status: SpaceAnalysisResult.CheckStatus) -> String {
        switch status {
        case .pass(let msg), .warn(let msg), .skipped(let msg):
            return msg
        }
    }

    private func statusTextColor(for status: SpaceAnalysisResult.CheckStatus) -> Color {
        switch status {
        case .pass: return .secondary
        case .warn: return .primary
        case .skipped: return .secondary
        }
    }

    private func statusBackground(for status: SpaceAnalysisResult.CheckStatus) -> Color {
        switch status {
        case .pass: return Color.green.opacity(0.08)
        case .warn: return Color.orange.opacity(0.08)
        case .skipped: return Color(.secondarySystemGroupedBackground)
        }
    }
}
