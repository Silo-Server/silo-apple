import SwiftUI

// MARK: - Filter presets

/// Server-side calendar presets surfaced in the UI. Raw values are the
/// API `filter` query values.
enum CalendarFilter: String, CaseIterable, Identifiable {
    case following
    case trending
    case everything

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .following: return "Following"
        case .trending: return "Trending"
        case .everything: return "All"
        }
    }
}

// MARK: - Wire types

/// Response from `GET /api/v2/calendar`. Snake_case keys are mapped by the
/// shared decoder's `.convertFromSnakeCase` strategy.
struct CalendarResponse: Codable {
    let events: [CalendarDay]
}

/// One local day's worth of events. `date` is the viewer-local
/// "YYYY-MM-DD" grouping key (`local_air_date` on each item).
struct CalendarDay: Codable, Identifiable {
    let date: String
    let items: [CalendarEvent]

    var id: String { date }
}

/// A single airing/release: a movie release, an episode airing, or a
/// season premiere placeholder (used when episode 1 has no air date yet).
struct CalendarEvent: Codable, Identifiable {
    let contentId: String
    let type: String // "movie" | "episode" | "season_premiere"
    let title: String
    let episodeTitle: String?
    let seriesId: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let airDate: String?
    let airTime: String?
    let airAt: String?
    let airTimezone: String?
    let localAirDate: String?
    let posterUrl: String?
    let posterThumbhash: String?
    let watched: Bool?
    let badges: [String]?

    var id: String { contentId }

    /// Where tapping the event should land: episodes and season premieres
    /// open their series; movies open themselves.
    var navigationContentId: String {
        type == "movie" ? contentId : (seriesId ?? contentId)
    }

    var isWatched: Bool { watched == true }

    /// "S5 · E14" for episodes, "Season 2" for season premieres.
    var episodeSubtitle: String? {
        switch type {
        case "episode":
            guard let season = seasonNumber, let episode = episodeNumber else { return nil }
            return "S\(season) · E\(episode)"
        case "season_premiere":
            guard let season = seasonNumber else { return nil }
            return "Season \(season)"
        default:
            return nil
        }
    }

    /// Localized air time for display ("9:00 PM"). Prefers the absolute
    /// instant when the server knows the source timezone; falls back to
    /// interpreting the wall-clock time in the viewer's timezone.
    var displayAirTime: String? {
        if let airAt {
            return DateFormatters.localShortTime(fromRFC3339: airAt)
        }
        if let airTime {
            return DateFormatters.localShortTime(fromWallClock: airTime)
        }
        return nil
    }

    var displayBadges: [CalendarBadge] {
        (badges ?? []).compactMap(CalendarBadge.init)
    }
}

/// Editorial badges the server attaches to calendar events.
enum CalendarBadge: String {
    case seriesPremiere = "series_premiere"
    case seasonPremiere = "season_premiere"
    case finale

    var label: String {
        switch self {
        case .seriesPremiere: return "SERIES PREMIERE"
        case .seasonPremiere: return "NEW SEASON"
        case .finale: return "FINALE"
        }
    }
}
