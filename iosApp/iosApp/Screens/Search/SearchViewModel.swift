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

    private var searchTask: Task<Void, Never>?
    private var peopleTask: Task<Void, Never>?
    private let api: SiloAPI
    /// Only the Search screen shows people; pickers that reuse this model
    /// never ask for them.
    private let includesPeople: Bool
    private let pageSize = 60
    private let peopleLimit = 20
    /// Whether the server can scope people search and filter it by access;
    /// `nil` until the first search asks.
    private var peopleSearchSupported: Bool?
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

    init(api: SiloAPI = .shared, includesPeople: Bool = false) {
        self.api = api
        self.includesPeople = includesPeople
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

        let mediaType = selectedMediaType.queryValue(audiobooksEnabled: audiobooksEnabled)
        if reset { startPeopleSearch(for: trimmed, mediaScope: mediaType, generation: myGeneration) }

        do {
            let page: CatalogListPage
            if let nextPage {
                page = try await api.nextCatalogPage(nextPage)
            } else {
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
            if peopleSearchSupported == nil {
                peopleSearchSupported = try await api.peopleSearchSupported()
            }
            guard peopleSearchSupported == true else { return [] }
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
