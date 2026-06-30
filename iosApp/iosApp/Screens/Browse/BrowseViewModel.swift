import Foundation

@Observable
@MainActor
class BrowseViewModel {
    var items: [BrowseItem] = []
    var isLoading = false
    var isRefreshing = false
    var error: ErrorState?
    var hasMore = true

    /// The committed filter + sort state. The filter sheet edits a draft and
    /// commits it via `apply`.
    private(set) var filterState = CatalogFilterState()
    /// Media family of this library — picks the sort/facet vocabulary. Best
    /// effort until the first page lands, then refined from the items.
    private(set) var mediaType: BrowseMediaType = .movie
    /// Live facet vocabulary for the filter sheet, loaded lazily.
    private(set) var facets: CatalogFacets?

    private var currentPage = 0
    private let pageSize = 60
    private var libraryId: Int?
    /// Bumped on every reset; a returning fetch from an older generation
    /// discards its results instead of appending stale data.
    private var generation = 0

    func configure(libraryId: Int?) {
        self.libraryId = libraryId
        // Restore persisted sort/filters for this library + profile (no-op
        // when the user turned "Preserve" off).
        if let saved = BrowsePrefsStore.shared.savedState(libraryId: libraryId) {
            filterState = saved
        }
        facets = FacetLoader.shared.cachedFacets(libraryId: libraryId)
        // Hydrate the page-1 snapshot the next reset will write back into.
        hydratePage1FromCache()
    }

    // MARK: - Load Items

    func loadItems(reset: Bool = false) async {
        guard !isLoading else { return }
        if reset {
            generation += 1
            // Surface the cached page-1 snapshot instantly so the grid
            // doesn't blank out while the network call runs.
            if !items.isEmpty {
                isRefreshing = true
            } else if let cached: CatalogResponse = ResponseCache.shared.get(currentCacheKey) {
                items = cached.items
                hasMore = cached.hasMore ?? false
                isRefreshing = true
            }
            currentPage = 0
            if items.isEmpty {
                hasMore = true
            }
        }
        guard hasMore else {
            isRefreshing = false
            return
        }

        let myGeneration = generation
        if items.isEmpty {
            isLoading = true
        }
        error = nil

        do {
            let response: CatalogResponse
            if reset && currentPage == 0 {
                response = try await StartupContentPrefetcher.fetchBrowseFirstPage(
                    libraryId: libraryId,
                    state: filterState
                )
            } else {
                let query = CatalogQueryBuilder.build(
                    filterState,
                    libraryId: libraryId,
                    mediaType: mediaType,
                    offset: currentPage * pageSize,
                    limit: pageSize,
                    includeType: false
                )
                response = try await ContinuumAPI.shared.catalog(query: query)
            }
            // Discard if another reset superseded us while we awaited.
            guard myGeneration == generation else { return }

            if reset {
                items = response.items
                ResponseCache.shared.set(response, for: currentCacheKey)
                refineMediaType(from: response)
            } else {
                items.append(contentsOf: response.items)
            }
            hasMore = response.hasMore ?? false
            currentPage += 1
        } catch let err {
            guard myGeneration == generation else { return }
            if items.isEmpty {
                self.error = ErrorState(err)
            }
        }
        isLoading = false
        isRefreshing = false
    }

    // MARK: - Filters / Sort

    /// Commit a new filter/sort state: persist it, reset pagination, refetch.
    func apply(_ newState: CatalogFilterState) async {
        guard newState != filterState else { return }
        filterState = newState
        BrowsePrefsStore.shared.saveState(newState, libraryId: libraryId)
        items = []
        hydratePage1FromCache()
        await loadItems(reset: true)
    }

    /// Sort menu behavior: tapping the active key flips direction; tapping a
    /// different key selects it at its default order.
    func setSort(_ key: CatalogSortKey) async {
        var next = filterState
        if next.sort == key {
            next.order = next.effectiveOrder.flipped
        } else {
            next.sort = key
            next.order = nil
        }
        await apply(next)
    }

    func removeChip(_ chip: CatalogFilterChip) async {
        var next = filterState
        next.toggle(chip.facet, value: chip.value)
        await apply(next)
    }

    func resetFilters() async {
        var next = filterState
        next.resetFilters()
        await apply(next)
    }

    /// Load the live facet vocabulary for the filter sheet.
    func loadFacetsIfNeeded() async {
        if facets != nil { return }
        facets = try? await FacetLoader.shared.facets(libraryId: libraryId)
    }

    /// Probe the result count for a candidate state — drives the live count on
    /// the sheet's apply button. A tiny page with `include_total`.
    func resultCount(for candidate: CatalogFilterState) async -> Int? {
        let query = CatalogQueryBuilder.build(
            candidate,
            libraryId: libraryId,
            mediaType: mediaType,
            offset: 0,
            limit: 1,
            includeTotal: true,
            includeType: false
        )
        let response: CatalogResponse? = try? await ContinuumAPI.shared.catalog(query: query)
        return response?.total
    }

    var hasActiveFilters: Bool { !filterState.isDefault }

    // MARK: - Preserve toggle

    var preserveEnabled: Bool { BrowsePrefsStore.shared.preserveEnabled(libraryId: libraryId) }

    func setPreserveEnabled(_ enabled: Bool) {
        BrowsePrefsStore.shared.setPreserveEnabled(enabled, libraryId: libraryId)
        if enabled {
            BrowsePrefsStore.shared.saveState(filterState, libraryId: libraryId)
        }
    }

    // MARK: - Cache

    private var currentCacheKey: String {
        CacheKey.browse(libraryId: libraryId, filterKey: filterState.cacheKeyFragment)
    }

    private func hydratePage1FromCache() {
        guard items.isEmpty,
              let cached: CatalogResponse = ResponseCache.shared.get(currentCacheKey) else {
            return
        }
        items = cached.items
        hasMore = cached.hasMore ?? false
    }

    /// Refine the media family from the first loaded item so the sort/facet
    /// vocabulary matches the library (audiobook vs video) without ever
    /// sending a `type` scope that could filter the page empty.
    private func refineMediaType(from response: CatalogResponse) {
        guard let first = response.items.first else { return }
        mediaType = BrowseMediaType.from(libraryType: first.type)
    }
}
