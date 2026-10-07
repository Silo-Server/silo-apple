#if os(tvOS)
import Foundation
import Observation

/// View model backing the tvOS library grid. Purpose-built for 100k-item
/// libraries; does not share state with the iOS `BrowseViewModel`, but both
/// now drive the shared `CatalogFilterState` + `CatalogQueryBuilder`.
///
/// Key differences from iOS:
///
/// - **Pagination** follows the v2 catalog cursor. The server fences the
///   cursor at the first page, so pages stay coherent even if items are being
///   ingested mid-scroll.
/// - **Page size** is 100 (the v2 query cap) instead of 60.
/// - **Prefetch trigger** fires earlier (more lead rows) and warms posters via
///   Nuke.
/// - **Filter state** resets pagination when changed; any in-flight fetch is
///   superseded by a generation counter.
@Observable
@MainActor
final class TVLibraryGridViewModel {
    // MARK: - Observable state

    var items: [BrowseItem] = []
    var isLoading: Bool = false
    var isRefreshing: Bool = false
    var error: ErrorState? = nil
    var hasMore: Bool = true
    /// Why the grid is empty. Read only when a finished load left `items`
    /// empty; set before that load finishes so the wrong message never shows.
    private(set) var emptyReason: BrowseEmptyReason = .libraryEmpty
    private(set) var filter: CatalogFilterState
    /// Live facet vocabulary for the filter panel (loaded lazily).
    private(set) var facets: CatalogFacets?

    // MARK: - Private state

    private let libraryId: Int
    private let mediaScope: LibraryVideoScope?
    /// Media family — picks the sort/facet vocabulary in the panels.
    let mediaType: BrowseMediaType
    /// Whether to send the `type` media-scope param (video libraries only;
    /// audiobook/music libraries are scoped by `library_id`).
    private let sendsType: Bool
    private static let pageSize = 100

    /// Where the next page starts; `nil` before the live page 1 arrives and
    /// after the last page. A cached page 1 has no continuation.
    private var continuation: APIv2CatalogContinuation?
    /// Warm-ups in flight by poster URL, kept with the size they were
    /// started at so stopping one targets the same request.
    @ObservationIgnored private var prefetchedPosters: [String: CardArtwork] = [:]
    @ObservationIgnored private var visiblePosterRows: [Int: Range<Int>] = [:]
    private var generation: Int = 0

    init(libraryId: Int, libraryType: String, mediaScope: LibraryVideoScope? = nil, initialFilter: CatalogFilterState = .none) {
        self.libraryId = libraryId
        self.mediaScope = mediaScope
        self.mediaType = BrowseMediaType.from(libraryType: mediaScope?.rawValue ?? libraryType)
        self.sendsType = Self.sendsType(libraryType: libraryType)
        // A non-default initial filter (a deep-linked landing tap) wins;
        // otherwise restore the persisted per-library state.
        if !initialFilter.isDefault {
            self.filter = initialFilter
        } else {
            self.filter = Self.savedFilter(libraryId: libraryId, mediaScope: mediaScope)
        }
        facets = FacetLoader.shared.cachedFacets(libraryId: libraryId)
        hydratePage1FromCache()
    }

    private var currentCacheKey: String {
        CacheKey.tvLibrary(libraryId: libraryId, filterKey: (mediaScope.map { "type=\($0.rawValue)|" } ?? "") + filter.cacheKeyFragment)
    }

    // MARK: - First page

    /// The filter a grid opened without a deep-linked filter starts with.
    /// A mixed library's Movies/Series tab keeps its own saved state.
    static func savedFilter(libraryId: Int, mediaScope: LibraryVideoScope? = nil) -> CatalogFilterState {
        BrowsePrefsStore.shared.savedState(libraryId: libraryId, mediaScope: mediaScope?.rawValue) ?? .none
    }

