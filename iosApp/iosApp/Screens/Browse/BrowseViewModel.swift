import Foundation

@Observable
@MainActor
class BrowseViewModel {
    var items: [BrowseItem] = []
    var isLoading = false
    var error: ErrorState?
    var hasMore = true

    /// The committed filter + sort state. The filter sheet edits a draft and
    /// commits it via `apply`.
    private(set) var filterState = CatalogFilterState()
    /// Media family of this library — picks the sort/facet vocabulary.
    private(set) var mediaType: BrowseMediaType = .movie
    /// Live facet vocabulary for the filter sheet, loaded lazily.
    private(set) var facets: CatalogFacets?

    private var currentPage = 0
    private let pageSize = 60
    private var libraryId: Int?
    private var hasConfigured = false
    private var configurationGeneration = 0
    /// Bumped on every reset; a returning fetch from an older generation
    /// discards its results instead of appending stale data.
    private var generation = 0

    @discardableResult
    func configure(libraryId: Int?, libraryType: String? = nil) async -> Bool {
        configurationGeneration += 1
        let myConfiguration = configurationGeneration
        let libraryChanged = !hasConfigured || self.libraryId != libraryId
        let resolvedMediaType = await resolveMediaType(libraryId: libraryId, libraryType: libraryType)
        guard myConfiguration == configurationGeneration, !Task.isCancelled else { return false }

        self.libraryId = libraryId
        hasConfigured = true
        mediaType = resolvedMediaType

        if libraryChanged {
            generation += 1
            currentPage = 0
            hasMore = true
            items = []
            filterState = BrowsePrefsStore.shared.savedState(libraryId: libraryId) ?? .none
        }

        facets = FacetLoader.shared.cachedFacets(libraryId: libraryId)
        // Hydrate the page-1 snapshot the next reset will write back into.
        hydratePage1FromCache()
        return true
    }

    // MARK: - Load Items

    func loadItems(reset: Bool = false) async {
        if reset {
            generation += 1
            if items.isEmpty {
                // Surface the cached page-1 snapshot instantly so the grid
                // doesn't blank out while the network call runs.
                hydratePage1FromCache()
            }
            currentPage = 0
            hasMore = true
        } else if isLoading {
            return
        }

        let myGeneration = generation
        guard hasMore else {
            finishLoading(for: myGeneration)
            return
        }

        isLoading = true
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
                response = try await SiloAPI.shared.catalog(query: query)
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
        finishLoading(for: myGeneration)
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

    var hasActiveFilters: Bool { filterState.hasActiveFilters }

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
        refineMediaType(from: cached)
    }

    private func finishLoading(for completedGeneration: Int) {
        guard completedGeneration == generation else { return }
        isLoading = false
    }

    private func resolveMediaType(libraryId: Int?, libraryType: String?) async -> BrowseMediaType {
        if let libraryType {
            return BrowseMediaType.from(libraryType: libraryType)
        }

        guard let libraryId else { return .movie }

        if let cached: LibrariesResponse = ResponseCache.shared.get(CacheKey.userLibraries),
           let library = cached.libraries.first(where: { $0.id == libraryId }) {
            return BrowseMediaType.from(libraryType: library.type)
        }

        if let response = try? await StartupContentPrefetcher.fetchUserLibraries(),
           let library = response.libraries.first(where: { $0.id == libraryId }) {
            return BrowseMediaType.from(libraryType: library.type)
        }

        return .movie
    }

    /// Refine the media family from the first loaded item so the sort/facet
    /// vocabulary matches the library (audiobook vs video) without ever
    /// sending a `type` scope that could filter the page empty.
    private func refineMediaType(from response: CatalogResponse) {
        // A mixed library was resolved from the library list in `configure`;
        // refining from a (movie or series) item would hide the Type facet.
        guard mediaType != .mixed, let first = response.items.first else { return }
        mediaType = BrowseMediaType.from(libraryType: first.type)
    }
}
