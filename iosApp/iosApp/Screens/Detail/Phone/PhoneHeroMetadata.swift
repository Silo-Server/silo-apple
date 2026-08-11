#if !os(tvOS)
import Foundation

/// A token in the hero's editorial facts row. `.text` items get a
/// middle-dot separator; `.rating` retains the supported rating treatment.
enum PhoneHeroFactToken: Hashable {
    case text(String)
    case rating(String)
}

/// Builds the eyebrow / source / facts / starring strings shown by the
/// phone hero from an `ItemDetail`. Mirrors `TVHeroMetadata` — the same
/// editorial logic, just exposed under an iOS-only namespace so the
/// tvOS surface doesn't leak across.
enum PhoneHeroMetadata {

    // MARK: - Source row

    static func movieSourceTokens(from detail: ItemDetail) -> [String] {
        if detail.type.lowercased() == "episode" {
            var tokens: [String] = []
            if let label = HeroEditorialMetadata.episodeIdentity(
                season: detail.seasonNumber,
                episode: detail.episodeNumber,
                style: .detail
            ) {
                tokens.append(label)
            }
            tokens.append(contentsOf: HeroEditorialMetadata.normalizedGenres(detail.genres, limit: 1))
            return tokens
        }
        var tokens: [String] = [typeLabel(detail: detail)]
        tokens.append(contentsOf: HeroEditorialMetadata.normalizedGenres(detail.genres, limit: 2))
        return tokens
    }

    static func seriesSourceTokens(from detail: ItemDetail) -> [String] {
        var tokens: [String] = ["TV Show"]
        tokens.append(contentsOf: HeroEditorialMetadata.normalizedGenres(detail.genres, limit: 2))
        return tokens
    }

    static func seasonSourceTokens(from detail: ItemDetail, episodeCount: Int) -> [String] {
        var tokens: [String] = []
        let count = detail.episodeCount ?? episodeCount
        if count > 0 { tokens.append("\(count) Episode\(count == 1 ? "" : "s")") }
        tokens.append(contentsOf: HeroEditorialMetadata.normalizedGenres(detail.genres, limit: 2))
        return tokens
    }

    static func contentRatingChip(from detail: ItemDetail) -> String? {
        HeroEditorialMetadata.normalizedValue(detail.contentRating)
    }

    // MARK: - Facts row

    static func movieFactsLine(from detail: ItemDetail) -> [PhoneHeroFactToken] {
        var tokens: [PhoneHeroFactToken] = []
        if detail.type.lowercased() == "episode",
           let airDate = DetailDateFormatting.abbreviatedDate(detail.airDate) {
            tokens.append(.text(airDate))
        } else if let year = detail.year, year > 0 {
            tokens.append(.text(String(year)))
        }
        if let runtime = detail.runtime, runtime > 0 {
            tokens.append(.text(formatRuntime(runtime)))
        }
        if let imdb = HeroEditorialMetadata.imdbRatingText(detail.ratingImdb) {
            tokens.append(.text("★ \(imdb)"))
        }
        return tokens
    }

    static func seriesFactsLine(from detail: ItemDetail) -> [PhoneHeroFactToken] {
        var tokens: [PhoneHeroFactToken] = []
        if let year = detail.year, year > 0 { tokens.append(.text(String(year))) }
        if let count = detail.seasonCount, count > 0 {
            tokens.append(.text("\(count) Season\(count == 1 ? "" : "s")"))
        }
        if let imdb = HeroEditorialMetadata.imdbRatingText(detail.ratingImdb) {
            tokens.append(.text("★ \(imdb)"))
        }
        return tokens
    }

    // MARK: - Eyebrow

    static func eyebrow(from detail: ItemDetail) -> String? {
        if detail.type.lowercased() == "episode" {
            if let seriesTitle = HeroEditorialMetadata.normalizedValue(detail.seriesTitle) {
                return seriesTitle
            }
        }
        if let status = HeroEditorialMetadata.normalizedValue(detail.status),
           detail.type.lowercased() == "series" {
            switch status.lowercased() {
            case "continuing", "returning series", "returning":
                return "Continuing Series"
            case "ended":
                return "Complete Series"
            case "in production":
                return "New Season Coming"
            default: break
            }
        }
        return nil
    }

    // MARK: - Title parts

    /// Splits "Monarch: Legacy of Monsters" into ("Monarch", "Legacy of
    /// Monsters") so the hero can stack a heavier primary line over a
    /// lighter subtitle.
    static func splitTitle(_ raw: String) -> (primary: String, subtitle: String?) {
        let separators: [String] = [": ", " — ", " – ", " - "]
        for sep in separators {
            if let range = raw.range(of: sep) {
                let head = String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let tail = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !head.isEmpty, !tail.isEmpty {
                    return (head, tail)
                }
            }
        }
        return (raw, nil)
    }

    // MARK: - Helpers

    private static func typeLabel(detail: ItemDetail) -> String {
        switch detail.type.lowercased() {
        case "movie": return "Movie"
        case "series": return "TV Show"
        case "episode": return "Episode"
        case "season": return "Season"
        default: return detail.type.capitalized
        }
    }

    static func formatRuntime(_ minutes: Int) -> String {
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes) min"
    }
}
#endif