    /// Page 1 for `filter`. The startup prefetch sends this same query and
    /// caches the result under the key the grid hydrates from.
    static func firstPageQuery(libraryId: Int, libraryType: String, filter: CatalogFilterState) -> APIv2CatalogQuery {
        CatalogQueryBuilder.build(
            filter,
            libraryId: libraryId,
            mediaType: BrowseMediaType.from(libraryType: libraryType),
            limit: pageSize,
            includeType: sendsType(libraryType: libraryType)
        )
    }

    private static func sendsType(libraryType: String) -> Bool {
        SiloMediaType.isSeries(libraryType) || SiloMediaType.isMovieLibrary(libraryType)
    }

    private func hydratePage1FromCache() {
        guard items.isEmpty,
              let cached: CatalogResponse = ResponseCache.shared.get(currentCacheKey) else {
            return
        }
        items = cached.items
        hasMore = cached.hasMore ?? false
    }

    // MARK: - Public API

    func loadInitial() async {
        await reload()
    }

    func loadMoreIfNeeded() async {
        guard hasMore, !isLoading, !isRefreshing else { return }
        // Without a continuation the grid shows a cached page 1 whose refresh
        // failed; `fetchPage` starts over from page 1 instead of guessing a cursor.
        await fetchPage(reset: false)
    }

    /// Jump to a name prefix (A–Z + "#"). Resets pagination.
    func jumpToPrefix(_ letter: String?) async {
        filter.namePrefix = letter
        await reload()
    }

    /// Replace the full filter/sort set. Persists it and resets pagination.
    func applyFilter(_ newFilter: CatalogFilterState) async {
        guard newFilter != filter else { return }
        filter = newFilter
        BrowsePrefsStore.shared.saveState(newFilter, libraryId: libraryId, mediaScope: mediaScope?.rawValue)
        await reload()
    }

    /// Clears every filter facet and the letter-rail prefix, keeping the sort.
    func clearFilters() async {
        var next = filter
        next.resetFilters()
        next.namePrefix = nil
        await applyFilter(next)
    }

    /// Sort menu behavior: tapping the active key flips direction; tapping a
    /// different key selects it at its default order.
    func setSort(_ key: CatalogSortKey) async {
        var next = filter
        if next.sort == key {
            next.order = next.effectiveOrder.flipped
        } else {
            next.sort = key
            next.order = nil
        }
        await applyFilter(next)
    }

    func loadFacetsIfNeeded() async {
        if facets != nil { return }
        facets = try? await FacetLoader.shared.facets(libraryId: libraryId)
    }

    var preserveEnabled: Bool { BrowsePrefsStore.shared.preserveEnabled(libraryId: libraryId, mediaScope: mediaScope?.rawValue) }

    func setPreserveEnabled(_ enabled: Bool) {
        BrowsePrefsStore.shared.setPreserveEnabled(enabled, libraryId: libraryId, mediaScope: mediaScope?.rawValue)
        if enabled {
            BrowsePrefsStore.shared.saveState(filter, libraryId: libraryId, mediaScope: mediaScope?.rawValue)
        }
    }

    func setPosterRowVisibility(_ range: Range<Int>, isVisible: Bool) {
        guard !range.isEmpty else { return }
        if isVisible {
            visiblePosterRows[range.lowerBound] = range
        } else {
            visiblePosterRows.removeValue(forKey: range.lowerBound)
        }
        refreshPosterPrefetch()
    }

    /// Data can change while the same row positions remain visible.
    private func refreshPosterPrefetch() {
        let rows = visiblePosterRows.values
        guard let first = rows.map(\.lowerBound).min(),
              let last = rows.map(\.upperBound).max(),
              let widestRow = rows.map(\.count).max() else {
            cancelPosterPrefetch()
            return
        }
        // Two rows either side of the visible band.
        let nearbyCount = widestRow * 2
        prefetchPosters(in: (first - nearbyCount)..<(last + nearbyCount))
    }

