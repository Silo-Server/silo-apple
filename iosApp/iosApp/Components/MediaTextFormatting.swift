import Foundation

/// Display text for the resolution and runtime facts that many screens show
/// for the same item: card overlays, the tvOS marquee, detail heroes, episode
/// rows, Next Up, Watch Party, Requests and Downloads. Every screen calls
/// these helpers so one item never reads "1080P" in one place and "1080p" in
/// another, or "45 min" beside "45m".
///
/// Both match the web client's shared formatters (`prettyResolution` and
/// `formatRuntimeMinutes` in silo-server `web/src/lib/mediaFormat.ts`), which
/// the card overlays on web, Android and Apple already use.
enum MediaTextFormatting {
    /// "4K" and "8K" for UHD values, the lowercase line-count form for the
    /// rest ("1080p", "720p"), and any other value uppercased ("SD"). Returns
    /// nil for nil or blank input.
    static func resolution(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        let lowered = value.lowercased()
        switch lowered {
        case "2160p", "4k", "uhd": return "4K"
        case "4320p", "8k": return "8K"
        default:
            let lineCount = lowered.dropLast()
            if lowered.hasSuffix("p"),
               !lineCount.isEmpty,
               lineCount.allSatisfy({ ("0"..."9").contains($0) }) {
                return lowered
            }
            return value.uppercased()
        }
    }

    /// "45m", "1h 0m" or "2h 15m" for a runtime in minutes. Returns nil for
    /// nil, zero or negative input so callers can skip the token.
    static func runtime(minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let hours = minutes / 60
        let rest = minutes % 60
        return hours > 0 ? "\(hours)h \(rest)m" : "\(rest)m"
    }
}
