import SwiftUI

// The mesh preview's bottom-docked time scrubber. Split out of MeshPreviewView+Timeline.swift,
// which owns the SceneKit side (slot loading, visibility, the prefetch pump) — this file is purely
// the control: the notch track, the readout, and the A/B comparison affordances. Same reason
// MeshPreviewView+KeyframeFrustums.swift exists: keep each file inside the length limit.

// MARK: - Scrubber bar

/// Bottom-docked time scrubber: a discrete track with one notch per generation, the selected notch
/// doubling as the thumb, each notch's date centred under it, and the A/B comparison controls.
/// Only ever mounted for locations with more than one scan — a single-scan preview keeps exactly
/// the UI it had.
///
/// Custom rather than a stock `Slider` + a tick row because those two lay out differently and the
/// mismatch was visible: a Slider puts value `i` at `i/(N-1)` of its track (edges included), while
/// an equal-flex `HStack` of N ticks centres tick `i` at `(i+0.5)/N` — for two scans, 0%/100%
/// against 25%/75%, so the thumb never sat on the tick it was reporting. Here `markX` is the single
/// source of x for the notches, the thumb and the labels, and `nearestIndex` is its inverse for
/// hit-testing, so all four agree by construction.
struct ScanTimelineBar: View {
    let timeline: [TimelineScan]
    @ObservedObject var state: ScanTimelineState
    @Binding var visibleIndex: Int
    /// Non-nil once two generations are pinned for comparison.
    @Binding var comparison: ABComparison?
    /// While arming a comparison: the index pinned as side A (nil = not arming). Holding the index
    /// rather than a bool lets A stay put while the cursor moves to find B — with a bool, A was
    /// whatever the cursor happened to be on, so scrubbing dragged A along with it.
    @Binding var pendingA: Int?
    @Binding var isBlinking: Bool

    /// True once a drag has moved: a press that never moves is a TAP (full tick semantics — pick B,
    /// re-point B, jump), a press that moves is a SCRUB (plain seek, never arms).
    @State private var isScrubbing = false

    /// Track/notch/thumb/label geometry. One set of numbers for all four, because the bug this
    /// replaced was two layouts disagreeing about where scan `i` is.
    private enum Metrics {
        /// Selected notch (the thumb). Its radius is also the track inset, so the first and last
        /// notches — which sit exactly at the ends of the usable track — can't be clipped.
        static let thumb: CGFloat = 18
        static let mark: CGFloat = 10
        /// Notches closer together than `tightSpacing` shrink instead of overlapping.
        static let markTight: CGFloat = 6
        static let tightSpacing: CGFloat = 18
        static let notchWidth: CGFloat = 2
        static let notchHeight: CGFloat = 11
        static let track: CGFloat = 3
        static let trackRow: CGFloat = 22
        static let labelRow: CGFloat = 13
    }

    private var visible: TimelineScan? {
        timeline.indices.contains(visibleIndex) ? timeline[visibleIndex] : nil
    }

