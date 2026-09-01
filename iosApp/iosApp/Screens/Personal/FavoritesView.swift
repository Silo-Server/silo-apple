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
    #if os(tvOS)
    @State private var selectedSection: FavoriteMediaSection = .movies
    #endif
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var hSize
    #if os(iOS)
    @State private var selectedSection: IOSPersonalMediaSection = .movies
    #endif

    private var columns: [GridItem] {
        #if os(tvOS)
        let count = AdaptiveColumns.tvPosterCount(
            standardCount: 6,
            posterSize: uiCustomization.cardPresentation.posterSize
        )
        return Array(
            repeating: GridItem(.flexible(), spacing: 48, alignment: .top),
            count: count
        )
        #else
        AdaptiveColumns.posters(
            for: hSize,
            posterSize: uiCustomization.cardPresentation.posterSize
        )
        #endif
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

    @ViewBuilder
    private var gridContent: some View {
        #if os(tvOS)
        tvGridContent
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
        #endif
    }

    #if os(tvOS)
    private var filteredItems: [BrowseItem] {
        items.filter(selectedSection.includes)
    }

    private var tvGridContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 40) {
                sectionSelector

                if filteredItems.isEmpty {
                    selectedSectionEmptyState
                } else {
                    LazyVGrid(
                        columns: columns,
                        alignment: .leading,
                        spacing: 60
                    ) {
                        ForEach(filteredItems) { item in
                            favoriteCard(for: item)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .focusSection()
                }
            }
            .padding(.horizontal, ContinuumTheme.safePadding)
            .padding(.top, 20)
            .padding(.bottom, ContinuumTheme.safePadding)
        }
    }

    private var sectionSelector: some View {
        HStack(spacing: 14) {
            ForEach(FavoriteMediaSection.allCases) { section in
                Button {
                    withAnimation(.easeInOut(duration: ContinuumTheme.normalDuration)) {
                        selectedSection = section
                    }
                } label: {
                    Text(section.rawValue)
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(1)
                }
                .buttonStyle(FavoriteSectionPillStyle(isSelected: selectedSection == section))
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }

            Spacer(minLength: 0)
        }
        .focusSection()
    }

    private var selectedSectionEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: selectedSection == .movies ? "film" : "tv")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Color.continuumOnSurface.opacity(0.34))

            Text("No favorite \(selectedSection.rawValue.lowercased())")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.continuumOnSurface)

            Text("Add favorites from any detail page and they will appear here.")
                .font(.system(size: 22))
                .foregroundStyle(Color.continuumSecondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 430)
    }

    private func favoriteCard(for item: BrowseItem) -> some View {
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
            cardWidthOverride: 252,
            onUserStateChanged: { state in
                guard !state.isFavorite else { return }
                withAnimation(.easeInOut(duration: ContinuumTheme.normalDuration)) {
                    items.removeAll { $0.contentId == item.contentId }
                }
            }
        )
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

#if os(tvOS)
private enum FavoriteMediaSection: String, CaseIterable, Identifiable {
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

private struct FavoriteSectionPillStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        FavoriteSectionPillBody(
            configuration: configuration,
            isSelected: isSelected
        )
    }
}

private struct FavoriteSectionPillBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .foregroundStyle(isFocused ? Color.continuumBackground : Color.continuumOnSurface)
            .background(
                Capsule().fill(
                    isFocused
                        ? Color.continuumOnSurface
                        : (isSelected
                            ? Color.continuumChromeSelectedFill
                            : Color.continuumChromeRestingFill)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    isFocused
                        ? Color.clear
                        : (isSelected
                            ? Color.continuumChromeSelectedBorder
                            : Color.continuumChromeRestingBorder),
                    lineWidth: 1
                )
            )
            .scaleEffect(isFocused ? 1.04 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .focusEffectDisabled()
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
    }
}
#endif
