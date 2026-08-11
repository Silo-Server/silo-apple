import Foundation

/// Shared validation and normalization for editorial hero metadata.
enum HeroEditorialMetadata {
    enum EpisodeIdentityStyle {
        case detail
        case compact
    }

    static func normalizedValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.caseInsensitiveCompare("Unknown") != .orderedSame else {
            return nil
        }
        return value
    }

    static func normalizedGenres(_ genres: [String]?, limit: Int) -> [String] {
        guard limit > 0 else { return [] }

        var seen: Set<String> = []
        var result: [String] = []
        for rawGenre in genres ?? [] {
            guard let genre = normalizedValue(rawGenre) else { continue }
            let key = genre.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(genre)
            if result.count == limit { break }
        }
        return result
    }

    static func imdbRatingText(_ rating: Double?) -> String? {
        guard let rating, rating.isFinite, rating > 0, rating <= 10 else {
            return nil
        }
        return rating.formatted(.number.precision(.fractionLength(1)))
    }

    static func browseMetadataParts(
        year: Int?,
        runtime: String?,
        imdbRating: Double?,
        genres: [String]?,
        genreLimit: Int = 2
    ) -> [String] {
        var parts: [String] = []
        if let year, year > 0 {
            parts.append(String(year))
        }
        if let runtime = normalizedValue(runtime) {
            parts.append(runtime)
        }
        if let rating = imdbRatingText(imdbRating) {
            parts.append(rating)
        }
        parts.append(contentsOf: normalizedGenres(genres, limit: genreLimit))
        return parts
    }

    static func episodeIdentity(
        season: Int?,
        episode: Int?,
        style: EpisodeIdentityStyle
    ) -> String? {
        let seasonPart: String?
        if let season, season >= 0 {
            switch style {
            case .detail:
                seasonPart = season == 0 ? "Specials" : "Season \(season)"
            case .compact:
                seasonPart = season == 0 ? "Specials" : "S\(season)"
            }
        } else {
            seasonPart = nil
        }

        let episodePart = episode.flatMap { value -> String? in
            guard value > 0 else { return nil }
            switch style {
            case .detail: return "Episode \(value)"
            case .compact: return "E\(value)"
            }
        }

        let separator: String
        switch style {
        case .detail: separator = " · "
        case .compact: separator = " "
        }
        return [seasonPart, episodePart]
            .compactMap { $0 }
            .joined(separator: separator)
            .nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
