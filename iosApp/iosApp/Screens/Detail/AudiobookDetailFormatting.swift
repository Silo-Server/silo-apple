import Foundation

/// Pure formatting helpers for the audiobook detail screen. Kept free of
/// SwiftUI so the title-cleanup and credit-summarisation rules — the bits
/// most likely to mangle real-world catalog strings — can be unit tested.
///
/// Everything here is deliberately conservative: it only rewrites patterns
/// it positively recognises and otherwise returns the input untouched, so a
/// title it doesn't understand can never come out worse than it went in.
enum AudiobookDetailFormatting {

    /// Cleans redundant series locators out of a raw audiobook title. Server
    /// titles frequently bake the series name and volume into the title
    /// ("Stormlight Archive 5 - Wind and Truth (5 of 5)"); we lift those out
    /// so the title can read as just "Wind and Truth".
    static func cleanTitle(_ rawTitle: String, seriesName: String?) -> String {
        let original = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = original

        if let seriesName, !seriesName.isEmpty {
            title = strippingSeriesPrefix(title, seriesName: seriesName)
        }
        title = strippingTrailingVolume(title)
        title = title.trimmingCharacters(in: trimEdges)

        return title.isEmpty ? original : title
    }

    /// Parses a trailing "(N of M)" volume locator from a raw title. This is
    /// the most reliable source of the series *total* — the structured
    /// series grouping can lump in alternate editions/narrations, so its
    /// entry count overstates how many books are in the series.
    static func volume(in rawTitle: String) -> (index: Int?, total: Int?) {
        let pattern = #"\(\s*(\d+)\s+of\s+(\d+)\s*\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (nil, nil)
        }
        let range = NSRange(rawTitle.startIndex..., in: rawTitle)
        guard let match = regex.firstMatch(in: rawTitle, range: range),
              let indexRange = Range(match.range(at: 1), in: rawTitle),
              let totalRange = Range(match.range(at: 2), in: rawTitle) else {
            return (nil, nil)
        }
        return (Int(rawTitle[indexRange]), Int(rawTitle[totalRange]))
    }

    /// "The Stormlight Archive · Book 5 of 5" / "… · Book 5" / "…".
    static func seriesLine(name: String?, index: Int?, total: Int?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return nil
        }
        guard let index, index > 0 else { return name }
        if let total, total >= index, total > 1 {
            return "\(name) · Book \(index) of \(total)"
        }
        return "\(name) · Book \(index)"
    }

    /// Summarises a credit list: keeps the first `visible` names and rolls
    /// the rest into "& N more". Splits on commas first, because servers
    /// sometimes deliver a whole cast as one comma-joined string rather than
    /// discrete people. Small lists join naturally with "&" so we never
    /// print the awkward "& 1 more".
    ///
    /// - `["Brandon Sanderson"]` → "Brandon Sanderson"
    /// - `["A", "B", "C"]` → "A, B & C"
    /// - `["A, B, C, D, E"]` (one combined string, visible 2) → "A, B & 3 more"
    static func peopleSummary(_ names: [String], visible: Int = 2) -> String? {
        let cleaned = names
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }

        if cleaned.count <= visible + 1 {
            return naturalJoin(cleaned)
        }
        let shown = cleaned.prefix(visible).joined(separator: ", ")
        let remaining = cleaned.count - visible
        return "\(shown) & \(remaining) more"
    }

    // MARK: - Internals

    private static let trimEdges = CharacterSet(charactersIn: " -–—:·,").union(.whitespacesAndNewlines)

    private static func naturalJoin(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) & \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " & " + (names.last ?? "")
        }
    }

    /// Drops a leading "<Series>[ N][ -:–] " prefix when the title opens
    /// with the series name (ignoring a leading article on either side).
    private static func strippingSeriesPrefix(_ title: String, seriesName: String) -> String {
        let core = droppingLeadingArticle(seriesName).trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return title }

        let hay = droppingLeadingArticle(title)
        guard hay.lowercased().hasPrefix(core.lowercased()) else { return title }

        var rest = Substring(hay.dropFirst(core.count))
        // The series name must end at a word boundary: series "Dune" is not
        // a prefix of "Dunes of Arrakis", nor series "A" of "American Gods".
        if let next = rest.first, next.isLetter { return title }
        // Eat the volume number and separators that sit between the series
        // name and the actual title ("Stormlight Archive" → " 5 - " → title).
        rest = rest.drop { ch in
            ch == " " || ch.isNumber || ch == "-" || ch == "–" || ch == "—" || ch == ":" || ch == "#"
        }
        let candidate = rest.trimmingCharacters(in: .whitespaces)
        // Bail out if we'd consume the whole thing — that means the "prefix"
        // was actually the title.
        return candidate.isEmpty ? title : candidate
    }

    /// Removes a trailing volume locator: "(5 of 5)", "(Book 5)",
    /// "(Volume 5)". These are pure series metadata the series line carries.
    private static func strippingTrailingVolume(_ title: String) -> String {
        let patterns = [
            #"\s*\(\s*\d+\s+of\s+\d+\s*\)$"#,
            #"\s*\(\s*book\s+\d+\s*\)$"#,
            #"\s*\(\s*vol(?:ume)?\.?\s*\d+\s*\)$"#,
        ]
        var result = title
        for pattern in patterns {
            if let range = result.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) {
                result.removeSubrange(range)
            }
        }
        return result
    }

    private static func droppingLeadingArticle(_ s: String) -> String {
        let lower = s.lowercased()
        for article in ["the ", "a ", "an "] where lower.hasPrefix(article) {
            return String(s.dropFirst(article.count))
        }
        return s
    }
}

func audiobookRelatedItemAccessibilityLabel(_ item: AudiobookRelatedItem) -> String {
    var components = [item.title]
    if let seriesIndex = item.seriesIndex {
        components.append("Book \(seriesIndex)")
    }
    if let year = item.year {
        components.append(String(year))
    }
    return components.joined(separator: ", ")
}
