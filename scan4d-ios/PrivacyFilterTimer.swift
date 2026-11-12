import Foundation

/// The Privacy Filter's time limit. Switched off, the filter turns itself back on once it has
/// been off longer than `AppConstants.privacyFilterTimeLimitHours` (a Developer Mode setting;
/// 0 = no limit), because a switch left off by mistake puts everyone in later scans into the
/// data unblurred.
///
/// The capture screen checks it when it opens, when the app returns to the foreground and when
/// a scan is about to start, never during a recording: the filter must describe a whole scan
/// as one state (see `PrivacyFilterPill`). An unknown switch-off time, as on the first launch
/// after this shipped, counts as run out: the filter fails closed, like the export's blur gate.
enum PrivacyFilterTimer {
    /// Whether a filter switched off at `offAt` has been off past the limit.
    static func hasExpired(offAt: Date?, limitHours: Int, now: Date) -> Bool {
        guard limitHours > 0 else { return false }
        guard let offAt else { return true }
        return now.timeIntervalSince(offAt) >= TimeInterval(limitHours) * 3600
    }

    /// Call whenever the switch changes: remembers when it went off, forgets it when it goes on.
    static func noteSwitch(isOn: Bool, defaults: UserDefaults = .standard, now: Date = Date()) {
        if isOn {
            defaults.removeObject(forKey: AppConstants.Key.privacyFilterOffAt)
        } else {
            defaults.set(now.timeIntervalSince1970, forKey: AppConstants.Key.privacyFilterOffAt)
        }
    }

    /// Turns the filter back on when it has been off past the limit. Returns true when it did,
    /// so the caller can say so.
    @discardableResult
    static func enforce(defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        let isOn = (defaults.object(forKey: AppConstants.Key.privacyFilter) as? Bool) ?? AppConstants.privacyFilter
        guard !isOn else { return false }
        let offAt = (defaults.object(forKey: AppConstants.Key.privacyFilterOffAt) as? Double)
            .map(Date.init(timeIntervalSince1970:))
        let limit = (defaults.object(forKey: AppConstants.Key.privacyFilterTimeLimitHours) as? Int)
            ?? AppConstants.privacyFilterTimeLimitHours
        guard hasExpired(offAt: offAt, limitHours: limit, now: now) else { return false }
        defaults.set(true, forKey: AppConstants.Key.privacyFilter)
        defaults.removeObject(forKey: AppConstants.Key.privacyFilterOffAt)
        return true
    }

    /// The limit as the Settings picker and the notices name it: "12 h", "24 h", "1 week", "no limit".
    static func describe(hours: Int) -> String {
        switch hours {
        case ..<1: return "no limit"
        case 168: return "1 week"
        default: return "\(hours) h"
        }
    }

    /// The current limit, for notices.
    static func currentLimitDescription(defaults: UserDefaults = .standard) -> String {
        describe(hours: (defaults.object(forKey: AppConstants.Key.privacyFilterTimeLimitHours) as? Int)
                 ?? AppConstants.privacyFilterTimeLimitHours)
    }
}
