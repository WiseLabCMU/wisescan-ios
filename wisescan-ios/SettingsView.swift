import SwiftUI

struct SettingsView: View {
    @AppStorage("rawOverlapMax") private var rawOverlapMax: Double = 60.0
    @AppStorage("rawRejectBlur") private var rawRejectBlur: Bool = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                LinearGradient(colors: [Color(white: 0.1), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Image Overlap Maximum")
                                    .foregroundColor(.white)
                                Spacer()
                                Text("\(Int(rawOverlapMax))%")
                                    .foregroundColor(.cyan)
                                    .font(.headline)
                            }
                            Slider(value: $rawOverlapMax, in: 10...100, step: 5)
                                .tint(.cyan)
                            Text("Controls maximum overlap between consecutive captured frames. Lower values capture fewer, more distinct frames. Higher values capture more frames with greater overlap.")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                        .padding(.vertical, 4)

                        Toggle(isOn: $rawRejectBlur) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Reject Blurred Frames")
                                    .foregroundColor(.white)
                                Text("Automatically discard frames with motion blur or camera shake during capture.")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        .tint(.cyan)
                        .padding(.vertical, 4)
                    } header: {
                        Text("RAW EXPORT")
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

#Preview {
    SettingsView()
}
