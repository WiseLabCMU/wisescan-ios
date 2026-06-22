import Foundation
import RoomPlan

/// Results of a pre-scan space analysis. Each check is either `.pass` (good), `.warn` (actionable),
/// or `.skipped` (could not evaluate, e.g. RoomPlan not available for doors/screens).
struct SpaceAnalysisResult {
    enum CheckStatus {
        case pass(String)         // Green: condition is good, with description
        case warn(String)         // Yellow: condition needs attention, with recommendation
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
/// 2. Feed `updateYaw(_:)` from the ARFrame yaw each frame.
/// 3. When `isComplete` becomes true (360° covered or timeout), call `buildReport(...)`.
@Observable
class SpaceAnalyzer {
    /// Coverage of the 360° yaw sweep, 0.0–1.0.
    var progress: Float = 0
    /// True once the analysis is complete (360° reached or timeout).
    var isComplete: Bool = false
    /// Human-readable progress label for the overlay.
    var progressLabel: String = "Pan slowly around the room…"

    // MARK: - Private state

    /// Set of yaw buckets (0..<360) that have been visited. Each bucket is 1°.
    private var visitedBuckets: Set<Int> = []
    /// Start time for the fallback timeout.
    private var startTime: Date = .distantPast
    /// Whether the first yaw sample has been received (gate the "waiting for data" state).
    private var hasFirstSample = false

    // MARK: - Lifecycle

    /// Resets all tracking state and starts the analysis window.
    func start() {
        visitedBuckets = []
        progress = 0
        isComplete = false
        hasFirstSample = false
        progressLabel = "Pan slowly around the room…"
        startTime = Date()
    }

    /// Feed the raw camera yaw (radians, ±π from ARFrame.camera.eulerAngles.y).
    /// Call this on main from the ScanStats.analysisYaw observer.
    func updateYaw(_ yawRadians: Float) {
        guard !isComplete else { return }
        hasFirstSample = true

        // Convert radians to 0–359 bucket
        var degrees = yawRadians * (180.0 / .pi)
        if degrees < 0 { degrees += 360 }
        let bucket = Int(degrees.truncatingRemainder(dividingBy: 360))
        visitedBuckets.insert(max(0, min(359, bucket)))

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

    // MARK: - Report Generation

    /// Builds the analysis report from the current ScanStats snapshot.
    /// - Parameters:
    ///   - stats: The ScanStats populated during the analysis window.
    ///   - privacyFilterOn: Whether the privacy filter is currently enabled.
    func buildReport(from stats: ScanStats, privacyFilterOn: Bool) -> SpaceAnalysisResult {
        var result = SpaceAnalysisResult()

        // ── Lighting ──
        let avgLight = stats.averageAmbientIntensity
        if avgLight > 0 {
            if avgLight >= AppConstants.analysisAmbientLightThreshold {
                result.lighting = .pass("Lighting is good (\(Int(avgLight)) lumens)")
            } else {
                result.lighting = .warn("Low lighting (\(Int(avgLight)) lumens). Turn on lights for better detail.")
            }
        } else {
            result.lighting = .skipped("Could not measure lighting")
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
