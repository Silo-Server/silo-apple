import Foundation

/// A single Monday-anchored 7-day window. The Monday anchor is fixed
/// (matching the server web UI's week convention) regardless of the
/// device locale's first weekday, so the same week of data renders
/// identically everywhere.
struct CalendarWeek: Equatable, Hashable {
    /// ISO 8601 weeks start on Monday by definition; using one calendar
    /// for every operation keeps the anchor and the day arithmetic from
    /// disagreeing (the device calendar may not even be Gregorian).
    private static let isoCalendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        return calendar
    }()

    /// Midnight on the week's Monday, in the device timezone.
    let startDate: Date
    /// All 7 day dates, Monday through Sunday.
    let days: [Date]

    /// The week containing `date`.
    init(containing date: Date) {
        let components = Self.isoCalendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear],
            from: date
        )
        let startDate = Self.isoCalendar.date(from: components) ?? date
        self.startDate = startDate
        self.days = (0..<7).compactMap {
            Self.isoCalendar.date(byAdding: .day, value: $0, to: startDate)
        }
    }

    var endDate: Date {
        Self.isoCalendar.date(byAdding: .day, value: 6, to: startDate) ?? startDate
    }

    func advanced(by weeks: Int) -> CalendarWeek {
        guard let shifted = Self.isoCalendar.date(
            byAdding: .weekOfYear, value: weeks, to: startDate
        ) else { return self }
        return CalendarWeek(containing: shifted)
    }

    /// "YYYY-MM-DD" API strings.
    var startString: String { DateFormatters.isoDate.string(from: startDate) }
    var endString: String { DateFormatters.isoDate.string(from: endDate) }

    /// "June 2026" — anchored on the week's Thursday so a month-spanning week
    /// shows the month that owns most of its days.
    var monthLabel: String {
        let anchor = Self.isoCalendar.date(byAdding: .day, value: 3, to: startDate) ?? startDate
        return anchor.formatted(.dateTime.month(.wide).year())
    }

    func containsToday(_ today: Date = Date()) -> Bool {
        days.contains { Self.isoCalendar.isDate($0, inSameDayAs: today) }
    }
}
