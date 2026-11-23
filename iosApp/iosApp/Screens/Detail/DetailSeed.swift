import Foundation

/// The card a detail page was opened from, kept until the tap so building a
/// seed costs nothing while the card is only on screen.
enum DetailSeedSource: Hashable {
    case section(SectionItem)
    case browse(BrowseItem)

    var sectionItem: SectionItem {
        switch self {
        case .section(let item): item
        case .browse(let item): SectionItem(browseItem: item)
        }
    }
}

extension ItemDetail {
    /// A provisional detail drawn from the card that opened `contentId`, so
    /// the page can paint its title, facts and artwork before the catalog
    /// answers. Fields a card does not carry (files, watch state, cast,
    /// crew, the ratings row, themes, trailers, a book's authors, narrators
    /// and series) stay nil; the page shows those parts in their loading
    /// form while the detail is provisional.
    ///
    /// A movie, series or audiobook card seeds its own page. An episode card
    /// that opens its series seeds a series page from the series' id, title
    /// and artwork only, never the episode's description, still, runtime or
    /// ratings. Anything else, or a card without a title, seeds nothing.
    static func seed(from item: SectionItem, opening contentId: String) -> ItemDetail? {
        if item.contentId == contentId {
            guard let type = pageType(ofCard: item.type),
                  let title = nonEmpty(item.title) else { return nil }
            return provisional(
                contentId: contentId,
                type: type,
                title: title,
                status: item.status,
                originalLanguage: item.originalLanguage,
                showStatus: item.showStatus,
                year: item.year,
                overview: item.overview,
                runtime: item.runtime,
                contentRating: item.contentRating,
                advisoryAge: item.advisoryAge,
                advisorySource: item.advisorySource,
                genres: item.genres,
                ratingImdb: item.ratingImdb,
                ratingTmdb: item.ratingTmdb,
                ratingRtCritic: item.ratingRtCritic,
                ratingRtAudience: item.ratingRtAudience,
                studios: item.studios,
                networks: item.networks,
                lastAirDate: item.lastAirDate,
                episodeLabels: item.episodeLabels,
                posterIsEpisodeStill: item.posterIsEpisodeStill,
                backdropIsEpisodeStill: item.backdropIsEpisodeStill,
                posterUrl: item.posterUrl,
                posterThumbhash: item.posterThumbhash,
                backdropUrl: item.backdropUrl,
                backdropThumbhash: item.backdropThumbhash,
                logoUrl: item.logoUrl,
                overlaySummary: item.overlaySummary,
                userState: item.userState,
                machineTranslatedFields: item.machineTranslatedFields
            )
        }
        guard SiloMediaType.isEpisode(item.type),
              item.seriesId == contentId,
              let seriesTitle = nonEmpty(item.seriesTitle) else { return nil }
        // The card's own poster, backdrop and logo belong to the episode (or
        // may), so only the parent artwork the server marks as the series'
        // is used.
        let poster = nonEmpty(item.seriesPosterUrl)
        let backdrop = nonEmpty(item.seriesBackdropUrl)
        return provisional(
            contentId: contentId,
            type: "series",
            title: seriesTitle,
            // An episode card carries its series' episode labels.
            episodeLabels: item.episodeLabels,
            posterUrl: poster,
            posterThumbhash: poster == nil ? nil : item.seriesPosterThumbhash,
            backdropUrl: backdrop,
            backdropThumbhash: backdrop == nil ? nil : item.seriesBackdropThumbhash
        )
    }

