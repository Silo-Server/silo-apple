import Foundation

/// All navigable destinations in the Continuum app.
enum Route: Hashable {
    // Auth flow
    case serverSetup
    case serverNeedsSetup

    // Main tabs
    case home
    case search
    case browse(libraryId: Int?)
    case library(libraryId: Int, title: String?)
    case libraryCollection(libraryId: Int, collectionId: String, title: String?, kind: LibraryCollectionKind?)
    case itemDetail(contentId: String)
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
}
