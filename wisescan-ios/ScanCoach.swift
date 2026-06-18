import Foundation
import Observation
import RoomPlan
import simd

// MARK: - Coach Tip Model

/// A single coaching tip to display in the coach bar.
struct CoachTip: Equatable, Identifiable {
    let id: String          // Stable identifier for cooldown/dismiss tracking
    let message: String
    let icon: String        // SF Symbol name
    let priority: TipPriority

    static func == (lhs: CoachTip, rhs: CoachTip) -> Bool { lhs.id == rhs.id }
}

/// Priority tiers for scan coaching tips, ordered from highest to lowest.
enum TipPriority: Int, Comparable {
    case critical = 3   // Tracking lost/degraded — stays until resolved
    case warning = 2    // Near capacity, motion blur — 8s or resolved
    case guidance = 1   // Scan pattern hints — 6s, cooldown 30s
    case info = 0       // Progress encouragement — 5s, cooldown 60s

    static func < (lhs: TipPriority, rhs: TipPriority) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Background color for the coach bar at this priority level.
    var color: (red: Double, green: Double, blue: Double) {
        switch self {
        case .critical: return (0.9, 0.2, 0.2)   // Red
        case .warning:  return (0.95, 0.6, 0.1)   // Orange
        case .guidance: return (0.35, 0.35, 0.85)  // Indigo
        case .info:     return (0.2, 0.75, 0.4)    // Green
        }
    }

    /// Default SF Symbol for this priority level (tips can override).
    var defaultIcon: String {
        switch self {
        case .critical: return "exclamationmark.triangle.fill"
        case .warning:  return "exclamationmark.triangle.fill"
        case .guidance: return "lightbulb.fill"
        case .info:     return "checkmark.circle.fill"
        }
    }

    /// Auto-dismiss duration. `nil` means stays until resolved.
    var autoDismissSeconds: TimeInterval? {
        switch self {
        case .critical: return nil // stays until resolved
        case .warning:  return AppConstants.warningAutoDismissSeconds
        case .guidance: return AppConstants.guidanceAutoDismissSeconds
        case .info:     return AppConstants.infoAutoDismissSeconds
        }
    }

    /// Minimum cooldown before this tip can re-show.
    var cooldownSeconds: TimeInterval {
        switch self {
        case .critical, .warning: return 0 // no cooldown — condition-driven
        case .guidance: return AppConstants.guidanceCooldownSeconds
        case .info:     return AppConstants.infoCooldownSeconds
        }
    }
}

// MARK: - ScanCoach Engine

/// Rules engine that evaluates live scan data and produces a single coaching tip.
/// Owned by CaptureView as `@State`; fed at ~1Hz with current scan metrics.
/// Thread-safe: evaluate() runs on a background queue, publishes result to main.
@Observable
class ScanCoach {
    /// The current tip to display (nil = no tip).
    private(set) var currentTip: CoachTip?

    /// Timestamp when the current tip was first shown (for auto-dismiss).
    private var tipShownAt: Date?

    // MARK: - Anti-nag state (per-session)

    /// When each tip ID was last shown.
    private var tipCooldowns: [String: Date] = [:]
    /// How many times each tip ID has been shown this session.
    private var tipShowCounts: [String: Int] = [:]
    /// Tips manually dismissed by the user (track count for suppression).
    private var tipDismissCounts: [String: Int] = [:]

    /// Timestamp of last evaluation (throttle gate).
    private var lastEvaluationTime: Date = .distantPast

    /// Background queue for evaluation (keeps main thread free).
    private let evaluationQueue = DispatchQueue(label: "com.scan4d.scancoach", qos: .utility)

    // MARK: - Public API

    /// Resets all state for a new recording session.
    func reset() {
        currentTip = nil
        tipShownAt = nil
        tipCooldowns.removeAll()
        tipShowCounts.removeAll()
        tipDismissCounts.removeAll()
        lastEvaluationTime = .distantPast
    }

    /// Manually dismiss the current tip (user swiped up).
    func dismissCurrentTip() {
        guard let tip = currentTip else { return }
        tipDismissCounts[tip.id, default: 0] += 1
        // Set cooldown to 60s for manually dismissed tips
        tipCooldowns[tip.id] = Date()
        currentTip = nil
        tipShownAt = nil
    }