    /// The detail type of the page a card opens on its own, in the form the
    /// page branches on. Nil for episodes and seasons, which open their
    /// series, and for types the page does not draw.
    private static func pageType(ofCard cardType: String) -> String? {
        if SiloMediaType.isMovieLibrary(cardType) { return "movie" }
        if SiloMediaType.isSeries(cardType) { return "series" }
        if SiloMediaType.isAudiobook(cardType) { return "audiobook" }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func provisional(
        contentId: String,
        type: String,
        title: String,
        status: String? = nil,
        originalLanguage: String? = nil,
        showStatus: String? = nil,
        year: Int? = nil,
        overview: String? = nil,
        runtime: Int? = nil,
        contentRating: String? = nil,
        advisoryAge: Int? = nil,
        advisorySource: String? = nil,
        genres: [String]? = nil,
        ratingImdb: Double? = nil,
        ratingTmdb: Double? = nil,
        ratingRtCritic: Int? = nil,
        ratingRtAudience: Int? = nil,
        studios: [String]? = nil,
        networks: [String]? = nil,
        lastAirDate: String? = nil,
        episodeLabels: String? = nil,
        posterIsEpisodeStill: Bool? = nil,
        backdropIsEpisodeStill: Bool? = nil,
        posterUrl: String? = nil,
        posterThumbhash: String? = nil,
        backdropUrl: String? = nil,
        backdropThumbhash: String? = nil,
        logoUrl: String? = nil,
        overlaySummary: OverlaySummary? = nil,
        userState: MediaItemUserState? = nil,
        machineTranslatedFields: [String]? = nil
    ) -> ItemDetail {
        ItemDetail(
            contentId: contentId,
            type: type,
            status: status,
            title: title,
            sortTitle: nil,
            originalTitle: nil,
            originalLanguage: originalLanguage,
            showStatus: showStatus,
            year: year,
            overview: overview,
            tagline: nil,
            runtime: runtime,
            contentRating: contentRating,
            advisoryAge: advisoryAge,
            advisorySource: advisorySource,
            genres: genres,
            ratingImdb: ratingImdb,
            ratingTmdb: ratingTmdb,
            ratingRtCritic: ratingRtCritic,
            ratingRtAudience: ratingRtAudience,
            imdbId: nil,
            tmdbId: nil,
            tvdbId: nil,
            cast: nil,
            crew: nil,
            studios: studios,
            networks: networks,
            countries: nil,
            releaseDate: nil,
            firstAirDate: nil,
            lastAirDate: lastAirDate,
            posterIsEpisodeStill: posterIsEpisodeStill,
            backdropIsEpisodeStill: backdropIsEpisodeStill,
            posterUrl: posterUrl,
            posterThumbhash: posterThumbhash,
            backdropUrl: backdropUrl,
            backdropThumbhash: backdropThumbhash,
            logoUrl: logoUrl,
            seasonCount: nil,
            seriesId: nil,
            seriesTitle: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            episodeCount: nil,
            airDate: nil,
            episodeLabels: episodeLabels,
            isSpecials: nil,
            userData: nil,
            versions: nil,
            subtitles: nil,
            intro: nil,
            credits: nil,
            effectiveSubtitleMode: nil,
            effectiveShowForcedSubtitles: nil,
            effectiveSubtitleTrackSignature: nil,
            overlaySummary: overlaySummary,
            audiobook: nil,
            // The page's own translation starts from the real detail only.
            pendingTranslationLanguage: nil,
            userState: userState,
            machineTranslatedFields: machineTranslatedFields
        )
    }
}

/// The artwork a card seed drew, which the page keeps showing in the same
/// slots while the fetched detail's larger artwork loads.
struct DetailSeedArtwork: Equatable {
    let backdrop: String?
    let poster: String?

    /// The hero's artwork: the backdrop, else the poster.
    var hero: String? { backdrop ?? poster }

    init(_ seed: ItemDetail) {
        backdrop = seed.backdropUrl.flatMap { $0.isEmpty ? nil : $0 }
        poster = seed.posterUrl.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Hands the tapped card to the detail page it opens, without threading it
/// through every navigation path.
///
/// Holds one seed, the last card tapped, under the `item:` cache family, so
/// it is dropped with item metadata at every boundary that drops it (profile
/// switch, sign-out, metadata-language change, memory warning). It is
/// stamped with the server and profile it was offered under and never
/// returned under another one, since it carries that profile's flags. It
/// lives under its own key, so it is never read as a fetched detail.
@MainActor
enum DetailSeedStore {
    private struct Entry {
        let contentId: String
        let scope: Scope
        let detail: ItemDetail
    }

    struct Scope: Equatable {
        let serverId: String?
        let profileId: String?
    }

    /// The server and profile requests go out as. Tests replace it.
    static var currentScope: @MainActor () -> Scope = {
        Scope(serverId: ServerRegistry.activeServerIDSnapshot, profileId: AuthService.shared.profileId)
    }

    /// Offer the card a tap is about to open `contentId` from. A card that
    /// cannot seed that page clears the previous seed instead.
    static func offer(_ source: DetailSeedSource?, opening contentId: String) {
        guard let detail = source.flatMap({ ItemDetail.seed(from: $0.sectionItem, opening: contentId) }) else {
            ResponseCache.shared.remove(CacheKey.itemDetailSeed)
            return
        }
        ResponseCache.shared.set(
            Entry(contentId: contentId, scope: currentScope(), detail: detail),
            for: CacheKey.itemDetailSeed
        )
    }

    static func seed(for contentId: String) -> ItemDetail? {
        guard let entry: Entry = ResponseCache.shared.get(CacheKey.itemDetailSeed),
              entry.contentId == contentId,
              entry.scope == currentScope() else { return nil }
        return entry.detail
    }

    /// Drop the seed once the real detail for `contentId` is on screen.
    static func discard(contentId: String) {
        guard let entry: Entry = ResponseCache.shared.get(CacheKey.itemDetailSeed),
              entry.contentId == contentId else { return }
        ResponseCache.shared.remove(CacheKey.itemDetailSeed)
    }
}
