#if os(tvOS)
import Foundation
import Observation
import Nuke

/// View model backing the tvOS library grid. Purpose-built for 100k-item
/// libraries; does not share state with the iOS `BrowseViewModel`, but both
/// now drive the shared `CatalogFilterState` + `CatalogQueryBuilder`.
///
/// Key differences from iOS:
///
/// - **Pagination** uses the server's snapshot timestamp (`snapshot_at`) as a
///   fence so pages stay coherent even if items are being ingested mid-scroll.
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

    private let libraryId: Int
    /// Media family — picks the sort/facet vocabulary in the panels.
    let mediaType: BrowseMediaType
    /// Whether to send the `type` media-scope param (video libraries only;
    /// audiobook/music libraries are scoped by `library_id`).
    private let sendsType: Bool
    private let pageSize: Int = 100

    private var snapshot: String? = nil
    private var nextOffset: Int = 0
    @ObservationIgnored private var prefetchedPosterURLs: Set<URL> = []
    @ObservationIgnored private var visiblePosterRows: [Int: Range<Int>] = [:]
    private let posterPrefetcher = ImagePrefetcher(
        pipeline: ImagePipeline.shared,
        destination: .diskCache,
        maxConcurrentRequestCount: 2
    )
    private var generation: Int = 0

    init(libraryId: Int, libraryType: String, initialFilter: CatalogFilterState = .none) {
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
        hydratePage1FromCache()
    }

    private var currentCacheKey: String {
        CacheKey.tvLibrary(libraryId: libraryId, filterKey: filter.cacheKeyFragment)
    }

    private func hydratePage1FromCache() {
        guard items.isEmpty,
              let cached: CatalogResponse = ResponseCache.shared.get(currentCacheKey) else {
            return
        }
        items = cached.items
        hasMore = cached.hasMore ?? false
        nextOffset = cached.items.count
        snapshot = cached.snapshot
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
        guard let first = visiblePosterRows.values.map(\.lowerBound).min(),
              let last = visiblePosterRows.values.map(\.upperBound).max() else {
            cancelPosterPrefetch()
            return
        }
        let nearbyCount = (visiblePosterRows.values.map(\.count).max() ?? 6) * 2
        let lowerBound = min(items.count, max(0, first - nearbyCount))
        let upperBound = max(lowerBound, min(items.count, last + nearbyCount))
        prefetchPosters(in: lowerBound..<upperBound)
    }

    private func prefetchPosters(in range: Range<Int>) {
        // Keep one bounded window. Data-only prefetch avoids full-resolution
        // decodes for posters the user may never reach; visible cells request
        // their own resized image through the same coalescing pipeline.
        let urls = items[safe: range].prefix(48)
            .compactMap { $0.posterUrl }
            .compactMap { URL(string: $0) }
        let desiredURLs = Set(urls)
        let staleURLs = prefetchedPosterURLs.subtracting(desiredURLs)
        let newURLs = urls.filter { !prefetchedPosterURLs.contains($0) }
        prefetchedPosterURLs = desiredURLs
        posterPrefetcher.stopPrefetching(with: Array(staleURLs))
        posterPrefetcher.startPrefetching(with: newURLs)
    }

    func cancelPosterPrefetch() {
        posterPrefetcher.stopPrefetching()
        prefetchedPosterURLs.removeAll()
        visiblePosterRows.removeAll()
    }

    // MARK: - Fetch logic

    private func reload() async {
        cancelPosterPrefetch()
        generation += 1
        items = []
        nextOffset = 0
        hasMore = true
        snapshot = nil
        error = nil
        hydratePage1FromCache()
        await fetchPage(reset: true)
    }

    private func fetchPage(reset: Bool) async {
        let myGeneration = generation
        if reset, !items.isEmpty {
            isRefreshing = true
        } else {
            isLoading = true
        }
        defer {
            isLoading = false
            isRefreshing = false
        }

        let requestOffset = reset ? 0 : nextOffset
        let requestSnapshot = reset ? nil : snapshot
        let query = CatalogQueryBuilder.build(
            filter,
            libraryId: libraryId,
            mediaType: mediaType,
            offset: requestOffset,
            limit: pageSize,
            snapshot: requestSnapshot,
            includeType: sendsType
        )

        do {
            let response: CatalogResponse = try await ContinuumAPI.shared.get(
                "/api/v1/catalog", query: query
            )

            // Discard if another reload superseded us while we awaited.
            guard myGeneration == generation else { return }

            if reset {
                items = response.items
                ResponseCache.shared.set(response, for: currentCacheKey)
                nextOffset = response.items.count
                snapshot = response.snapshot
            } else {
                items.append(contentsOf: response.items)
                nextOffset += response.items.count
                if snapshot == nil { snapshot = response.snapshot }
            }
            hasMore = response.hasMore ?? false
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
