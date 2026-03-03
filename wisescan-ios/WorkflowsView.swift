import SwiftUI

struct WorkflowsView: View {
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                LinearGradient(colors: [Color(white: 0.1), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {

                        // Thumbnail Card
                        VStack(alignment: .leading) {
                            ZStack {
                                Color.white.opacity(0.1)
                                Image(systemName: "cube.transparent")
                                    .font(.system(size: 60))
                                    .foregroundColor(.white)
                            }
                            .frame(height: 180)

                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Name: Bronze Statue")
                                        .font(.subheadline).bold()
                                        .foregroundColor(.white)
                                    HStack(spacing: 12) {
                                        Text("Filesize: 42.1 MB")
                                        Text("Poly: 1.2M")
                                        Text("Captured: 2 min ago")
                                    }
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                }
                                Spacer()
                            }
                            .padding()
                        }
                        .background(.ultraThinMaterial)
                        .cornerRadius(16)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
                        .padding(.horizontal)

                        // Workflows List
                        HStack {
                            Text("Post-Capture")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                            Spacer()
                        }
                        .padding(.horizontal)

                        VStack(spacing: 16) {
                            WorkflowCard(
                                icon: "bolt.fill",
                                title: "QUICK MESH",
                                description: "Fast processing for low-poly mesh & textures. Ideal for preview, AR, game assets.",
                                time: "~5m",
                                buttonText: "Start Quick Mesh"
                            )
                            WorkflowCard(
                                icon: "sparkles",
                                title: "HIGH-QUALITY SPLAT",
                                description: "Maximum density 3D Gaussian splat. Photorealistic detail, radiance fields, cinematic export.",
                                time: "~15m",
                                buttonText: "Process Splat",
                                isPrimary: true
                            )
                            WorkflowCard(
                                icon: "arkit",
                                title: "SPATIAL INDEXING",
                                description: "Optimized index for large environments. Efficient retrieval, spatial queries, cloud storage.",
                                time: "~10m",
                                buttonText: "Index Space"
                            )
                        }
                        .padding(.horizontal)
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("SELECT WORKFLOW")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {}
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Export") {}.buttonStyle(.borderedProminent).tint(.blue)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

struct WorkflowCard: View {
    var icon: String
    var title: String
    var description: String
    var time: String
    var buttonText: String
    var isPrimary: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title)
                .foregroundColor(isPrimary ? .cyan : .white)
                .frame(width: 40)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Label("Time: \(time)", systemImage: "clock")
                        .font(.caption)
                        .foregroundColor(.green)

                    Spacer()

                    Button(action: {}) {
                        Text(buttonText)
                            .font(.caption).bold()
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isPrimary ? Color.blue : Color.white.opacity(0.2))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isPrimary ? Color.cyan.opacity(0.3) : Color.white.opacity(0.1), lineWidth: 1)
        )
        .cornerRadius(16)
    }
}

#Preview {
    WorkflowsView()
}
