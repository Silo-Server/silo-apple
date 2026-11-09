import Foundation

/// The wall-clock finish time shown beside the time remaining. Callers refresh
/// it on a clock tick because the position stands still while paused, and a
/// paused finish time still has to move.
enum PlayerEndTime {
    /// "Ends 11:42 PM", or nil when nothing is left to play.
    static func label(
        now: Date,
        remaining: Double,
        speed: Double,
        style: Date.FormatStyle = Date.FormatStyle(date: .omitted, time: .shortened)
    ) -> String? {
        guard remaining.isFinite, remaining > 0 else { return nil }
        let rate = speed.isFinite && speed > 0 ? speed : 1
        return "Ends \(now.addingTimeInterval(remaining / rate).formatted(style))"
    }

    /// `time`, followed by the finish time when there is one.
    static func appending(to time: String, now: Date, remaining: Double, speed: Double) -> String {
        guard let label = label(now: now, remaining: remaining, speed: speed) else { return time }
        return "\(time) · \(label)"
    }
}
