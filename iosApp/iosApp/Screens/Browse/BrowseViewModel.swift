import Foundation

@Observable
@MainActor
class BrowseViewModel: CatalogMembershipModel {
    var items: [BrowseItem] = []
    var isLoading = false
    var isRefreshing = false
    var error: ErrorState?
    var hasMore = true

    /// The committed filter + sort state. The filter sheet edits a draft and
    /// commits it via `apply`.
    private(set) var filterState = CatalogFilterState()
    /// Media family of this library — picks the sort/facet vocabulary.
    private(set) var mediaType: BrowseMediaType = .movie
    /// Live facet vocabulary for the filter sheet, loaded lazily.
    private(set) var facets: CatalogFacets?

    private var continuation: APIv2CatalogContinuation?
    private var libraryId: Int?
    private var hasConfigured = false
    private var configurationGeneration = 0
    /// Bumped on every reset; a returning fetch from an older generation
    /// discards its results instead of appending stale data.
    private var generation = 0

    private let api: SiloAPI
    private let tokens: TokenStore
    private let authorityCheck: (CapturedOrdinaryRequestAuth) async -> Bool

    init(api: SiloAPI = .shared, tokens: TokenStore = .shared,
         authorityCheck: ((CapturedOrdinaryRequestAuth) async -> Bool)? = nil) {
        self.api = api
        self.tokens = tokens
        self.authorityCheck = authorityCheck ?? { await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: $0) != nil }
    }

    private var cardScope: String { libraryId.map { "library:\($0)" } ?? "browse" }
    struct CachedPage {
        let owner: CatalogCardOwner
        let response: CatalogResponse
    }

    func cancel() {
        configurationGeneration += 1
        generation += 1
        clearDisplayedRows()
        isLoading = false
        isRefreshing = false
    }

    private func clearDisplayedRows() {
        items = []
        displayedRead = nil
        cardGeneration += 1
        continuation = nil
        hasMore = false
    }

    private(set) var displayedRead: CatalogCardOwner?
    private(set) var cardGeneration = 0
    private var pendingCardActions: [String: UUID] = [:]

    private func matchesCardScope(_ owner: CatalogCardOwner) -> Bool {
        owner.scope == cardScope && owner.filterKey == filterState.cacheKeyFragment
    }

    func prepareCardAction(contentId: String, target: APIv2PersonalListKind, included: Bool) -> CatalogMembershipAction? {
        guard let owner = displayedRead, matchesCardScope(owner), pendingCardActions[contentId] == nil,
              items.contains(where: { $0.contentId == contentId && $0.userState != nil }) else { return nil }
        let action = CatalogMembershipAction(id: UUID(), contentId: contentId, owner: owner,
            generation: cardGeneration, target: target, included: included)
        pendingCardActions[contentId] = action.id
        return action
    }

    private func isCurrent(_ action: CatalogMembershipAction) -> Bool {
        action.owner == displayedRead && matchesCardScope(action.owner) && action.generation == cardGeneration
            && pendingCardActions[action.contentId] == action.id && !Task.isCancelled
            && items.contains(where: { $0.contentId == action.contentId })
    }

    func performCardAction(_ action: CatalogMembershipAction) async -> Bool? {
        defer { if pendingCardActions[action.contentId] == action.id { pendingCardActions[action.contentId] = nil } }
        let current = await authorityCheck(action.owner.auth)
        guard current, isCurrent(action) else { return nil }
        do {
            switch action.target {
            case .favorites: try await api.v2.setFavoriteMembership(id: action.contentId, included: action.included, auth: action.owner.auth)
            case .watchlist: try await api.v2.setWatchlistMembership(id: action.contentId, included: action.included, auth: action.owner.auth)
            }
            let current = await authorityCheck(action.owner.auth)
            guard current, isCurrent(action) else { return nil }
            generation += 1
            isLoading = false
            isRefreshing = false
            let cached: CachedPage? = ResponseCache.shared.get(currentCacheKey)
            if cached?.owner == action.owner { ResponseCache.shared.remove(currentCacheKey) }
            if let index = items.firstIndex(where: { $0.contentId == action.contentId }) {
                let old = items[index].userState
                items[index].userState = MediaItemUserState(played: old?.played ?? false,
                    isFavorite: action.target == .favorites ? action.included : old?.isFavorite ?? false,
                    inWatchlist: action.target == .watchlist ? action.included : old?.inWatchlist ?? false)
            }
            ResponseCache.shared.remove(CacheKey.itemUserState(action.contentId))
            ResponseCache.shared.remove(action.target == .favorites ? CacheKey.favorites : CacheKey.watchlist)
            ResponseCache.shared.remove(CacheKey.homeSections)
            return true
        } catch {
            let current = await authorityCheck(action.owner.auth)
            guard current, isCurrent(action) else { return nil }
            return false
        }
    }

    @discardableResult
    func configure(libraryId: Int?, libraryType: String? = nil) async -> Bool {
        configurationGeneration += 1
        let myConfiguration = configurationGeneration
        generation += 1
        cardGeneration += 1
        isLoading = false
        isRefreshing = false
        let libraryChanged = !hasConfigured || self.libraryId != libraryId
        let resolvedMediaType = await resolveMediaType(libraryId: libraryId, libraryType: libraryType)
        guard myConfiguration == configurationGeneration, !Task.isCancelled else { return false }

        self.libraryId = libraryId
        hasConfigured = true
        mediaType = resolvedMediaType

        if libraryChanged {
            generation += 1
            continuation = nil
            hasMore = true
            clearDisplayedRows()
            filterState = BrowsePrefsStore.shared.savedState(libraryId: libraryId) ?? .none
        }

        facets = FacetLoader.shared.cachedFacets(libraryId: libraryId)
        // Cache hydration waits for full authority in loadItems.
        return true
    }

    // MARK: - Load Items

    func loadItems(reset: Bool = false) async {
        if reset {
            generation += 1
            cardGeneration += 1
            continuation = nil
            hasMore = true
        } else if isLoading || !hasMore { return }
        let myGeneration = generation
        let requestedFilter = filterState
        let scope = cardScope
        let requestedLibrary = libraryId
        let cacheKey = currentCacheKey
        isLoading = true
        isRefreshing = reset && !items.isEmpty
        error = nil
        defer { finishLoading(for: myGeneration) }
        let captured = await tokens.captureOrdinaryRequestAuth()
        guard myGeneration == generation, !Task.isCancelled else { return }
        guard let auth = captured, let profile = auth.profileId, !profile.isEmpty else {
            clearDisplayedRows()
            error = ErrorState(HTTPError.requestIdentityChanged)
            return
        }
        let owner = CatalogCardOwner(auth: auth, scope: scope, filterKey: requestedFilter.cacheKeyFragment)
        if displayedRead != owner {
            clearDisplayedRows()
            if !reset {
                error = ErrorState(HTTPError.requestIdentityChanged)
                return
            }
        }
        do {
            let current = await authorityCheck(auth)
            guard myGeneration == generation, !Task.isCancelled else { return }
            guard current else { throw HTTPError.requestIdentityChanged }
            if reset { hydratePage1FromCache(owner: owner) }
            let result: APIv2CatalogResult
            if !reset {
                guard let continuation, continuation.auth == auth else { throw HTTPError.requestIdentityChanged }
                result = try await api.v2.nextCatalogPage(continuation)
            } else {
                let query = CatalogQueryBuilder.build(requestedFilter, libraryId: requestedLibrary,
                    mediaType: mediaType, limit: 60, includeType: false)
                result = try await api.catalogPage(query: query, auth: auth)
            }
            let mayPublish = await authorityCheck(auth)
            guard myGeneration == generation, !Task.isCancelled, matchesCardScope(owner) else { return }
            guard mayPublish, result.auth == auth else { throw HTTPError.requestIdentityChanged }
            let response = CatalogResponse(catalogPage: result.value)
            if reset {
                items = response.items
                ResponseCache.shared.set(CachedPage(owner: owner, response: response), for: cacheKey)
                refineMediaType(from: response)
            } else {
                let existing = Set(items.map(\.contentId))
                items.append(contentsOf: response.items.filter { !existing.contains($0.contentId) })
            }
            displayedRead = owner
            hasMore = result.continuation != nil
            continuation = result.continuation
        } catch {
            let current = await authorityCheck(auth)
            guard myGeneration == generation, !Task.isCancelled, matchesCardScope(owner) else { return }
            if !current { clearDisplayedRows() }
            self.error = ErrorState(current ? error : HTTPError.requestIdentityChanged)
            hasMore = false
            continuation = nil
        }
    }

    // MARK: - Filters / Sort

    /// Commit a new filter/sort state: persist it, reset pagination, refetch.
    func apply(_ newState: CatalogFilterState) async {
        guard newState != filterState else { return }
        filterState = newState
        BrowsePrefsStore.shared.saveState(newState, libraryId: libraryId)
        clearDisplayedRows()
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

    private func hydratePage1FromCache(owner: CatalogCardOwner) {
        guard items.isEmpty,
              let cached: CachedPage = ResponseCache.shared.get(currentCacheKey), cached.owner == owner else {
            return
        }
        items = cached.response.items
        displayedRead = owner
        hasMore = false
        refineMediaType(from: cached.response)
    }

    private func finishLoading(for completedGeneration: Int) {
        guard completedGeneration == generation else { return }
        isLoading = false
        isRefreshing = false
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
