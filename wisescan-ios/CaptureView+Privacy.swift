import SwiftUI

// MARK: - Privacy Filter rules: the time limit and a space's requirement

extension CaptureView {
    /// Turns the Privacy Filter back on when the active space requires it or its time limit has
    /// run out (PrivacyFilterTimer), and says so. Called when the capture screen opens, when the
    /// active space changes, when the app returns to the foreground, and on a record tap. Never
    /// while capturing: a room scan's filter must describe the whole scan as one state, and a
    /// focus scan takes its value at Stop.
    ///
    /// Returns true when it turned the filter on. At a record tap that cancels the start, so the
    /// operator sees the change before anything is captured and can switch it off again on purpose.
    @discardableResult
    func enforcePrivacyFilterRules(atRecordStart: Bool = false) -> Bool {
        guard !isRecording, !isStillCapturing else { return false }
        if activeLocationRequiresPrivacy && !isPrivacyFilterOn {
            isPrivacyFilterOn = true
            showTransientMessage("Privacy Filter on: this space requires it", duration: 4,
                                 systemImage: "lock.fill", tint: .green)
            return true
        }
        guard PrivacyFilterTimer.enforce() else { return false }
        isPrivacyFilterOn = true
        let limit = PrivacyFilterTimer.currentLimitDescription()
        showTransientMessage("Privacy Filter is back on: it was off for over \(limit)."
                             + (atRecordStart ? " Switch it off again to record without it." : ""),
                             duration: 5, systemImage: "hand.raised.fill", tint: .green)
        return true
    }
}
