import Foundation

/// Time formatters shared across player overlays. Consolidated so the HMS
/// format, runtime shorthand, and sleep-timer countdown all render
/// identically — previously each view re-implemented the HMS path and the
/// copies were starting to drift.
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

    /// Signed millisecond label for the subtitle-delay controls: "0 ms",
    /// "+250 ms", "-250 ms". Shared by the iOS settings sheet and the tvOS
    /// HUD so both surfaces read the same value the same way.
    static func formatSubtitleDelay(_ milliseconds: Int) -> String {
        if milliseconds == 0 { return "0 ms" }
        return (milliseconds > 0 ? "+" : "") + "\(milliseconds) ms"
    }

    /// Locale-shortened wall-clock time ("9:41 PM" / "21:41"), used by the
    /// tvOS transport bar's now/finish-at row.
    static func formatClockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
