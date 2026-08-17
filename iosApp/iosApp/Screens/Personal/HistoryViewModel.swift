import Foundation

/// Loads the user's watch history through the catalog `source=history`
/// endpoint with offset/limit paging. A server-issued snapshot freezes the
/// result set so paging stays consistent while the user scrolls.
@Observable
@MainActor
class HistoryViewModel {
    var items: [BrowseItem] = []
    var isLoading = false
    var error: ErrorState?
    var hasMore = true

    /// Exact catalog total when the server computed one (only the first page
    /// asks for it); `nil` once we can only show a lower bound.
    private(set) var totalItems: Int?

    private var nextOffset = 0
    /// Snapshot token issued by the first page that pins the history result
    /// set. Held stable across subsequent pages so offset paging is consistent.
    private var snapshot: String?
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
        // doesn't blank while the network call runs. Hydrating the cursor too
        // means a load-more still resumes correctly if the refresh below fails.
        if reset, items.isEmpty,
           let cached: CatalogResponse = ResponseCache.shared.get(CacheKey.history) {
            apply(firstPage: cached)
        }

        guard reset || hasMore else { return }

        isLoading = true
        error = nil

        // A reset restarts at offset 0 with a fresh snapshot. Compute the
        // request from locals and leave the live cursor untouched until the
        // call succeeds — if it fails we keep the current page and its cursor,
        // so a later load-more resumes instead of re-fetching (and duplicating)
        // page 1.
        let requestOffset = reset ? 0 : nextOffset
        let requestSnapshot = reset ? nil : snapshot

        do {
            let response = try await SiloAPI.shared.historyCatalog(
                offset: requestOffset,
                limit: pageSize,
                snapshot: requestSnapshot,
                includeTotal: reset
            )
            if reset {
                apply(firstPage: response)
                ResponseCache.shared.set(response, for: CacheKey.history)
            } else {
                items.append(contentsOf: response.items)
                advanceCursor(with: response, from: requestOffset)
            }
        } catch let err {
            // Only surface an error when there's nothing on screen; otherwise
            // keep the current page (and cursor) so the user can retry.
            if items.isEmpty {
                error = ErrorState(err)
            }
        }

        isLoading = false
    }

    /// Replaces all paging state with a freshly-fetched (or cached) first page.
    private func apply(firstPage response: CatalogResponse) {
        items = response.items
        hasMore = response.hasMore ?? false
        // `total` is only authoritative when the server computed it; a
        // `total_exact == false` response carries a placeholder we must ignore.
        totalItems = response.totalExact == false ? nil : response.total
        snapshot = response.snapshot
        nextOffset = response.items.count
    }

    /// Folds a subsequent page into the cursor without disturbing the pinned
    /// snapshot or a previously known-exact total (load-more pages skip the
    /// count, so their `total_exact == false` placeholder is ignored).
    private func advanceCursor(with response: CatalogResponse, from requestOffset: Int) {
        if response.totalExact != false {
            totalItems = response.total
        }
        hasMore = response.hasMore ?? false
        nextOffset = requestOffset + response.items.count
        if snapshot == nil {
            snapshot = response.snapshot
        }
    }
}
