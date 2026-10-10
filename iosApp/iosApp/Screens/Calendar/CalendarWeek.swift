import Foundation

/// A single Monday-anchored 7-day window. The Monday anchor is fixed
/// (matching the server web UI's week convention) regardless of the
/// device locale's first weekday, so the same week of data renders
/// identically everywhere.
struct CalendarWeek: Equatable, Hashable {
    /// The timezone the week's days are midnights in. The week keeps the
    /// zone it was built in, so its dates and their "YYYY-MM-DD" strings
    /// always agree; `rebuilt(in:)` moves it after a device timezone change.
    let timeZone: TimeZone
    /// Midnight on the week's Monday, in `timeZone`.
    let startDate: Date
    /// All 7 day dates, Monday through Sunday.
    let days: [Date]

    /// ISO 8601 weeks start on Monday by definition; using one calendar
    /// for every operation keeps the anchor and the day arithmetic from
    /// disagreeing (the device calendar may not even be Gregorian).
    private var isoCalendar: Calendar { Self.isoCalendar(in: timeZone) }

    private static func isoCalendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The week containing `date`.
    init(containing date: Date, timeZone: TimeZone = .current) {
        let calendar = Self.isoCalendar(in: timeZone)
        let components = calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear],
            from: date
        )
        let startDate = calendar.date(from: components) ?? date
        self.timeZone = timeZone
        self.startDate = startDate
        self.days = (0..<7).compactMap {
            calendar.date(byAdding: .day, value: $0, to: startDate)
        }
    }

    var endDate: Date {
        isoCalendar.date(byAdding: .day, value: 6, to: startDate) ?? startDate
    }

    func advanced(by weeks: Int) -> CalendarWeek {
        guard let shifted = isoCalendar.date(
            byAdding: .weekOfYear, value: weeks, to: startDate
        ) else { return self }
        return CalendarWeek(containing: shifted, timeZone: timeZone)
    }

    /// The same ISO week with its days as midnights in `timeZone`. Anchored
    /// on Thursday noon: the old Monday midnight can fall on the Sunday
    /// before in a zone further west.
    func rebuilt(in timeZone: TimeZone) -> CalendarWeek {
        CalendarWeek(containing: startDate.addingTimeInterval(3.5 * 86_400), timeZone: timeZone)
    }

    /// "YYYY-MM-DD" for `date` in the week's timezone: the API's `start` and
    /// `end`, and the key matched against the server's `local_air_date`.
    func dateString(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day())
    }

    var startString: String { dateString(startDate) }
    var endString: String { dateString(endDate) }

    /// "June 2026" — anchored on the week's Thursday so a month-spanning week
    /// shows the month that owns most of its days.
    var monthLabel: String {
        let anchor = isoCalendar.date(byAdding: .day, value: 3, to: startDate) ?? startDate
        return anchor.formatted(.dateTime.month(.wide).year())
    }

    func containsToday(_ today: Date = Date()) -> Bool {
        days.contains { isoCalendar.isDate($0, inSameDayAs: today) }
    }
}
