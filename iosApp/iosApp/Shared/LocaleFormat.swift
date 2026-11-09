import Foundation

/// Numbers, durations, sizes and names shown in the app's language (D26,
/// D55). US English output keeps the exact bytes the app printed before:
/// decimals still go through `printf` and only their separator and digits
/// change, and English sizes keep `ByteCountFormatter`.
///
/// Every helper takes the locale to format in. A view passes its
/// `\.locale`, so it re-renders on a language switch; other code gets
/// ``AppLanguage/formattingLocale``, which is English while
/// ``AppLanguage/inEnglish(_:)`` builds data.
enum LocaleFormat {
    /// An integer in the locale's digits, never grouped: a count or an
    /// episode number passed to a text placeholder (D55). "1234" in English.
    static func integer(_ value: some BinaryInteger, locale: Locale = AppLanguage.formattingLocale) -> String {
        Int(value).formatted(.number.grouping(.never).locale(locale))
    }

    /// `value` with exactly `fractionDigits` decimals, rounded as `printf`
    /// rounds: "1.25", "1,25" in German.
    static func decimal(_ value: Double, fractionDigits: Int, locale: Locale = AppLanguage.formattingLocale) -> String {
        localized(String(format: "%.\(fractionDigits)f", value), locale: locale)
    }

