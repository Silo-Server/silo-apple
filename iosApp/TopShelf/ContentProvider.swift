import Foundation
import TVServices

/// Top Shelf content provider for the Apple TV Home Screen.
///
/// tvOS invokes this out-of-process when the Continuum app icon is
/// focused. We have a tight budget (a few seconds) to return content
/// before the system falls back to the static top-shelf image.
///
/// Content model: two poster-shape sections — Continue Watching and
/// Next Up — sorted most-recently-progressed first. Selecting a tile
/// opens the main app at the detail screen via the `continuum://item/`
/// URL scheme; pressing Play on the Siri remote jumps straight to
/// playback via `continuum://play/`.
final class ContentProvider: TVTopShelfContentProvider {

    private static let timestampFormatter = ISO8601DateFormatter()

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let defaults = SharedStorage.suite
        defaults.set(
            Self.timestampFormatter.string(from: Date()),
            forKey: SharedStorage.topShelfLastRunAtKey
        )

        let http = TopShelfHTTPClient()
        guard http.isPersonalizedContentAllowed else {
            defaults.set(
                "profile-selection-required",
                forKey: SharedStorage.topShelfLastStatusKey
            )
            return nil
        }
        let response: TopShelfSectionsResponse
        let imageSizeQuery = await http.fetchImageSizeQuery()
        do {
            response = try await http.fetchHomeSections(imageSizeQuery: imageSizeQuery)
        } catch {
            defaults.set(
                "fetch-failed: \(error)",
                forKey: SharedStorage.topShelfLastStatusKey
            )
            return nil
        }

        let cwItems = items(from: response, matching: Self.isContinueWatching)
        let nuItems = items(from: response, matching: Self.isNextUp)
        let seriesPosters = await fetchSeriesPosters(
            for: cwItems + nuItems,
            using: http,
            imageSizeQuery: imageSizeQuery
        )

        let continueWatching = collection(
            title: "Continue Watching",
            items: cwItems,
            seriesPosters: seriesPosters
        )
        let nextUp = collection(
            title: "Next Up",
            items: nuItems,
            seriesPosters: seriesPosters
        )

        let collections = [continueWatching, nextUp].compactMap { $0 }
        let cwCount = continueWatching?.items.count ?? 0
        let nuCount = nextUp?.items.count ?? 0
        defaults.set(
            "ok: sections=\(response.sections.count) cw=\(cwCount) nu=\(nuCount) types=\(response.sections.map(\.sectionType).joined(separator: ","))",
            forKey: SharedStorage.topShelfLastStatusKey
        )
        guard !collections.isEmpty else { return nil }

