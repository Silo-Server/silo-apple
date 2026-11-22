import Foundation

/// Every title of one row of the server's Discover layout, read page by
/// page as the viewer scrolls: the hub row's See all page.
@Observable
@MainActor
final class RequestDiscoverRowViewModel {
    private(set) var title: String
    private(set) var results: [RequestMediaResult] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    /// A first page that failed; a later page's failure keeps what loaded.
    private(set) var error: ErrorState?
    /// The row is gone from the server's layout (turned off or removed).
    private(set) var notFound = false
    /// A later page failed: the grid offers to try it again.
    private(set) var moreFailed = false

    private let key: String
    private let api: SiloAPI
    private var nextPage: Int? = 1
    private var seen = Set<String>()

    init(key: String, title: String, api: SiloAPI = .shared) {
        self.key = key
        self.title = title
        self.api = api
    }

    var endReached: Bool { nextPage == nil }

    func loadMore() async {
        guard let page = nextPage, !isLoading, !isLoadingMore, !notFound else { return }
        if results.isEmpty { isLoading = true } else { isLoadingMore = true }
        error = nil
        moreFailed = false
        defer {
            isLoading = false
            isLoadingMore = false
        }
        var requested = page
        do {
            // A page of titles already shown gives the grid no new last card
            // to scroll to, so read on until one adds something.
            while true {
                let section = try await api.requestsDiscoverRow(key: key, page: requested)
                nextPage = RequestDiscoverPaging.nextPage(after: section, requested: requested)
                if !section.title.isEmpty { title = section.title }
                // Charts shift between pages, so a title can come twice.
                let fresh = section.results.filter { seen.insert($0.id).inserted }
                results += fresh
                guard fresh.isEmpty, let next = nextPage else { break }
                requested = next
            }
        } catch {
            // With nothing shown yet (a first page, or empty pages before it),
            // a failure is the screen's; after that, the grid's.
            let state = ErrorState(error)
            if state.statusCode == 404 {
                // A row removed mid-scroll ends where it is.
                if results.isEmpty { notFound = true } else { nextPage = nil }
            } else if results.isEmpty {
                self.error = state
            } else {
                moreFailed = true
            }
        }
    }

    /// A request made anywhere in the app shows on this row's cards too.
    func applyRequestUpdate(_ record: MediaRequest) {
        results.applyRequestUpdate(record)
    }

    func applyTitleState(_ update: RequestTitleStateUpdate) {
        results.applyTitleState(update)
    }
}
