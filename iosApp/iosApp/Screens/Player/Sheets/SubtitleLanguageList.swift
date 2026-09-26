import Foundation

/// One language row in the in-player subtitle search and AI subtitle menus.
struct SubtitleLanguageChoice: Identifiable, Equatable {
    /// Why a row is floated above the full list.
    enum Suggestion: Equatable {
        /// The profile's preferred subtitle language.
        case preferred
        /// The spoken audio language (AI Subtitles menu only).
        case originalLanguage

        /// Row hint copy shown under the language name.
        var label: String {
            switch self {
            case .preferred: return "Preferred"
            case .originalLanguage: return "Original language"
            }
        }
    }

    let code: String
    let label: String
    let suggestion: Suggestion?
    var id: String { code }
    var hint: String? { suggestion?.label }

    /// Curated label from `options`, else the English locale name, else the
    /// uppercased code.
    static func displayName(
        _ code: String,
        options: [PlaybackLanguageOption] = PlaybackLanguageOption.all
    ) -> String {
        if let opt = options.first(where: { $0.code.caseInsensitiveCompare(code) == .orderedSame }) {
            return opt.label
        }
        return Locale(identifier: "en").localizedString(forLanguageCode: code)?.capitalized
            ?? code.uppercased()
    }
}

/// The language rows offered by the subtitle search and AI subtitle menus.
struct SubtitleLanguageList: Equatable {
    /// Suggestions in priority order (preferred, then spoken), then `options`
    /// in contract order; trimmed, blanks dropped, deduped by
    /// `PlaybackLanguageOption.languageIdentity` (first occurrence wins).
    let ordered: [SubtitleLanguageChoice]

    init(
        preferred: String?,
        spoken: String? = nil,
        options: [PlaybackLanguageOption] = PlaybackLanguageOption.all
    ) {
        var result: [SubtitleLanguageChoice] = []
        var seen = Set<String>()
        func add(_ code: String, suggestion: SubtitleLanguageChoice.Suggestion?) {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = PlaybackLanguageOption.languageIdentity(trimmed)
            guard !seen.contains(key) else { return }
            seen.insert(key)
            result.append(.init(
                code: trimmed,
                label: SubtitleLanguageChoice.displayName(trimmed, options: options),
                suggestion: suggestion
            ))
        }
        if let preferred { add(preferred, suggestion: .preferred) }
        if let spoken { add(spoken, suggestion: .originalLanguage) }
        for option in options { add(option.code, suggestion: nil) }
        ordered = result
    }

    /// Floated rows, in priority order (not alphabetized).
    var suggested: [SubtitleLanguageChoice] { ordered.filter { $0.suggestion != nil } }

    /// The remaining rows, sorted by display label.
    var other: [SubtitleLanguageChoice] {
        ordered
            .filter { $0.suggestion == nil }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    /// Rows in on-screen order.
    var displayOrder: [SubtitleLanguageChoice] { suggested + other }
}
