import Foundation

enum SearchMediaType: String, CaseIterable, Identifiable {
    case all
    case movie
    case series
    case audiobook

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .movie: "Movies"
        case .series: "Series"
        case .audiobook: "Audiobooks"
        }
    }

    /// The `type` query value for this filter. `.all` is context-dependent:
    /// when audiobooks aren't part of this search it means video-only (the old
    /// "Movies & Series" filter), so hidden audiobooks never leak into
    /// unfiltered results; when they are, it sends no filter (true everything).
    func queryValue(audiobooksEnabled: Bool) -> String? {
        switch self {
        case .all: audiobooksEnabled ? nil : "video"
        case .movie: "movie"
        case .series: "series"
        case .audiobook: "audiobook"
        }
    }
}

@Observable
@MainActor
class SearchViewModel {
    var query = ""
    var selectedMediaType: SearchMediaType = .all
    var results: [BrowseItem] = []

    /// Whether audiobooks participate in this search session. Drives both the
    /// offered filters (`availableMediaTypes`) and what `.all` means. On tvOS
    /// this mirrors the Audiobooks tab — an audiobook library exists and the
    /// user has opted to show it. On iOS it mirrors the local Settings toggle.
    /// macOS has no hide setting, so it stays `true`. Clamp the selection if
    /// audiobooks become unavailable.
    var audiobooksEnabled = true {
        didSet {
            if !audiobooksEnabled, selectedMediaType == .audiobook {
                selectedMediaType = .all
            }
        }
    }

    /// Filters offered in the picker — Audiobooks only when enabled.
    var availableMediaTypes: [SearchMediaType] {
        audiobooksEnabled ? [.all, .movie, .series, .audiobook] : [.all, .movie, .series]
    }
    var isSearching = false
    var error: ErrorState?
    var hasSearched = false
    var hasMore = false
    var total = 0

    private let api: APIv2Client
    private let tokens: TokenStore
    private let authorityCheck: (CapturedOrdinaryRequestAuth) async -> Bool

