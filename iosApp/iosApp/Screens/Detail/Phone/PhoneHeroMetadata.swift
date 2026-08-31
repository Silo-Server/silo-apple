#if !os(tvOS)
import Foundation

/// A token in the hero's facts row. `.text` items get a middle-dot
/// separator between them; `.rating` renders a green check + maturity
/// label; `.chip` renders an outlined uppercase pill (4K / HDR / ATMOS / CC).
enum PhoneHeroFactToken: Hashable {
    case text(String)
    case rating(String)
    case chip(String)
}

/// Builds the eyebrow / source / facts / starring strings shown by the
/// phone hero from an `ItemDetail`. Mirrors `TVHeroMetadata` — the same
/// editorial logic, just exposed under an iOS-only namespace so the
/// tvOS surface doesn't leak across.
enum PhoneHeroMetadata {

    // MARK: - Source row

    static func movieSourceTokens(from detail: ItemDetail) -> [String] {
        if detail.type == "episode" {
            var tokens: [String] = []
            if let label = episodeNumberLabel(from: detail) { tokens.append(label) }
            if let genres = detail.genres, !genres.isEmpty {
                tokens.append(genres.prefix(1).joined(separator: ", "))
            }
            return tokens
        }
        if let genres = detail.genres, !genres.isEmpty {
            return [genres.prefix(2).joined(separator: ", ")]
        }
        return []
    }

    static func seriesSourceTokens(from detail: ItemDetail) -> [String] {
        if let genres = detail.genres, !genres.isEmpty {
            return [genres.prefix(2).joined(separator: ", ")]
        }
        return []
    }

    static func seasonSourceTokens(from detail: ItemDetail, episodeCount: Int) -> [String] {
        var tokens: [String] = []
        let count = detail.episodeCount ?? episodeCount
        if count > 0 { tokens.append("\(count) Episode\(count == 1 ? "" : "s")") }
        if let genres = detail.genres, !genres.isEmpty {
            tokens.append(contentsOf: genres.prefix(2))
        }
        return tokens
    }

    static func contentRatingChip(from detail: ItemDetail) -> String? {
        guard let rating = detail.contentRating?
            .trimmingCharacters(in: .whitespaces), !rating.isEmpty
        else { return nil }
        return rating
    }

    // MARK: - Facts row

    static func movieFactsLine(from detail: ItemDetail, version selectedVersion: FileVersion? = nil) -> [PhoneHeroFactToken] {
        var tokens: [PhoneHeroFactToken] = []
        if detail.type == "episode",
           let airDate = DetailDateFormatting.abbreviatedDate(detail.airDate) {
            tokens.append(.text(airDate))
        } else if let year = detail.year, year > 0 {
            tokens.append(.text(String(year)))
        }
        if let runtime = detail.runtime, runtime > 0 {
            tokens.append(.text(formatRuntime(runtime)))
        }
        if let imdb = detail.ratingImdb {
            tokens.append(.text(String(format: "★ %.1f", imdb)))
        }
        tokens.append(contentsOf: qualityTokens(from: detail, version: selectedVersion))
        return tokens
    }

    static func seriesFactsLine(from detail: ItemDetail) -> [PhoneHeroFactToken] {
        var tokens: [PhoneHeroFactToken] = []
        if let year = detail.year, year > 0 { tokens.append(.text(String(year))) }
        if let count = detail.seasonCount, count > 0 {
            tokens.append(.text("\(count) Season\(count == 1 ? "" : "s")"))
        }
        if let imdb = detail.ratingImdb {
            tokens.append(.text(String(format: "★ %.1f", imdb)))
        }
        tokens.append(contentsOf: qualityTokens(from: detail))
        return tokens
    }

    // MARK: - Eyebrow

