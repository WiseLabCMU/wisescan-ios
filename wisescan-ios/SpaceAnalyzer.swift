import Foundation
import RoomPlan

/// Results of a pre-scan space analysis. Each check is `.pass` (good), `.warn` (actionable),
/// `.alert` (critical — usability impact), or `.skipped` (could not evaluate).
struct SpaceAnalysisResult {
    enum CheckStatus {
        case pass(String)         // Green: condition is good, with description
        case warn(String)         // Yellow: condition needs attention, with recommendation
        case alert(String)        // Red: critical issue — scan quality severely impacted
        case skipped(String)      // Gray: could not evaluate, with reason
    }

    var lighting: CheckStatus = .skipped("Not evaluated")
    var screens: CheckStatus = .skipped("Not evaluated")
    var doors: CheckStatus = .skipped("Not evaluated")
    var people: CheckStatus = .skipped("Not evaluated")
}

/// Tracks camera yaw coverage during the analysis phase and produces a final report.
/// Designed to be `@Observable` so CaptureView can display live 360° progress.
///
/// Usage:
/// 1. Call `start()` to begin the analysis (resets all state).
/// 2. Feed `updateYaw(_:currentLux:)` from the ARFrame yaw each frame.
/// 3. When `isComplete` becomes true (360° covered or timeout), call `buildReport(...)`.
@Observable
class SpaceAnalyzer {
    /// Coverage of the 360° yaw sweep, 0.0–1.0.
    var progress: Float = 0
    /// True once the analysis is complete (360° reached or timeout).
    var isComplete: Bool = false
    /// Human-readable progress label for the overlay.
    var progressLabel: String = "Pan slowly around the room…"

    // MARK: - Lighting tier for per-zone tracking

    enum LightTier: Int {
        case alert = 0   // < alertThreshold (very dark — RGB nearly useless)
        case warn = 1    // < warnThreshold (dim — reduced quality)
        case pass = 2    // >= warnThreshold (good)
    }

    // MARK: - Private state

    /// Set of yaw buckets (0..<360) that have been visited. Each bucket is 1°.
    private var visitedBuckets: Set<Int> = []
    /// Per-bucket lighting tier: first lux reading at each bucket determines its tier.
    /// Only buckets that have been visited have entries.
    private var bucketTiers: [Int: LightTier] = [:]
    /// Start time for the fallback timeout.
    private var startTime: Date = .distantPast
    /// Whether the first yaw sample has been received (gate the "waiting for data" state).
    private var hasFirstSample = false

    // MARK: - Lifecycle

    /// Resets all tracking state and starts the analysis window.
    func start() {
        visitedBuckets = []
        bucketTiers = [:]
        progress = 0
        isComplete = false
        hasFirstSample = false
        progressLabel = "Pan slowly around the room…"
        startTime = Date()
    }

    /// Feed the raw camera yaw (radians, ±π from ARFrame.camera.eulerAngles.y) and the
    /// current ambient intensity (lux from ARFrame.lightEstimate).
    /// Call this on main from the ScanStats observer.
    func updateYaw(_ yawRadians: Float, currentLux: CGFloat) {
        guard !isComplete else { return }
        hasFirstSample = true

        // Convert radians to 0–359 bucket
        var degrees = yawRadians * (180.0 / .pi)
        if degrees < 0 { degrees += 360 }
        let bucket = Int(degrees.truncatingRemainder(dividingBy: 360))
        let clampedBucket = max(0, min(359, bucket))
        visitedBuckets.insert(clampedBucket)

        // Tag the bucket with its lux tier on first visit
        if bucketTiers[clampedBucket] == nil {
            bucketTiers[clampedBucket] = Self.luxTier(for: currentLux)
        }

        // Update progress
        let covered = Float(visitedBuckets.count)
        progress = min(1.0, covered / AppConstants.analysisYawCompletionDeg)

        // Update label
        if progress < 0.3 {
            progressLabel = "Keep panning slowly… \(Int(progress * 100))%"
        } else if progress < 0.7 {
            progressLabel = "Good progress! \(Int(progress * 100))%"
        } else if progress < 1.0 {
            progressLabel = "Almost done… \(Int(progress * 100))%"
        }

        // Check completion
        if visitedBuckets.count >= Int(AppConstants.analysisYawCompletionDeg) {
            complete()
        }

        // Fallback timeout
        if Date().timeIntervalSince(startTime) >= AppConstants.analysisTimeoutSeconds {
            complete()
        }
    }

    private func complete() {
        guard !isComplete else { return }
        isComplete = true
        progress = 1.0
        progressLabel = "Analysis complete!"
    }

