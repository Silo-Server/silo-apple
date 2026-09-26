import SwiftUI

/// Shows the items within a specific collection.
struct CollectionDetailView: View {
    let collectionId: String

    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var error: ErrorState?
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            if !items.isEmpty {
                gridContent
            } else if let error {
                ErrorView(state: error, onRetry: { Task { await loadItems() } })
            } else if isLoading {
                Color.clear
            } else {
                EmptyStateView(
                    icon: "square.stack",
                    title: "Collection is empty",
                    subtitle: "Add items from their detail pages"
                )
            }
        }
        .siloPageBackground()
        .navigationTitle("Collection")
        .siloNavigationTitleDisplayMode(.large)
        .task {
            await loadItems()
        }
        .refreshable {
            await loadItems()
        }
    }

    private var gridContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                CatalogGrid(
                    items: items,
                    isLoading: false,
                    hasMore: false,
                    forcesThreeColumnsOnPhone: true,
                    onItemTap: { item in
                        router.navigate(to: .itemDetail(browseItem: item))
                    },
                    onLoadMore: {}
                )
            }
            .padding(SiloTheme.padding)
        }
    }

    private func loadItems() async {
        // Hydrate from cache so a return visit paints the previous grid
        // instantly while the silent revalidate runs.
        let cacheKey = CacheKey.collectionItems(collectionId)
        if items.isEmpty,
           let cached: CatalogResponse = ResponseCache.shared.get(cacheKey) {
            items = cached.items
        }
        if items.isEmpty {
            isLoading = true
        }
        error = nil
        do {
            let response = try await SiloAPI.shared.collectionItems(collectionId: collectionId)
            ResponseCache.shared.set(response, for: cacheKey)
            items = response.items
        } catch let err {
            if items.isEmpty {
                self.error = ErrorState(err)
            }
        }
        isLoading = false
    }
}
