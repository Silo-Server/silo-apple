import Foundation

enum DetailDateFormatting {
    static func longDate(_ raw: String?) -> String? {
        formattedDate(raw, formatter: longDisplayFormatter)
    }

    static func abbreviatedDate(_ raw: String?) -> String? {
        formattedDate(raw, formatter: abbreviatedDisplayFormatter)
    }

    private static func formattedDate(_ raw: String?, formatter: DateFormatter) -> String? {
        guard let cleaned = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty
        else {
            return nil
        }
        guard let parsed = parsedDate(cleaned) else { return cleaned }
        return formatter.string(from: parsed)
    }

    private static func parsedDate(_ raw: String) -> Date? {
        fullDateParser.date(from: raw)
            ?? DateFormatters.parseRFC3339(raw)
            ?? fallbackDateParser.date(from: raw)
    }

    private static let fullDateParser: ISO8601DateFormatter = {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withFullDate]
        return parser
    }()

    private static let fallbackDateParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
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
