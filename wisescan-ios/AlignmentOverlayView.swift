import SwiftUI

/// Overlay shown during the cross-session alignment phase (Flow B).
/// Guides the user through relocalization and lets them confirm
/// the boundary position before starting a new scan.
///
/// Confirm button enables when ARKit tracking is normal (relocalized),
/// not based on distance to a boundary anchor.
struct AlignmentOverlayView: View {
    @Environment(ScanStore.self) private var scanStore
    var scanStats: ScanStats
    var onConfirm: () -> Void
    var onCancel: () -> Void

    private var isTracking: Bool {
        scanStats.trackingStatus.isNormal
    }

    /// Confirm is available once tracking is normal (relocalized).
    private var isAligned: Bool {
        scanStore.capturePhase == .alignedReady && isTracking
    }

    /// Distance to the PREVIOUS link's boundary pin baked into the loaded map
    /// (relocalization-confidence cue, not the boundary being created — may be nil).
    private var distance: Float? {
        scanStore.distanceToBoundaryAnchor
    }

    private var statusText: String {
        switch scanStore.capturePhase {
        case .loadingWorldMap:
            return "Relocalizing with previous scan..."
        case .aligning:
            return "Relocalized — walk to where the new boundary should be, then confirm"
        case .alignedReady:
            return "Ready — confirm to start scanning adjacent space"
        default:
            return ""
        }
    }

    var body: some View {
        VStack {
            Spacer()

            VStack(spacing: 20) {
                // Status header
                VStack(spacing: 8) {
                    Image(systemName: scanStore.capturePhase == .loadingWorldMap
                          ? "location.magnifyingglass"
                          : "mappin.and.ellipse")
                        .font(.system(size: 36))
                        .foregroundColor(.white)
                        .symbolEffect(.pulse, isActive: scanStore.capturePhase == .loadingWorldMap)

                    Text("Align with Previous Scan")
                        .font(.title3.bold())
                        .foregroundColor(.white)

                    Text(statusText)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }

                // Previous-link reference (only shown if the loaded map already had a
                // boundary anchor from an earlier extend). This is NOT the boundary
                // you're about to create — it marks where this scan was previously
                // linked. Shown as a neutral, informational relocalization cue (a
                // reading near the marker confirms ARKit locked onto the map), not a
                // target to walk toward — hence no green/proximity coloring.
                if scanStore.capturePhase != .loadingWorldMap, let dist = distance {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                        Text(String(format: "Previous link · %.1f m away", dist))
                    }
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
                }

                // Tracking state warning
                if !isTracking && scanStore.capturePhase != .loadingWorldMap {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text("Tracking lost — move slowly and look at textured surfaces")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.yellow.opacity(0.15))
                    .cornerRadius(12)
                }

                // Action buttons
                HStack(spacing: 16) {
                    Button(action: onCancel) {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark")
                            Text("Cancel")
                        }
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.15))
                        .cornerRadius(14)
                    }

                    Button(action: onConfirm) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Confirm & Start Scan")
                        }
                        .font(.subheadline.bold())
                        .foregroundColor(isAligned ? .white : .gray)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(isAligned ? Color.green.opacity(0.85) : Color.gray.opacity(0.3))
                        .cornerRadius(14)
                    }
                    .disabled(!isAligned)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.indigo.opacity(0.6), lineWidth: 2)
                    )
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
    }
}
