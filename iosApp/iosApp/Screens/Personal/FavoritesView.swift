import SwiftUI

#if os(iOS)
/// Shared iPhone/iPad filter used by Favorites and Watchlist. Keeping the
/// picker and inclusion rules in one place guarantees both saved-list screens
/// retain identical tabs and grid geometry.
enum IOSPersonalMediaSection: String, CaseIterable, Identifiable {
    case movies = "Movies"
    case tvShows = "TV Shows"

    var id: Self { self }

    func includes(_ item: BrowseItem) -> Bool {
        switch self {
        case .movies:
            return SiloMediaType.isMovieLibrary(item.type)
        case .tvShows:
            return SiloMediaType.isSeries(item.type)
                || item.type.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare("episode") == .orderedSame
        }
    }
}

struct IOSPersonalMediaSectionPicker: View {
    @Binding var selection: IOSPersonalMediaSection

    var body: some View {
        Picker("Media type", selection: $selection) {
            ForEach(IOSPersonalMediaSection.allCases) { section in
                Text(section.rawValue).tag(section)
            }
        }
        .pickerStyle(.segmented)
        .tint(.white)
        .accessibilityLabel("Saved media type")
    }
}

/// Saved titles use compact, Home-like rails rather than stretching two cards
/// across an iPhone. Six titles is the maximum membership of one rail; larger
/// lists continue in as many vertically stacked rails as needed.
struct IOSPersonalMediaCarouselRows: View {
    let items: [BrowseItem]
    let onUserStateChanged: (BrowseItem, MediaItemUserState) -> Void

    @Environment(AppRouter.self) private var router
    @State private var originID = UUID().uuidString
    @State private var rowScrollPositions: [Int: String] = [:]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, rowItems in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: HomeFeedMetrics.cardSpacing) {
                        ForEach(rowItems) { item in
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
                                    onUserStateChanged(item, state)
                                }
                            )
                            .id(item.contentId)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                .scrollPosition(
                    id: rowScrollPositionBinding(for: rowIndex),
                    anchor: .center
                )
                .scrollClipDisabled()
                .environment(
                    \.itemDetailBrowseSource,
                    ItemDetailBrowseSource(
                        originID: rowOriginID(rowIndex),
                        contentIDs: rowItems.map(\.contentId)
                    )
                )
            }
        }
        .onChange(of: router.presentedItemDetail) { _, presentation in
            guard let sourceID = presentation?.browseSource?.originID,
                  let contentID = presentation?.contentId,
                  let rowIndex = rows.indices.first(where: {
                      rowOriginID($0) == sourceID
                  }) else { return }

            withAnimation(.easeInOut(duration: 0.28)) {
                rowScrollPositions[rowIndex] = contentID
            }
        }
    }

    private var rows: [[BrowseItem]] {
        stride(from: 0, to: items.count, by: 6).map { start in
            let end = min(start + 6, items.count)
            return Array(items[start..<end])
        }
    }

    private func rowOriginID(_ rowIndex: Int) -> String {
        "\(originID):\(rowIndex)"
    }

    private func rowScrollPositionBinding(for rowIndex: Int) -> Binding<String?> {
        Binding(
            get: { rowScrollPositions[rowIndex] },
            set: { rowScrollPositions[rowIndex] = $0 }
        )
    }
}
#endif

/// Grid of the user's favorited items.
struct FavoritesView: View {
    let showsNavigationTitle: Bool

    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var error: ErrorState?
    @State private var uiCustomization = UICustomizationPreferences.shared
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var hSize
    #if os(iOS)
    @State private var selectedSection: IOSPersonalMediaSection = .movies
    #endif

    private var columns: [GridItem] {
        AdaptiveColumns.posters(
            for: hSize,
            posterSize: uiCustomization.cardPresentation.posterSize
        )
    }

    init(showsNavigationTitle: Bool = true) {
        self.showsNavigationTitle = showsNavigationTitle
    }

    #if os(iOS)
    private var iosGridContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                IOSPersonalMediaSectionPicker(selection: $selectedSection)

                if filteredIOSItems.isEmpty {
                    iosSelectedSectionEmptyState
                } else {
                    IOSPersonalMediaCarouselRows(items: filteredIOSItems) { item, state in
                        guard !state.isFavorite else { return }
                        withAnimation {
                            items.removeAll { $0.contentId == item.contentId }
                        }
                    }
                }
            }
            .padding(ContinuumTheme.padding)
        }
    }

    private var filteredIOSItems: [BrowseItem] {
        items.filter(selectedSection.includes)
    }

    private var iosSelectedSectionEmptyState: some View {
        ContentUnavailableView(
            "No Favorite \(selectedSection.rawValue)",
            systemImage: selectedSection == .movies ? "film" : "tv",
            description: Text("Add favorites from a detail page and they will appear here.")
        )
        .frame(maxWidth: .infinity, minHeight: 360)
    }
    #endif

    var body: some View {
        Group {
            if !items.isEmpty {
                #if os(iOS)
                iosGridContent
                #else
                gridContent
                #endif
            } else if let error {
                ErrorView(state: error, onRetry: { Task { await loadFavorites() } })
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
                    icon: "heart",
                    title: "No favorites",
                    subtitle: "Tap the heart icon on any item to add it here"
                )
            }
        }
        .continuumBackground()
        .modifier(PersonalListNavigationChrome(title: showsNavigationTitle ? "Favorites" : nil))
        .task {
            await loadFavorites()
        }
        .refreshable {
            await loadFavorites()
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
                        playAction: playAction(for: item),
                        contentId: item.contentId,
                        onUserStateChanged: { state in
                            guard !state.isFavorite else { return }
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

    private func loadFavorites() async {
        if items.isEmpty,
           let cached: CatalogResponse = ResponseCache.shared.get(CacheKey.favorites) {
            items = cached.items
        }
        if items.isEmpty {
            isLoading = true
        }
        error = nil
        do {
            let response: CatalogResponse = try await ContinuumAPI.shared.get(
                "/api/v1/favorites"
            )
            ResponseCache.shared.set(response, for: CacheKey.favorites)
            items = response.items
        } catch let err {
            if items.isEmpty {
                self.error = ErrorState(err)
            }
        }
        isLoading = false
    }
}