    init(api: APIv2Client = APIv2Client(), tokens: TokenStore = .shared,
         authorityCheck: ((CapturedOrdinaryRequestAuth) async -> Bool)? = nil) {
        self.api = api
        self.tokens = tokens
        self.authorityCheck = authorityCheck ?? { await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: $0) != nil }
    }

    struct DisplayedRead: Equatable {
        let auth: CapturedOrdinaryRequestAuth
        let query: String
        let type: String?
    }
    private(set) var displayedRead: DisplayedRead?
    private(set) var cardGeneration = 0
    private var pendingCardActions: [String: UUID] = [:]
    struct CardAction {
        let id: UUID
        let contentId: String
        let owner: DisplayedRead
        let generation: Int
        let target: APIv2PersonalListKind
        let included: Bool
    }

    private func matchesQuery(_ owner: DisplayedRead) -> Bool {
        owner.query == query.trimmingCharacters(in: .whitespaces)
            && owner.type == selectedMediaType.queryValue(audiobooksEnabled: audiobooksEnabled)
    }

    func prepareCardAction(contentId: String, target: APIv2PersonalListKind, included: Bool) -> CardAction? {
        guard let owner = displayedRead, matchesQuery(owner), pendingCardActions[contentId] == nil,
              results.contains(where: { $0.contentId == contentId && $0.userState != nil }) else { return nil }
        let action = CardAction(id: UUID(), contentId: contentId, owner: owner, generation: cardGeneration,
            target: target, included: included)
        pendingCardActions[contentId] = action.id
        return action
    }

    private func isCurrent(_ action: CardAction) -> Bool {
        action.owner == displayedRead && matchesQuery(action.owner) && action.generation == cardGeneration
            && pendingCardActions[action.contentId] == action.id
            && results.contains(where: { $0.contentId == action.contentId }) && !Task.isCancelled
    }

    func performCardAction(_ action: CardAction) async -> Bool? {
        defer { if pendingCardActions[action.contentId] == action.id { pendingCardActions[action.contentId] = nil } }
        let current = await authorityCheck(action.owner.auth)
        guard current, isCurrent(action) else { return nil }
        do {
            switch action.target {
            case .favorites: try await api.setFavoriteMembership(id: action.contentId, included: action.included, auth: action.owner.auth)
            case .watchlist: try await api.setWatchlistMembership(id: action.contentId, included: action.included, auth: action.owner.auth)
            }
            let current = await authorityCheck(action.owner.auth)
            guard current, isCurrent(action) else { return nil }
            generation += 1
            isSearching = false
            if let index = results.firstIndex(where: { $0.contentId == action.contentId }) {
                let old = results[index].userState
                results[index].userState = MediaItemUserState(played: old?.played ?? false,
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

    func cancel() {
        searchTask?.cancel()
        resetState()
    }

    private var searchTask: Task<Void, Never>?
    private let pageSize = 60
    private var continuation: APIv2CatalogContinuation?
    private var generation = 0
    var totalExact = true
    var resultWindowLimit: Int?
    var sessionExpiresAt: Date?

    var countLabel: String {
        "\(totalExact ? "" : "About ")\(total) result\(total == 1 ? "" : "s")"
    }

    /// Debounced search triggered on query change.
    func onQueryChanged() {
        searchTask?.cancel()
        generation += 1
        cardGeneration += 1
        continuation = nil
        hasMore = false
        isSearching = false

        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            resetState()
            return
        }

        searchTask = Task {
            // 300ms debounce
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(reset: true)
        }
    }

    func applyMediaType() async {
        searchTask?.cancel()

        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }

        await performSearch(reset: true)
    }

    func loadMore() async {
        guard hasMore, !isSearching else { return }
        await performSearch(reset: false)
    }

    func performSearch(reset: Bool = true) async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { resetState(); return }
        if !reset, !hasMore || isSearching { return }
        if reset { generation += 1; cardGeneration += 1; continuation = nil }
        let requestGeneration = generation
        let type = selectedMediaType.queryValue(audiobooksEnabled: audiobooksEnabled)
        isSearching = true
        error = nil
        defer { if requestGeneration == generation { isSearching = false } }
        let captured = await tokens.captureOrdinaryRequestAuth()
        guard requestGeneration == generation, !Task.isCancelled else { return }
        guard let auth = captured, auth.profileId != nil else {
            resetState()
            error = ErrorState(HTTPError.requestIdentityChanged)
            return
        }
        let owner = DisplayedRead(auth: auth, query: trimmed, type: type)
        if displayedRead != owner {
            results = []; displayedRead = nil; total = 0
            if !reset {
                hasMore = false; continuation = nil
                error = ErrorState(HTTPError.requestIdentityChanged)
                return
            }
        }
        do {
            let page: APIv2CatalogResult
            if !reset {
                guard let continuation, continuation.auth == auth else { throw HTTPError.requestIdentityChanged }
                page = try await api.nextCatalogPage(continuation)
            } else {
                let capabilities = try await api.catalogSearchCapabilities(auth: auth)
                guard requestGeneration == generation, !Task.isCancelled, matchesQuery(owner) else { return }
                guard capabilities.allowed != false else { throw CatalogSearchUnavailable() }
                var searchQuery = APIv2CatalogQuery()
                searchQuery.q = trimmed
                searchQuery.limit = pageSize
                searchQuery.imageSize = ImageSizeCapability.shared.requestQuery["image_size"]
                searchQuery.type = type
                page = try await api.catalogPage(query: searchQuery, auth: auth)
            }
            let current = await authorityCheck(auth)
            guard requestGeneration == generation, !Task.isCancelled, matchesQuery(owner) else { return }
            guard current, page.auth == auth else { throw HTTPError.requestIdentityChanged }
            let response = page.value
            if reset { results = response.items } else {
                let existingIds = Set(results.map(\.contentId))
                results.append(contentsOf: response.items.filter { !existingIds.contains($0.contentId) })
            }
            displayedRead = owner
            continuation = page.continuation
            total = response.total
            totalExact = response.totalExact
            resultWindowLimit = response.searchDiagnostics?.resultWindowLimit
            sessionExpiresAt = response.searchDiagnostics?.sessionExpiresAt
            hasMore = page.continuation != nil
            hasSearched = true
        } catch {
            let current = await authorityCheck(auth)
            guard requestGeneration == generation, !Task.isCancelled, matchesQuery(owner) else { return }
            hasMore = false
            continuation = nil
            self.error = ErrorState(current ? error : HTTPError.requestIdentityChanged)
            if reset || !current {
                results = []; displayedRead = nil; total = 0
                hasSearched = true
            }
        }
    }

    private func resetState() {
        displayedRead = nil
        cardGeneration += 1
        results = []
        isSearching = false
        error = nil
        hasSearched = false
        hasMore = false
        total = 0
        generation += 1
        continuation = nil
        totalExact = true
        resultWindowLimit = nil
        sessionExpiresAt = nil
    }
}

private struct CatalogSearchUnavailable: LocalizedError {
    var errorDescription: String? { "Search is currently unavailable. Please try again later." }
}
