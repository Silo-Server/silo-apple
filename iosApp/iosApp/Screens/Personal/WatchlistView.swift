import SwiftUI

/// Grid of items in the user's watchlist.
struct WatchlistView: View {
    let showsNavigationTitle: Bool

    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var error: ErrorState?
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var hSize

    private var columns: [GridItem] {
        AdaptiveColumns.posters(for: hSize)
    }

    init(showsNavigationTitle: Bool = true) {
        self.showsNavigationTitle = showsNavigationTitle
    }

    var body: some View {
        Group {
            if !items.isEmpty {
                gridContent
            } else if let error {
                ErrorView(state: error, onRetry: { Task { await loadWatchlist() } })
            } else if isLoading {
                // tvOS: this is a pushed destination, so the top menu bar
                // isn't there to hold focus — without a focusable element
                // the remote goes dead until the grid renders.
                Color.clear
                #if os(tvOS)
                    .focusable()
                #endif
            } else {
                EmptyStateView(
                    icon: "bookmark",
                    title: "Watchlist is empty",
                    subtitle: "Tap the bookmark icon on any item to add it here"
                )
            }
        }
        .continuumBackground()
        .modifier(PersonalListNavigationChrome(title: showsNavigationTitle ? "Watchlist" : nil))
        .task {
            await loadWatchlist()
        }
        .refreshable {
            await loadWatchlist()
        }
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(items) { item in
                    MediaCard(
                        title: item.title,
                        posterUrl: item.posterUrl ?? "",
                        thumbhash: item.posterThumbhash,
                        year: item.year,
                        userState: item.userState,
                        overlayData: OverlayData.from(item),
                        action: {
                            router.navigate(to: .itemDetail(contentId: item.contentId))
                        },
                        contentId: item.contentId,
                        onUserStateChanged: { state in
                            guard !state.inWatchlist else { return }
                            withAnimation {
                                items.removeAll { $0.contentId == item.contentId }
                            }
                        }
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(ContinuumTheme.padding)
        }
    }

    private func loadWatchlist() async {
        if items.isEmpty,
           let cached: CatalogResponse = ResponseCache.shared.get(CacheKey.watchlist) {
            items = cached.items
        }
        if items.isEmpty {
            isLoading = true
        }
        error = nil
        do {
            let response: CatalogResponse = try await ContinuumAPI.shared.get(
                "/api/v1/watchlist"
            )
            ResponseCache.shared.set(response, for: CacheKey.watchlist)
            items = response.items
        } catch let err {
            if items.isEmpty {
                self.error = ErrorState(err)
            }
        }
        isLoading = false
    }
}
