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

    /// When the fast-motion blur condition became continuously true (nil = not active).
    /// The demoted fastMotion hint requires the condition SUSTAINED, not a spike.
    private var blurActiveSince: Date?

    /// When the near-depth obstruction condition became continuously true.
    private var nearDepthActiveSince: Date?

    /// Background queue for evaluation (keeps main thread free).
    private let evaluationQueue = DispatchQueue(label: "com.scan4d.scancoach", qos: .utility)

    // MARK: - Public API

    /// Resets all state for a new recording session.
    func reset() {
        currentTip = nil
        tipShownAt = nil
        blurActiveSince = nil
        nearDepthActiveSince = nil
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
    /// Per-face ARMeshClassification census over the live mesh — the mesh-gap coach
    /// input, logged each refresh ([Coach] census) so the floor/ceiling thresholds can
    /// be tuned from field runs. wall/total ride along for that tuning only.
    struct MeshClassCensus {
        let ceiling: Int
        let floor: Int
        let wall: Int
        let total: Int
    }

    func evaluate(
        scanStats: ScanStats,
        frameCaptureSession: FrameCaptureSession,
        capturedRoom: CapturedRoom?,
        semanticLabelingEnabled: Bool,
        isRecording: Bool,
        coachingEnabled: Bool = true,
        meshGapCensus: MeshClassCensus? = nil,
        rigMode: Bool = false
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
        // Thermal state read directly (cheap, main-thread safe): on the field iPad,
        // .serious preceded the RoomPlan/OU EXC_BREAKPOINT crash by ~30 s (360post12) —
        // enough warning to wrap up and SAVE instead of losing the scan.
        let thermalState = ProcessInfo.processInfo.thermalState
        // Sustained-condition trackers (helpers keep evaluate's complexity flat):
        // the demoted fastMotion hint and the near-depth obstruction warning both
        // require their condition held continuously, not a spike.
        let fastMotionSustained = updateFastMotionSustain(
            isBlurActive: isBlurActive, blurReason: blurReason, now: now)
        let nearDepthSustained = updateNearDepthSustain(
            fraction: frameCaptureSession.nearDepthFraction, now: now)
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
        let sharpFrameCount = frameCaptureSession.sharpFrameCount
        let isCurrentlyStill = frameCaptureSession.isCurrentlyStill
        let photoCoverageFraction = scanStats.photoCoverageFraction
        let photoCoverageOccupied = scanStats.photoCoverageOccupied
        let meanStillOverlap = scanStats.meanStillOverlap
        let standpointDiversity = scanStats.standpointDiversity

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
                sharpFrameCount: sharpFrameCount,
                isCurrentlyStill: isCurrentlyStill,
                photoCoverageFraction: photoCoverageFraction,
                photoCoverageOccupied: photoCoverageOccupied,
                meanStillOverlap: meanStillOverlap,
                standpointDiversity: standpointDiversity,
                now: now,
                coachingEnabled: coachingEnabled,
                meshGapCensus: meshGapCensus,
                rigMode: rigMode,
                thermalState: thermalState,
                fastMotionSustained: fastMotionSustained,
                nearDepthSustained: nearDepthSustained
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
                        // Field-log which tips actually fired — 360post13 validated the
                        // near-depth warning only via the operator's word; logs should
                        // carry it (PerfDiag → Logger, survives Release).
                        PerfDiag.log("[Coach] tip: \(newTip.id)")
                    }
                } else if let current = self.currentTip, current.priority >= .warning {
                    // CRITICAL/WARNING condition resolved (no candidate tip this eval) — clear
                    // immediately rather than waiting out the full auto-dismiss timer. The guard MUST
                    // be `>= .warning`: `.critical` is the top tier, so the old `>= .critical` only
                    // ever matched critical and the inner `== .warning` branch was dead code — which
                    // is why a resolved WARNING (e.g. "Slow down — moving too fast" after the blur
                    // flag clears at blurWarningTimeout = 1.5s) lingered for the full
                    // warningAutoDismissSeconds (8s) instead of dismissing when the user held still.
                    // Guidance/info tips are time/cooldown-driven (not condition-driven), so the
                    // `>= .warning` guard correctly leaves them to their own auto-dismiss.
                    self.currentTip = nil
                    self.tipShownAt = nil
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
        sharpFrameCount: Int,
        isCurrentlyStill: Bool,
        photoCoverageFraction: Double,
        photoCoverageOccupied: Int,
        meanStillOverlap: Double,
        standpointDiversity: Double,
        now: Date,
        coachingEnabled: Bool,
        meshGapCensus: MeshClassCensus? = nil,
        rigMode: Bool = false,
        thermalState: ProcessInfo.ThermalState = .nominal,
        fastMotionSustained: TimeInterval = 0,
        nearDepthSustained: TimeInterval = 0
    ) -> CoachTip? {
        // Evaluate rules in priority order — first match wins

        // ── CRITICAL ──

        // Thermal runaway outranks everything: past .serious the OS is seconds-to-
        // minutes from killing RoomPlan/OU (360post12: ~30 s), and an unsaved scan is
        // a total loss — no other coaching matters if the session dies.
        if thermalState == .critical {
            return tip("critical.thermalCritical",
                       "🌡️ Device critically hot — save the scan NOW",
                       icon: "thermometer.high",
                       priority: .critical, now: now)
        }

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

        // Device hot: persistent while .serious — the one warning where persistence is
        // the point (crash imminent, action = end the scan). Everything chronic and
        // merely informational (fastMotion) lives in guidance now, so this channel
        // stays credible for exactly this moment.
        if thermalState == .serious {
            return tip("warning.thermalSerious",
                       "🌡️ Device hot — wrap up and save",
                       icon: "thermometer.high",
                       priority: .warning, now: now)
        }

        // Near-depth obstruction: something is parked centimeters from the LiDAR —
        // rig hardware (tension knob, strap) or a grip finger — and it is corrupting
        // depth on every frame it appears in. Condition-driven persistent warning:
        // it clears the moment the hardware is adjusted, and unlike fastMotion this
        // is never normal operation. The sustain gate keeps passing hands silent.
        if nearDepthSustained >= AppConstants.coachNearDepthSustainSeconds {
            return tip("warning.nearDepthObstruction",
                       rigMode ? "🔧 Something is right in front of the camera — check the rig clamp/knob"
                               : "🔧 Something is right in front of the camera — check your grip",
                       icon: "eye.trianglebadge.exclamationmark",
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

        // Mesh-gap coach — ALL scans (field verdict 2026-08-05: "useful with or without
        // 360 capture"), wording per source: on the rig the clamp-fixed pitch is the
        // cause (tilt the rod); handheld it's just an unswept surface. FLOOR at WARNING
        // tier — the nadir face is dropped downstream (operator), so LiDAR is the
        // floor's ONLY source; ceiling at guidance (up-faces give it image coverage;
        // mesh still helps the solver).
        if let census = meshGapCensus, sessionDuration > AppConstants.coachRigGapSeconds {
            if census.floor < AppConstants.coachFloorMinFaces {
                if let gapTip = tip("warning.rigFloorGap",
                                    rigMode ? "⬇️ Floor gaps — tilt the rig down briefly"
                                            : "⬇️ Floor not meshed — sweep the floor",
                                    icon: "arrow.down.to.line",
                                    priority: .warning, now: now) { return gapTip }
            }
            if census.ceiling < AppConstants.coachCeilingMinFaces, coachingEnabled {
                if let gapTip = tip("guidance.rigCeilingGap",
                                    rigMode ? "⬆️ Ceiling not meshed — tilt the rig up briefly"
                                            : "⬆️ Ceiling not meshed — sweep the ceiling",
                                    icon: "arrow.up.to.line",
                                    priority: .guidance, now: now) { return gapTip }
            }
        }

        // ── GUIDANCE ── (suppressed when coaching is disabled)

        guard coachingEnabled else { return nil }

        // Fast motion — DEMOTED from warning (field verdict 2026-08-05: as a persistent
        // warning it fired through every normal walk phase and trained the operator to
        // ignore the channel). It is informational by its own logic — moving builds
        // depth, only photo capture pauses — so it now (a) requires the motion
        // SUSTAINED for a few seconds, not a spike, (b) inherits guidance auto-dismiss
        // (6 s) + 30 s cooldown + swipe suppression, and (c) caps out per session.
        if fastMotionSustained >= AppConstants.coachFastMotionSustainSeconds,
           tipShowCounts["guidance.fastMotion", default: 0] < AppConstants.coachFastMotionMaxShows {
            if let hint = tip("guidance.fastMotion",
                              "⚡ Moving fast — depth only (pause for photos)",
                              icon: "hare.fill",
                              priority: .guidance, now: now) { return hint }
        }

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
                               "↔️ Walk the room for depth, pause at each area for photos",
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

        // Sharp photo captured — positive reinforcement when the user pauses and captures
        if isCurrentlyStill && sharpFrameCount > 0 && sharpFrameCount % 5 == 0 {
            if let t = tip("info.sharpCapture",
                           "📸 Sharp photo captured!",
                           icon: "camera.fill",
                           priority: .info, now: now) { return t }
        }

        // Good coverage encouragement
        if !isEarlyScan && anchorCount >= 15 && capacityScore < 0.5 {
            if let t = tip("info.goodCoverage",
                           "⭐ Coverage looking good!",
                           priority: .info, now: now) { return t }
        }

        // Encourage pausing for photos, driven by actual photo-coverage debt: depth mesh
        // is outrunning sharp-keyframe coverage. This replaces the old fixed 30s-since-last-
        // sharp-frame timer with a signal that reflects where coverage is actually lacking
        // (the amber regions of the overlay). Requires enough mesh to be meaningful, and the
        // user to be moving (a pause is already producing a keyframe).
        if !isEarlyScan && !isCurrentlyStill &&
           photoCoverageOccupied >= AppConstants.photoCoverageDebtMinVoxels &&
           photoCoverageFraction < AppConstants.photoCoverageDebtFraction {
            if let t = tip("guidance.pauseForPhoto",
                           "📸 Hold still on amber areas, then tap for a photo",
                           icon: "camera.fill",
                           priority: .guidance, now: now) { return t }
        }

        // Multi-view stills coaching — both need a few stills of signal first.
        if !isEarlyScan && sharpFrameCount >= AppConstants.stillOverlapMinStills {
            // Stills barely overlap each other: splat/photogrammetry texture wants
            // ~60% shared content between neighboring photos, not isolated islands.
            if meanStillOverlap < AppConstants.stillOverlapFloor {
                if let overlapTip = tip("guidance.stillOverlap",
                                        "📸 Overlap your photos — shoot the next one closer to the last",
                                        icon: "square.on.square",
                                        priority: .guidance, now: now) { return overlapTip }
            }
            // Photo coverage is all single-standpoint: parallax (a sidestep between
            // photos) matters more than re-aiming from the same spot.
            if standpointDiversity < AppConstants.stillParallaxDiversityFloor {
                if let parallaxTip = tip("guidance.stillParallax",
                                         "↔️ Step sideways and photograph covered areas again",
                                         icon: "figure.walk",
                                         priority: .guidance, now: now) { return parallaxTip }
            }
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

    // MARK: - Sustained-condition trackers

    /// How long the fast-motion blur condition has been continuously true.
    private func updateFastMotionSustain(isBlurActive: Bool,
                                         blurReason: FrameCaptureSession.CaptureWarning?,
                                         now: Date) -> TimeInterval {
        if isBlurActive, blurReason == .fastMotion {
            if blurActiveSince == nil { blurActiveSince = now }
        } else {
            blurActiveSince = nil
        }
        return blurActiveSince.map { now.timeIntervalSince($0) } ?? 0
    }

    /// How long the near-depth obstruction fraction has been continuously over threshold.
    private func updateNearDepthSustain(fraction: Float, now: Date) -> TimeInterval {
        if fraction >= AppConstants.nearDepthObstructionMinFraction {
            if nearDepthActiveSince == nil { nearDepthActiveSince = now }
        } else {
            nearDepthActiveSince = nil
        }
        return nearDepthActiveSince.map { now.timeIntervalSince($0) } ?? 0
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
