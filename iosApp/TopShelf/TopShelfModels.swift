import Foundation

/// Minimal mirror of the server's `/api/v1/home/sections` response,
/// trimmed to the fields the Top Shelf surface actually uses. We keep
/// this separate from the main app's `Models.swift` so the extension
/// doesn't compile the full DTO surface (and its supporting types).
struct TopShelfSectionsResponse: Decodable {
    let sections: [TopShelfSection]

    enum CodingKeys: String, CodingKey { case sections }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sections = try c.decodeIfPresent([TopShelfSection].self, forKey: .sections) ?? []
    }
}

struct TopShelfSection: Decodable {
    let sectionType: String
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
    let posterUrl: String?

    /// 0.0...1.0 or nil when we don't have both position and duration.
    var playbackProgress: Double? {
        guard let position = positionSeconds,
              let duration = durationSeconds,
              duration > 0 else { return nil }
        return max(0, min(1, position / duration))
    }
}

/// Subset of `/api/v1/catalog/series/{id}/seasons` we need. The main app
/// decodes the full `Season` shape, but the extension only cares about
/// matching a season number to its poster URL.
struct TopShelfSeasonsResponse: Decodable {
    let seasons: [TopShelfSeason]

    enum CodingKeys: String, CodingKey { case seasons }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seasons = try c.decodeIfPresent([TopShelfSeason].self, forKey: .seasons) ?? []
    }
}

struct TopShelfSeason: Decodable {
    let seasonNumber: Int
    let posterUrl: String?
}

/// Subset of `/api/v1/catalog/items/{id}` — only the poster URL.
struct TopShelfItemDetail: Decodable {
    let posterUrl: String?
}
