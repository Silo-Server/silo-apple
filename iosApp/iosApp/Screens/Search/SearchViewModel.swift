import Foundation
import os

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
    /// when audiobooks are part of this search it sends no filter (true
    /// everything). When they aren't, it names a video scope so hidden
    /// audiobooks never leak into unfiltered results: `video_with_episodes`
    /// (movies, series, and episodes) when `includesEpisodes`, else `video`
    /// (movies and series). Pass `includesEpisodes` only for a text search on
    /// a server that advertises the scope; older servers ignore the value
    /// and search every type.
    func queryValue(audiobooksEnabled: Bool, includesEpisodes: Bool = false) -> String? {
        switch self {
        case .all: audiobooksEnabled ? nil : (includesEpisodes ? "video_with_episodes" : "video")
        case .movie: "movie"
        case .series: "series"
        case .audiobook: "audiobook"
        }
    }
}

/// What the Search screen shows under the filters.
enum SearchContentState: Equatable {
    /// No query yet.
    case prompt
    /// A new search has no titles or people yet: it is waiting for the
    /// server (capabilities, titles, or people).
    case loading
    /// The search failed; Try Again reruns it.
    case failed(ErrorState)
    case noResults
    case results
}

@MainActor
@Observable
class SearchViewModel {
    var query = ""
    var selectedMediaType: SearchMediaType = .all
    var results: [BrowseItem] = []
    /// People whose names match the query, exact names first, limited to
    /// credits in the selected media type. Replaced with each new search;
    /// title paging never changes it. Always empty unless `includesPeople`.
    var people: [Person] = []
    /// True while a new search's people lookup is still running, so an empty
    /// title page is not reported as "No results" before people arrive.
    var isSearchingPeople = false

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

    var contentState: SearchContentState {
        if (isSearching || isSearchingPeople) && results.isEmpty && people.isEmpty { return .loading }
        if let error { return .failed(error) }
        if results.isEmpty && people.isEmpty { return hasSearched ? .noResults : .prompt }
        return .results
    }

    private var searchTask: Task<Void, Never>?
    private var peopleTask: Task<Void, Never>?
    private let api: SiloAPI
    /// Only the Search screen shows people; pickers that reuse this model
    /// never ask for them.
    private let includesPeople: Bool
    /// Only the Search screen lists episodes under "All"; pickers that reuse
    /// this model choose movies and series.
    private let includesEpisodes: Bool
    private let pageSize = 60
    private let peopleLimit = 20
    /// The server's search features; `nil` until a search first needs them.
    /// A failed read is not kept, so the next search asks again.
    private var searchFeatures: CatalogSearchFeatures?
    /// The read in flight, shared by the title and people lookups.
    private var searchFeaturesTask: Task<CatalogSearchFeatures, Error>?
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Search"
    )
    /// Where the next page of the current results starts; `nil` after the
    /// last page. A new search replaces it.
    private var continuation: APIv2CatalogContinuation?
    /// Bumped by every new search so a load-more for the previous results
    /// cannot append to (or hand its continuation to) the new ones.
    private var generation = 0

    init(api: SiloAPI = .shared, includesPeople: Bool = false, includesEpisodes: Bool = false) {
        self.api = api
        self.includesPeople = includesPeople
        self.includesEpisodes = includesEpisodes
    }

    /// Debounced search triggered on query change.
    func onQueryChanged() {
        searchTask?.cancel()

        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            resetState()
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
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
        guard !trimmed.isEmpty else {
            resetState()
            return
        }

        let nextPage = reset ? nil : continuation
        if !reset, nextPage == nil {
            return
        }
        if reset { generation += 1 }
        let myGeneration = generation

        isSearching = true
        error = nil

        do {
            let page: CatalogListPage
            if let nextPage {
                page = try await api.nextCatalogPage(nextPage)
            } else {
                let mediaType = try await mediaScope()
                guard !Task.isCancelled, myGeneration == generation else { return }
                startPeopleSearch(for: trimmed, mediaScope: mediaType, generation: myGeneration)
                page = try await api.catalogPage(.search(trimmed, type: mediaType, limit: pageSize))
            }
            guard !Task.isCancelled, myGeneration == generation else { return }
            let response = page.response

            if reset || page.startsOver {
                results = response.items
            } else {
                let existingIds = Set(results.map(\.contentId))
                results.append(contentsOf: response.items.filter { !existingIds.contains($0.contentId) })
            }

            continuation = page.continuation
            total = response.total ?? results.count
            hasMore = page.continuation != nil
            hasSearched = true
        } catch let err {
            guard !Task.isCancelled, myGeneration == generation else { return }
            self.error = ErrorState(err)
            if reset {
                results = []
                cancelPeopleSearch()
                total = 0
                hasMore = false
                continuation = nil
                hasSearched = true
            }
        }
        isSearching = false
    }

    /// The `type` for a new search, also sent as the people `media_scope`.
    /// "All" without audiobooks covers episodes only when the server
    /// advertises `video_with_episodes`, and stays `video` when the server
    /// answers without it. A capability read that fails (timeout, lost
    /// connection, refused credentials) fails the search instead of quietly
    /// narrowing it to `video`, which would report "No results" for an
    /// episode.
    private func mediaScope() async throws -> String? {
        let mediaType = selectedMediaType
        let audiobooksEnabled = audiobooksEnabled
        var includesEpisodes = false
        if self.includesEpisodes, mediaType == .all, !audiobooksEnabled {
            includesEpisodes = try await loadSearchFeatures().videoWithEpisodesScope
        }
        return mediaType.queryValue(audiobooksEnabled: audiobooksEnabled, includesEpisodes: includesEpisodes)
    }

    /// The server's search features, read once per model. Concurrent callers
    /// share one request.
    private func loadSearchFeatures() async throws -> CatalogSearchFeatures {
        if let searchFeatures { return searchFeatures }
        let task = searchFeaturesTask ?? Task { [api] in try await api.catalogSearchFeatures() }
        searchFeaturesTask = task
        do {
            let features = try await task.value
            searchFeatures = features
            return features
        } catch {
            if searchFeaturesTask == task { searchFeaturesTask = nil }
            throw error
        }
    }

    /// Loads people for a new search on their own task, so titles publish as
    /// soon as their page arrives. A later search or a reset discards the
    /// result.
    private func startPeopleSearch(for query: String, mediaScope: String?, generation searchGeneration: Int) {
        peopleTask?.cancel()
        guard includesPeople else { return }
        isSearchingPeople = true
        peopleTask = Task {
            let found = await matchingPeople(for: query, mediaScope: mediaScope)
            guard !Task.isCancelled, searchGeneration == generation else { return }
            people = found
            isSearchingPeople = false
        }
    }

    private func cancelPeopleSearch() {
        peopleTask?.cancel()
        peopleTask = nil
        people = []
        isSearchingPeople = false
    }

    /// Empty when the server cannot scope people search or the request
    /// fails, so people never replace title results.
    private func matchingPeople(for query: String, mediaScope: String?) async -> [Person] {
        do {
            guard try await loadSearchFeatures().peopleMediaScope else { return [] }
            return try await api.searchPeople(query: query, mediaScope: mediaScope, limit: peopleLimit)
        } catch {
            if !Task.isCancelled {
                Self.logger.error("people search failed: \(error.localizedDescription, privacy: .public)")
            }
            return []
        }
    }

    private func resetState() {
        generation += 1
        results = []
        cancelPeopleSearch()
        isSearching = false
        error = nil
        hasSearched = false
        hasMore = false
        total = 0
        continuation = nil
    }
}
