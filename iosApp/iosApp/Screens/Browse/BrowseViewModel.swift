import Foundation

@Observable
@MainActor
class BrowseViewModel {
    var items: [BrowseItem] = []
    var isLoading = false
    var isRefreshing = false
    var error: ErrorState?
    var hasMore = true
    var selectedGenre: String? = nil
    var sortBy: String = "title"

    private var currentPage = 0
    private let pageSize = 60
    private var libraryId: Int?

    func configure(libraryId: Int?) {
        self.libraryId = libraryId
        // Hydrate the page-1 snapshot the next reset will write back into.
        hydratePage1FromCache()
    }

    // MARK: - Load Items

    func loadItems(reset: Bool = false) async {
        guard !isLoading else { return }
        if reset {
            // Surface the cached page-1 snapshot instantly so the grid
            // doesn't blank out while the network call runs.
            if !items.isEmpty {
                isRefreshing = true
            } else if let cached: CatalogResponse = ResponseCache.shared.get(currentCacheKey) {
                items = cached.items
                hasMore = cached.hasMore ?? false
                isRefreshing = true
            }
            currentPage = 0
            if items.isEmpty {
                hasMore = true
            }
        }
        guard hasMore else {
            isRefreshing = false
            return
        }

        if items.isEmpty {
            isLoading = true
        }
        error = nil

        do {
            var query: [String: String] = [
                "offset": String(currentPage * pageSize),
                "limit": String(pageSize),
                "sort": sortBy
            ]
            if let libraryId {
                query["library_id"] = String(libraryId)
            }
            if let genre = selectedGenre {
                query["genre"] = genre
            }

            let response: CatalogResponse
            if reset && currentPage == 0 {
                response = try await StartupContentPrefetcher.fetchBrowseFirstPage(
                    libraryId: libraryId,
                    genre: selectedGenre,
                    sort: sortBy
                )
            } else {
                response = try await ContinuumAPI.shared.get(
                    "/api/v1/catalog", query: query
                )
            }
            if reset {
                items = response.items
                ResponseCache.shared.set(response, for: currentCacheKey)
            } else {
                items.append(contentsOf: response.items)
            }
            hasMore = response.hasMore ?? false
            currentPage += 1
        } catch let err {
            if items.isEmpty {
                self.error = ErrorState(err)
            }
        }
        isLoading = false
        isRefreshing = false
    }

    // MARK: - Filters

    func applyGenre(_ genre: String?) async {
        selectedGenre = genre
        items = []
        hydratePage1FromCache()
        await loadItems(reset: true)
    }

    func applySort(_ sort: String) async {
        sortBy = sort
        items = []
        hydratePage1FromCache()
        await loadItems(reset: true)
    }

    // MARK: - Cache

    private var currentCacheKey: String {
        CacheKey.browse(libraryId: libraryId, genre: selectedGenre, sort: sortBy)
    }

    private func hydratePage1FromCache() {
        guard items.isEmpty,
              let cached: CatalogResponse = ResponseCache.shared.get(currentCacheKey) else {
            return
        }
        items = cached.items
        hasMore = cached.hasMore ?? false
    }
}
