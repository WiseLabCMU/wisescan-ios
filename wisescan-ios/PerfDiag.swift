import Foundation
import QuartzCore
import os

/// Lightweight performance diagnostics for investigating mid-scan ARKit VIO starvation
/// (the 1–2s freeze + tracking drift). Everything here is a **no-op unless the
/// `perfDiagnostics` Developer-Mode flag is on**, so it is safe to leave the
/// instrumentation calls in hot paths permanently.
///
/// Output goes to two places:
/// - `OSLog`/`Logger` (subsystem `org.arenaxr.scan4d`, category `perf`) — visible live in
///   Xcode's console and in Console.app while a device is attached.
/// - `os_signpost` intervals via `OSSignposter` — show up on the **Instruments** timeline
///   (Points of Interest / os_signpost), so an encode/GPU spike can be visually correlated
///   with a main-thread stall and an ARKit frame gap.
enum PerfDiag {
    /// Cached so hot paths are a single branch instead of a `UserDefaults` read.
    /// Refresh via `refresh()` when entering the capture screen.
    nonisolated(unsafe) static var enabled: Bool =
        UserDefaults.standard.bool(forKey: AppConstants.Key.perfDiagnostics)

    /// Re-read the toggle (call when the capture view appears so a Settings change takes effect).
    static func refresh() {
        enabled = UserDefaults.standard.bool(forKey: AppConstants.Key.perfDiagnostics)
    }

    static let subsystem = "org.arenaxr.scan4d"
    private static let logger = Logger(subsystem: subsystem, category: "perf")
    private static let signposter = OSSignposter(subsystem: subsystem, category: "perf")

    /// Emit a one-line diagnostic. The message closure is not evaluated when disabled.
    @inline(__always)
    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let m = message()
        logger.info("\(m, privacy: .public)")
    }

    /// Time `body`, emit a signpost interval, and log its duration (always, or only when it
    /// exceeds `warnOverMs`). Use for discrete operations (encodes, GPU/voxel passes).
    @inline(__always)
    static func timed<T>(_ label: StaticString, warnOverMs: Double = 0, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let start = CACurrentMediaTime()
        let state = signposter.beginInterval(label)
        defer {
            signposter.endInterval(label, state)
            let ms = (CACurrentMediaTime() - start) * 1000.0
            if warnOverMs == 0 || ms > warnOverMs {
                let name = "\(label)"
                logger.info("\(name, privacy: .public) \(Int(ms))ms")
            }
        }
        return try body()
    }

    /// Pure signpost interval (no logging) for very hot paths where even the duration log is
    /// too noisy; inspect on the Instruments timeline instead.
    @inline(__always)
    static func interval<T>(_ label: StaticString, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let state = signposter.beginInterval(label)
        defer { signposter.endInterval(label, state) }
        return try body()
    }
}

/// Detects multi-hundred-millisecond main-thread stalls — the visible "freeze".
///
/// A `CADisplayLink` stamps `lastTick` every frame on the main thread; a background timer
/// samples the elapsed time since that stamp and reports when the main thread has gone dark
/// for longer than `stallThreshold`. The reported duration is the longest no-frame gap seen
/// during the episode (accurate to within the ~250 ms sampling interval). Start/stop on the
/// main thread (tied to the capture-view lifecycle).
final class MainThreadWatchdog: NSObject, @unchecked Sendable {
    private var displayLink: CADisplayLink?
    private let lastTick = OSAllocatedUnfairLock<CFTimeInterval>(initialState: 0)
    private var monitor: DispatchSourceTimer?
    private let monitorQueue = DispatchQueue(label: "org.arenaxr.scan4d.perf.watchdog", qos: .utility)
    private let stallThreshold: CFTimeInterval

    // Touched only on monitorQueue (serial) — no extra synchronization needed.
    private var stallActive = false
    private var stallMaxGap: CFTimeInterval = 0

    init(stallThresholdMs: Double = 400) {
        self.stallThreshold = stallThresholdMs / 1000.0
    }

    func start() {
        guard PerfDiag.enabled, displayLink == nil else { return }
        lastTick.withLock { $0 = CACurrentMediaTime() }

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link

        let t = DispatchSource.makeTimerSource(queue: monitorQueue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        monitor = t

        PerfDiag.log("MainThreadWatchdog started (threshold \(Int(stallThreshold * 1000))ms)")
    }

    @objc private func tick(_ link: CADisplayLink) {
        lastTick.withLock { $0 = link.timestamp }
    }

    private func check() {
        let now = CACurrentMediaTime()
        let last = lastTick.withLock { $0 }
        let gap = now - last
        if gap > stallThreshold {
            if !stallActive {
                stallActive = true
                stallMaxGap = gap
                PerfDiag.log("⚠️ main-thread stall BEGIN (no frame for \(Int(gap * 1000))ms)")
            } else {
                stallMaxGap = max(stallMaxGap, gap)
            }
        } else if stallActive {
            stallActive = false
            PerfDiag.log("✓ main-thread stall END (max no-frame gap \(Int(stallMaxGap * 1000))ms)")
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        monitor?.cancel()
        monitor = nil
        monitorQueue.async { [weak self] in self?.stallActive = false }
    }
}