    /// `value` with at most `maxFractionDigits` decimals and no trailing
    /// zeros: "1", "1.5", "1.25".
    static func trimmed(_ value: Double, maxFractionDigits: Int = 2, locale: Locale = AppLanguage.formattingLocale) -> String {
        var text = String(format: "%.\(maxFractionDigits)f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return localized(text, locale: locale)
    }

    /// A whole percentage: "42%", "42 %" in German.
    static func percent(_ wholePercent: Int, locale: Locale = AppLanguage.formattingLocale) -> String {
        (Double(wholePercent) / 100).formatted(.percent.precision(.fractionLength(0)).grouping(.never).locale(locale))
    }

    /// A playback rate: "1×", "1.25×".
    static func rate(_ value: Double, locale: Locale = AppLanguage.formattingLocale) -> String {
        trimmed(value, locale: locale) + "×"
    }

    /// A timecode, `h:mm:ss` from one hour, otherwise `m:ss`, in the
    /// locale's digits. The colons stay: a timecode reads the same way in
    /// every language.
    static func clock(seconds: Int, locale: Locale = AppLanguage.formattingLocale) -> String {
        let total = max(0, seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let text = h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
        return localized(text, locale: locale)
    }

    /// A length in whole minutes, in the locale's short units: "45m",
    /// "1h 42m" ("1h 42min" in German, "1時間42分" in Japanese). With
    /// `showZeroMinutes`, a whole hour reads "1h 0m"; otherwise "1h".
    static func duration(minutes: Int, showZeroMinutes: Bool, locale: Locale = AppLanguage.formattingLocale) -> String {
        // Far beyond any real length; keeps `minutes * 60` from overflowing.
        let minutes = min(max(0, minutes), Int.max / 60)
        let style: Duration.UnitsFormatStyle = minutes >= 60
            ? .units(allowed: [.hours, .minutes], width: .narrow,
                     zeroValueUnits: showZeroMinutes ? .show(length: 1) : .hide)
            : .units(allowed: [.minutes], width: .narrow, zeroValueUnits: .show(length: 1))
        let text = Duration.seconds(minutes * 60).formatted(style.locale(locale))
        // The style groups 1,000 hours and up; numbers in text never group.
        guard minutes >= 60_000, let separator = locale.groupingSeparator?.first else { return text }
        let characters = Array(text)
        return String(characters.indices.compactMap { index in
            let isGrouping = characters[index] == separator
                && index > 0 && characters[index - 1].isNumber
                && index + 1 < characters.count && characters[index + 1].isNumber
            return isGrouping ? nil : characters[index]
        })
    }

    /// A byte count: "1.5 GB", "1,5 GB" in German. English keeps
    /// `ByteCountFormatter`, whose output ("2 KB", "Zero KB", "999 bytes")
    /// differs from the format style's ("2 kB", "Zero kB", "1 kB").
    /// `megabytesAndUp` limits the units to MB and GB.
    ///
    /// `ByteCountFormatter` takes no locale: it follows the process's, which
    /// keeps the previous language after a live switch until the app
    /// relaunches. English uses it only while that locale is English too;
    /// otherwise it takes the format style below, with "KB" as English writes
    /// it, so no other language's digits show.
    static func bytes(
        _ count: Int64,
        style: ByteCountFormatter.CountStyle = .file,
        megabytesAndUp: Bool = false,
        locale: Locale = AppLanguage.formattingLocale,
        processLocale: Locale = .current
    ) -> String {
        let english = locale.language.languageCode == .english
        if english, processLocale.language.languageCode == .english {
            guard megabytesAndUp else { return ByteCountFormatter.string(fromByteCount: count, countStyle: style) }
            let formatter = megabyteFormatters.value(for: "\(style.rawValue)") {
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useMB, .useGB]
                formatter.countStyle = style
                return formatter
            }
            return formatter.string(fromByteCount: count)
        }
        let formatStyle: ByteCountFormatStyle.Style = switch style {
        case .binary: .binary
        case .memory: .memory
        case .decimal: .decimal
        default: .file
        }
        let text = count.formatted(.byteCount(style: formatStyle, allowedUnits: megabytesAndUp ? ByteCountFormatStyle.Units([.mb, .gb]) : .all).locale(locale))
        return english ? text.replacingOccurrences(of: "kB", with: "KB") : text
    }

    private static let megabyteFormatters = LocaleKeyedCache<ByteCountFormatter>()

    /// An ordinal: "3rd", "3." in German.
    static func ordinal(_ value: Int, locale: Locale = AppLanguage.formattingLocale) -> String {
        let formatter = ordinalFormatters.value(for: locale.identifier) {
            let formatter = NumberFormatter()
            formatter.numberStyle = .ordinal
            formatter.locale = locale
            return formatter
        }
        return formatter.string(from: NSNumber(value: value)) ?? "#\(integer(value, locale: locale))"
    }

    private static let ordinalFormatters = LocaleKeyedCache<NumberFormatter>()

    /// A language tag's name in the locale's language ("German", "Deutsch"),
    /// or nil when the system can't name it. English capitalizes every word,
    /// as the app always has ("Brazilian Portuguese"); other languages
    /// capitalize only the first letter, as a list item.
    static func languageName(_ code: String, locale: Locale = AppLanguage.formattingLocale) -> String? {
        let identifier = code.replacingOccurrences(of: "_", with: "-")
        return (locale.localizedString(forIdentifier: identifier)
            ?? locale.localizedString(forLanguageCode: identifier))
            .map { capitalizedName($0, locale: locale) }
    }

    /// The name of a language or region capitalized for a label in
    /// `locale`'s language: every word in English, as the app always has,
    /// only the first letter elsewhere ("Español de México").
    static func capitalizedName(_ name: String, locale: Locale) -> String {
        if locale.language.languageCode == .english { return name.capitalized }
        return name.prefix(1).capitalized(with: locale) + name.dropFirst()
    }

    /// A shared `DateFormatter` with the given styles in `locale`, for code
    /// that formats many dates or parses with the same zone. Formatting with
    /// a shared `DateFormatter` is thread-safe.
    static func dateFormatter(
        dateStyle: DateFormatter.Style,
        timeStyle: DateFormatter.Style = .none,
        calendar: Calendar? = nil,
        locale: Locale = AppLanguage.formattingLocale
    ) -> DateFormatter {
        let key = "\(locale.identifier)|\(dateStyle.rawValue)|\(timeStyle.rawValue)|\(calendar?.identifier.debugDescription ?? "")"
        return dateFormatters.value(for: key) {
            let formatter = DateFormatter()
            // Setting the locale resets the calendar, so the calendar comes after.
            formatter.locale = locale
            if let calendar { formatter.calendar = calendar }
            formatter.dateStyle = dateStyle
            formatter.timeStyle = timeStyle
            return formatter
        }
    }

    private static let dateFormatters = LocaleKeyedCache<DateFormatter>()

    // MARK: Digits

    /// ASCII digits and "." from `printf` rewritten in the locale's digits
    /// and decimal separator. Unchanged for Latin-digit locales that use ".".
    static func localized(_ text: String, locale: Locale = AppLanguage.formattingLocale) -> String {
        let symbols = Symbols.for(locale)
        guard symbols.digits != nil || symbols.decimalSeparator != "." else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            if let ascii = character.asciiValue, (48...57).contains(ascii), let digits = symbols.digits {
                result.append(digits[Int(ascii - 48)])
            } else if character == "." {
                result.append(symbols.decimalSeparator)
            } else {
                result.append(character)
            }
        }
        return result
    }

    private struct Symbols {
        /// Nil for ASCII digits.
        var digits: [Character]?
        var decimalSeparator: String

        static func `for`(_ locale: Locale) -> Symbols {
            cache.value(for: locale.identifier) {
                let zeroToNine = 1_234_567_890.formatted(.number.grouping(.never).locale(locale))
                var digits = Array(zeroToNine)
                if digits.count == 10 { digits = [digits[9]] + digits[0..<9] }
                return Symbols(
                    digits: digits.count == 10 && digits != Array("0123456789") ? digits : nil,
                    decimalSeparator: locale.decimalSeparator ?? "."
                )
            }
        }

        private static let cache = LocaleKeyedCache<Symbols>()
    }
}

/// A small lock-guarded memo for values that depend only on a locale (and
/// fixed options), keyed by the locale's identifier.
final class LocaleKeyedCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Value] = [:]

    func value(for key: String, make: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let value = values[key] { return value }
        let value = make()
        values[key] = value
        return value
    }
}
