import Foundation

/// All navigable destinations in the Continuum app.
enum Route: Hashable {
    // Auth flow
    case serverSetup
    case login
    case serverNeedsSetup
    case signup

    // Profile selection
    case profileSelection

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
    case collections
    case collectionDetail(collectionId: String)
    case settings
    case recommendations
    case admin
    case serverList

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
