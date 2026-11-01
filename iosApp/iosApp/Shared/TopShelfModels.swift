import Foundation

/// The Home rows Top Shelf shows, in display order, trimmed to the fields
/// the Top Shelf surface actually uses. We keep this in Shared so the
/// extension and artwork regression tests can use it without compiling the
/// full app DTO surface.
struct TopShelfSectionsResponse: Decodable {
    let sections: [TopShelfSection]
    /// Rows the layout listed whose read failed or changed type.
    let failedSectionCount: Int

    enum CodingKeys: String, CodingKey { case sections }

    init(sections: [TopShelfSection], failedSectionCount: Int) {
        self.sections = sections
        self.failedSectionCount = failedSectionCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sections = try c.decodeIfPresent([TopShelfSection].self, forKey: .sections) ?? []
        failedSectionCount = 0
    }
}

/// The rows Top Shelf shows, by `section_type`.
enum TopShelfRow {
    /// Matches the home screen's `ResolvedSection.isContinueWatchingSection`.
    static func isContinueWatching(_ sectionType: String) -> Bool {
        let type = sectionType.lowercased()
        return type == "continue_watching" || type == "in_progress"
    }

    /// Matches the next-up half of the home screen's `SectionRow.isEpisodeRow`.
    static func isNextUp(_ sectionType: String) -> Bool {
        sectionType.lowercased().contains("next")
    }

    static func isShown(_ sectionType: String) -> Bool {
        isContinueWatching(sectionType) || isNextUp(sectionType)
    }
}

/// `GET /api/v2/home/layout` without cards: every Home row in display order.
struct TopShelfHomeLayout: Decodable {
    struct Entry: Decodable {
        let id: String
        let sectionType: String
    }

    let sections: [Entry]
}

/// One Home row with its cards, as `GET /api/v2/home/sections/{id}/items`
/// answers it.
struct TopShelfSection: Decodable {
    let id: String
    let sectionType: String
    let title: String
    let items: [TopShelfItem]
}

struct TopShelfItem: Decodable {
    let contentId: String
    let type: String
    let title: String
    let seriesId: String?
    let seriesTitle: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let positionSeconds: Double?
    let durationSeconds: Double?
    let progressUpdatedAt: String?
    @ArtworkURL var posterUrl: String?
    @ArtworkURL var backdropUrl: String?
    /// Episode cards from servers with `episode_parent_artwork`.
    @ArtworkURL var seasonPosterUrl: String?
    @ArtworkURL var seriesPosterUrl: String?
    let posterIsEpisodeStill: Bool?
    let userState: TopShelfUserState?

    /// The tile's last-resort artwork: the item's own poster, usually an
    /// episode's still. An untouched episode shows none when the profile
    /// hides unwatched episode images, unless the server marks the poster as
    /// series or season artwork.
    func fallbackPosterUrl(hidingEpisodeStills: Bool) -> String? {
        let isUntouched = userState?.played != true && (positionSeconds ?? 0) <= 0
        if hidingEpisodeStills, isEpisode, isUntouched, posterIsEpisodeStill != false { return nil }
        return posterUrl
    }

    /// Matches `SiloMediaType.isEpisode`, which the extension does not compile.
    var isEpisode: Bool {
        ["episode", "episodes"].contains(type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The season's poster, else the series', when the card carries them.
    var cardShowPosterUrl: String? {
        if let url = seasonPosterUrl, !url.isEmpty { return url }
        if let url = seriesPosterUrl, !url.isEmpty { return url }
        return nil
    }

    /// 0.0...1.0 or nil when we don't have both position and duration.
    var playbackProgress: Double? {
        guard let position = positionSeconds,
              let duration = durationSeconds,
              duration > 0 else { return nil }
        return max(0, min(1, position / duration))
    }
}

struct TopShelfUserState: Decodable {
    let played: Bool
}

/// Subset of `/api/v2/catalog/series/{id}/seasons` we need. The main app
/// decodes the full `Season` shape, but the extension only cares about
/// matching a season number to its poster URL.
struct TopShelfSeasonsResponse: Decodable {
    let seasons: [TopShelfSeason]

    enum CodingKeys: String, CodingKey { case items }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seasons = try c.decodeIfPresent([TopShelfSeason].self, forKey: .items) ?? []
    }
}

struct TopShelfSeason: Decodable {
    let seasonNumber: Int
    @ArtworkURL var posterUrl: String?
}

/// Subset of `/api/v2/catalog/items/{id}` — only the poster URL.
struct TopShelfItemDetail: Decodable {
    @ArtworkURL var posterUrl: String?
}
