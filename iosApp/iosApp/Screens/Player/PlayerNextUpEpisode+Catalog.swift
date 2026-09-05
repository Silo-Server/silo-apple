import Foundation

extension PlayerNextUpEpisode {
    /// Shared catalog reads used by next-up, with no playback session changes.
    static func resolve(contentId: String, seriesId: String, seriesTitle: String?,
                        seasonNumber: Int, episodeNumber: Int, api: SiloAPI = .shared) async throws -> PlayerNextUpEpisode? {
        async let seasonsTask = api.seasons(seriesId: seriesId)
        async let currentEpisodesTask = api.episodes(
            seriesId: seriesId,
            seasonNumber: seasonNumber
        )

        let seasonsResponse = try await seasonsTask
        let currentEpisodesResponse = try await currentEpisodesTask
        let seasons = seasonsResponse.seasons.sortedForDisplay()
        var episodes = currentEpisodesResponse.episodes

        let nextSeason = seasons.first { season in
            !(season.isSpecials ?? false) && season.seasonNumber > seasonNumber
        }
        if let nextSeason {
            let nextSeasonEpisodes = try await api.episodes(
                seriesId: seriesId,
                seasonNumber: nextSeason.seasonNumber
            )
            episodes.append(contentsOf: nextSeasonEpisodes.episodes)
        }

        let orderedEpisodes = episodes.sorted { lhs, rhs in
            if lhs.seasonNumber != rhs.seasonNumber {
                return lhs.seasonNumber < rhs.seasonNumber
            }
            if lhs.episodeNumber != rhs.episodeNumber {
                return lhs.episodeNumber < rhs.episodeNumber
            }
            return lhs.contentId < rhs.contentId
        }

        let currentIndex = orderedEpisodes.firstIndex { $0.contentId == contentId }
            ?? orderedEpisodes.firstIndex {
                $0.seasonNumber == seasonNumber && $0.episodeNumber == episodeNumber
            }
        guard let currentIndex, currentIndex < orderedEpisodes.index(before: orderedEpisodes.endIndex) else {
            return nil
        }

        return PlayerNextUpEpisode(
            episode: orderedEpisodes[orderedEpisodes.index(after: currentIndex)],
            seriesId: seriesId,
            seriesTitle: seriesTitle
        )
    }
}