    var body: some View {
        VStack(spacing: 6) {
            readout
            // A/B takes over the free-scrub affordance (the flip/blink controls replace it), but the
            // notch strip stays: it's where the A and B badges live and where a tap re-points B.
            if let comparison {
                flipControls(comparison)
            }
            scrubber(dragEnabled: comparison == nil)
            if state.resolvedCount(in: timeline) < timeline.count {
                loadingRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    // MARK: Scrubber geometry
    //
    // Every mark derives its x from `markX`, and touches resolve through `nearestIndex`, which is
    // its inverse — so the thumb, the notch under it, that notch's label and the touch column all
    // land on the same coordinate by construction. (The stock Slider couldn't: it places its thumb
    // at i/(N-1) of the track, while an equal-flex HStack of ticks centres tick i at (i+0.5)/N —
    // for two scans, 0%/100% against 25%/75%.)

    /// x of scan `index` within a track of `width`, inset by half a thumb at each end.
    /// `count == 1` centres (the bar isn't mounted for one scan, but the math must not divide by 0).
    private func markX(_ index: Int, width: CGFloat) -> CGFloat {
        let inset = Metrics.thumb / 2
        let usable = max(0, width - inset * 2)
        guard timeline.count > 1 else { return inset + usable / 2 }
        return inset + usable * CGFloat(index) / CGFloat(timeline.count - 1)
    }

    /// The scan a touch at `x` belongs to — the inverse of `markX`, rounded. That makes each notch's
    /// touch column the full-height band centred on it (half-width at the two ends), and anything
    /// past the last notch clamps to it.
    private func nearestIndex(atX xPos: CGFloat, width: CGFloat) -> Int {
        guard timeline.count > 1 else { return 0 }
        let inset = Metrics.thumb / 2
        let usable = max(1, width - inset * 2)
        // Clamped BEFORE the Int conversion: the x comes from a gesture, and converting an
        // out-of-range float to Int traps rather than saturating.
        let position = (xPos - inset) / usable * CGFloat(timeline.count - 1)
        return Int(min(max(position.rounded(), 0), CGFloat(timeline.count - 1)))
    }

    /// Gap between neighbouring notches, for the crowding rules.
    private func spacing(width: CGFloat) -> CGFloat {
        guard timeline.count > 1 else { return width }
        return max(0, width - Metrics.thumb) / CGFloat(timeline.count - 1)
    }

    /// The scrubber: one track, one notch per generation, the selected notch doubling as the thumb,
    /// and the labels centred under their own notches. `dragEnabled` is false in A/B mode, where
    /// free scrubbing would fight the flip control — taps still work (they re-point B).
    private func scrubber(dragEnabled: Bool) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            VStack(spacing: 3) {
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: max(0, width - Metrics.thumb), height: Metrics.track)
                        .position(x: width / 2, y: Metrics.trackRow / 2)
                    ForEach(Array(timeline.enumerated()), id: \.element.id) { index, scan in
                        notch(index: index, scan: scan, spacing: spacing(width: width))
                            .position(x: markX(index, width: width), y: Metrics.trackRow / 2)
                    }
                }
                .frame(height: Metrics.trackRow)

                ZStack(alignment: .topLeading) {
                    ForEach(Array(timeline.enumerated()), id: \.element.id) { index, scan in
                        if showsLabel(index) {
                            Text(Self.tickLabel(for: scan, in: timeline))
                                .font(.caption2)
                                .foregroundColor(index == visibleIndex ? .white : .gray)
                                .lineLimit(1).fixedSize()
                                .position(x: markX(index, width: width), y: Metrics.labelRow / 2)
                        }
                    }
                }
                .frame(height: Metrics.labelRow)
            }
            // Both rows are one tall touch surface, so the column for a notch is grabbable well
            // above and below the notch itself.
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: width, dragEnabled: dragEnabled))
        }
        .frame(height: Metrics.trackRow + 3 + Metrics.labelRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scan timeline")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: visibleIndex = min(visibleIndex + 1, timeline.count - 1)
            case .decrement: visibleIndex = max(visibleIndex - 1, 0)
            @unknown default: break
            }
        }
        .modifier(ArmingAccessibilityAction(
            armable: pendingA != nil && pendingA != visibleIndex,
            label: visible.map { "Compare with \($0.name) as B" } ?? "Compare as B",
            action: { if let sideA = pendingA { arm(sideA: sideA, sideB: visibleIndex) } }
        ))
    }

    private func scrubGesture(width: CGFloat, dragEnabled: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard dragEnabled else { return }
                // Only once the finger has actually travelled: otherwise a plain tap would be
                // consumed as a scrub and never reach the tick semantics.
                if isScrubbing || abs(value.translation.width) > 2 {
                    isScrubbing = true
                    visibleIndex = nearestIndex(atX: value.location.x, width: width)
                }
            }
            .onEnded { value in
                let index = nearestIndex(atX: value.location.x, width: width)
                if isScrubbing {
                    isScrubbing = false
                    visibleIndex = index
                } else {
                    select(index)
                }
            }
    }

    /// Labels are dropped past `timelineMaxTickLabels` generations (they'd overlap into noise) — the
    /// NOTCHES always stay, they're what makes the increments readable, and the selected one keeps
    /// its label so the position is never unlabelled. The readout above names it in full either way.
    private func showsLabel(_ index: Int) -> Bool {
        timeline.count <= AppConstants.timelineMaxTickLabels || index == visibleIndex
    }

    private var accessibilityValue: String {
        guard let visible else { return "" }
        let position = "\(visibleIndex + 1) of \(timeline.count)"
        return "\(visible.name), \(Self.absoluteLabel(visible.capturedAt)), \(position)"
    }

    // MARK: Rows

    private var readout: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                if let pendingA {
                    let sideA = timeline.indices.contains(pendingA) ? timeline[pendingA].name : "—"
                    Text("Pick a scan to compare")
                        .font(.subheadline.weight(.semibold)).foregroundColor(.cyan)
                    Text("A is \(sideA) · tap another notch for B")
                        .font(.caption2).foregroundColor(.gray)
                } else {
                    HStack(spacing: 6) {
                        if let badge = comparison?.badge(for: visibleIndex) {
                            Text(badge)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.cyan).foregroundColor(.black)
                                .clipShape(Capsule())
                        }
                        Text(visible?.name ?? "—")
                            .font(.subheadline.weight(.semibold)).foregroundColor(.white)
                            .lineLimit(1)
                    }
                    Text(subtitle)
                        .font(.caption2).foregroundColor(.gray).lineLimit(1)
                }
                if let visible, state.unregisteredIDs.contains(visible.id) {
                    // Honest about the 4D contract: this generation never registered into the
                    // room's canonical frame, so any offset you see here is the registration
                    // failing — not the room moving.
                    Text("Not registered to the room frame — may sit offset")
                        .font(.caption2).foregroundColor(.orange).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            abButton
        }
    }

    private var subtitle: String {
        guard let visible else { return "" }
        return "\(Self.absoluteLabel(visible.capturedAt)) · \(visible.relativeAge)"
    }

    /// One increment on the track: a notch bar (so the stops are visible even when the labels are
    /// dropped) plus its mark. HOLLOW until that generation is resident — that doubles as the
    /// progress indication for the background prefetch, so the bar needs no second progress control.
    /// The SELECTED mark is the thumb: it sits on its notch, enlarged, and carries the failed-load
    /// or A/B badge inside itself. Marks thin down rather than overlap once the notches crowd.
    @ViewBuilder
    private func notch(index: Int, scan: TimelineScan, spacing: CGFloat) -> some View {
        let selected = index == visibleIndex
        let badge = badge(for: index)
        let resident = state.readyIDs.contains(scan.id)
        let tight = spacing < Metrics.tightSpacing
        let diameter: CGFloat = selected ? Metrics.thumb
            : (badge != nil ? Metrics.mark : (tight ? Metrics.markTight : Metrics.mark))
        ZStack {
            Capsule()
                .fill(Color.white.opacity(selected ? 0.0 : (tight ? 0.28 : 0.45)))
                .frame(width: Metrics.notchWidth, height: Metrics.notchHeight)
            Circle()
                // Unloaded generations stay HOLLOW (clear, not dark) — an empty ring on the bar's
                // material reads as "not here yet"; a filled dark dot reads as another state.
                .fill(selected ? Color.cyan : (resident ? Color.gray.opacity(0.85) : Color.clear))
                .overlay(
                    Circle().strokeBorder(selected || badge != nil ? Color.cyan : Color.gray,
                                          lineWidth: 1.5)
                )
                .frame(width: diameter, height: diameter)
                .shadow(color: .black.opacity(selected ? 0.4 : 0), radius: 2, y: 1)
            if state.failedIDs.contains(scan.id) {
                Image(systemName: "exclamationmark")
                    .font(.system(size: selected ? 11 : 9, weight: .bold)).foregroundColor(.orange)
            } else if let badge {
                Text(badge)
                    .font(.system(size: selected ? 11 : 8, weight: .bold))
                    .foregroundColor(selected ? .black : .cyan)
            }
        }
        .frame(width: Metrics.thumb, height: Metrics.trackRow)
    }

    /// The A/B badge a notch wears: the pinned side once armed, or the parked A while arming (so it
    /// stays visible on the strip while the cursor goes looking for B).
    private func badge(for index: Int) -> String? {
        if let pendingA, pendingA == index { return "A" }
        return comparison?.badge(for: index)
    }

    private var loadingRow: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini).tint(.gray)
            Text("Loading \(state.resolvedCount(in: timeline)) of \(timeline.count) scans…")
                .font(.caption2).foregroundColor(.gray)
        }
    }

    // MARK: A/B

    private var abButton: some View {
        let active = comparison != nil || pendingA != nil
        return Button {
            if active {
                exitComparison()
            } else {
                // Pin A to what's already on screen so arming a comparison is ONE more tap.
                pendingA = visibleIndex
            }
        } label: {
            Text(active ? "Exit A/B" : "A/B")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(active ? Color.cyan : Color.white.opacity(0.12))
                .foregroundColor(active ? .black : .white)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(active ? "Exit A/B comparison" : "Compare two scans")
    }

    private func flipControls(_ comparison: ABComparison) -> some View {
        HStack(spacing: 10) {
            sideChip("A", index: comparison.sideA)
            Button { visibleIndex = comparison.other(than: visibleIndex) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right")
                    Text("Flip").font(.subheadline.bold())
                }
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(Color.cyan)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .foregroundColor(.black)
            sideChip("B", index: comparison.sideB)
            Button { isBlinking.toggle() } label: {
                Image(systemName: isBlinking ? "stop.fill" : "arrow.triangle.2.circlepath")
                    .font(.subheadline)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(isBlinking ? Color.orange : Color.white.opacity(0.12))
                    .foregroundColor(isBlinking ? .black : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isBlinking ? "Stop auto blink" : "Auto blink between A and B")
        }
    }

    private func sideChip(_ badge: String, index: Int) -> some View {
        let scan = timeline.indices.contains(index) ? timeline[index] : nil
        let selected = index == visibleIndex
        return Button { visibleIndex = index } label: {
            VStack(spacing: 0) {
                Text(badge).font(.caption2.weight(.bold))
                Text(scan.map { Self.tickLabel(for: $0, in: timeline) } ?? "—")
                    .font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? Color.cyan.opacity(0.25) : Color.white.opacity(0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.cyan : Color.clear, lineWidth: 1.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show \(badge), \(scan.map { Self.absoluteLabel($0.capturedAt) } ?? "")")
    }

    /// Notch tap. Three meanings, by state: pick B while arming; re-point B while armed (so you can
    /// keep exploring without leaving the comparison); plain seek otherwise.
    private func select(_ index: Int) {
        if let sideA = pendingA {
            // Tapping A itself just shows A — A and B have to be different generations.
            guard index != sideA else { visibleIndex = index; return }
            arm(sideA: sideA, sideB: index)
        } else if let armed = comparison, !armed.contains(index) {
            comparison = ABComparison(sideA: armed.sideA, sideB: index)
            visibleIndex = index
        } else {
            visibleIndex = index
        }
    }

    private func arm(sideA: Int, sideB: Int) {
        comparison = ABComparison(sideA: sideA, sideB: sideB)
        pendingA = nil
        visibleIndex = sideB
    }

    private func exitComparison() {
        comparison = nil
        pendingA = nil
        isBlinking = false
    }

    // MARK: Date labels

    /// Compact absolute tick label: "Jun 11", with the year when it isn't the current one, and the
    /// TIME instead when another generation shares the same calendar day (two scans of one room in
    /// a day is the ordinary QA case, and two identical ticks would be unreadable).
    static func tickLabel(for scan: TimelineScan, in timeline: [TimelineScan]) -> String {
        let calendar = Calendar.current
        let sharesDay = timeline.contains {
            $0.id != scan.id && calendar.isDate($0.capturedAt, inSameDayAs: scan.capturedAt)
        }
        if sharesDay { return TimelineDateFormat.time.string(from: scan.capturedAt) }
        if calendar.component(.year, from: scan.capturedAt) == calendar.component(.year, from: Date()) {
            return TimelineDateFormat.dayMonth.string(from: scan.capturedAt)
        }
        return TimelineDateFormat.dayMonthYear.string(from: scan.capturedAt)
    }

    /// Unambiguous date + time for the readout line, where there's room for it.
    static func absoluteLabel(_ date: Date) -> String {
        TimelineDateFormat.full.string(from: date)
    }
}

/// Adds the "compare as B" action to the scrubber only while a comparison is being armed. The
/// notches are drawn, not buttons, so VoiceOver has nothing to tap to pick B — it adjusts the
/// scrubber to the generation it wants and then invokes this. (A conditional `.accessibilityAction`
/// needs a modifier: applying one inside an `if` would change the view's type between states.)
private struct ArmingAccessibilityAction: ViewModifier {
    let armable: Bool
    let label: String
    let action: () -> Void

    func body(content: Content) -> some View {
        if armable {
            content.accessibilityAction(named: Text(label), action)
        } else {
            content
        }
    }
}

/// Cached formatters — building a `DateFormatter` is expensive and these render on every scrub.
/// Localized templates rather than hardcoded patterns so the day/month order follows the device.
private enum TimelineDateFormat {
    static let dayMonth: DateFormatter = {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("MMMd")
        return fmt
    }()
    static let dayMonthYear: DateFormatter = {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("MMMdyy")
        return fmt
    }()
    static let time: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .none
        fmt.timeStyle = .short
        return fmt
    }()
    static let full: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt
    }()
}
