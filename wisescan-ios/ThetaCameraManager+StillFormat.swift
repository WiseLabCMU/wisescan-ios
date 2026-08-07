import Foundation

// Still-resolution menu logic: what the resolution picker offers for the connected
// camera. Kept out of the main manager (which owns the stored state + OSC calls) so the
// type stays within length limits, matching the +OSC / +ScanCapture split.
//
// Preference order: the camera's own `fileFormatSupport` list (works for any model) →
// a per-model fallback table (older firmware that doesn't report the list) → the current
// format alone. So the menu is always correct for X / Z1 / V and never empty when
// connected — no more hardcoded Theta X-only presets.
extension ThetaCameraManager {

    /// Camera model from the active connection (nil unless connected).
    var model: String? {
        if case .connected(let model, _) = state { return model }
        return nil
    }

    /// Resolutions to offer in the picker, largest first and de-duplicated. Uses the
    /// camera-reported list when available, else the model fallback, and always folds in
    /// the current format so at least one correct option shows.
    var stillFormatMenu: [StillFormat] {
        var formats = supportedStillFormats.isEmpty
            ? Self.fallbackStillFormats(forModel: model)
            : supportedStillFormats
        if let current = currentStillFormat { formats.append(current) }
        var seen = Set<StillFormat>()
        return formats
            .sorted { $0.width * $0.height > $1.width * $1.height }
            .filter { seen.insert($0).inserted }
    }

    /// Fallback JPEG still sizes per model, used only when the camera doesn't report
    /// `fileFormatSupport`. Matched against the `/osc/info` model string.
    static func fallbackStillFormats(forModel model: String?) -> [StillFormat] {
        guard let model else { return [] }
        if model.contains("THETA X") {
            return [StillFormat(width: 11008, height: 5504),   // ~60 MP
                    StillFormat(width: 5504, height: 2752)]     // ~15 MP
        }
        if model.contains("THETA Z1") {
            return [StillFormat(width: 6720, height: 3360)]     // ~23 MP
        }
        if model.contains("THETA V") || model.contains("THETA SC") {
            return [StillFormat(width: 5376, height: 2688)]     // ~14 MP
        }
        return []
    }
}
