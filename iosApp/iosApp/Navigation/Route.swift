import Foundation

/// All navigable destinations in the Continuum app.
enum Route: Hashable {
    // Auth flow
    case serverSetup
    case login
    case serverNeedsSetup

    /// Server-driven first-run feature tour, shown after profile selection.
    case onboardingTour

    // Profile selection
    case profileSelection

    // Main tabs
    case home
    case search
    case browse(libraryId: Int?)
    case library(libraryId: Int, title: String?)
    case libraryCollection(libraryId: Int, collectionId: String, title: String?, kind: LibraryCollectionKind?)
    case itemDetail(
        contentId: String,
        tvSeed: TVItemDetailRouteSeed? = nil
    )
    case personDetail(personId: Int)
    case player(contentId: String, startFromBeginning: Bool, resumePosition: Double?)
    case playerWithFile(
        contentId: String,
        fileId: Int,
        audioTrackIndex: Int?,
        subtitleTrackIndex: Int?,
        startFromBeginning: Bool,
        resumePosition: Double?
    )
    case favorites
    case watchlist
    case history
    case collections
    case collectionDetail(collectionId: String)
    case settings
    case recommendations
    case serverList
    case downloads

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

    // tvOS-specific: deep-linked library grid with a pre-applied filter.
    // Pushed from `TVLibraryLandingView` when the user picks a genre,
    // decade, sort order, or "Browse All". Handled only by `TVMainTabView`;
    // iOS's `MainTabView` falls through to the unknown-route placeholder.
    case tvLibraryGrid(
        libraryId: Int,
        libraryName: String,
        libraryType: String,
        filter: TVLibraryFilterPayload,
        subtitle: String?
    )
}

/// Card metadata that lets tvOS paint a branded detail frame before the
/// authoritative item response arrives. The seed is deliberately display-only:
/// playback, personal state, selectors, and actions still wait for `ItemDetail`.
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
    /// Builds the platform-appropriate route from a section card. tvOS carries
    /// the card's presentation seed; iOS/macOS retain their existing ID-only
    /// route so poster zoom and detail behavior are unchanged.
    static func itemDetail(
        destinationContentId: String,
        sectionItem: SectionItem
    ) -> Route {
        #if os(tvOS)
        return .itemDetail(
            contentId: destinationContentId,
            tvSeed: TVItemDetailRouteSeed.destination(
                contentId: destinationContentId,
                from: sectionItem
            )
        )
        #else
        return .itemDetail(contentId: destinationContentId)
        #endif
    }

    /// Builds the platform-appropriate route from a catalog card. The seed is
    /// display-only and is ignored entirely on iOS/macOS.
    static func itemDetail(browseItem: BrowseItem) -> Route {
        #if os(tvOS)
        return .itemDetail(
            contentId: browseItem.contentId,
            tvSeed: TVItemDetailRouteSeed(browseItem)
        )
        #else
        return .itemDetail(contentId: browseItem.contentId)
        #endif
    }
}

/// Plain-data copy of `TVLibraryFilter` that can live in the shared `Route`
/// enum without dragging the tvOS-only view model into iOS compilation.
struct TVLibraryFilterPayload: Hashable {
    var namePrefix: String? = nil
    var genre: String? = nil
    var yearMin: Int? = nil
    var yearMax: Int? = nil
    var sort: String = "title"

    /// Lower the deep-link payload into the shared filter state used by the
    /// grid view model.
    func toFilterState() -> CatalogFilterState {
        var state = CatalogFilterState()
        state.namePrefix = namePrefix
        if let genre { state.genres = [genre] }
        if let yearMin, let yearMax {
            let lower = min(yearMin, yearMax)
            let upper = max(yearMin, yearMax)
            let start = (lower / 10) * 10
            let end = (upper / 10) * 10
            state.decades = Set(stride(from: start, through: end, by: 10))
        } else if let yearMin {
            state.decades = [(yearMin / 10) * 10]
        } else if let yearMax {
            state.decades = [(yearMax / 10) * 10]
        }
        state.sort = CatalogSortKey(rawValue: sort) ?? .title
        return state
    }
}
