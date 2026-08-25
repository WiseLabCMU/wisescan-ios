import Foundation
import QuartzCore
import os
import Synchronization
import Darwin

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
    /// Cached so hot paths are a single atomic load instead of a `UserDefaults` read. Atomic
    /// (not a plain `var`) because it's read from many threads — render, ioQueue, voxelQueue,
    /// delegate queue — while `refresh()` writes it on main; a bare global would be a data race.
    private static let _enabled = Atomic<Bool>(UserDefaults.standard.bool(forKey: AppConstants.Key.perfDiagnostics))

    /// Single relaxed atomic load — diagnostics gating tolerates seeing a toggle flip one tick late.
    static var enabled: Bool { _enabled.load(ordering: .relaxed) }

    /// Re-read the toggle (call when the capture view appears so a Settings change takes effect).
    static func refresh() {
        _enabled.store(UserDefaults.standard.bool(forKey: AppConstants.Key.perfDiagnostics), ordering: .relaxed)
    }

    /// Wall-clock marks for work that happens BEFORE the capture view exists, and is
    /// therefore invisible to `MainThreadWatchdog` — which only starts in that view's
    /// `.onAppear`, i.e. after the stall it would have measured has already finished.
    /// A field report of "major stall opening the capture view" left a 60 s hole in the
    /// diagnostics with nothing in it at all; `mark`/`sinceMark` fill exactly that hole.
    /// Stored regardless of the toggle so turning diagnostics on mid-session still gets a
    /// sane baseline; only the logging is gated.
    private static let marks = Mutex<[String: Double]>([:])

    static func mark(_ name: String) {
        let now = CACurrentMediaTime()
        marks.withLock { $0[name] = now }
    }

    /// Milliseconds since `mark(name)`, or nil if it was never marked. Consumes the mark,
    /// so a repeated transition measures each occurrence rather than accumulating.
    static func sinceMark(_ name: String) -> Int? {
        let start = marks.withLock { $0.removeValue(forKey: name) }
        guard let start else { return nil }
        return Int((CACurrentMediaTime() - start) * 1000)
    }

    static let subsystem = "org.arenaxr.scan4d"
    private static let logger = Logger(subsystem: subsystem, category: "perf")
    private static let signposter = OSSignposter(subsystem: subsystem, category: "perf")

    /// Emit a one-line diagnostic. The message closure is not evaluated when disabled.
    @inline(__always)
    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let m = message()
        // NOTICE, not info: `info` lives only in the in-memory ring buffer and never
        // reaches disk, so it is evicted long before an untethered run can be exported
        // (field log 2026-08-17 came back holding only the last ~77 entries — the whole
        // capture phase was gone). `notice` persists, which is the entire point of
        // lines that exist to be read after the fact.
        logger.notice("\(m, privacy: .public)")
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
                // [PerfTimer] prefix so every timed-block duration line greps/filters as one
                // family (like [MemDiag]/[LocDiag]), e.g. `[PerfTimer] voxel_decay 163ms`.
                let name = "\(label)"
                logger.info("[PerfTimer] \(name, privacy: .public) \(Int(ms))ms")
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
    /// One app-wide instance, started at launch when Perf Diagnostics is on. It was
    /// capture-view-scoped, which is why #71's 79.5 s tab-tap freeze produced a total
    /// blackout (the watchdog started at the END of the stall, in onAppear) and why the
    /// 2026-08-25 18 s save-flow stall was caught only by luck (capture still open).
    /// A display-link tick + a 4 Hz timestamp compare is negligible to keep running.
    static let shared = MainThreadWatchdog()

    // MARK: Mid-stall main-thread sampler (#71)
    //
    // Three field stalls of ~18.0 s each (17989 / 18087 / 17953 ms, 2026-08-25) at two
    // different call sites, with every app-side path verified async — reading the code
    // cannot name the owner, so the watchdog captures the main thread's backtrace WHILE
    // it is stalled: a SIGUSR1 is directed at the main thread (SA_RESTART, so interrupted
    // syscalls resume), and the handler — kept async-signal-safe — fills a preallocated
    // buffer via backtrace(3), resolved through dlsym at start(). The monitor queue then
    // symbolizes with dladdr OUTSIDE the handler and logs one frame per line.
    private typealias BacktraceFn = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>, Int32) -> Int32
    private nonisolated(unsafe) static var backtraceFn: BacktraceFn?
    private nonisolated(unsafe) static var sampleBuf = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
    private nonisolated(unsafe) static var sampleCount: Int32 = 0
    private nonisolated(unsafe) static var mainPthread: pthread_t?
    /// Set true once per stall when the sample request is sent; cleared at stall END.
    private var sampledThisStall = false

    private static let installSampler: Void = {
        mainPthread = pthread_self()   // start() runs on main at app launch
        if let sym = dlsym(dlopen(nil, RTLD_NOW), "backtrace") {
            backtraceFn = unsafeBitCast(sym, to: BacktraceFn.self)
        }
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in
            // Async-signal-safe only: one C call into a static buffer, two stores.
            if let bt = MainThreadWatchdog.backtraceFn {
                MainThreadWatchdog.sampleBuf.withUnsafeMutableBufferPointer { buf in
                    MainThreadWatchdog.sampleCount = bt(buf.baseAddress!, 64)
                }
            }
        }
        action.sa_flags = SA_RESTART
        sigemptyset(&action.sa_mask)
        sigaction(SIGUSR1, &action, nil)
    }()

    /// lldb intercepts SIGUSR1 before our handler and PAUSES the process — under Xcode,
    /// where a Debug build trips the 2 s threshold constantly, that made the app unusable
    /// (field, 2026-08-25). When a debugger is attached the pause itself is the sample
    /// (Xcode shows the full stack), so the signal is pointless: skip it and say so.
    private static var isDebuggerAttached: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let rc = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        return rc == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
    }

    /// Fire one sample at the stalled main thread, then symbolize what came back.
    private func sampleMainThread(gapMs: Int) {
        guard let main = Self.mainPthread, Self.backtraceFn != nil else { return }
        // Under a debugger the signal pauses the process unless lldb is told to pass it —
        // the app cannot see lldb's settings, so the operator opts in explicitly.
        if Self.isDebuggerAttached,
           !UserDefaults.standard.bool(forKey: AppConstants.Key.perfSampleUnderDebugger) {
            PerfDiag.log("[PerfDiag] stall sample skipped — debugger attached (lldb pauses on the signal). Pause Xcode to read the main-thread stack, or run `process handle SIGUSR1 -n false -p true -s false` in lldb AND enable Developer Settings → Sample Stalls Under Debugger")
            return
        }
        Self.sampleCount = 0
        pthread_kill(main, SIGUSR1)
        // The handler runs on the main thread more or less immediately, even mid-block
        // (SA_RESTART resumes the interrupted call). Give it a beat, then symbolize here
        // on the monitor queue where malloc is safe again.
        usleep(50_000)
        let n = Int(Self.sampleCount)
        guard n > 0 else {
            PerfDiag.log("[PerfDiag] stall sample: no frames captured (handler did not run — thread may be in an uninterruptible wait)")
            return
        }
        PerfDiag.log("[PerfDiag] main-thread sample \(gapMs)ms into the stall — \(n) frame(s):")
        for i in 0..<n {
            guard let addr = Self.sampleBuf[i] else { continue }
            var info = Dl_info()
            if dladdr(addr, &info) != 0 {
                let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
                let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
                let offset = info.dli_saddr.map { UInt(bitPattern: addr) - UInt(bitPattern: $0) } ?? 0
                PerfDiag.log("[PerfDiag]   #\(i) \(image) \(symbol) + \(offset)")
            } else {
                PerfDiag.log("[PerfDiag]   #\(i) \(String(describing: addr))")
            }
        }
    }

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
        _ = Self.installSampler   // main pthread + SIGUSR1 handler + backtrace symbol, once
        lastTick.withLock { $0 = CACurrentMediaTime() }

        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link

        let t = DispatchSource.makeTimerSource(queue: monitorQueue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        monitor = t

        PerfDiag.log("[PerfDiag] MainThreadWatchdog started (threshold \(Int(stallThreshold * 1000))ms)")
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
                PerfDiag.log("[PerfDiag] ⚠️ main-thread stall BEGIN (no frame for \(Int(gap * 1000))ms)")
            } else {
                stallMaxGap = max(stallMaxGap, gap)
            }
            // 2 s in: this is a real freeze, not a frame hiccup — sample the main thread
            // while it is still inside the blocking work. Once per stall.
            if gap > 2.0, !sampledThisStall {
                sampledThisStall = true
                sampleMainThread(gapMs: Int(gap * 1000))
            }
        } else if stallActive {
            stallActive = false
            sampledThisStall = false
            PerfDiag.log("[PerfDiag] ✓ main-thread stall END (max no-frame gap \(Int(stallMaxGap * 1000))ms)")
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

/// [MemDiag] Redline trip-flag: logs when the OS raises a memory-pressure event (warn / critical)
/// against the app. These are the kernel's own "you're near the jetsam limit" signals — the last
/// warning before a kill — so a `MEM-PRESSURE` marker tells us which scan phase actually walks the
/// app up to the edge on a real device (the low-RAM iPhones sooner than the iPad). Stamps footprint +
/// remaining headroom at the moment of the event. No-op unless Perf Diagnostics is on; start/stop on
/// the main thread tied to the capture-view lifecycle, alongside MainThreadWatchdog.
final class MemoryPressureMonitor: @unchecked Sendable {
    private var source: DispatchSourceMemoryPressure?
    private let queue = DispatchQueue(label: "org.arenaxr.scan4d.perf.mempressure", qos: .utility)

    /// Snapshot closure supplied by the owner (footprint/avail live in ScanStats, which PerfDiag
    /// can't see). Called on the monitor queue when an event fires; returns the marker suffix.
    private let snapshot: () -> String

    init(snapshot: @escaping () -> String) { self.snapshot = snapshot }

    func start() {
        guard PerfDiag.enabled, source == nil else { return }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let level = src.data.contains(.critical) ? "CRITICAL" : "warning"
            PerfDiag.log("[MemDiag] EVENT MEM-PRESSURE \(level) \(self.snapshot())")
        }
        src.resume()
        source = src
        PerfDiag.log("[PerfDiag] MemoryPressureMonitor started")
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
