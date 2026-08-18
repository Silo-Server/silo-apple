import SwiftUI

/// Which saved list a ``PersonalListGridView`` renders. Both lists share the
/// same grid, loading, and removal behavior; they differ only in copy, cache
/// key, endpoint, and which user-state flag keeps an item in the grid.
enum PersonalListKind: Hashable {
    case favorites
    case watchlist

    var navigationTitle: String {
        switch self {
        case .favorites: return "Favorites"
        case .watchlist: return "Watchlist"
        }
    }

    var emptyIcon: String {
        switch self {
        case .favorites: return "heart"
        case .watchlist: return "bookmark"
        }
    }

    var emptyTitle: String {
        switch self {
        case .favorites: return "No favorites"
        case .watchlist: return "Watchlist is empty"
        }
    }

    var emptySubtitle: String {
        switch self {
        case .favorites: return "Tap the heart icon on any item to add it here"
        case .watchlist: return "Tap the bookmark icon on any item to add it here"
        }
    }

    var cacheKey: String {
        switch self {
        case .favorites: return CacheKey.favorites
        case .watchlist: return CacheKey.watchlist
        }
    }

    /// Whether an item carrying `state` still belongs in this list.
    func contains(_ state: MediaItemUserState) -> Bool {
        switch self {
        case .favorites: return state.isFavorite
        case .watchlist: return state.inWatchlist
        }
    }
}

/// Grid of one of the user's saved lists.
struct PersonalListGridView: View {
    let kind: PersonalListKind
    let showsNavigationTitle: Bool

    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var error: ErrorState?
    @State private var uiCustomization = UICustomizationPreferences.shared
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var hSize

    private var columns: [GridItem] {
        AdaptiveColumns.posters(
            for: hSize,
            posterSize: uiCustomization.cardPresentation.posterSize
        )
    }

    init(kind: PersonalListKind, showsNavigationTitle: Bool = true) {
        self.kind = kind
        self.showsNavigationTitle = showsNavigationTitle
    }

    var body: some View {
        Group {
            if !items.isEmpty {
                gridContent
            } else if let error {
                ErrorView(state: error, onRetry: { Task { await load() } })
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
                    icon: kind.emptyIcon,
                    title: kind.emptyTitle,
                    subtitle: kind.emptySubtitle
                )
            }
        }
        .siloBackground()
        .modifier(PersonalListNavigationChrome(title: showsNavigationTitle ? kind.navigationTitle : nil))
        .task {
            await load()
        }
        .refreshable {
            await load()
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
                        playAction: router.playAction(for: item),
                        contentId: item.contentId,
                        onUserStateChanged: { state in
                            guard !kind.contains(state) else { return }
                            withAnimation {
                                items.removeAll { $0.contentId == item.contentId }
                            }
                        }
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(SiloTheme.padding)
        }
    }

    private func load() async {
        if items.isEmpty,
           let cached: CatalogResponse = ResponseCache.shared.get(kind.cacheKey) {
            items = cached.items
        }
        if items.isEmpty {
            isLoading = true
        }
        error = nil
        do {
            let response: CatalogResponse
            switch kind {
            case .favorites:
                response = try await SiloAPI.shared.favorites(offset: 0, limit: 100)
            case .watchlist:
                response = try await SiloAPI.shared.watchlist(offset: 0, limit: 100)
            }
            ResponseCache.shared.set(response, for: kind.cacheKey)
            items = response.items
        } catch let err {
            if items.isEmpty {
                self.error = ErrorState(err)
            }
        }
        isLoading = false
    }
}