        return TVTopShelfSectionedContent(sections: collections)
    }

    // MARK: - Series / season poster lookup

    /// Cache of the best poster URL to show for each episode, keyed by
    /// (seriesId, seasonNumber). We prefer the season's own poster; if
    /// the season has no poster (or the seasons call fails), we fall
    /// back to the series poster. Episodes whose series has neither
    /// fall back at render time to their original item poster.
    private struct EpisodePosters {
        var seasonPoster: [SeriesSeasonKey: String] = [:]
        var seriesPoster: [String: String] = [:]

        func lookup(seriesId: String?, seasonNumber: Int?) -> String? {
            guard let seriesId else { return nil }
            if let seasonNumber,
               let poster = seasonPoster[SeriesSeasonKey(seriesId: seriesId, seasonNumber: seasonNumber)] {
                return poster
            }
            return seriesPoster[seriesId]
        }
    }

    private struct SeriesSeasonKey: Hashable {
        let seriesId: String
        let seasonNumber: Int
    }

    /// Issues one seasons fetch per unique series and only falls back to
    /// the item-detail endpoint when a series has no season-level poster.
    /// For a typical Continue Watching / Next Up payload (2–5 unique
    /// series with season posters on most) this halves the request count
    /// inside the Top Shelf's tight time budget. Individual series errors
    /// are swallowed — a missing poster means the episode renders its own
    /// still instead.
    private func fetchSeriesPosters(
        for items: [TopShelfItem],
        using http: TopShelfHTTPClient,
        imageSizeQuery: [String: String]
    ) async -> EpisodePosters {
        let seriesIds = Set(items.compactMap { item -> String? in
            guard item.type == "episode" else { return nil }
            return item.seriesId
        })
        guard !seriesIds.isEmpty else { return EpisodePosters() }

        var posters = await withTaskGroup(
            of: (seriesId: String, seasons: TopShelfSeasonsResponse?).self
        ) { group in
            for seriesId in seriesIds {
                group.addTask {
                    (
                        seriesId,
                        try? await http.fetchSeasons(
                            seriesId: seriesId,
                            imageSizeQuery: imageSizeQuery
                        )
                    )
                }
            }
            var acc = EpisodePosters()
            for await (seriesId, seasons) in group {
                for season in seasons?.seasons ?? [] {
                    if let poster = season.posterUrl {
                        acc.seasonPoster[SeriesSeasonKey(
                            seriesId: seriesId,
                            seasonNumber: season.seasonNumber
                        )] = poster
                    }
                }
            }
            return acc
        }

        let seriesMissingPoster = seriesIds.filter { id in
            !posters.seasonPoster.keys.contains(where: { $0.seriesId == id })
        }
        guard !seriesMissingPoster.isEmpty else { return posters }

        await withTaskGroup(
            of: (seriesId: String, poster: String?).self
        ) { group in
            for seriesId in seriesMissingPoster {
                group.addTask {
                    (
                        seriesId,
                        (try? await http.fetchItemDetail(
                            contentId: seriesId,
                            imageSizeQuery: imageSizeQuery
                        ))?.posterUrl
                    )
                }
            }
            for await (seriesId, poster) in group {
                if let poster {
                    posters.seriesPoster[seriesId] = poster
                }
            }
        }
        return posters
    }

    // MARK: - Section selection

    /// Matches the home screen's `SectionRow.isContinueWatching` check.
    private static func isContinueWatching(_ section: TopShelfSection) -> Bool {
        section.sectionType == "continue_watching" || section.sectionType == "in_progress"
    }

    /// Matches the home screen's `SectionRow.isEpisodeRow` next-up check.
    private static func isNextUp(_ section: TopShelfSection) -> Bool {
        let t = section.sectionType
        return t.contains("next") || t.contains("up_next") || t.contains("next_up")
    }

    // MARK: - Item construction

    private func items(
        from response: TopShelfSectionsResponse,
        matching predicate: (TopShelfSection) -> Bool
    ) -> [TopShelfItem] {
        response.sections
            .filter(predicate)
            .flatMap { $0.items }
            .sorted { lhs, rhs in
                sortKey(lhs) > sortKey(rhs)
            }
    }

    /// ISO-8601 `progressUpdatedAt` sorts naturally as a string (fixed-
    /// width year-first format), so lexicographic comparison is enough
    /// and avoids the cost of date parsing in the extension.
    private func sortKey(_ item: TopShelfItem) -> String {
        item.progressUpdatedAt ?? ""
    }

    private func collection(
        title: String,
        items: [TopShelfItem],
        seriesPosters: EpisodePosters
    ) -> TVTopShelfItemCollection<TVTopShelfSectionedItem>? {
        guard !items.isEmpty else { return nil }
        let shelfItems = items.map { sectionedItem(from: $0, seriesPosters: seriesPosters) }
        let collection = TVTopShelfItemCollection(items: shelfItems)
        collection.title = title
        return collection
    }

    private func sectionedItem(
        from item: TopShelfItem,
        seriesPosters: EpisodePosters
    ) -> TVTopShelfSectionedItem {
        let shelfItem = TVTopShelfSectionedItem(identifier: item.contentId)
        shelfItem.title = displayTitle(for: item)
        shelfItem.imageShape = .poster
        if let progress = item.playbackProgress {
            shelfItem.playbackProgress = progress
        }
        let posterString = posterURLString(for: item, seriesPosters: seriesPosters)
        if let posterString, let url = URL(string: posterString) {
            shelfItem.setImageURL(url, for: .screenScale1x)
            shelfItem.setImageURL(url, for: .screenScale2x)
        }
        shelfItem.displayAction = TVTopShelfAction(
            url: URL(string: "continuum://item/\(item.contentId)")!
        )
        shelfItem.playAction = TVTopShelfAction(
            url: URL(string: "continuum://play/\(item.contentId)")!
        )
        return shelfItem
    }

    /// For episodes, prefer the season poster; fall back to the series
    /// poster; only use the item's own `posterUrl` as a last resort,
    /// because for episodes the server emits a 16:9 still which looks
    /// bad in a 2:3 poster tile. Movies use their own poster directly.
    private func posterURLString(
        for item: TopShelfItem,
        seriesPosters: EpisodePosters
    ) -> String? {
        if item.type == "episode",
           let poster = seriesPosters.lookup(
               seriesId: item.seriesId,
               seasonNumber: item.seasonNumber
           ) {
            return poster
        }
        return item.posterUrl
    }

    /// Episodes benefit from a "Series Name · S1E3" label instead of
    /// just the episode title. Movies use the bare title.
    private func displayTitle(for item: TopShelfItem) -> String {
        guard item.type == "episode",
              let seriesTitle = item.seriesTitle,
              let season = item.seasonNumber,
              let episode = item.episodeNumber else {
            return item.title
        }
        return "\(seriesTitle) · S\(season)E\(episode)"
    }
}