    static func eyebrow(from detail: ItemDetail) -> String? {
        if detail.type == "episode" {
            if let seriesTitle = detail.seriesTitle?
                .trimmingCharacters(in: .whitespaces), !seriesTitle.isEmpty {
                return seriesTitle
            }
        }
        if let status = detail.status?
            .trimmingCharacters(in: .whitespaces), !status.isEmpty,
           detail.type == "series" {
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

    // MARK: - Credits

    static func creditText(from detail: ItemDetail) -> String? {
        if detail.type == "movie" {
            let directors = detail.crew?
                .filter { $0.job?.caseInsensitiveCompare("Director") == .orderedSame }
                .map(\.name) ?? []
            guard !directors.isEmpty else { return nil }
            return "Directed by " + directors.prefix(2).joined(separator: ", ")
        }
        if detail.type == "episode" { return nil }
        guard let cast = detail.cast, !cast.isEmpty else { return nil }
        return "Starring " + cast.prefix(3).map(\.name).joined(separator: ", ")
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

    private static func episodeNumberLabel(from detail: ItemDetail) -> String? {
        let seasonPart: String?
        if let season = detail.seasonNumber {
            seasonPart = season == 0 ? "Specials" : "Season \(season)"
        } else {
            seasonPart = nil
        }
        let episodePart = detail.episodeNumber.flatMap { n in n > 0 ? "Episode \(n)" : nil }

        switch (seasonPart, episodePart) {
        case let (.some(s), .some(e)): return "\(s) \u{00B7} \(e)"
        case let (.some(s), .none):    return s
        case let (.none, .some(e)):    return e
        case (.none, .none):           return nil
        }
    }

    private static func typeLabel(detail: ItemDetail) -> String {
        switch detail.type.lowercased() {
        case "movie": return "Movie"
        case "series": return "TV Show"
        case "episode": return "Episode"
        case "season": return "Season"
        default: return detail.type.capitalized
        }
    }

    private static func qualityTokens(from detail: ItemDetail, version selectedVersion: FileVersion? = nil) -> [PhoneHeroFactToken] {
        guard let version = selectedVersion ?? preferredVersion(from: detail) else { return [] }
        var tokens: [PhoneHeroFactToken] = []
        if let res = resolutionLabel(version.resolution) { tokens.append(.chip(res)) }
        if version.hdr == true {
            tokens.append(.chip(dolbyVisionLabel(version: version) ?? "HDR"))
        }
        if let audio = primaryAudioLabel(version: version) { tokens.append(.chip(audio)) }
        if hasSubtitles(version: version) { tokens.append(.chip("CC")) }
        return tokens
    }

    private static func preferredVersion(from detail: ItemDetail) -> FileVersion? {
        guard let versions = detail.versions, !versions.isEmpty else { return nil }
        if let lastId = detail.userData?.lastFileId,
           let lastVersion = versions.first(where: { $0.fileId == lastId }) {
            return lastVersion
        }
        return versions.first
    }

    private static func resolutionLabel(_ raw: String?) -> String? {
        guard let raw = raw?.lowercased() else { return nil }
        if raw.contains("2160") || raw.contains("4k") { return "4K" }
        if raw.contains("1080") { return "HD" }
        if raw.contains("720") { return "HD" }
        if raw.contains("480") { return "SD" }
        return nil
    }

    private static func dolbyVisionLabel(version: FileVersion) -> String? {
        let videoTracks = version.videoTracks ?? []
        if videoTracks.contains(where: { ($0.dolbyVision ?? "").isEmpty == false }) {
            return "DOLBY VISION"
        }
        return nil
    }

    private static func primaryAudioLabel(version: FileVersion) -> String? {
        let tracks = version.audioTracks ?? []
        let defaultTrack = tracks.first(where: { $0.isDefault == true }) ?? tracks.first
        guard let track = defaultTrack else { return nil }

        if let layout = track.channelLayout?.lowercased() {
            if layout.contains("atmos") { return "ATMOS" }
            if layout.contains("7.1") { return "7.1" }
            if layout.contains("5.1") { return "5.1" }
            if layout.contains("stereo") || layout == "2.0" { return nil }
        }
        if let channels = track.channels {
            switch channels {
            case 8: return "7.1"
            case 6: return "5.1"
            default: return nil
            }
        }
        return nil
    }

    private static func hasSubtitles(version: FileVersion) -> Bool {
        !(version.subtitleTracks ?? []).isEmpty
    }

    static func formatRuntime(_ minutes: Int) -> String {
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes) min"
    }
}
#endif
