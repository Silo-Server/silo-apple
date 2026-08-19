#if os(tvOS)
import Foundation
import Observation

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
    private var prefetchedPosterURLs: Set<URL> = []
    private var generation: Int = 0

    init(libraryId: Int, libraryType: String) {
        self.libraryId = libraryId
        self.mediaType = BrowseMediaType.from(libraryType: libraryType)
        self.sendsType = SiloMediaType.isSeries(libraryType) || SiloMediaType.isMovieLibrary(libraryType)
        // Restore the persisted per-library state, else start unfiltered.
        self.filter = BrowsePrefsStore.shared.savedState(libraryId: libraryId) ?? .none
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

    func prefetchPosters(in range: Range<Int>) {
        let urls = items[safe: range]
            .compactMap { $0.posterUrl }
            .compactMap { URL(string: $0) }
        let newURLs = urls.filter { prefetchedPosterURLs.insert($0).inserted }
        guard !newURLs.isEmpty else { return }
        PosterImageCache.prefetcher.startPrefetching(with: newURLs)
    }

    // MARK: - Fetch logic

    private func reload() async {
        if !prefetchedPosterURLs.isEmpty {
            PosterImageCache.prefetcher.stopPrefetching(with: Array(prefetchedPosterURLs))
            prefetchedPosterURLs.removeAll()
        }
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
        if !reset || items.isEmpty {
            isLoading = true
        }
        defer {
            isLoading = false
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
            let response: CatalogResponse = try await SiloAPI.shared.catalog(query: query)

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

extension Array {
    subscript(safe range: Range<Int>) -> ArraySlice<Element> {
        let lower = Swift.max(0, range.lowerBound)
        let upper = Swift.min(count, range.upperBound)
        guard lower < upper else { return [] }
        return self[lower..<upper]
    }
}
#endif
