import Foundation

/// Loads watch history using viewer-pinned catalog cursors.
@Observable
@MainActor
class HistoryViewModel {
    var items: [BrowseItem] = []
    var isLoading = false
    var error: ErrorState?
    var hasMore = true

    /// Exact catalog total when available; estimated totals are not presented as exact.
    private(set) var totalItems: Int?

    private var continuation: APIv2CatalogContinuation?
    private let pageSize = 60

    /// "523 items" when the exact total is known, otherwise a lower bound such
    /// as "60+ items" while more pages remain.
    var countLabel: String {
        let count = totalItems ?? items.count
        let isLowerBound = totalItems == nil && (hasMore || error != nil)
        let suffix = isLowerBound ? "+" : ""
        let unit = (count == 1 && !isLowerBound) ? "item" : "items"
        return "\(count)\(suffix) \(unit)"
    }

    func load(reset: Bool) async {
        guard !isLoading else { return }

        // Cold start: surface the cached first page instantly so the grid
        // does not blank while the network call runs. Cached cards never carry
        // a resumable cursor across viewer changes.
        if reset, items.isEmpty,
           let cached: CatalogResponse = ResponseCache.shared.get(CacheKey.history) {
            apply(firstPage: cached)
        }

        guard reset || hasMore else { return }

        isLoading = true
        error = nil

        do {
            let page: APIv2CatalogResult
            if !reset, let continuation {
                page = try await SiloAPI.shared.v2.nextCatalogPage(continuation)
            } else {
                var query = APIv2CatalogQuery()
                query.source = "history"
                query.limit = pageSize
                page = try await SiloAPI.shared.catalogPage(query: query)
            }
            let response = CatalogResponse(catalogPage: page.value)
            if reset {
                apply(firstPage: response)
                ResponseCache.shared.set(response, for: CacheKey.history)
            } else {
                items.append(contentsOf: response.items)
                totalItems = response.totalExact == true ? response.total : nil
            }
            continuation = page.continuation
            hasMore = page.continuation != nil
        } catch let err {
            error = ErrorState(err)
            hasMore = false
        }

        isLoading = false
    }

    /// Applies display data; the caller installs a live cursor only after a fresh read.
    private func apply(firstPage response: CatalogResponse) {
        items = response.items
        hasMore = false
        // `total` is only authoritative when the server computed it; a
        // `total_exact == false` response may carry an estimate.
        totalItems = response.totalExact == false ? nil : response.total
        continuation = nil
    }
}
