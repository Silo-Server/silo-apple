import SwiftUI

/// Shows the items within a specific collection.
struct CollectionDetailView: View {
    let collectionId: String
    /// The collection's name, when the page that opened it knows it.
    var title: String? = nil

    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var error: ErrorState?
    @State private var loadGeneration = 0
    @State private var shuffleLauncher = ShuffleLauncher()
    @Environment(AppRouter.self) private var router
    @Environment(\.locale) private var locale

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
                    title: AppLanguage.string(.collectionsEmptyItemsTitle, locale: locale),
                    subtitle: AppLanguage.string(.collectionsEmptyItemsHint, locale: locale)
                )
            }
        }
        .siloPageBackground()
        .navigationTitle(title.map { Text($0) } ?? Text(.collectionsCollection))
        .siloNavigationTitleDisplayMode(.large)
        .task {
            await loadItems()
        }
        .refreshable {
            await loadItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: .collectionItemsDidChange)) { note in
            guard (note.object as? String) == collectionId else { return }
            Task { await loadItems() }
        }
        .shuffleFailureAlert(shuffleLauncher)
        #if os(tvOS)
        .tvActionPopoverHost()
        #endif
    }

    private var gridContent: some View {
        ScrollView {
            HStack(spacing: 12) {
                if ShuffleFeatureStore.shared.supports(.userCollection) {
                    ShuffleButton(isStarting: shuffleLauncher.isStarting) {
                        shuffleLauncher.start(ShuffleScopeRequest(kind: .userCollection, id: collectionId), router: router)
                    }
                }
                CollectionPinActionBar(
                    collectionId: collectionId,
                    title: title,
                    isUserCollection: true
                )
                .id(collectionId)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, SiloTheme.smallPadding)
            #if os(tvOS)
            // Up from any grid column reaches Shuffle & Pin to Home.
            .focusSection()
            #endif
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
        loadGeneration += 1
        let myGen = loadGeneration
        let startIdentity = SeekIntervalPreferences.activeRequestIdentity()
        let startToken = ResponseCache.shared.writeToken
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
        defer {
            if loadGeneration == myGen {
                isLoading = false
            }
        }
        error = nil
        do {
            let response = try await SiloAPI.shared.collectionItems(collectionId: collectionId)
            guard !Task.isCancelled,
                  loadGeneration == myGen,
                  SeekIntervalPreferences.activeRequestIdentity() == startIdentity,
                  !ResponseCache.shared.wasInvalidated(cacheKey, after: startToken) else { return }
            ResponseCache.shared.set(response, for: cacheKey, fetchedAt: startToken)
            items = response.items
        } catch let err {
            guard !(err is CancellationError),
                  !Task.isCancelled,
                  loadGeneration == myGen,
                  SeekIntervalPreferences.activeRequestIdentity() == startIdentity,
                  !ResponseCache.shared.wasInvalidated(cacheKey, after: startToken) else { return }
            if items.isEmpty {
                self.error = ErrorState(err)
            }
        }
    }
}
