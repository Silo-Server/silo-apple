import Foundation

/// The hub summary row's counts: requests still moving, by stage, and ones
/// that need the user.
struct RequestStatusCounts: Equatable {
    var pending = 0
    var onTheWay = 0
    var needsAttention = 0

    var inProgress: Int { pending + onTheWay }
    var isEmpty: Bool { inProgress + needsAttention == 0 }

    init() {}

    init(_ requests: [MediaRequest]) {
        for record in requests {
            switch RequestDisplayState(record: record) {
            case .pending: pending += 1
            case .onTheWay: onTheWay += 1
            case .needsAttention: needsAttention += 1
            case .inLibrary, .unavailable: break
            }
        }
    }
}

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
    private(set) var myRequests: [MediaRequest] = [] {
        didSet { statusCounts = RequestStatusCounts(myRequests) }
    }
    /// Kept in step with `myRequests` so the body reads stored counts.
    private(set) var statusCounts = RequestStatusCounts()
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
    /// Bumped by every read; only the newest read installs its answer.
    private var listGeneration = 0
    /// Requests the user removed this session. A read that started before a
    /// removal still lists it, so every answer leaves them out.
    private var removedRequestIds: Set<String> = []
    private let api: SiloAPI

    init(api: SiloAPI = .shared) {
        self.api = api
    }

    /// True while the hub should show discover content (no active query).
    var isShowingDiscover: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Returns whether discover and the user's requests read successfully.
    /// A read overtaken by a newer one installs nothing and reports false.
    @discardableResult
    func load() async -> Bool {
        listGeneration &+= 1
        let generation = listGeneration
        isLoading = carousels.isEmpty && myRequests.isEmpty
        error = nil
        defer { if generation == listGeneration { isLoading = false } }
        async let discover = api.requestsDiscover()
        async let mine = api.myRequests()
        var succeeded = false
        do {
            let (layout, answer) = try await (discover, mine)
            guard generation == listGeneration else { return false }
            // The cache too: a removed record must not seed its title's page.
            let requests = answer.filter { !removedRequestIds.contains($0.id) }
            carousels = RequestCarouselMerge.carousels(from: layout)
            myRequests = MyRequestsBucket.bucket(requests).flatMap(\.requests)
            RequestDetailCache.shared.storeOwnRecords(requests)
            RequestDetailCache.shared.prefetch(myRequests, api: api)
            succeeded = true
        } catch {
            // Keep any prior content on a transient failure; only surface
            // the error when there's nothing to show instead.
            if generation == listGeneration, carousels.isEmpty, myRequests.isEmpty {
                self.error = ErrorState(error)
            }
        }
        return succeeded
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
            try? await Task.sleep(for: .milliseconds(300))
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

    /// Bus consumer: a follow toggle patches the title's cards in place.
    func applyTitleState(_ update: RequestTitleStateUpdate) {
        searchResults.applyTitleState(update)
        carousels = carousels.map { carousel in
            var results = carousel.results
            results.applyTitleState(update)
            return RequestCarousel(id: carousel.id, title: carousel.title, results: results, seeAll: carousel.seeAll)
        }
    }

    /// Bus consumer: the user removed one of their requests. A read already
    /// running still lists it, so the row stays out of every answer.
    func applyRemoval(_ record: MediaRequest) {
        removedRequestIds.insert(record.id)
        myRequests.removeAll { $0.id == record.id }
    }

    /// Bus consumer: patch every visible surface in place after a mutation
    /// anywhere in the app (detail submit, My Requests cancel, …).
    func applyRequestUpdate(_ record: MediaRequest) {
        // A late answer for a request removed since must not bring it back.
        guard !removedRequestIds.contains(record.id) else { return }
        searchResults.applyRequestUpdate(record)
        carousels = carousels.map { carousel in
            var results = carousel.results
            results.applyRequestUpdate(record)
            return RequestCarousel(id: carousel.id, title: carousel.title, results: results, seeAll: carousel.seeAll)
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
