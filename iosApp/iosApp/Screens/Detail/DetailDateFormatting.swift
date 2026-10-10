import Foundation

enum DetailDateFormatting {
    static func longDate(_ raw: String?) -> String? {
        formattedDate(raw, formatter: longDisplayFormatter)
    }

    static func abbreviatedDate(_ raw: String?) -> String? {
        formattedDate(raw, formatter: abbreviatedDisplayFormatter)
    }

    /// Internal rather than private so tests can pass a formatter pinned to a
    /// specific time zone. Parsing uses the formatter's own zone, so parse and
    /// display always agree on the calendar day.
    static func formattedDate(_ raw: String?, formatter: DateFormatter) -> String? {
        guard let cleaned = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty
        else {
            return nil
        }
        guard let parsed = parsedDate(cleaned, displayTimeZone: formatter.timeZone) else { return cleaned }
        return formatter.string(from: parsed)
    }

    /// Server release and air dates are calendar dates (`YYYY-MM-DD`) with no
    /// time zone. They are anchored at noon in the display zone so they show
    /// the same day everywhere; noon also stays clear of DST gaps at midnight.
    /// RFC 3339 instants keep their zone and convert to the display zone.
    private static func parsedDate(_ raw: String, displayTimeZone: TimeZone) -> Date? {
        calendarDate(raw, in: displayTimeZone)
            ?? rfc3339Parser.date(from: raw)
            ?? rfc3339FractionalParser.date(from: raw)
    }

    /// Accepts `YYYY-M(M)-D(D)` and rejects dates that do not exist, such as
    /// `2024-02-30`. The server value is Gregorian; the display formatter
    /// converts the resulting instant into the device calendar.
    private static func calendarDate(_ raw: String, in timeZone: TimeZone) -> Date? {
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              (1...2).contains(parts[1].count),
              (1...2).contains(parts[2].count),
              parts.allSatisfy({ $0.allSatisfy { ("0"..."9").contains($0) } }),
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    private static let rfc3339Parser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return parser
    }()

    private static let rfc3339FractionalParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return parser
    }()

    private static let longDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    private static let abbreviatedDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
