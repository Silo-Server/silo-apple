import Foundation

/// The wall-clock finish time shown beside the time remaining. Callers refresh
/// it on a clock tick because the position stands still while paused, and a
/// paused finish time still has to move.
enum PlayerEndTime {
    /// When playback finishes at `speed`, or nil when nothing is left to play.
    static func date(now: Date, remaining: Double, speed: Double) -> Date? {
        guard remaining.isFinite, remaining > 0 else { return nil }
        let rate = speed.isFinite && speed > 0 ? speed : 1
        return now.addingTimeInterval(remaining / rate)
    }

    /// `time`, followed by "Ends 11:42 PM" in the view's language when there
    /// is a finish time.
    static func appending(to time: String, now: Date, remaining: Double, speed: Double, locale: Locale) -> String {
        guard let end = date(now: now, remaining: remaining, speed: speed) else { return time }
        let clock = end.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale))
        let label = AppLanguage.string(.playerScrubberEndsAt(clock), locale: locale)
        return "\(time) · \(AppLanguage.isolated(label, language: AppLanguage.language(of: locale)))"
    }
}
