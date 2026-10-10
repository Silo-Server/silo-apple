import Foundation

@Observable
@MainActor
class BrowseViewModel {
    var items: [BrowseItem] = []
    var isLoading = false
    /// False until this library's first load finishes, so the grid shows its
    /// placeholder rather than "No items found" before anything was fetched.
    private(set) var hasLoaded = false
    var error: ErrorState?
    var hasMore = true
    /// Why the grid is empty. Read only when a finished load left `items`
    /// empty; set before that load finishes so the wrong message never shows.
    private(set) var emptyReason: BrowseEmptyReason = .libraryEmpty

    /// The committed filter + sort state. The filter sheet edits a draft and
    /// commits it via `apply`.
    private(set) var filterState = CatalogFilterState()
    /// Media family of this library — picks the sort/facet vocabulary.
    private(set) var mediaType: BrowseMediaType = .movie
    /// Live facet vocabulary for the filter sheet, loaded lazily.
    private(set) var facets: CatalogFacets?

    /// Where the next page starts; `nil` before page 1 arrives and after the
    /// last page. Only the live page-1 fetch sets it: a cached page 1 has
    /// no continuation, so a load-more over it restarts from page 1.
    private var continuation: APIv2CatalogContinuation?
    private var libraryId: Int?
    private var mediaScope: LibraryVideoScope?
    private var hasConfigured = false
    private var configurationGeneration = 0
    /// Bumped on every reset; a returning fetch from an older generation
    /// discards its results instead of appending stale data.
    private var generation = 0

    @discardableResult
    func configure(libraryId: Int?, libraryType: String? = nil, mediaScope: LibraryVideoScope? = nil) async -> Bool {
        configurationGeneration += 1
        let myConfiguration = configurationGeneration
        let libraryChanged = !hasConfigured || self.libraryId != libraryId || self.mediaScope != mediaScope
        if libraryChanged {
            // Invalidate before metadata I/O so an old page cannot publish while
            // the next library or type is being configured.
            invalidatePages()
        }
        let resolvedMediaType = await resolveMediaType(libraryId: libraryId, libraryType: libraryType)
        guard myConfiguration == configurationGeneration, !Task.isCancelled else { return false }

        self.libraryId = libraryId
        self.mediaScope = mediaScope
        hasConfigured = true
        mediaType = mediaScope.map { $0 == .movie ? .movie : .series } ?? resolvedMediaType

        if libraryChanged {
            // A load-more during the metadata await read the old library or
            // type under the new generation; drop it before the new scope loads.
            invalidatePages()
            filterState = BrowsePrefsStore.shared.savedState(libraryId: libraryId, mediaScope: mediaScope?.rawValue) ?? .none
            if mediaScope != nil { filterState.mediaScope = nil }
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
            // Surface the cached page-1 snapshot instantly so the grid
            // doesn't blank out while the network call runs.
            hydratePage1FromCache()
            continuation = nil
            hasMore = true
        } else if isLoading {
            return
        }

        let myGeneration = generation
        let writeToken = ResponseCache.shared.writeToken
        guard hasMore else {
            finishLoading(for: myGeneration)
            return
        }

        isLoading = true
        error = nil

        do {
            let page: CatalogListPage
            var startsOver = continuation == nil
            if let continuation {
                page = try await SiloAPI.shared.nextCatalogPage(continuation)
            } else {
                page = try await StartupContentPrefetcher.fetchBrowseFirstPage(
                    libraryId: libraryId,
                    state: filterState,
                    mediaScope: mediaScope
                )
            }
            // Discard if another reset superseded us while we awaited.
            guard myGeneration == generation else { return }
            guard !Task.isCancelled else { return cancelLoading(for: myGeneration) }

            startsOver = startsOver || page.startsOver
            if startsOver {
                items = page.response.items
                ResponseCache.shared.set(page.response, for: currentCacheKey, fetchedAt: writeToken)
                refineMediaType(from: page.response)
                if items.isEmpty {
                    var probe = CatalogQueryBuilder.libraryProbe(libraryId: libraryId)
                    // A Movies/Series view of a mixed library is empty when that
                    // type is, even if the other type has titles.
                    probe.type = mediaScope?.rawValue
                    let reason = await BrowseEmptyReason.classify(filter: filterState) {
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
        } catch let err {
            guard myGeneration == generation else { return }
            guard !Task.isCancelled else { return cancelLoading(for: myGeneration) }
            if items.isEmpty {
                self.error = ErrorState(err)
            }
        }
        finishLoading(for: myGeneration)
    }

    // MARK: - Filters / Sort

    /// Commit a new filter/sort state: persist it, reset pagination, refetch.
    func apply(_ newState: CatalogFilterState) async {
        var scopedState = newState
        if mediaScope != nil { scopedState.mediaScope = nil }
        guard scopedState != filterState else { return }
        filterState = scopedState
        BrowsePrefsStore.shared.saveState(scopedState, libraryId: libraryId, mediaScope: mediaScope?.rawValue)
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

    /// Clear every filter facet, keeping the chosen sort.
    func clearFilters() async {
        var next = filterState
        next.resetFilters()
        next.namePrefix = nil
        await apply(next)
    }

    func removeChip(_ chip: CatalogFilterChip) async {
        var next = filterState
        next.toggle(chip.facet, value: chip.value)
        await apply(next)
    }

    /// Load the live facet vocabulary for the filter sheet.
    func loadFacetsIfNeeded() async {
        if facets != nil { return }
        let configuration = configurationGeneration
        let loaded = try? await FacetLoader.shared.facets(libraryId: libraryId)
        guard configuration == configurationGeneration, !Task.isCancelled else { return }
        facets = loaded
    }

    var hasActiveFilters: Bool { filterState.hasActiveFilters }

    // MARK: - Preserve toggle

    var preserveEnabled: Bool { BrowsePrefsStore.shared.preserveEnabled(libraryId: libraryId, mediaScope: mediaScope?.rawValue) }

    func setPreserveEnabled(_ enabled: Bool) {
        BrowsePrefsStore.shared.setPreserveEnabled(enabled, libraryId: libraryId, mediaScope: mediaScope?.rawValue)
        if enabled {
            BrowsePrefsStore.shared.saveState(filterState, libraryId: libraryId, mediaScope: mediaScope?.rawValue)
        }
    }

    // MARK: - Cache

    private var currentCacheKey: String {
        CacheKey.browse(libraryId: libraryId, filterKey: filterState.cacheKeyFragment, mediaScope: mediaScope?.rawValue)
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

    private func invalidatePages() {
        generation += 1
        continuation = nil
        items = []
        hasMore = true
        hasLoaded = false
        isLoading = false
        error = nil
    }

    /// A cancelled load publishes nothing but must release `isLoading`, or
    /// load-more stays blocked until the next reset.
    private func cancelLoading(for cancelledGeneration: Int) {
        guard cancelledGeneration == generation else { return }
        isLoading = false
    }

    private func finishLoading(for completedGeneration: Int) {
        guard completedGeneration == generation else { return }
        isLoading = false
        hasLoaded = true
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
        guard mediaScope == nil, mediaType != .mixed, let first = response.items.first else { return }
        mediaType = BrowseMediaType.from(libraryType: first.type)
    }
}
