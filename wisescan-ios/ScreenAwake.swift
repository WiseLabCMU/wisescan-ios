import UIKit
import os

// MARK: - Keeping the screen on while long work runs

/// Holds the screen awake (auto-lock off) while any holder needs it.
///
/// WHY IT EXISTS: an export can take minutes to build, and a room scan with automatic stills
/// needs no taps, so the operator may not touch the screen for longer than the Auto-Lock delay
/// (30 s on an iPhone by default). When the screen locks, iOS suspends the app: the zip build
/// stops and a recording ends. Field operators were tapping the screen every half minute to stop
/// that.
///
/// HOW: one `isIdleTimerDisabled` flag is shared by the whole app, so a plain set/clear from two
/// places would let the first to finish turn auto-lock back on under the other. Each holder names
/// itself instead (`upload:<scan id>`, `capture`), and auto-lock comes back only when the last
/// one lets go. Holding and releasing are idempotent, so a status that is set twice, or a release
/// for something never held, is harmless.
///
/// It keeps the app in front only while the screen stays on. Pressing the side button still
/// locks the phone. A scan's bundle for the lab server needs neither: it goes up in a background
/// session (`BundleSync`), which the system finishes with the screen locked.
///
/// Callable from any thread: the SwiftData model's status setter is not main-actor isolated. The
/// holder set is locked, and the flag is applied on main from the set as it stands then, so calls
/// arriving in any order still end on the right state.
nonisolated enum ScreenAwake {
    private static let holders = OSAllocatedUnfairLock(initialState: Set<String>())

    /// The holder for one scan's export or upload: held while its status is in flight.
    static func uploadHolder(_ scanId: UUID) -> String { "upload:\(scanId.uuidString)" }

    /// The holder for an active recording (room scan or focus scan).
    static let captureHolder = "capture"

    static func hold(_ holder: String) {
        holders.withLock { _ = $0.insert(holder) }
        apply()
    }

    static func release(_ holder: String) {
        holders.withLock { _ = $0.remove(holder) }
        apply()
    }

    static func set(_ holder: String, held: Bool) {
        if held { hold(holder) } else { release(holder) }
    }

    /// Whether anything is holding the screen awake.
    static var isHeld: Bool { holders.withLock { !$0.isEmpty } }

    static func isHeld(by holder: String) -> Bool { holders.withLock { $0.contains(holder) } }

    private static func apply() {
        if Thread.isMainThread {
            MainActor.assumeIsolated { applyOnMain() }
        } else {
            DispatchQueue.main.async { applyOnMain() }
        }
    }

    @MainActor private static func applyOnMain() {
        let disabled = isHeld
        guard UIApplication.shared.isIdleTimerDisabled != disabled else { return }
        UIApplication.shared.isIdleTimerDisabled = disabled
    }
}
