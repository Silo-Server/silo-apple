import SwiftUI

/// Grid of items in the user's watchlist.
struct WatchlistView: View {
    let showsNavigationTitle: Bool
    let usesTVTopMenu: Bool
    var focusRequest: Int
    var isTopMenuFocused: Bool
    var onTopMenuFocusRequest: (() -> Void)?

    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var error: ErrorState?
    @State private var uiCustomization = UICustomizationPreferences.shared
    #if os(iOS)
    @State private var selectedSection: IOSPersonalMediaSection = .movies
    #endif
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var hSize

    #if os(tvOS)
    @FocusState private var focusedContentId: String?
    @State private var lastAppliedFocusRequest = 0
    #endif

    private var columns: [GridItem] {
        #if os(tvOS)
        return Array(
            repeating: GridItem(.flexible(), spacing: 40, alignment: .top),
            count: 8
        )
        #else
        AdaptiveColumns.posters(
            for: hSize,
            posterSize: uiCustomization.cardPresentation.posterSize
        )
        #endif
    }

    init(
        showsNavigationTitle: Bool = true,
        usesTVTopMenu: Bool = false,
        focusRequest: Int = 0,
        isTopMenuFocused: Bool = false,
        onTopMenuFocusRequest: (() -> Void)? = nil
    ) {
        self.showsNavigationTitle = showsNavigationTitle
        self.usesTVTopMenu = usesTVTopMenu
        self.focusRequest = focusRequest
        self.isTopMenuFocused = isTopMenuFocused
        self.onTopMenuFocusRequest = onTopMenuFocusRequest
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
        #if os(tvOS)
        .onAppear { applyFocusRequest(focusRequest) }
        .onChange(of: focusRequest) { _, request in applyFocusRequest(request) }
        .onChange(of: items.map(\.contentId)) { _, _ in applyFocusRequest(focusRequest) }
        #endif
    }

    @ViewBuilder
    private var gridContent: some View {
        #if os(tvOS)
        tvGridContent
        #elseif os(iOS)
        ScrollView {
            VStack(spacing: 16) {
                IOSPersonalMediaSectionPicker(selection: $selectedSection)

                if filteredIOSItems.isEmpty {
                    iosSelectedSectionEmptyState
                } else {
                    IOSPersonalMediaCarouselRows(items: filteredIOSItems) { item, state in
                        guard !state.inWatchlist else { return }
                        withAnimation {
                            items.removeAll { $0.contentId == item.contentId }
                        }
                    }
                }
            }
            .padding(ContinuumTheme.padding)
        }
        #else
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
                            router.navigate(to: .itemDetail(browseItem: item))
                        },
                        playAction: playAction(for: item),
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
        #endif
    }

    #if os(tvOS)
    private var tvGridContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 40) {
                if usesTVTopMenu {
                    Text("Watchlist")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(Color.continuumOnSurface)
                }

                LazyVGrid(columns: columns, alignment: .leading, spacing: 60) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
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
                            playAction: playAction(for: item),
                            focusedItemId: $focusedContentId,
                            contentId: item.contentId,
                            cardWidthOverride: tvCardWidthOverride,
                            onUserStateChanged: { state in
                                guard !state.inWatchlist else { return }
                                withAnimation(.easeInOut(duration: ContinuumTheme.normalDuration)) {
                                    items.removeAll { $0.contentId == item.contentId }
                                }
                            }
                        )
                        .frame(maxWidth: .infinity)
                        .onMoveCommand { direction in
                            if direction == .up, index < columns.count {
                                onTopMenuFocusRequest?()
                            }
                        }
                    }
                }
                .focusSection()
            }
            .padding(.horizontal, ContinuumTheme.safePadding)
            .padding(.top, usesTVTopMenu ? TVTopMenuLayout.contentTopInset : ContinuumTheme.smallPadding)
            .padding(.bottom, ContinuumTheme.safePadding)
        }
    }

    /// Keep the final poster width stable even when the global poster-size
    /// preference is changed—`MediaCard` applies that scale after overrides.
    /// Eight 176-point posters plus 40-point gaps fit the tvOS safe width.
    private var tvCardWidthOverride: CGFloat {
        ContinuumTheme.Skyline.densePosterCardWidth
            / uiCustomization.cardPresentation.posterSize.scale
    }

    private func applyFocusRequest(_ request: Int) {
        guard usesTVTopMenu,
              request > 0,
              request != lastAppliedFocusRequest,
              !isTopMenuFocused,
              let firstId = items.first?.contentId else { return }
        lastAppliedFocusRequest = request
        focusedContentId = firstId
    }
    #elseif os(iOS)
    private var filteredIOSItems: [BrowseItem] {
        items.filter(selectedSection.includes)
    }

    private var iosSelectedSectionEmptyState: some View {
        ContentUnavailableView(
            "No Watchlist \(selectedSection.rawValue)",
            systemImage: selectedSection == .movies ? "film" : "tv",
            description: Text("Add titles from a detail page and they will appear here.")
        )
        .frame(maxWidth: .infinity, minHeight: 360)
    }
    #endif

    private func playAction(for item: BrowseItem) -> (() -> Void)? {
        #if os(tvOS)
        guard SiloMediaType.isDirectlyPlayable(item.type) else { return nil }
        return {
            router.presentPlayer(
                contentId: item.contentId,
                posterURL: item.posterUrl,
                backdropURL: item.backdropUrl
            )
        }
        #else
        return nil
        #endif
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
