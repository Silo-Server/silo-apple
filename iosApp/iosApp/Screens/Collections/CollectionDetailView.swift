import SwiftUI

/// Shows the items within a specific collection.
struct CollectionDetailView: View {
    let collectionId: String
    /// The collection's name, when the page that opened it knows it.
    var title: String? = nil

    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var hasLoadedOnce = false
    @State private var error: ErrorState?
    @State private var refreshError: ErrorState?
    @State private var loadGeneration = 0
    @State private var invalidationGeneration = 0
    @State private var isVisible = false
    @State private var hasPendingInvalidation = false
    @State private var reloadTask: Task<Void, Never>?
    @State private var shuffleLauncher = ShuffleLauncher()
    @Environment(AppRouter.self) private var router
    @Environment(\.locale) private var locale

    var body: some View {
        Group {
            if items.isEmpty, let error {
                ErrorView(state: error, onRetry: { scheduleReload(delay: nil) })
            } else if items.isEmpty && !hasLoadedOnce {
                Color.clear
                    #if os(tvOS)
                    .tvPageFocusOwner(
                        focusRequest: 0,
                        isTopMenuFocused: false,
                        accessibilityLabel: AppLanguage.string(.commonLoading, locale: locale),
                        onMoveUp: nil
                    )
                    #endif
            } else {
                gridContent
            }
        }
        .siloPageBackground()
        .navigationTitle(title.map { Text($0) } ?? Text(.collectionsCollection))
        .siloNavigationTitleDisplayMode(.large)
        .task {
            await loadItems()
        }
        .refreshable {
            reloadTask?.cancel()
            reloadTask = nil
            await loadItems()
        }
        .onAppear {
            isVisible = true
            if hasPendingInvalidation {
                scheduleReload(delay: nil)
            }
        }
        .onDisappear {
            isVisible = false
            reloadTask?.cancel()
            reloadTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .collectionItemsDidChange)) { note in
            guard (note.object as? String) == collectionId else { return }
            invalidationGeneration += 1
            hasPendingInvalidation = true
            if isVisible {
                scheduleReload(delay: .milliseconds(350))
            } else {
                reloadTask?.cancel()
                reloadTask = nil
            }
        }
        .shuffleFailureAlert(shuffleLauncher)
        #if os(tvOS)
        .tvActionPopoverHost()
        #endif
    }

    private var gridContent: some View {
        ScrollView {
            HStack(spacing: 12) {
                if !items.isEmpty && ShuffleFeatureStore.shared.supports(.userCollection) {
                    ShuffleButton(isStarting: shuffleLauncher.isStarting) {
                        shuffleLauncher.start(ShuffleScopeRequest(kind: .userCollection, id: collectionId), router: router)
                    }
                }
                CollectionPinActionBar(
                    collectionId: collectionId,
                    title: title,
                    isUserCollection: true
                )
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, SiloTheme.smallPadding)
            #if os(tvOS)
            // Up from any grid column reaches Shuffle & Pin to Home.
            .focusSection()
            #endif
            if let refreshError {
                HStack(spacing: 10) {
                    Label(refreshError.message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button(.commonRetry) {
                        scheduleReload(delay: nil)
                    }
                    .font(.footnote.weight(.semibold))
                    #if os(tvOS)
                    .buttonStyle(.bordered)
                    #endif
                }
                .padding(.horizontal, SiloTheme.padding)
                .padding(.top, SiloTheme.smallPadding)
            }
            if items.isEmpty {
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .padding(.vertical, SiloTheme.largePadding)
                } else {
                    EmptyStateView(
                        icon: "square.stack",
                        title: AppLanguage.string(.collectionsEmptyItemsTitle, locale: locale),
                        subtitle: AppLanguage.string(.collectionsEmptyItemsHint, locale: locale)
                    )
                    .padding(.top, SiloTheme.largePadding)
                }
            } else {
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
    }

    private func scheduleReload(delay: Duration?) {
        reloadTask?.cancel()
        reloadTask = Task {
            if let delay {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await loadItems()
        }
    }

    private func loadItems() async {
        loadGeneration += 1
        let myGen = loadGeneration
        let startInvalidationGen = invalidationGeneration
        let startIdentity = SeekIntervalPreferences.activeRequestIdentity()
        let startToken = ResponseCache.shared.writeToken
        // Hydrate from cache so a return visit paints the previous grid
        // instantly while the silent revalidate runs.
        let cacheKey = CacheKey.collectionItems(collectionId)
        if items.isEmpty,
           let cached: CatalogResponse = ResponseCache.shared.get(cacheKey) {
            items = cached.items
            if !items.isEmpty {
                hasLoadedOnce = true
            }
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
        refreshError = nil
        do {
            let response = try await SiloAPI.shared.collectionItems(collectionId: collectionId)
            guard !Task.isCancelled,
                  loadGeneration == myGen,
                  invalidationGeneration == startInvalidationGen,
                  SeekIntervalPreferences.activeRequestIdentity() == startIdentity,
                  !ResponseCache.shared.wasInvalidated(cacheKey, after: startToken) else { return }
            ResponseCache.shared.set(response, for: cacheKey, fetchedAt: startToken)
            items = response.items
            hasLoadedOnce = true
            error = nil
            refreshError = nil
            hasPendingInvalidation = false
        } catch let err {
            guard !(err is CancellationError),
                  !Task.isCancelled,
                  loadGeneration == myGen,
                  invalidationGeneration == startInvalidationGen,
                  SeekIntervalPreferences.activeRequestIdentity() == startIdentity,
                  !ResponseCache.shared.wasInvalidated(cacheKey, after: startToken) else { return }
            if items.isEmpty && !hasLoadedOnce {
                self.error = ErrorState(err)
            } else {
                self.refreshError = ErrorState(err)
                self.hasPendingInvalidation = true
            }
        }
    }
}
