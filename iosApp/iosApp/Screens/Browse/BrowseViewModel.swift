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
    /// Where each letter starts in the grid while it is in title order, for
    /// the letter index. Nil in other orders, until it loads, and from a
    /// server without one.
    private(set) var letterIndex: APIv2CatalogLetters?
    /// False once the server has answered that it has no letter index.
    private(set) var offersLetterIndex = true
    /// Reads the whole title-ordered list by position, for the grid on
    /// iPhone and iPad, which shows every title from the start. Set with
    /// `letterIndex`, whose total is the list's length.
    private(set) var pager: CatalogPositionPager?
    /// List position of `items[0]`. Zero until a jump to a letter past the
    /// loaded titles starts the grid partway down the list.
    private(set) var windowStart = 0
    /// After a jump, the grid pages by list position in both directions
    /// instead of following page 1's continuation.
    private var pagesByPosition = false
    /// List position after the last title read below a jump. Duplicates
    /// dropped from `items` would make `windowStart + items.count` fall short
    /// of it and read the same titles again.
    private var windowEnd = 0
    /// Bumped by every jump, so a jump still waiting for its titles gives way
    /// to a later one, including a later jump to a letter already loaded.
    private var jumpGeneration = 0
    /// Bumped by every letter-index read; only the latest one publishes.
    private var letterIndexRead = 0
    /// The list `pager` reads, as `currentCacheKey` named it.
    private var pagerKey: String?
    private var isLoadingEarlier = false

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

    typealias FirstPageRead = @MainActor (
        _ libraryId: Int?, _ state: CatalogFilterState, _ mediaScope: LibraryVideoScope?
    ) async throws -> CatalogListPage
    typealias PageRead = @MainActor (_ query: APIv2CatalogQuery) async throws -> CatalogListPage
    typealias LettersRead = @MainActor (_ query: APIv2CatalogQuery) async throws -> APIv2CatalogLetters?

    /// Reads page 1 of the grid. The app shares the startup prefetch's
    /// request; tests read from a stubbed server.
    private let readFirstPage: FirstPageRead
    /// Reads a page at a list position, for a grid that starts partway down.
    private let readPage: PageRead
    private let readLetters: LettersRead

    init(
        readFirstPage: @escaping FirstPageRead = {
            try await StartupContentPrefetcher.fetchBrowseFirstPage(libraryId: $0, state: $1, mediaScope: $2)
        },
        readPage: @escaping PageRead = { try await SiloAPI.shared.catalogPage($0) },
        readLetters: @escaping LettersRead = { try await SiloAPI.shared.catalogLetters($0) }
    ) {
        self.readFirstPage = readFirstPage
        self.readPage = readPage
        self.readLetters = readLetters
    }

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
            // Another library may have a letter index where the last didn't.
            offersLetterIndex = true
            // A load-more during the metadata await read the old library or
            // type under the new generation; drop it before the new scope loads.
            invalidatePages()
            filterState = BrowsePrefsStore.shared.savedState(libraryId: libraryId, mediaScope: mediaScope?.rawValue) ?? .none
            if mediaScope != nil { filterState.mediaScope = nil }
        }

        facets = FacetLoader.shared.cachedFacets(libraryId: libraryId)
        // Hydrate the page-1 snapshot the next reset will write back into.
        hydratePage1FromCache()
        hydrateLetterIndexFromCache()
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
            closeWindow()
        } else if isLoading {
            return
        } else if pagesByPosition {
            return await loadLater()
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
                page = try await readFirstPage(libraryId, filterState, mediaScope)
            }
            // Discard if another reset superseded us while we awaited.
            guard myGeneration == generation else { return }
            guard !Task.isCancelled else { return cancelLoading(for: myGeneration) }

            startsOver = startsOver || page.startsOver
            if startsOver {
                items = page.response.items
                // These titles are fresher than any the pager read before:
                // they replace its pages from the top.
                if windowStart == 0 { pager?.replaceFromTop(items) }
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
        // The old positions point into the old list.
        letterIndex = nil
        dropPager()
        hydratePage1FromCache()
        hydrateLetterIndexFromCache()
        await loadFromTop()
    }

    /// The first page and the letter index, read side by side so the letter
    /// index is ready when the grid is.
    func loadFromTop() async {
        async let letters: Void = loadLetterIndex()
        await loadItems(reset: true)
        await letters
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

    // MARK: - Letter jump

    /// Number of titles one read of the full-length grid asks for.
    static let windowPageSize = 60

    /// Read where each letter starts, when the grid is in title order. Runs
    /// after each load from the top, so the index matches the list it jumps in.
    func loadLetterIndex(rereadsTitles: Bool = false) async {
        guard filterState.sort == .title, offersLetterIndex else {
            letterIndex = nil
            dropPager()
            return
        }
        let configuration = configurationGeneration
        let key = currentCacheKey
        letterIndexRead += 1
        let myRead = letterIndexRead
        // Captured before the read, so a cache cleared meanwhile (a profile
        // switch) isn't filled again with this answer.
        let writeToken = ResponseCache.shared.writeToken
        do {
            let index = try await readLetters(titleQuery(limit: 1))
            guard configuration == configurationGeneration, key == currentCacheKey,
                  myRead == letterIndexRead, !Task.isCancelled else { return }
            // A list that changed shape changed its pages too; read them again.
            let changed = index != letterIndex
            // A jump still loading aimed at a position the old index gave.
            if changed { jumpGeneration += 1 }
            letterIndex = index
            offersLetterIndex = index != nil
            if let index { ResponseCache.shared.set(index, for: lettersCacheKey, fetchedAt: writeToken) }
            syncPager(rereadsTitles: rereadsTitles || changed)
        } catch {
            // Keep the index already shown; the next load from the top asks again.
        }
    }

    /// A title's watched state, favourite or progress changed elsewhere:
    /// read the titles shown again and update their cards in place, so the
    /// list keeps its length and the grid its scroll position.
    func refreshShownTitles() async {
        guard hasLoaded else { return }
        pager?.rereadKept()
        let myGeneration = generation
        let key = currentCacheKey
        guard let page = try? await readFirstPage(libraryId, filterState, mediaScope),
              myGeneration == generation, key == currentCacheKey, !Task.isCancelled else { return }
        let fresh = Dictionary(page.response.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let updated = items.map { fresh[$0.id] ?? $0 }
        if updated != items { items = updated }
    }

    /// Reload the list from the top and drop the titles read further down,
    /// for pull-to-refresh.
    func refresh() async {
        await loadItems(reset: true)
        await loadLetterIndex(rereadsTitles: true)
    }

    /// Names the list the grid shows; changes with the library, its scope,
    /// the filters and the order.
    var listIdentity: String { currentCacheKey }

    /// The finger is on `letter` in the index: read where a jump would land.
    func prepareJump(to letter: String) {
        guard let position = letterIndex?.position(of: letter) else { return }
        pager?.prepareLanding(at: position)
    }

    /// List position of `letter`'s first title, for the full-length grid to
    /// scroll to. Waits up to `patience` for the titles there.
    func position(forJumpTo letter: String, patience: Duration = .milliseconds(300)) async -> Int? {
        guard let pager, let position = letterIndex?.position(of: letter) else { return nil }
        await pager.awaitLanding(at: position, patience: patience)
        // A sort, filter or library change during the wait replaced the list.
        return self.pager === pager ? position : nil
    }

    /// Keep the pager while it reads the list the index describes; otherwise
    /// start one, seeded with the titles already loaded from the top.
    private func syncPager(rereadsTitles: Bool) {
        guard let total = letterIndex?.total, total > 0 else { return dropPager() }
        let key = currentCacheKey
        if !rereadsTitles, let pager, pager.total == total, pagerKey == key { return }
        dropPager()
        let template = titleQuery(limit: CatalogPositionPager.pageSize)
        let readPage = readPage
        let pager = CatalogPositionPager(total: total) { start, limit in
            var query = template
            query.limit = limit
            query.seek = start
            return try await readPage(query).response.items
        }
        if windowStart == 0 { pager.seed(items) }
        self.pager = pager
        pagerKey = key
    }

    private func dropPager() {
        pager?.cancel()
        pager = nil
        pagerKey = nil
    }

    /// Titles above the first one shown, after a jump started the grid
    /// partway down the list.
    var hasEarlier: Bool { windowStart > 0 }

    /// Rows read above a jumped-to letter, so the titles just before it are
    /// already there and the read of earlier titles starts off screen.
    static let rowsBeforeJump = 6

    /// Get `letter`'s first title into the grid and return its ID to scroll
    /// to. A letter already loaded is only a scroll away. Otherwise the grid
    /// starts over from a few rows above the letter, aligned to `columns` so
    /// every title keeps its column as earlier titles load above it.
    func jump(to letter: String, columns: Int) async -> String? {
        jumpGeneration += 1
        let myJump = jumpGeneration
        guard let letterIndex, let position = letterIndex.position(of: letter) else { return nil }
        let loadedEnd = pagesByPosition ? windowEnd : items.count
        if position >= windowStart, position < loadedEnd, items.indices.contains(position - windowStart) {
            return items[position - windowStart].id
        }
        let columns = max(columns, 1)
        let rowStart = position - position % columns
        let before = min(rowStart, columns * Self.rowsBeforeJump)
        let start = rowStart - before
        var query = titleQuery(limit: min(100, before + Self.windowPageSize))
        query.seek = start
        // Supersedes any load in flight; its results would belong elsewhere,
        // and it won't clear the loading state it set, so clear it here.
        generation += 1
        let myGeneration = generation
        isLoading = false
        isLoadingEarlier = false
        // It also overtakes a first load still running, which would have
        // marked the grid loaded.
        hasLoaded = true
        let read = try? await readPage(query)
        guard myGeneration == generation, myJump == jumpGeneration, !Task.isCancelled,
              let read else { return nil }
        items = Self.unique(read.response.items)
        windowStart = start
        windowEnd = start + read.response.items.count
        pagesByPosition = true
        continuation = nil
        hasMore = windowEnd < letterIndex.total && !read.response.items.isEmpty
        let offset = position - start
        return items.indices.contains(offset) ? items[offset].id : items.last?.id
    }

    /// Read the titles just above the first one shown, a whole number of
    /// `columns` rows at a time so the titles below keep their columns.
    func loadEarlier(columns: Int) async {
        guard windowStart > 0, !isLoadingEarlier else { return }
        let columns = max(columns, 1)
        let rows = max(1, Self.windowPageSize / columns)
        let start = max(0, windowStart - rows * columns)
        isLoadingEarlier = true
        let myGeneration = generation
        var query = titleQuery(limit: min(100, windowStart - start))
        query.seek = start
        let read = try? await readPage(query)
        guard myGeneration == generation else { return }
        isLoadingEarlier = false
        guard let read else { return }
        let shown = Set(items.map(\.id))
        items.insert(contentsOf: read.response.items.filter { !shown.contains($0.id) }, at: 0)
        windowStart = start
    }

    /// The next titles below a grid that started partway down the list.
    private func loadLater() async {
        guard hasMore, let total = letterIndex?.total else { return }
        let myGeneration = generation
        isLoading = true
        var query = titleQuery(limit: Self.windowPageSize)
        query.seek = windowEnd
        let read = try? await readPage(query)
        guard myGeneration == generation else { return }
        isLoading = false
        guard let read else { return }
        let shown = Set(items.map(\.id))
        items.append(contentsOf: read.response.items.filter { !shown.contains($0.id) })
        windowEnd += read.response.items.count
        hasMore = !read.response.items.isEmpty && windowEnd < total
    }

    private static func unique(_ items: [BrowseItem]) -> [BrowseItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private func titleQuery(limit: Int) -> APIv2CatalogQuery {
        CatalogQueryBuilder.build(
            filterState, libraryId: libraryId, mediaType: .movie, limit: limit,
            includeType: false, enforcedScope: mediaScope
        )
    }

    /// Back to paging forward from the first title.
    private func closeWindow() {
        windowStart = 0
        windowEnd = 0
        pagesByPosition = false
        isLoadingEarlier = false
    }

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

    /// Session-only: not a launch screen, so never written to the snapshots.
    private var lettersCacheKey: String { "browseletters:" + currentCacheKey }

    /// Show the letter index read on an earlier visit at once; the read that
    /// follows the load from the top replaces it.
    private func hydrateLetterIndexFromCache() {
        guard letterIndex == nil, filterState.sort == .title, offersLetterIndex,
              let cached: APIv2CatalogLetters = ResponseCache.shared.get(lettersCacheKey) else { return }
        letterIndex = cached
        syncPager(rereadsTitles: false)
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
        closeWindow()
        letterIndex = nil
        dropPager()
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