    /// Main evaluation entry point. Called at ~1Hz from CaptureView.
    /// Computes the highest-priority active tip and publishes it.
    func evaluate(
        scanStats: ScanStats,
        frameCaptureSession: FrameCaptureSession,
        capturedRoom: CapturedRoom?,
        semanticLabelingEnabled: Bool,
        isRecording: Bool,
        coachingEnabled: Bool = true
    ) {
        guard isRecording else {
            if currentTip != nil {
                currentTip = nil
                tipShownAt = nil
            }
            return
        }

        // Throttle: skip if less than the evaluation interval has passed
        let now = Date()
        guard now.timeIntervalSince(lastEvaluationTime) >= AppConstants.coachEvaluationInterval else { return }
        lastEvaluationTime = now

        // Auto-dismiss check for time-limited tips
        if let tip = currentTip, let shownAt = tipShownAt,
           let autoDismiss = tip.priority.autoDismissSeconds,
           now.timeIntervalSince(shownAt) >= autoDismiss {
            currentTip = nil
            tipShownAt = nil
        }

        // Snapshot values for background evaluation
        let trackingStatus = scanStats.trackingStatus
        let isBlurActive = frameCaptureSession.isBlurWarningActive
        let blurReason = frameCaptureSession.blurWarningReason
        let isNearCapacity = scanStats.isNearCapacity
        let isAtCapacity = scanStats.isAtCapacity
        let sessionDuration = scanStats.sessionDuration
        let anchorCount = scanStats.anchorCount
        let totalFaces = scanStats.totalFaces
        let capacityScore = scanStats.capacityScore
        let mappingStatus = scanStats.mappingStatus
        let detectedClasses = scanStats.detectedClasses
        let recentTransforms = frameCaptureSession.recentTransforms(count: 30)
        let roomPlanInstruction = scanStats.roomPlanInstruction

        // Capture RoomPlan data for semantic tips
        let hasWalls = capturedRoom?.walls.isEmpty == false
        let hasFloors = capturedRoom?.floors.isEmpty == false
        let objectCount = capturedRoom?.objects.count ?? 0
        let surfaceCount = (capturedRoom?.walls.count ?? 0) + (capturedRoom?.floors.count ?? 0)

        evaluationQueue.async { [weak self] in
            guard let self = self else { return }

            let candidateTip = self.computeBestTip(
                trackingStatus: trackingStatus,
                isBlurActive: isBlurActive,
                blurReason: blurReason,
                isNearCapacity: isNearCapacity,
                isAtCapacity: isAtCapacity,
                sessionDuration: sessionDuration,
                anchorCount: anchorCount,
                totalFaces: totalFaces,
                capacityScore: capacityScore,
                mappingStatus: mappingStatus,
                detectedClasses: detectedClasses,
                recentTransforms: recentTransforms,
                roomPlanInstruction: roomPlanInstruction,
                semanticLabelingEnabled: semanticLabelingEnabled,
                hasWalls: hasWalls,
                hasFloors: hasFloors,
                objectCount: objectCount,
                surfaceCount: surfaceCount,
                now: now,
                coachingEnabled: coachingEnabled
            )

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                if let newTip = candidateTip {
                    // Only update if it's a different tip or higher priority than current
                    if self.currentTip == nil || newTip.id != self.currentTip?.id {
                        // Higher priority always preempts
                        if let current = self.currentTip, newTip.priority <= current.priority {
                            // Don't replace current with lower/equal priority
                            // UNLESS current has auto-dismissed (already nil'd above)
                            return
                        }
                        self.currentTip = newTip
                        self.tipShownAt = now
                        self.tipShowCounts[newTip.id, default: 0] += 1
                        self.tipCooldowns[newTip.id] = now
                    }
                } else if let current = self.currentTip, current.priority >= .critical {
                    // CRITICAL/WARNING condition resolved — clear immediately
                    if current.priority == .critical || current.priority == .warning {
                        self.currentTip = nil
                        self.tipShownAt = nil
                    }
                }
            }
        }
    }

    // MARK: - Rules Engine

    // swiftlint:disable:next function_parameter_count
    private func computeBestTip(
        trackingStatus: TrackingStatus,
        isBlurActive: Bool,
        blurReason: FrameCaptureSession.CaptureWarning?,
        isNearCapacity: Bool,
        isAtCapacity: Bool,
        sessionDuration: TimeInterval,
        anchorCount: Int,
        totalFaces: Int,
        capacityScore: Double,
        mappingStatus: String,
        detectedClasses: Set<String>,
        recentTransforms: [simd_float4x4],
        roomPlanInstruction: RoomCaptureSession.Instruction?,
        semanticLabelingEnabled: Bool,
        hasWalls: Bool,
        hasFloors: Bool,
        objectCount: Int,
        surfaceCount: Int,
        now: Date,
        coachingEnabled: Bool
    ) -> CoachTip? {
        // Evaluate rules in priority order — first match wins

        // ── CRITICAL ──

        // Tracking degraded (not initializing/relocalizing — those are normal recovery)
        switch trackingStatus {
        case .limited(let reason):
            switch reason {
            case .excessiveMotion:
                return tip("critical.excessiveMotion",
                           "⚠️ Hold steady — excessive motion detected",
                           priority: .critical, now: now)
            case .insufficientFeatures:
                return tip("critical.insufficientFeatures",
                           "⚠️ Hold steady — not enough visual features",
                           priority: .critical, now: now)
            default: break
            }
        case .notAvailable:
            return tip("critical.notAvailable",
                       "⚠️ Tracking unavailable — hold device steady",
                       priority: .critical, now: now)
        default: break
        }

        // ── WARNING ──

        // Motion blur (fast motion)
        if isBlurActive, blurReason == .fastMotion {
            return tip("warning.fastMotion",
                       "⚠️ Slow down — moving too fast",
                       icon: "hare.fill",
                       priority: .warning, now: now)
        }

        // At capacity (critical)
        if isAtCapacity {
            return tip("warning.atCapacity",
                       "Session at capacity — save now to avoid quality loss",
                       icon: "exclamationmark.octagon.fill",
                       priority: .warning, now: now)
        }

        // Near capacity
        if isNearCapacity {
            return tip("warning.nearCapacity",
                       "Approaching session limits — consider saving",
                       priority: .warning, now: now)
        }

        // ── GUIDANCE ── (suppressed when coaching is disabled)

        guard coachingEnabled else { return nil }

        let isEarlyScan = sessionDuration < AppConstants.earlyScanThresholdSeconds

        // Early scan: scan all walls
        if isEarlyScan && anchorCount < 8 {
            let extent = cameraSpatialExtent(recentTransforms)
            if extent < 3.0 { // Less than 3m extent — haven't moved around much
                if let t = tip("guidance.scanWalls",
                               "🏠 Scan all 4 walls quickly for layout context",
                               priority: .guidance, now: now) { return t }
            }
        }

        // Early scan: systematic sweep
        if isEarlyScan && recentTransforms.count >= 10 {
            let pattern = cameraMovementPattern(recentTransforms)
            if pattern < 0.3 { // Erratic movement (low directional progress ratio)
                if let t = tip("guidance.systematicSweep",
                               "↔️ Start from one wall, sweep to the opposite",
                               icon: "arrow.left.and.right",
                               priority: .guidance, now: now) { return t }
            }
        }

        // Mid-scan: move closer for detail
        if !isEarlyScan && anchorCount > 5 && totalFaces > 0 {
            let facesPerAnchor = Double(totalFaces) / Double(anchorCount)
            if facesPerAnchor < 200 { // Very coarse geometry
                if let t = tip("guidance.moveCloser",
                               "🔍 Move closer to capture fine details",
                               icon: "magnifyingglass",
                               priority: .guidance, now: now) { return t }
            }
        }

        // Mid-scan: vary scanning height
        if !isEarlyScan && recentTransforms.count >= 15 {
            let heightVar = cameraHeightVariance(recentTransforms)
            if heightVar < 0.02 { // Less than ~14cm std dev — very flat scanning
                if let t = tip("guidance.varyHeight",
                               "↕️ Try scanning from a different height",
                               icon: "arrow.up.and.down",
                               priority: .guidance, now: now) { return t }
            }
        }

        // ── Semantic tips (only when labeling is ON) ──

        if semanticLabelingEnabled && !isEarlyScan {
            // Walls detected but no floor
            if hasWalls && !hasFloors {
                if let t = tip("guidance.semantic.scanFloor",
                               "🪟 Walls detected, try scanning the floor",
                               icon: "square.bottomhalf.filled",
                               priority: .guidance, now: now) { return t }
            }

            // Surfaces detected but few objects
            if surfaceCount >= 3 && objectCount == 0 {
                if let t = tip("guidance.semantic.scanObjects",
                               "🛋️ Don't forget furniture — scan objects up close",
                               icon: "sofa.fill",
                               priority: .guidance, now: now) { return t }
            }

            // Floor detected but objects only at height (low object count relative to surface area)
            if hasFloors && objectCount > 0 && objectCount < 3 {
                if let t = tip("guidance.semantic.lowerAngle",
                               "🔽 Try scanning from a lower angle for floor objects",
                               icon: "arrow.down.to.line",
                               priority: .guidance, now: now) { return t }
            }
        }

        // ── INFO ──

        // Good coverage encouragement
        if !isEarlyScan && anchorCount >= 15 && capacityScore < 0.5 {
            if let t = tip("info.goodCoverage",
                           "⭐ Coverage looking good!",
                           priority: .info, now: now) { return t }
        }

        // Great coverage — consider finishing
        if sessionDuration > 60 && mappingStatus == "mapped" && capacityScore > 0.3 && anchorCount >= 20 {
            // Check if mesh growth has plateaued (low face count relative to duration)
            let facesPerSecond = Double(totalFaces) / max(sessionDuration, 1)
            if facesPerSecond < 500 { // Growth has slowed
                if let t = tip("info.considerFinishing",
                               "✅ Great coverage — consider finishing",
                               priority: .info, now: now) { return t }
            }
        }

        return nil
    }

    // MARK: - Tip Factory (with cooldown/dismiss checks)

    /// Creates a tip if it passes cooldown and dismiss-count gates.
    /// Returns nil if the tip should be suppressed.
    private func tip(_ id: String, _ message: String, icon: String? = nil, priority: TipPriority, now: Date) -> CoachTip? {
        // CRITICAL and WARNING always show (no cooldown/dismiss suppression)
        if priority <= .guidance {
            // Check dismiss suppression
            if let dismissCount = tipDismissCounts[id], dismissCount >= AppConstants.coachMaxDismissCount {
                return nil // User dismissed this tip too many times
            }

            // Check cooldown
            if let lastShown = tipCooldowns[id] {
                let cooldown = priority.cooldownSeconds
                if now.timeIntervalSince(lastShown) < cooldown {
                    return nil // Still in cooldown
                }
            }
        }

        return CoachTip(
            id: id,
            message: message,
            icon: icon ?? priority.defaultIcon,
            priority: priority
        )
    }

    // MARK: - Spatial Analysis Helpers

    /// Bounding box extent of camera positions (max dimension).
    private func cameraSpatialExtent(_ transforms: [simd_float4x4]) -> Float {
        guard transforms.count >= 2 else { return 0 }
        var minPos = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxPos = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for t in transforms {
            let pos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            minPos = min(minPos, pos)
            maxPos = max(maxPos, pos)
        }
        let extent = maxPos - minPos
        return max(extent.x, max(extent.y, extent.z))
    }

    /// Standard deviation of camera Y-positions (scanning height diversity).
    private func cameraHeightVariance(_ transforms: [simd_float4x4]) -> Float {
        guard transforms.count >= 2 else { return 0 }
        let heights = transforms.map { $0.columns.3.y }
        let mean = heights.reduce(0, +) / Float(heights.count)
        let variance = heights.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(heights.count)
        return variance // Return variance (caller compares threshold)
    }

    /// Ratio of directional progress to total distance traveled.
    /// High ratio = systematic sweep; low ratio = erratic/clustered movement.
    private func cameraMovementPattern(_ transforms: [simd_float4x4]) -> Float {
        guard transforms.count >= 3 else { return 1.0 }

        var totalDistance: Float = 0
        for i in 1..<transforms.count {
            let prev = SIMD3<Float>(transforms[i-1].columns.3.x, transforms[i-1].columns.3.y, transforms[i-1].columns.3.z)
            let curr = SIMD3<Float>(transforms[i].columns.3.x, transforms[i].columns.3.y, transforms[i].columns.3.z)
            totalDistance += simd_distance(prev, curr)
        }

        guard totalDistance > 0.01 else { return 1.0 } // Not moving at all

        let first = SIMD3<Float>(transforms.first!.columns.3.x, transforms.first!.columns.3.y, transforms.first!.columns.3.z)
        let last = SIMD3<Float>(transforms.last!.columns.3.x, transforms.last!.columns.3.y, transforms.last!.columns.3.z)
        let directDistance = simd_distance(first, last)

        return directDistance / totalDistance
    }
}
