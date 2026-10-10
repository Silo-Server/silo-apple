import Foundation

/// Minimal mirror of the server's `/api/v2/home/sections` response,
/// trimmed to the fields the Top Shelf surface actually uses. We keep
/// this in Shared so the extension and artwork regression tests can use it
/// without compiling the full app DTO surface.
struct TopShelfSectionsResponse: Decodable {
    let sections: [TopShelfSection]

    enum CodingKeys: String, CodingKey { case sections }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sections = try c.decodeIfPresent([TopShelfSection].self, forKey: .sections) ?? []
    }
}

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
    let posterIsEpisodeStill: Bool?
    let userState: TopShelfUserState?

    /// The tile's last-resort artwork: the item's own poster, usually an
    /// episode's still. An untouched episode shows none when the profile
    /// hides unwatched episode images, unless the server marks the poster as
    /// series or season artwork.
    func fallbackPosterUrl(hidingEpisodeStills: Bool) -> String? {
        let isEpisode = ["episode", "episodes"].contains(type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        let isUntouched = userState?.played != true && (positionSeconds ?? 0) <= 0
        if hidingEpisodeStills, isEpisode, isUntouched, posterIsEpisodeStill != false { return nil }
        return posterUrl
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
