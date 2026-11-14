import SwiftUI

/// Movies / TV Shows split for the saved-list screens (Favorites and
/// Watchlist on iOS, Favorites on tvOS).
enum PersonalMediaSection: CaseIterable, Identifiable {
    case movies
    case tvShows

    var id: Self { self }

    var label: LocalizedStringResource {
        switch self {
        case .movies: .personalFilterMovies
        case .tvShows: .personalFilterTvShows
        }
    }

    func includes(_ item: BrowseItem) -> Bool {
        includes(type: item.type)
    }

    func includes(type: String) -> Bool {
        switch self {
        case .movies:
            return SiloMediaType.isMovieLibrary(type)
        case .tvShows:
            return SiloMediaType.isSeries(type) || SiloMediaType.isEpisode(type)
        }
    }
}

/// All / Movies / TV Shows: what the iPhone For You tab's dock narrows its
/// pages to.
enum PersonalMediaFilter: String, CaseIterable, Identifiable {
    case all
    case movies
    case tvShows

    var id: Self { self }

    var label: LocalizedStringResource {
        switch self {
        case .all: .searchFilterAll
        case .movies: .personalFilterMovies
        case .tvShows: .personalFilterTvShows
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.stack.3d.up"
        case .movies: "film"
        case .tvShows: "tv"
        }
    }

    /// The Movies / TV Shows split this narrows to; nil keeps everything.
    private var section: PersonalMediaSection? {
        switch self {
        case .all: nil
        case .movies: .movies
        case .tvShows: .tvShows
        }
    }

    func includes(type: String) -> Bool {
        section?.includes(type: type) ?? true
    }

    func includes(_ item: BrowseItem) -> Bool {
        includes(type: item.type)
    }

    /// "9 movies", "6 shows", "14 titles": how many titles are showing.
    func countLabel(_ count: Int) -> LocalizedStringResource {
        let text = LocaleFormat.groupedCount(count)
        switch self {
        case .all: return .libraryTitleCount(count: count, text)
        case .movies: return .libraryCollectionCardMovies(count: count, text)
        case .tvShows: return .libraryCollectionCardShows(count: count, text)
        }
    }
}

/// Makes a saved list a page of the iPhone For You tab: the tab's dock
/// picks the type, so the list shows no picker of its own, and the tab's
/// header shows the count the list reports.
struct PersonalListDockPage {
    let filter: PersonalMediaFilter
    /// Bumped each time the page is switched to, so the list reads again,
    /// as a screen pushed afresh would.
    let reloadRequest: Int
    /// How many titles are showing; nil until the list has loaded.
    let onCount: (Int?) -> Void
}

#if os(iOS)
/// Shared iPhone/iPad picker used by Favorites and Watchlist, so both
/// saved-list screens keep identical tabs.
struct IOSPersonalMediaSectionPicker: View {
    @Binding var selection: PersonalMediaSection

    var body: some View {
        Picker(selection: $selection) {
            ForEach(PersonalMediaSection.allCases) { section in
                Text(section.label).tag(section)
            }
        } label: {
            Text(.personalMediaType)
        }
        .pickerStyle(.segmented)
        .tint(.white)
        .accessibilityLabel(Text(.personalMediaTypeAccessibility))
    }
}

/// Saved titles use a three-column poster grid on iPhone, with more columns in
/// phone windows too wide for three-up (the iPhone Duo's inner display). iPad
/// retains the wider Home-like rails that make better use of its additional
/// width.
struct IOSPersonalMediaPosterLayout: View {
    let items: [BrowseItem]
    let onUserStateChanged: (BrowseItem, MediaItemUserState) -> Void

    @Environment(AppRouter.self) private var router
    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var gridWidth: CGFloat = 0
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @ViewBuilder
    var body: some View {
        if UIDevice.current.userInterfaceIdiom == .phone {
            phoneGrid
        } else {
            tabletCarouselRows
        }
    }

