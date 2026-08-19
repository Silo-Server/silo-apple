import Foundation

/// Process-wide reusable date/time formatters. `DateFormatter` construction
/// is expensive — share instances instead of building them per render.
enum DateFormatters {
    /// "yyyy-MM-dd" in the device's current timezone. Used for calendar API
    /// request params, for matching server `local_air_date` strings (which the
    /// server computes in the same timezone the client sends), and for parsing
    /// plain `yyyy-MM-dd` metadata dates such as person birth/death dates.
    static let isoDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    /// Wall-clock time parser for the server's "HH:mm" / "HH:mm:ss" strings.
    static func parseWallClockTime(_ raw: String) -> DateComponents? {
        let parts = raw.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else {
            return nil
        }
        return DateComponents(hour: parts[0], minute: parts[1])
    }

    /// RFC3339 with or without fractional seconds — the two spellings the Silo
    /// server emits. `ISO8601DateFormatter` accepts exactly one of them per
    /// instance, so both are tried.
    static func parseRFC3339(_ raw: String) -> Date? {
        rfc3339Fractional.date(from: raw) ?? rfc3339.date(from: raw)
    }

    /// Localized short time ("9:00 PM" / "21:00" per locale) from an
    /// RFC3339 instant string. Returns nil when parsing fails.
    static func localShortTime(fromRFC3339 raw: String) -> String? {
        guard let date = parseRFC3339(raw) else {
            return nil
        }
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// Localized short time from a wall-clock "HH:mm" string, interpreted
    /// in the device timezone.
    static func localShortTime(fromWallClock raw: String) -> String? {
        guard let components = parseWallClockTime(raw),
              let date = Calendar.current.date(
                bySettingHour: components.hour ?? 0,
                minute: components.minute ?? 0,
                second: 0,
                of: Date()
              ) else {
            return nil
        }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private static let rfc3339: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let rfc3339Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
