import Foundation

/// State for the Requests hub: TMDB search (the primary interaction), the
/// user's own requests strip, and the two discover carousels. Fetches fresh
/// on every visit — request state changes server-side asynchronously, so
/// the stale-while-revalidate `ResponseCache` pattern would actively
/// mislead here (a stale "Pending" ribbon is worse than a spinner).
@Observable
@MainActor
final class RequestsHubViewModel {
    // Discover + own-requests strip
    private(set) var carousels: [RequestCarousel] = []
    private(set) var myRequests: [MediaRequest] = []
    var isLoading = false
    var error: ErrorState?

    // Search
    var query = ""
    private(set) var searchResults: [RequestMediaResult] = []
    private(set) var isSearching = false
    private(set) var hasSearched = false

    private var searchTask: Task<Void, Never>?
    private let api: SiloAPI

    init(api: SiloAPI = .shared) {
        self.api = api
    }

    /// True while the hub should show discover content (no active query).
    var isShowingDiscover: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func load() async {
        isLoading = carousels.isEmpty && myRequests.isEmpty
        error = nil
        async let discover = api.requestsDiscover()
        async let mine = api.myRequests()
        do {
            let (sections, requests) = try await (discover, mine)
            carousels = RequestCarouselMerge.carousels(from: sections)
            myRequests = MyRequestsBucket.bucket(requests).flatMap(\.requests)
        } catch {
            // Keep any prior content on a transient failure; only surface
            // the error when there's nothing to show instead.
            if carousels.isEmpty, myRequests.isEmpty {
                self.error = ErrorState(error)
            }
        }
        isLoading = false
    }

    /// Debounced TMDB search, mirroring `SearchViewModel`'s 300ms feel.
    func onQueryChanged() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            hasSearched = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(trimmed)
        }
    }

    private func performSearch(_ trimmed: String) async {
        isSearching = true
        // Cancellation paths must still clear the spinner: a replacement
        // search re-raises `isSearching` after its own 300ms debounce, so a
        // cancelled task's `false` can never stomp a successor's `true`.
        do {
            let page = try await api.requestsSearch(query: trimmed)
            guard !Task.isCancelled else {
                isSearching = false
                return
            }
            searchResults = page.results.filter { $0.mediaType != .unknown }
            hasSearched = true
        } catch {
            guard !Task.isCancelled else {
                isSearching = false
                return
            }
            searchResults = []
            hasSearched = true
        }
        isSearching = false
    }

    /// Bus consumer: patch every visible surface in place after a mutation
    /// anywhere in the app (detail submit, My Requests cancel, …).
    func applyRequestUpdate(_ record: MediaRequest) {
        searchResults.applyRequestUpdate(record)
        carousels = carousels.map { carousel in
            var results = carousel.results
            results.applyRequestUpdate(record)
            return RequestCarousel(id: carousel.id, title: carousel.title, results: results)
        }
        if let index = myRequests.firstIndex(where: { $0.id == record.id }) {
            if record.outcome == .cancelled {
                myRequests.remove(at: index)
            } else {
                myRequests[index] = record
            }
        } else if record.outcome == .active {
            myRequests.insert(record, at: 0)
        }
    }
}
