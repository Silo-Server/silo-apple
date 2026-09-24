import Foundation

/// Which season and episode a series opens on: the one in progress, else the
/// first unwatched one. Shared by the detail page, the tvOS marquee, and
/// Siri playback so "play this series" means the same episode everywhere.
enum SeriesNextUpPolicy {
    static func preferredSeason(in seasons: [Season]) -> Season? {
        if let inProgress = seasons.first(where: { ($0.userData?.inProgressCount ?? 0) > 0 }) {
            return inProgress
        }
        if let partial = seasons.first(where: {
            guard let userData = $0.userData else { return false }
            let watched = userData.watchedCount ?? 0
            return watched > 0 && watched < $0.episodeCount
        }) {
            return partial
        }
        // Specials sort first for display, but a fresh series should open on
        // its first numbered season rather than the specials bucket. Once
        // every numbered season is played, an unplayed Specials still wins
        // over a fully watched one.
        let regular = seasons.filter { !($0.isSpecials == true || $0.seasonNumber == 0) }
        let isUnplayed: (Season) -> Bool = { !($0.userData?.played ?? false) }
        if let firstUnplayed = regular.first(where: isUnplayed) ?? seasons.first(where: isUnplayed) {
            return firstUnplayed
        }
        return regular.first ?? seasons.first
    }

    static func nextUpEpisode(in episodes: [EpisodeListItem]) -> EpisodeListItem? {
        if let inProgress = episodes.first(where: { $0.userData?.isInProgress == true }) {
            return inProgress
        }
        if let unwatched = episodes.first(where: { !($0.userData?.played ?? false) }) {
            return unwatched
        }
        return episodes.first
    }
}
