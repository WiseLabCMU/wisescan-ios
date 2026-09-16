import SwiftUI

struct External360CameraCard: View {
    @Bindable var source: External360StillSource

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "square.and.arrow.down.on.square")
                    .foregroundColor(.cyan)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deferred Import")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Record 360° tickets during capture, then import stitched equirect JPGs into each scan afterwards.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.8))
                }
            }

            Picker("Camera Model", selection: Binding(
                get: { source.selectedModel },
                set: { source.selectedModel = $0 }
            )) {
                ForEach(External360CameraModel.allCases) { model in
                    Text(model.rawValue).tag(model)
                }
            }
            .pickerStyle(.menu)
            .tint(.cyan)

            Text("Use this path before Insta360 SDK approval. Scan4D records the phone pose at each stillness pause and waits for you to import the matching equirects later.")
                .font(.caption2)
                .foregroundColor(.gray)
        }
        .padding()
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .cornerRadius(16)
    }
}