    /// `range` may overrun `items`; the safe subscript clamps it.
    private func prefetchPosters(in range: Range<Int>) {
        // Keep one bounded window around the visible rows. Visible cells still
        // request their own resized image through the same coalescing
        // pipeline; the warmed decode only lets that first frame paint.
        let desired = items[safe: range].prefix(48).compactMap { item -> CardArtwork? in
            guard let url = item.posterUrl, !url.isEmpty else { return nil }
            // `TVCatalogGrid` draws audiobook covers square.
            let aspect: MediaCardAspect = item.isAudiobook ? .square : .poster
            return CardArtwork(url: url, pointSize: TVMediaCard.artworkSize(cardWidth: SiloTheme.posterCardWidth, aspect: aspect))
        }
        let desiredByURL = Dictionary(desired.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let stale = prefetchedPosters.values.filter { desiredByURL[$0.url]?.pointSize != $0.pointSize }
        let fresh = desired.filter { prefetchedPosters[$0.url]?.pointSize != $0.pointSize }
        prefetchedPosters = desiredByURL
        PosterImageCache.stopPrefetchingArtwork(Array(stale))
        PosterImageCache.prefetchArtwork(fresh)
    }

    func cancelPosterPrefetch() {
        stopPosterPrefetchRequests()
        visiblePosterRows.removeAll()
    }

    private func stopPosterPrefetchRequests() {
        PosterImageCache.stopPrefetchingArtwork(Array(prefetchedPosters.values))
        prefetchedPosters.removeAll()
    }

    // MARK: - Fetch logic

    private func reload() async {
        // A cache-backed reload can preserve the grid's row identities and
        // visibility. Cancel old URLs without discarding that geometry.
        stopPosterPrefetchRequests()
        generation += 1
        items = []
        continuation = nil
        hasMore = true
        error = nil
        hydratePage1FromCache()
        refreshPosterPrefetch()
        await fetchPage(reset: true)
    }

    private func fetchPage(reset: Bool) async {
        let myGeneration = generation
        let writeToken = ResponseCache.shared.writeToken
        let nextPage = reset ? nil : continuation
        let startsOver = nextPage == nil
        if startsOver, !items.isEmpty {
            isRefreshing = true
        } else {
            isLoading = true
        }
        defer {
            // A superseded fetch leaves the flags to the one that replaced
            // it; clearing them would show "No titles match" mid-load.
            if myGeneration == generation {
                isLoading = false
                isRefreshing = false
            }
        }

        do {
            let page: CatalogListPage
            if let nextPage {
                page = try await SiloAPI.shared.nextCatalogPage(nextPage)
            } else {
                page = try await SiloAPI.shared.catalogPage(CatalogQueryBuilder.build(
                    filter,
                    libraryId: libraryId,
                    mediaType: mediaType,
                    limit: Self.pageSize,
                    includeType: sendsType,
                    enforcedScope: mediaScope
                ))
            }

            // Discard if another reload superseded us while we awaited.
            guard myGeneration == generation else { return }

            if startsOver || page.startsOver {
                items = page.response.items
                ResponseCache.shared.set(page.response, for: currentCacheKey, fetchedAt: writeToken)
                if items.isEmpty {
                    let probe = CatalogQueryBuilder.libraryProbe(libraryId: libraryId)
                    let reason = await BrowseEmptyReason.classify(filter: filter) {
                        try await !SiloAPI.shared.catalogPage(probe).response.items.isEmpty
                    }
                    guard myGeneration == generation else { return }
                    emptyReason = reason
                }
            } else {
                items.append(contentsOf: page.response.items)
            }
            continuation = page.continuation
            hasMore = page.continuation != nil
            refreshPosterPrefetch()
        } catch {
            guard myGeneration == generation else { return }
            if items.isEmpty {
                self.error = ErrorState(error)
            }
        }
    }
}

// MARK: - Safe subscript

private extension Array {
    subscript(safe range: Range<Int>) -> ArraySlice<Element> {
        let lower = Swift.max(0, range.lowerBound)
        let upper = Swift.min(count, range.upperBound)
        guard lower < upper else { return [] }
        return self[lower..<upper]
    }
}
#endif
