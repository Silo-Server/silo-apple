import Foundation

/// Loads the user's watch history through the v2 catalog `source=history`
/// list. The server fences the cursor at the first page, so paging stays
/// consistent while the user scrolls.
@Observable
@MainActor
class HistoryViewModel {
    var items: [BrowseItem] = []
    var isLoading = false
    var error: ErrorState?
    var hasMore = true

    /// Exact catalog total when the server computed one; `nil` once we can
    /// only show a lower bound.
    private(set) var totalItems: Int?

    /// Where the next page starts; `nil` before the live first page arrives
    /// and after the last page. A cached first page has no continuation.
    private var continuation: APIv2CatalogContinuation?
    private let pageSize = 60

    /// "523 items" when the exact total is known, otherwise a lower bound such
    /// as "60+ items" while more pages remain.
    var countLabel: String {
        let count = totalItems ?? items.count
        let isLowerBound = totalItems == nil && hasMore
        let suffix = isLowerBound ? "+" : ""
        let unit = (count == 1 && !isLowerBound) ? "item" : "items"
        return "\(count)\(suffix) \(unit)"
    }

    func load(reset: Bool) async {
        guard !isLoading else { return }

        // Cold start: surface the cached first page instantly so the grid
        // doesn't blank while the network call runs.
        if reset, items.isEmpty,
           let cached: CatalogResponse = ResponseCache.shared.get(CacheKey.history) {
            apply(firstPage: cached)
        }

        guard reset || hasMore else { return }

        isLoading = true
        error = nil

        // Leave the live continuation untouched until the call succeeds: if a
        // reset fails we keep the current page and its continuation. A
        // load-more without a continuation (only a cached first page is on
        // screen) starts over from the first page instead of appending.
        let nextPage = reset ? nil : continuation

        do {
            if let nextPage {
                let page = try await SiloAPI.shared.nextCatalogPage(nextPage)
                items.append(contentsOf: page.response.items)
                advance(with: page)
            } else {
                let page = try await SiloAPI.shared.catalogPage(.history(limit: pageSize))
                apply(firstPage: page.response)
                continuation = page.continuation
                hasMore = page.continuation != nil
                ResponseCache.shared.set(page.response, for: CacheKey.history)
            }
        } catch let err {
            // Only surface an error when there's nothing on screen; otherwise
            // keep the current page (and continuation) so the user can retry.
            if items.isEmpty {
                error = ErrorState(err)
            }
        }

        isLoading = false
    }

    /// Replaces the items and totals with a freshly-fetched (or cached) first
    /// page. The continuation is set by the caller: a cached page has none.
    private func apply(firstPage response: CatalogResponse) {
        items = response.items
        hasMore = response.hasMore ?? false
        // `total` is only authoritative when the server computed it; a
        // `total_exact == false` response carries an estimate we must ignore.
        totalItems = response.totalExact == false ? nil : response.total
    }

    /// Folds a later page into the paging state without discarding a
    /// previously known-exact total.
    private func advance(with page: CatalogListPage) {
        if page.response.totalExact != false {
            totalItems = page.response.total
        }
        continuation = page.continuation
        hasMore = page.continuation != nil
    }
}
