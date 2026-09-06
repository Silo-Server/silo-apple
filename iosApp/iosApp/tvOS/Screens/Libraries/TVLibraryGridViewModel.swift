import Foundation
import Observation
import Nuke

/// View model backing the tvOS library grid. Purpose-built for 100k-item
/// libraries; does not share state with the iOS `BrowseViewModel`, but both
/// now drive the shared `CatalogFilterState` + `CatalogQueryBuilder`.
///
/// Key differences from iOS:
///
/// - **Pagination** follows server-issued cursors pinned to the active viewer.
/// - **Page size** is 100 (the server's hard cap) instead of 60.
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
    private(set) var filter: CatalogFilterState
    /// Live facet vocabulary for the filter panel (loaded lazily).
    private(set) var facets: CatalogFacets?

    // MARK: - Private state

    struct DisplayedRead: Equatable {
        let libraryId: Int
        let filterKey: String
        let auth: CapturedOrdinaryRequestAuth
    }

    private struct CachedPage {
        let owner: DisplayedRead
        let response: CatalogResponse
    }

    private(set) var displayedRead: DisplayedRead?
    private let api: SiloAPI
    private let tokens: TokenStore
    private let authorityCheck: (CapturedOrdinaryRequestAuth) async -> Bool
    private let libraryId: Int
    /// Media family — picks the sort/facet vocabulary in the panels.
    let mediaType: BrowseMediaType
    /// Whether to send the `type` media-scope param (video libraries only;
    /// audiobook/music libraries are scoped by `library_id`).
    private let sendsType: Bool
    private let pageSize: Int = 100

    private var continuation: APIv2CatalogContinuation?
    @ObservationIgnored private var prefetchedPosterURLs: Set<URL> = []
    @ObservationIgnored private var visiblePosterRows: [Int: Range<Int>] = [:]
    /// Decoded into the memory cache so a cell scrolling into view paints the
    /// warmed image on its first frame via `CachedAsyncImage.prefetchedImage()`
    /// instead of paying the decode + resize on arrival. The window is small
    /// (two rows either side, 48 URLs) and low priority, so visible cells and
    /// their own requests still win the pipeline.
    private let posterPrefetcher = ImagePrefetcher(
        pipeline: ImagePipeline.shared,
        destination: .memoryCache,
        maxConcurrentRequestCount: 2
    )
    private var generation: Int = 0

    init(libraryId: Int, libraryType: String, initialFilter: CatalogFilterState = .none,
         api: SiloAPI = .shared, tokens: TokenStore = .shared,
         authorityCheck: ((CapturedOrdinaryRequestAuth) async -> Bool)? = nil) {
        self.api = api
        self.tokens = tokens
        self.authorityCheck = authorityCheck ?? { await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: $0) != nil }
        self.libraryId = libraryId
        self.mediaType = BrowseMediaType.from(libraryType: libraryType)
        self.sendsType = SiloMediaType.isSeries(libraryType) || SiloMediaType.isMovieLibrary(libraryType)
        // A non-default initial filter (a deep-linked landing tap) wins;
        // otherwise restore the persisted per-library state.
        if !initialFilter.isDefault {
            self.filter = initialFilter
        } else if let saved = BrowsePrefsStore.shared.savedState(libraryId: libraryId) {
            self.filter = saved
        } else {
            self.filter = initialFilter
        }
        facets = FacetLoader.shared.cachedFacets(libraryId: libraryId)
    }

    private var currentCacheKey: String {
        CacheKey.tvLibrary(libraryId: libraryId, filterKey: filter.cacheKeyFragment)
    }

    private func hydratePage1FromCache(owner: DisplayedRead) {
        guard items.isEmpty,
              let cached: CachedPage = ResponseCache.shared.get(currentCacheKey),
              cached.owner == owner else { return }
        items = cached.response.items
        displayedRead = owner
        hasMore = false
    }

    private func clearDisplayedRows() {
        items = []
        displayedRead = nil
        continuation = nil
        hasMore = false
        cancelPosterPrefetch()
    }

    func cancel() {
        generation += 1
        clearDisplayedRows()
        isLoading = false
        isRefreshing = false
    }

    // MARK: - Public API

    func loadInitial() async {
        await reload()
    }

    func loadMoreIfNeeded() async {
        guard hasMore, !isLoading else { return }
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
        BrowsePrefsStore.shared.saveState(newFilter, libraryId: libraryId)
        await reload()
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

    var preserveEnabled: Bool { BrowsePrefsStore.shared.preserveEnabled(libraryId: libraryId) }

    func setPreserveEnabled(_ enabled: Bool) {
        BrowsePrefsStore.shared.setPreserveEnabled(enabled, libraryId: libraryId)
        if enabled {
            BrowsePrefsStore.shared.saveState(filter, libraryId: libraryId)
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
        let urls = items[safe: range].prefix(48)
            .compactMap { $0.posterUrl }
            .compactMap { URL(string: $0) }
        let desiredURLs = Set(urls)
        let staleURLs = prefetchedPosterURLs.subtracting(desiredURLs)
        let newURLs = urls.filter { !prefetchedPosterURLs.contains($0) }
        prefetchedPosterURLs = desiredURLs
        posterPrefetcher.stopPrefetching(with: staleURLs.map(PosterImageCache.cardWarmRequest(for:)))
        posterPrefetcher.startPrefetching(with: newURLs.map(PosterImageCache.cardWarmRequest(for:)))
    }

    func cancelPosterPrefetch() {
        stopPosterPrefetchRequests()
        visiblePosterRows.removeAll()
    }

    private func stopPosterPrefetchRequests() {
        posterPrefetcher.stopPrefetching()
        prefetchedPosterURLs.removeAll()
    }

    // MARK: - Fetch logic

    private func reload() async {
        stopPosterPrefetchRequests()
        generation += 1
        continuation = nil
        hasMore = false
        error = nil
        await fetchPage(reset: true)
    }

    private func fetchPage(reset: Bool) async {
        let myGeneration = generation
        let requestedFilter = filter
        let filterKey = requestedFilter.cacheKeyFragment
        let cacheKey = currentCacheKey
        // Reserve paging before the first await; a second Load More cannot
        // issue this continuation concurrently.
        isLoading = true
        isRefreshing = reset && !items.isEmpty
        defer {
            if myGeneration == generation {
                isLoading = false
                isRefreshing = false
            }
        }
        let captured = await tokens.captureOrdinaryRequestAuth()
        guard myGeneration == generation, !Task.isCancelled else { return }
        guard let auth = captured, let profile = auth.profileId, !profile.isEmpty else {
            clearDisplayedRows()
            error = ErrorState(HTTPError.requestIdentityChanged)
            return
        }
        let owner = DisplayedRead(libraryId: libraryId, filterKey: filterKey, auth: auth)
        if displayedRead != owner {
            clearDisplayedRows()
            if !reset {
                error = ErrorState(HTTPError.requestIdentityChanged)
                return
            }
        }
        if reset {
            let current = await authorityCheck(auth)
            guard myGeneration == generation, !Task.isCancelled else { return }
            guard current else {
                clearDisplayedRows()
                error = ErrorState(HTTPError.requestIdentityChanged)
                return
            }
            hydratePage1FromCache(owner: owner)
            refreshPosterPrefetch()
        }
        let cursor = continuation
        do {
            let result: APIv2CatalogResult
            if !reset {
                guard let cursor, cursor.auth == auth else { throw HTTPError.requestIdentityChanged }
                result = try await api.v2.nextCatalogPage(cursor)
            } else {
                let query = CatalogQueryBuilder.build(requestedFilter, libraryId: libraryId, mediaType: mediaType, limit: pageSize, includeType: sendsType)
                result = try await api.catalogPage(query: query, auth: auth)
            }
            let current = await authorityCheck(auth)
            guard myGeneration == generation, !Task.isCancelled else { return }
            guard current, result.auth == auth else { throw HTTPError.requestIdentityChanged }
            let response = CatalogResponse(catalogPage: result.value)
            if reset {
                items = response.items
                ResponseCache.shared.set(CachedPage(owner: owner, response: response), for: cacheKey)
            } else {
                items.append(contentsOf: response.items)
            }
            displayedRead = owner
            continuation = result.continuation
            hasMore = result.continuation != nil
            error = nil
            refreshPosterPrefetch()
        } catch {
            guard myGeneration == generation, !Task.isCancelled else { return }
            let current = await authorityCheck(auth)
            guard myGeneration == generation, !Task.isCancelled else { return }
            if !current { clearDisplayedRows() }
            self.error = ErrorState(current ? error : HTTPError.requestIdentityChanged)
            continuation = nil
            hasMore = false
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
