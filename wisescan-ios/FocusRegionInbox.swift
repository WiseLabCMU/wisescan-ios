import Foundation
import Observation

// MARK: - Focus region import (docs/design/capture-modes.md)

/// Where a focus region defined outside the app arrives: a downstream processor (a VLM that picked
/// out "the work table") hands the app a `focus_region.json` (schemas/focus_region.schema.json),
/// by deep link or as a file. The app opens that region in the editor of its space, to check and
/// adjust, then scans it.
///
/// Deep link: `scan4d://focus-region?data=<base64url of the JSON>` (or `json=<percent-encoded
/// JSON>`). The region's `location_id` picks the space; a file picked inside a space's Rescan
/// sheet goes to that space whatever it says.
@Observable
@MainActor
final class FocusRegionInbox {
    static let shared = FocusRegionInbox()

    /// The region waiting for its space's editor (cleared when that view takes it).
    var pending: FocusRegion?
    /// Why the last import was refused, for an alert.
    var lastError: String?

    enum ImportError: Error, LocalizedError, Equatable {
        case notARegionLink
        case noPayload
        case undecodable
        case invalidBox

        var errorDescription: String? {
            switch self {
            case .notARegionLink: return "This link is not a Scan4D focus region."
            case .noPayload: return "The focus region link carries no region."
            case .undecodable: return "The focus region could not be read (expected focus_region.json)."
            case .invalidBox: return "The focus region's box is not usable (it needs a positive size up to \(Int(AppConstants.focusRegionMaxSizeM)) m on each side)."
            }
        }
    }

    /// Handles a deep link. Returns false when the URL is not ours (so it goes elsewhere).
    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == AppConstants.focusRegionURLScheme else { return false }
        switch Self.region(from: url) {
        case .success(let region):
            pending = region
            lastError = nil
        case .failure(let error):
            lastError = error.localizedDescription
        }
        return true
    }

    nonisolated static func region(from url: URL) -> Result<FocusRegion, ImportError> {
        guard url.scheme?.lowercased() == AppConstants.focusRegionURLScheme,
              url.host?.lowercased() == AppConstants.focusRegionURLHost else { return .failure(.notARegionLink) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let payload: Data?
        if let encoded = items.first(where: { $0.name == "data" })?.value {
            payload = base64URLDecoded(encoded)
        } else if let json = items.first(where: { $0.name == "json" })?.value {
            payload = Data(json.utf8)
        } else {
            return .failure(.noPayload)
        }
        guard let payload else { return .failure(.undecodable) }
        return region(fromJSON: payload)
    }

    /// A `focus_region.json` file's contents, as imported.
    nonisolated static func region(fromJSON data: Data) -> Result<FocusRegion, ImportError> {
        guard var region = FocusRegion.decode(data) else { return .failure(.undecodable) }
        guard region.isValid else { return .failure(.invalidBox) }
        region.source = .imported
        return .success(region)
    }

    nonisolated static func base64URLDecoded(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