    private var phoneGrid: some View {
        LazyVGrid(columns: phoneColumns, spacing: 12) {
            ForEach(items) { item in
                MediaCard(
                    title: item.title,
                    posterUrl: item.posterUrl ?? "",
                    thumbhash: item.posterThumbhash,
                    episodeWatchState: item.isEpisodeItem ? EpisodeWatchState(browseItem: item) : nil,
                    imageIsEpisodeStill: item.posterIsEpisodeStill,
                    mediaType: item.type,
                    year: item.year,
                    userState: item.userState,
                    overlayData: OverlayData.from(item),
                    action: {
                        router.navigate(to: .itemDetail(contentId: item.contentId))
                    },
                    contentId: item.contentId,
                    cardWidthOverride: phoneCardWidthOverride,
                    onUserStateChanged: { state in
                        onUserStateChanged(item, state)
                    }
                )
                .frame(maxWidth: .infinity)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard abs(width - gridWidth) >= 0.5 else { return }
            gridWidth = width
        }
    }

    private var tabletCarouselRows: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, rowItems in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: HomeFeedMetrics.cardSpacing) {
                        ForEach(rowItems) { item in
                            MediaCard(
                                title: item.title,
                                posterUrl: item.posterUrl ?? "",
                                thumbhash: item.posterThumbhash,
                                episodeWatchState: item.isEpisodeItem ? EpisodeWatchState(browseItem: item) : nil,
                                imageIsEpisodeStill: item.posterIsEpisodeStill,
                                mediaType: item.type,
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
                .mediaRailScrolling()
                .scrollClipDisabled()
            }
        }
    }

    /// Three-up, or more columns once the phone window is too wide for that
    /// (the iPhone Duo's inner display).
    private var phoneColumns: [GridItem] {
        if let fit = widePhonePosterFit {
            return fit.columns
        }
        return Array(
            repeating: GridItem(.flexible(), spacing: 8, alignment: .top),
            count: 3
        )
    }

    private var widePhonePosterFit: AdaptiveColumns.PosterGridFit? {
        AdaptiveColumns.widePhonePosterFit(
            containerWidth: gridWidth,
            posterSize: uiCustomization.cardPresentation.posterSize,
            verticalSizeClass: verticalSizeClass
        )
    }

    /// MediaCard scales overrides by the selected global preference. Cancel
    /// that scale, then cap the standard width to the measured grid cell.
    private var phoneCardWidthOverride: CGFloat {
        if let fit = widePhonePosterFit {
            return fit.cardWidth / uiCustomization.cardPresentation.posterSize.scale
        }
        return AdaptiveColumns.fittedPosterWidth(
            containerWidth: gridWidth,
            columnCount: 3,
            spacing: 8
        ) / uiCustomization.cardPresentation.posterSize.scale
    }

    private var rows: [[BrowseItem]] {
        stride(from: 0, to: items.count, by: 6).map { start in
            let end = min(start + 6, items.count)
            return Array(items[start..<end])
        }
    }
}
#endif

