import Foundation

/// Time formatters shared across player overlays, in the app's language
/// (`LocaleFormat`). A view passes its `\.locale`.
enum PlayerTimeFormatter {
    /// `h:mm:ss` for durations ≥ 1 hour, otherwise `m:ss`, in the locale's
    /// digits. Clamps negative and non-finite input to `0:00` so mid-load /
    /// missing-duration states don't render garbage.
    static func formatHMS(_ seconds: Double, locale: Locale = AppLanguage.formattingLocale) -> String {
        guard seconds.isFinite, seconds >= 0 else { return LocaleFormat.clock(seconds: 0, locale: locale) }
        return LocaleFormat.clock(seconds: Int(seconds), locale: locale)
    }

    /// Compact runtime label for the hero strip: "1h 42m" / "42m" / "".
    /// Returns an empty string for zero/unknown duration so callers can
    /// simply filter it out when joining metadata segments.
    static func formatRuntime(_ seconds: Double, locale: Locale = AppLanguage.formattingLocale) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        return LocaleFormat.duration(minutes: Int(seconds) / 60, showZeroMinutes: false, locale: locale)
    }

    /// `m:ss` for the sleep-timer countdown in the status column.
    static func formatCountdown(_ seconds: Int, locale: Locale = AppLanguage.formattingLocale) -> String {
        let m = seconds / 60, s = seconds % 60
        return LocaleFormat.localized(String(format: "%d:%02d", m, s), locale: locale)
    }
}
