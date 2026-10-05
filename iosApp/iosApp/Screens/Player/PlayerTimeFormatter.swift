import Foundation

/// Time formatters shared across player overlays.
enum PlayerTimeFormatter {
    /// `h:mm:ss` for durations ≥ 1 hour, otherwise `m:ss`. Clamps negative
    /// and non-finite input to `0:00` so mid-load / missing-duration
    /// states don't render garbage.
    static func formatHMS(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Compact runtime label for the hero strip: "1h 42m" / "42m" / "".
    /// Returns an empty string for zero/unknown duration so callers can
    /// simply filter it out when joining metadata segments.
    static func formatRuntime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 {
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(m)m"
    }

    /// `m:ss` for the sleep-timer countdown in the status column.
    static func formatCountdown(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