/// Grid of the user's favorited items.
struct FavoritesView: View {
    let showsNavigationTitle: Bool
    let usesTVTopMenu: Bool
    var focusRequest: Int
    var isTopMenuFocused: Bool
    var onTopMenuFocusRequest: (() -> Void)?
    /// Set when the list is a page of the iPhone For You tab.
    var dockPage: PersonalListDockPage?

    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var error: ErrorState?
    /// Counts loads, so a reply overtaken by a later load is dropped.
    @State private var loadGeneration = 0
    @State private var uiCustomization = UICustomizationPreferences.shared
    #if os(tvOS)
    @State private var selectedSection: PersonalMediaSection = .movies
    @FocusState private var focusedSection: PersonalMediaSection?
    @State private var lastAppliedFocusRequest = 0
    #endif
    @Environment(AppRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.locale) private var locale
    #if os(iOS)
    @State private var selectedSection: PersonalMediaSection = .movies
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
        onTopMenuFocusRequest: (() -> Void)? = nil,
        dockPage: PersonalListDockPage? = nil
    ) {
        self.dockPage = dockPage
        self.showsNavigationTitle = showsNavigationTitle
        self.usesTVTopMenu = usesTVTopMenu
        self.focusRequest = focusRequest
        self.isTopMenuFocused = isTopMenuFocused
        self.onTopMenuFocusRequest = onTopMenuFocusRequest
    }

    #if os(iOS)
    private var iosGridContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                let visibleItems = filteredIOSItems
                if dockPage == nil {
                    IOSPersonalMediaSectionPicker(selection: $selectedSection)
                }

                if visibleItems.isEmpty {
                    iosSelectedSectionEmptyState
                } else {
                    IOSPersonalMediaPosterLayout(items: visibleItems) { item, state in
                        guard !state.isFavorite else { return }
                        withAnimation {
                            items.removeAll { $0.contentId == item.contentId }
                        }
                    }
                }
            }
            .padding(SiloTheme.padding)
        }
        .reportsPageChromeScroll()
        .scrollsToTopOnLibraryDockRequest()
    }

    private var filteredIOSItems: [BrowseItem] {
        if let dockPage { return items.filter(dockPage.filter.includes) }
        return items.filter(selectedSection.includes)
    }

    /// Movies or TV Shows, whichever the picker or the dock narrows to.
    private var iosShowsMovies: Bool {
        if let dockPage { return dockPage.filter == .movies }
        return selectedSection == .movies
    }

    /// The count for the For You tab's header; nil until the list loads.
    private var dockCount: Int? {
        guard dockPage != nil, !items.isEmpty || (!isLoading && error == nil) else { return nil }
        return filteredIOSItems.count
    }

    private var iosSelectedSectionEmptyState: some View {
        ContentUnavailableView {
            Label(iosEmptyTitle, systemImage: iosShowsMovies ? "film" : "tv")
        } description: {
            Text(.personalFavoritesEmptyBody)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private var iosEmptyTitle: LocalizedStringResource {
        iosShowsMovies ? .personalFavoritesEmptyMoviesTitle : .personalFavoritesEmptyTvShowsTitle
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
                Color.clear
                #if os(tvOS)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tvPageFocusOwner(
                        focusRequest: focusRequest,
                        isTopMenuFocused: isTopMenuFocused,
                        accessibilityLabel: AppLanguage.string(.personalFavoritesLoading, locale: locale),
                        onMoveUp: onTopMenuFocusRequest
                    )
                #endif
            } else {
                EmptyStateView(
                    icon: "heart",
                    title: AppLanguage.string(.personalFavoritesEmpty, locale: locale),
                    subtitle: AppLanguage.string(.personalFavoritesEmptyTapHint, locale: locale)
                )
                #if os(tvOS)
                .tvPageFocusOwner(
                    focusRequest: focusRequest,
                    isTopMenuFocused: isTopMenuFocused,
                    accessibilityLabel: AppLanguage.string(.personalFavoritesEmpty, locale: locale),
                    onMoveUp: onTopMenuFocusRequest
                )
                #endif
            }
        }
        .siloPageBackground()
        .modifier(PersonalListNavigationChrome(title: showsNavigationTitle ? .personalFavoritesTitle : nil))
        .task {
            await loadFavorites()
        }
        .refreshable {
            await loadFavorites()
        }
        #if os(iOS)
        .onChange(of: dockPage?.reloadRequest) {
            Task { await loadFavorites() }
        }
        .onChange(of: dockCount, initial: true) {
            dockPage?.onCount(dockCount)
        }
        #endif
        #if os(tvOS)
        .onChange(of: items.map(\.contentId)) { _, _ in applyFocusRequest(focusRequest) }
        #endif
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
                        episodeWatchState: item.isEpisodeItem ? EpisodeWatchState(browseItem: item) : nil,
                        imageIsEpisodeStill: item.posterIsEpisodeStill,
                        mediaType: item.type,
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
            .padding(SiloTheme.padding)
        }
        .reportsPageChromeScroll()
        #endif
    }

    #if os(tvOS)
    private var filteredItems: [BrowseItem] {
        items.filter(selectedSection.includes)
    }

    private var tvGridContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 40) {
                let visibleItems = filteredItems
                if usesTVTopMenu {
                    Text(.personalFavoritesTitle)
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(Color.siloOnSurface)
                }

                sectionSelector

                if visibleItems.isEmpty {
                    selectedSectionEmptyState
                } else {
                    LazyVGrid(
                        columns: columns,
                        alignment: .leading,
                        spacing: 60
                    ) {
                        ForEach(visibleItems) { item in
                            favoriteCard(for: item)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .focusSection()
                }
            }
            .padding(.horizontal, SiloTheme.safePadding)
            .padding(.top, usesTVTopMenu ? TVTopMenuLayout.contentTopInset : 20)
            .padding(.bottom, SiloTheme.safePadding)
        }
        .modifier(TVMenuEntryScroll(request: focusRequest, isTopMenuFocused: isTopMenuFocused, onReady: applyFocusRequest))
    }

    private var sectionSelector: some View {
        HStack(spacing: 14) {
            ForEach(PersonalMediaSection.allCases) { section in
                Button {
                    withAnimation(.easeInOut(duration: SiloTheme.normalDuration)) {
                        selectedSection = section
                    }
                } label: {
                    Text(section.label)
                        .font(.system(size: 24, weight: .semibold))
                        .lineLimit(1)
                }
                .buttonStyle(FavoriteSectionPillStyle(isSelected: selectedSection == section))
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
                .focused($focusedSection, equals: section)
            }

            Spacer(minLength: 0)
        }
        .focusSection()
        .onMoveCommand { direction in
            if direction == .up {
                onTopMenuFocusRequest?()
            }
        }
    }

    private var tvEmptyTitle: LocalizedStringResource {
        selectedSection == .movies ? .personalFavoritesNoMovies : .personalFavoritesNoTvShows
    }

    private var selectedSectionEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: selectedSection == .movies ? "film" : "tv")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Color.siloOnSurface.opacity(0.34))

            Text(tvEmptyTitle)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.siloOnSurface)

            Text(.personalFavoritesEmptyAnyBody)
                .font(.system(size: 22))
                .foregroundStyle(Color.siloSecondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 430)
    }

    private func favoriteCard(for item: BrowseItem) -> some View {
        MediaCard(
            title: item.title,
            posterUrl: item.posterUrl ?? "",
            thumbhash: item.posterThumbhash,
            episodeWatchState: item.isEpisodeItem ? EpisodeWatchState(browseItem: item) : nil,
            imageIsEpisodeStill: item.posterIsEpisodeStill,
            mediaType: item.type,
            year: item.year,
            userState: item.userState,
            overlayData: OverlayData.from(item),
            action: {
                router.navigate(to: .itemDetail(browseItem: item))
            },
            playAction: playAction(for: item),
            contentId: item.contentId,
            cardWidthOverride: tvCardWidthOverride,
            onUserStateChanged: { state in
                guard !state.isFavorite else { return }
                withAnimation(.easeInOut(duration: SiloTheme.normalDuration)) {
                    items.removeAll { $0.contentId == item.contentId }
                }
            }
        )
    }

    /// `MediaCard` applies the global size preference after this override;
    /// divide it out so the final eight-across grid stays at 176 points.
    private var tvCardWidthOverride: CGFloat {
        SiloTheme.Skyline.densePosterCardWidth
            / uiCustomization.cardPresentation.posterSize.scale
    }

    private func applyFocusRequest(_ request: Int) {
        guard usesTVTopMenu,
              request > 0,
              request != lastAppliedFocusRequest,
              !isTopMenuFocused,
              !items.isEmpty else { return }
        lastAppliedFocusRequest = request
        focusedSection = selectedSection
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
        loadGeneration += 1
        let generation = loadGeneration
        if items.isEmpty,
           let cached: CatalogResponse = ResponseCache.shared.get(CacheKey.favorites) {
            items = cached.items
        }
        if items.isEmpty {
            isLoading = true
        }
        error = nil
        do {
            let response = try await SiloAPI.shared.favorites()
            guard generation == loadGeneration else { return }
            ResponseCache.shared.set(response, for: CacheKey.favorites)
            items = response.items
        } catch let err {
            guard generation == loadGeneration else { return }
            if items.isEmpty {
                self.error = ErrorState(err)
            }
        }
        isLoading = false
    }
}

#if os(tvOS)
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
            .foregroundStyle(isFocused ? Color.siloBackground : Color.siloOnSurface)
            .background(
                Capsule().fill(
                    isFocused
                        ? Color.siloOnSurface
                        : (isSelected
                            ? Color.siloChromeSelectedFill
                            : Color.siloChromeRestingFill)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    isFocused
                        ? Color.clear
                        : (isSelected
                            ? Color.siloChromeSelectedBorder
                            : Color.siloChromeRestingBorder),
                    lineWidth: 1
                )
            )
            .scaleEffect(isFocused ? 1.04 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .focusEffectDisabled()
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
    }
}
#endif
