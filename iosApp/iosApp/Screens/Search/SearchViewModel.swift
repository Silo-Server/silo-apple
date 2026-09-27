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

@Observable
class SearchViewModel {
    var query = ""
    var selectedMediaType: SearchMediaType = .all
    var results: [BrowseItem] = []
    /// People whose names match the query, exact names first, limited to
    /// credits in the selected media type. Replaced with each new search;
    /// title paging never changes it.
    var people: [Person] = []

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

    /// Debounced search triggered on query change.
    func onQueryChanged() {
        searchTask?.cancel()

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
        // People load alongside the first title page. A people failure only
        // leaves the People row out; title results still show.
        async let matchedPeople: [Person]? = reset ? matchingPeople(for: trimmed, mediaScope: mediaType) : nil

        do {
            let page: CatalogListPage
            if let nextPage {
                page = try await SiloAPI.shared.nextCatalogPage(nextPage)
            } else {
                page = try await SiloAPI.shared.catalogPage(.search(trimmed, type: mediaType, limit: pageSize))
            }
            guard !Task.isCancelled, myGeneration == generation else { return }
            let response = page.response
            if let found = await matchedPeople {
                guard !Task.isCancelled, myGeneration == generation else { return }
                people = found
            }

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
                people = []
                total = 0
                hasMore = false
                continuation = nil
                hasSearched = true
            }
        }
        isSearching = false
    }

    /// Empty when the server cannot scope people search or the request
    /// fails, so people never block or replace title results.
    private func matchingPeople(for query: String, mediaScope: String?) async -> [Person] {
        do {
            if peopleSearchSupported == nil {
                peopleSearchSupported = try await SiloAPI.shared.peopleSearchSupported()
            }
            guard peopleSearchSupported == true else { return [] }
            return try await SiloAPI.shared.searchPeople(query: query, mediaScope: mediaScope, limit: peopleLimit)
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
        people = []
        isSearching = false
        error = nil
        hasSearched = false
        hasMore = false
        total = 0
        continuation = nil
    }
}
