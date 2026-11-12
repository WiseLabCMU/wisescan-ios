import SwiftUI

// MARK: - Focus scan capture HUD (docs/design/capture-modes.md)

/// What the operator sees during a focus scan: the region and detail level, the still count
/// against the target, one plain-language status line, and a coverage dial of the directions the
/// region has been photographed from. Drawn near the top of the capture view; ignores touches.
struct FocusCaptureHUD: View {
    let region: FocusRegion
    let stats: ARStillCaptureSession.LiveStats
    let isCapturing: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            FocusCoverageDial(counts: stats.coverageCounts,
                              perCellTarget: perCellTarget,
                              cameraAzimuthDeg: stats.regionInView ? stats.regionAzimuthDeg : nil,
                              cameraElevationDeg: stats.regionElevationDeg)
                .frame(width: AppConstants.focusHUDDialSize, height: AppConstants.focusHUDDialSize)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: region.detail.systemImage)
                    Text(region.displayName).lineLimit(1)
                }
                .font(.subheadline.bold())
                Text("\(region.detail.title) · \(stats.stillsSaved) of \(max(stats.targetStills, region.detail.targetStills)) photos")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.8))
                Label(status.text, systemImage: status.symbol)
                    .labelStyle(.tintedIcon(status.tint))
                    .font(.caption.bold())
            }
            .foregroundColor(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(AppConstants.focusHUDBackgroundOpacity))
        .cornerRadius(14)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    /// Stills per dial cell that read as "covered": the target spread over the cells.
    private var perCellTarget: Int {
        let cells = max(1, stats.coverageCounts.count)
        let target = max(stats.targetStills, region.detail.targetStills)
        return max(1, Int((Double(target) / Double(cells)).rounded(.up)))
    }

    private var status: (text: String, symbol: String, tint: Color) {
        guard isCapturing else {
            return ("Line up on the box, then tap record", "scope", .cyan)
        }
        switch stats.hold {
        case .none, .saving: return ("Capturing", "camera.fill", .green)
        case .tracking: return ("Hold on, finding tracking", "hourglass", .yellow)
        case .motion: return ("Hold steadier", "hand.raised.fill", .yellow)
        case .outOfView: return ("Point at the box", "viewfinder", .orange)
        case .tooFar: return ("Move closer", "arrow.down.right.and.arrow.up.left", .orange)
        case .sameView: return ("Move to a new angle", "arrow.triangle.2.circlepath", .white)
        }
    }
}

/// The directions the region has been photographed from, seen from above: sectors around the
/// region (sector 0, the region's +Z side, at the top), rings from low (outer) to high (inner).
/// A cell fills green as stills from that direction land; the dot is where the camera is now.
struct FocusCoverageDial: View {
    let counts: [Int]
    let perCellTarget: Int
    var cameraAzimuthDeg: Double?
    var cameraElevationDeg: Double = 0

    var body: some View {
        Canvas { context, size in
            let sectors = AppConstants.focusCoverageAzimuthBins
            let rings = AppConstants.focusCoverageElevationEdgesDeg.count + 1
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2
            let inner = outer * AppConstants.focusHUDDialHoleFraction
            let ringWidth = (outer - inner) / CGFloat(rings)
            let sweep = 360.0 / Double(sectors)
            for ring in 0..<rings {
                // Ring 0 (low views) is the outer band; higher views sit nearer the middle.
                let r1 = outer - CGFloat(ring) * ringWidth
                let r0 = r1 - ringWidth + AppConstants.focusHUDDialGap
                for sector in 0..<sectors {
                    let index = ring * sectors + sector
                    let count = index < counts.count ? counts[index] : 0
                    let fill = min(1, Double(count) / Double(max(1, perCellTarget)))
                    // Screen angle: sector 0 at the top, increasing clockwise.
                    let start = Angle.degrees(Double(sector) * sweep - 90 + AppConstants.focusHUDDialGapDeg / 2)
                    let end = Angle.degrees(Double(sector + 1) * sweep - 90 - AppConstants.focusHUDDialGapDeg / 2)
                    var cell = Path()
                    cell.addArc(center: centre, radius: r1, startAngle: start, endAngle: end, clockwise: false)
                    cell.addArc(center: centre, radius: r0, startAngle: end, endAngle: start, clockwise: true)
                    cell.closeSubpath()
                    let color = count == 0 ? Color.white.opacity(AppConstants.focusHUDEmptyCellOpacity)
                        : Color.green.opacity(AppConstants.focusHUDFilledCellMinOpacity
                                              + (1 - AppConstants.focusHUDFilledCellMinOpacity) * fill)
                    context.fill(cell, with: .color(color))
                }
            }
            if let azimuth = cameraAzimuthDeg {
                let edges = AppConstants.focusCoverageElevationEdgesDeg
                let ring = edges.filter { cameraElevationDeg >= $0 }.count
                let radius = outer - (CGFloat(ring) + 0.5) * ringWidth
                let angle = (azimuth - 90) * .pi / 180
                let dot = CGPoint(x: centre.x + radius * CGFloat(cos(angle)), y: centre.y + radius * CGFloat(sin(angle)))
                let dotSize = AppConstants.focusHUDDialDotSize
                context.fill(Path(ellipseIn: CGRect(x: dot.x - dotSize / 2, y: dot.y - dotSize / 2, width: dotSize, height: dotSize)),
                             with: .color(.white))
            }
            // The region itself, in the middle.
            let box = inner * AppConstants.focusHUDDialBoxFraction
            context.stroke(Path(CGRect(x: centre.x - box, y: centre.y - box, width: box * 2, height: box * 2)),
                           with: .color(.yellow), lineWidth: 1.5)
        }
        // Azimuth runs from the region's +Z toward its +X, which seen from above (+Z at the top)
        // is counterclockwise; the cells are laid out clockwise, so mirror the dial to match a
        // walk around the region.
        .scaleEffect(x: -1, y: 1)
        .accessibilityLabel("Coverage: \(counts.filter { $0 > 0 }.count) of \(counts.count) directions photographed")
    }
}

#Preview("Focus HUD, capturing") {
    var stats = ARStillCaptureSession.LiveStats()
    stats.hasRegion = true
    stats.detailLevel = .detail
    stats.targetStills = 30
    stats.stillsSaved = 11
    stats.regionInView = true
    stats.regionAzimuthDeg = 70
    stats.regionElevationDeg = 25
    stats.hold = .sameView
    var counts = [Int](repeating: 0, count: 36)
    for cell in [0, 1, 2, 13, 14, 15, 26] { counts[cell] = 2 }
    stats.coverageCounts = counts
    let region = FocusRegion(center: .zero, size: SIMD3(1.2, 0.5, 0.8), label: "work table", detail: .detail)
    return ZStack {
        Color.gray
        FocusCaptureHUD(region: region, stats: stats, isCapturing: true)
    }
}

#Preview("Focus HUD, before start") {
    FocusCaptureHUD(region: FocusRegion(center: .zero, size: SIMD3(0.5, 0.4, 0.5), detail: .check),
                    stats: ARStillCaptureSession.LiveStats(), isCapturing: false)
        .padding()
        .background(Color.gray)
}
