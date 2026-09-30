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
    /// Requests waiting on this admin's decision; zero for everyone else.
    private(set) var pendingApprovals = 0
    var isLoading = false
    var error: ErrorState?

    // Search
    var query = ""
    private(set) var searchResults: [RequestMediaResult] = []
    /// TMDB's total for the query, for the "N results" line.
    private(set) var searchTotal = 0
    private(set) var isSearching = false
    private(set) var hasSearched = false

    private var searchTask: Task<Void, Never>?
    private let api: SiloAPI
    /// False where the page reads the full approval queue itself (tvOS), so
    /// the hub doesn't read it a second time just to count it.
    private let countsPendingApprovals: Bool

    init(api: SiloAPI = .shared, countsPendingApprovals: Bool = true) {
        self.api = api
        self.countsPendingApprovals = countsPendingApprovals
    }

    /// True while the hub should show discover content (no active query).
    var isShowingDiscover: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Returns whether discover and the user's requests read successfully.
    @discardableResult
    func load() async -> Bool {
        isLoading = carousels.isEmpty && myRequests.isEmpty
        error = nil
        // The admin queue can take many pages; it fills its row when it
        // lands instead of holding the hub on placeholders.
        async let approvals: Void = loadPendingApprovals()
        async let discover = api.requestsDiscover()
        async let mine = api.myRequests()
        var succeeded = false
        do {
            let (sections, requests) = try await (discover, mine)
            carousels = RequestCarouselMerge.carousels(from: sections)
            myRequests = MyRequestsBucket.bucket(requests).flatMap(\.requests)
            RequestDetailCache.shared.storeOwnRecords(requests)
            RequestDetailCache.shared.prefetch(myRequests, api: api)
            succeeded = true
        } catch {
            // Keep any prior content on a transient failure; only surface
            // the error when there's nothing to show instead.
            if carousels.isEmpty, myRequests.isEmpty {
                self.error = ErrorState(error)
            }
        }
        isLoading = false
        await approvals
        return succeeded
    }

    /// The hub's approvals row is a nudge, not a list: a failed read hides it.
    private func loadPendingApprovals() async {
        guard countsPendingApprovals, RequestsFeatureStore.shared.canModerate else {
            pendingApprovals = 0
            return
        }
        let pending = try? await api.adminRequests(status: .pending, outcome: .active)
        pendingApprovals = pending?.count ?? 0
    }

    /// Bus consumer for admin decisions made anywhere in the app.
    func applyModeration() {
        Task { await loadPendingApprovals() }
    }

    /// Counts for the summary row: requests still moving, and ones that
    /// need the user.
    var inProgressCount: Int {
        myRequests.filter { MyRequestsBucket(RequestDisplayState(record: $0)) == .inMotion }.count
    }

    var needsAttentionCount: Int {
        myRequests.filter { MyRequestsBucket(RequestDisplayState(record: $0)) == .needsAttention }.count
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
            searchTotal = max(page.totalResults, searchResults.count)
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