    /// Classifies a lux value into a lighting tier using centralized AppConstants thresholds.
    private static func luxTier(for lux: CGFloat) -> LightTier {
        if lux < AppConstants.analysisAmbientLightAlertThreshold { return .alert }
        if lux < AppConstants.analysisAmbientLightWarnThreshold { return .warn }
        return .pass
    }

    // MARK: - Lighting Zone Breakdown

    /// Computes the percentage of visited buckets in each lighting tier.
    /// Returns (alertPct, warnPct, passPct) as 0–100 integers.
    private func lightingZoneBreakdown() -> (alert: Int, warn: Int, pass: Int) {
        let total = bucketTiers.count
        guard total > 0 else { return (0, 0, 100) }
        let alertCount = bucketTiers.values.filter { $0 == .alert }.count
        let warnCount = bucketTiers.values.filter { $0 == .warn }.count
        let passCount = total - alertCount - warnCount
        return (
            alert: Int(round(Double(alertCount) / Double(total) * 100)),
            warn: Int(round(Double(warnCount) / Double(total) * 100)),
            pass: Int(round(Double(passCount) / Double(total) * 100))
        )
    }

    // MARK: - Report Generation

    /// Builds the analysis report from the current ScanStats snapshot.
    /// - Parameters:
    ///   - stats: The ScanStats populated during the analysis window.
    ///   - privacyFilterOn: Whether the privacy filter is currently enabled.
    func buildReport(from stats: ScanStats, privacyFilterOn: Bool) -> SpaceAnalysisResult {
        var result = SpaceAnalysisResult()

        // ── Lighting (3-tier with per-zone breakdown) ──
        let zones = lightingZoneBreakdown()
        let avgLight = stats.averageAmbientIntensity
        if bucketTiers.isEmpty {
            result.lighting = .skipped("Could not measure lighting")
        } else if zones.alert > 0 && zones.alert >= zones.warn && zones.alert >= zones.pass {
            // Majority dark — alert
            result.lighting = .alert(
                "Very low lighting — RGB capture will be poor.\n" +
                "\(zones.pass)% well-lit · \(zones.warn)% dim · \(zones.alert)% very dark\n" +
                "Turn on lights for usable scan data."
            )
        } else if zones.alert > 0 || zones.warn > 20 {
            // Some dark zones or significant dim areas — warn
            result.lighting = .warn(
                "Dim areas detected — scan quality may be reduced.\n" +
                "\(zones.pass)% well-lit · \(zones.warn)% dim · \(zones.alert)% very dark\n" +
                "Consider adding more light."
            )
        } else {
            result.lighting = .pass(
                "Lighting is good (\(Int(avgLight)) lux)\n" +
                "\(zones.pass)% well-lit · \(zones.warn)% dim"
            )
        }

        // ── Screens (TV/Monitor via RoomPlan) ──
        if let room = stats.analysisRoom {
            let hasTV = room.objects.contains { $0.category == .television }
            if hasTV {
                result.screens = .warn("TV or monitor detected. Turn off screens to reduce visual artifacts.")
            } else {
                result.screens = .pass("No screens detected")
            }
        } else {
            result.screens = .skipped("Room detection not available")
        }

        // ── Doors (via RoomPlan) ──
        if let room = stats.analysisRoom {
            let doorCount = room.doors.count + room.openings.count
            if doorCount > 0 {
                result.doors = .warn("Door\(doorCount > 1 ? "s" : "") detected. Close doors to avoid trailing incomplete sections.")
            } else {
                result.doors = .pass("No open doors detected")
            }
        } else {
            result.doors = .skipped("Room detection not available")
        }

        // ── People/Pets ──
        // Person segmentation is always active during analysis (temporarily enabled even when
        // Privacy Filter is OFF), so we can always report on detection results.
        if stats.personDetectedDuringAnalysis {
            if privacyFilterOn {
                result.people = .warn("People detected. They will be masked from raw data.\nNote: Person detections still appear in previews.")
            } else {
                result.people = .warn("People detected. They will appear in raw data.\nTip: Enable the Privacy Filter to remove people from raw data.\nNote: Person detections still appear in previews.")
            }
        } else {
            result.people = .pass("No people detected")
        }

        return result
    }

    /// Resets analysis-specific fields in ScanStats for a fresh analysis run.
    func resetStats(_ stats: ScanStats) {
        stats.averageAmbientIntensity = 0
        stats.ambientLightSampleCount = 0
        stats.analysisRoom = nil
        stats.personDetectedDuringAnalysis = false
        stats.analysisYaw = 0
    }
}
