import Foundation

/// All navigable destinations in the Silo app.
enum Route: Hashable {
    // Auth flow
    case serverSetup
    case serverNeedsSetup

    // Main tabs
    case search
    case libraryCollection(libraryId: Int, collectionId: String, title: String?, kind: LibraryCollectionKind?)
    case itemDetail(
        contentId: String,
        tvSeed: TVItemDetailRouteSeed? = nil,
        libraryId: Int? = nil,
        seriesContext: SeriesDetailContext? = nil
    )
    case personDetail(personId: String)
    /// `prefersLastUsedVersion` is the Continue Watching resume intent: pick
    /// the server's last-used file before the profile-wide quality
    /// preference. Audio and subtitle memory ride on the server's
    /// `effective_*` fields and need no extra flag.
    case player(
        contentId: String,
        startFromBeginning: Bool,
        resumePosition: Double?,
        prefersLastUsedVersion: Bool = false,
        libraryId: Int? = nil
    )
    case playerWithFile(
        contentId: String,
        fileId: Int,
        audioTrackIndex: Int?,
        subtitleTrackIndex: Int?,
        startFromBeginning: Bool,
        resumePosition: Double?,
        libraryId: Int? = nil
    )
    case favorites
    case watchlist
    case history
    case collections
    case collectionDetail(collectionId: String)
    case settings
    case serverList

    /// The active party or the create/join hub.
    case watchParty

    /// Media-requests hub: discover carousels + search-to-request. Entry
    /// points (profile menu / tvOS profile dropdown) only render when
    /// `RequestsFeatureStore.shared.isEnabled`.
    case requestsHub

    /// TMDB title detail with the single server-state-computed request
    /// action. Titles already in the library route to `.itemDetail` instead.
    case requestDetail(mediaType: RequestMediaType, tmdbId: Int)

    /// The signed-in user's own request queue, bucketed by state.
    case myRequests

    /// Offline playback of a completed download. Distinct from `.player`
    /// so the player reads the local file + stored manifest instead of
    /// starting a server session.
    case offlinePlayer(downloadId: String, contentId: String, startFromBeginning: Bool, resumePosition: Double?)

    /// Offline series browse, reached from the Downloads tab: a season /
    /// episode list scoped to downloaded content, rendered entirely from
    /// stored records + manifests (no network).
    case offlineSeriesBrowse(seriesId: String)

    /// Offline leaf detail for one downloaded movie or episode.
    case offlineDownloadDetail(downloadId: String)
}

/// Card metadata that lets tvOS paint a branded detail frame before the
/// authoritative item response arrives. Series selection lives on the route.
/// Playback, personal state, selectors, and actions still wait for `ItemDetail`.
struct TVItemDetailRouteSeed: Hashable {
    let mediaType: String
    let title: String
    let year: Int?
    let overview: String?
    let runtime: Int?
    let contentRating: String?
    let genre: String?
    let logoUrl: String?
    let posterUrl: String?
    let posterThumbhash: String?
    let backdropUrl: String?
    let backdropThumbhash: String?

    init(_ item: SectionItem) {
        mediaType = item.type
        title = item.title
        year = item.year
        overview = item.overview
        runtime = item.runtime
        contentRating = item.contentRating
        genre = item.genres?.first
        logoUrl = item.logoUrl
        posterUrl = item.posterUrl
        posterThumbhash = item.posterThumbhash
        backdropUrl = item.backdropUrl
        backdropThumbhash = item.backdropThumbhash
    }

    init(_ item: BrowseItem) {
        mediaType = item.type
        title = item.title
        year = item.year
        overview = item.overview
        runtime = item.runtime
        contentRating = item.contentRating
        genre = item.genres?.first
        logoUrl = nil
        posterUrl = item.posterUrl
        posterThumbhash = item.posterThumbhash
        backdropUrl = item.backdropUrl
        backdropThumbhash = item.backdropThumbhash
    }

    /// Continue Watching episodes open their parent Series. Keep the immediate
    /// title/logo, but do not promote episode metadata into the Series frame.
    private init(parentSeriesFrom episode: SectionItem) {
        let seriesTitle = episode.seriesTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        mediaType = "series"
        title = seriesTitle.flatMap { $0.isEmpty ? nil : $0 } ?? episode.title
        year = nil
        overview = nil
        runtime = nil
        contentRating = nil
        genre = nil
        logoUrl = episode.logoUrl
        posterUrl = episode.posterUrl
        posterThumbhash = episode.posterThumbhash
        backdropUrl = nil
        backdropThumbhash = nil
    }

    static func destination(
        contentId: String,
        from item: SectionItem
    ) -> TVItemDetailRouteSeed {
        let seriesId = item.seriesId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isEpisode = item.type.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "episode" || item.episodeNumber != nil

        if isEpisode,
           seriesId?.isEmpty == false,
           seriesId == contentId,
           contentId != item.contentId {
            return TVItemDetailRouteSeed(parentSeriesFrom: item)
        }
        return TVItemDetailRouteSeed(item)
    }
}

extension Route {
    /// Section cards carry the same Series selection on every platform.
    /// tvOS additionally uses card artwork to paint its loading frame.
    static func itemDetail(
        destinationContentId: String,
        sectionItem: SectionItem,
        libraryId: Int? = nil
    ) -> Route {
        let context = SeriesDetailContext(item: sectionItem)
        let isSeriesLink = context?.seriesContentId == destinationContentId
        let isEpisodeLink = context != nil && destinationContentId == sectionItem.contentId
        let entryContext = isSeriesLink || isEpisodeLink ? context : nil
        let resolvedID = entryContext?.seriesContentId ?? destinationContentId
        #if os(tvOS)
        let seed: TVItemDetailRouteSeed? = .destination(contentId: resolvedID, from: sectionItem)
        #else
        let seed: TVItemDetailRouteSeed? = nil
        #endif
        return .itemDetail(
            contentId: resolvedID, tvSeed: seed, libraryId: libraryId,
            seriesContext: entryContext
        )
    }

    /// Builds the platform-appropriate route from a catalog card. The seed is
    /// display-only and is ignored entirely on iOS/macOS.
    static func itemDetail(browseItem: BrowseItem, libraryId: Int? = nil) -> Route {
        #if os(tvOS)
        return .itemDetail(
            contentId: browseItem.contentId,
            tvSeed: TVItemDetailRouteSeed(browseItem),
            libraryId: libraryId
        )
        #else
        return .itemDetail(contentId: browseItem.contentId, libraryId: libraryId)
        #endif
    }
}
