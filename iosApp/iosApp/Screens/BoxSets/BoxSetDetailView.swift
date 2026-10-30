import SwiftUI

/// One movie box set: the movies TMDB lists in one collection that the viewer
/// can see in one library, in release order. Built on the movie detail page's
/// surfaces (`PhoneDetailPageSurface` + `PhoneDetailHero` on iOS and macOS,
/// `TVDetailPageSurface` + `TVDetailHero` on tvOS): the hero carries the box
/// set's artwork, title, film count, years and overview, and Play starts the
/// first movie the profile has not played. The movies follow as a grid.
struct BoxSetDetailView: View {
    @State private var viewModel: BoxSetDetailViewModel
    @Environment(AppRouter.self) private var router
    /// Closes the whole detail card; set when this page is the card's root.
    private let onClose: (() -> Void)?
    #if !os(tvOS)
    @State private var scrollState = PhoneDetailScrollState()
    #endif
    #if os(tvOS)
    @FocusState private var playFocused: Bool
    #endif

    init(id: String, libraryId: Int, onClose: (() -> Void)? = nil) {
        _viewModel = State(initialValue: BoxSetDetailViewModel(id: id, libraryId: libraryId))
        self.onClose = onClose
    }

    var body: some View {
        Group {
            if let detail = viewModel.detail {
                loadedContent(detail)
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await viewModel.load() } }, onGoBack: goBackAction)
                    .siloPageBackground()
            } else {
                loadingContent
            }
        }
        // Runs again whenever the page reappears (back from one of its movies),
        // so watched counts and the next movie stay current.
        .task { await viewModel.load() }
        .onChange(of: router.presentedPlayer == nil) { _, playerClosed in
            if playerClosed { Task { await viewModel.load() } }
        }
        .environment(\.browseLibraryId, viewModel.libraryId)
        .animation(.smooth(duration: 0.3), value: viewModel.detail == nil)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) { topControls }
        #elseif os(macOS)
        .navigationTitle(viewModel.detail?.boxSet.title ?? "")
        #endif
    }

    @ViewBuilder
    private var loadingContent: some View {
        #if os(tvOS)
        TVItemDetailLoadingView(seed: nil)
        #else
        Color.clear
            .siloPageBackground()
        #endif
    }

    @ViewBuilder
    private func loadedContent(_ detail: CatalogBoxSetDetail) -> some View {
        #if os(tvOS)
        tvContent(detail)
        #else
        phoneContent(detail)
        #endif
    }

    private func play(_ movie: BrowseItem) {
        // The player resumes an in-progress movie from the server's position.
        router.presentPlayer(
            contentId: movie.contentId,
            libraryId: viewModel.libraryId,
            posterURL: movie.posterUrl,
            backdropURL: movie.backdropUrl
        )
    }

    private func openMovie(_ movie: BrowseItem) {
        router.navigate(to: .itemDetail(browseItem: movie, libraryId: viewModel.libraryId))
    }

    /// Close the card at its root, or step back inside it or the stack.
    private var goBackAction: (() -> Void)? {
        if let onClose { return onClose }
        #if os(iOS)
        if !router.itemDetailPath.isEmpty { return { router.itemDetailPath.removeLast() } }
        #endif
        return router.path.isEmpty ? nil : { router.goBack() }
    }

    // MARK: - iOS / macOS

    #if !os(tvOS)
    private func phoneContent(_ detail: CatalogBoxSetDetail) -> some View {
        PhoneDetailPageSurface(
            backdropURL: detail.boxSet.backdropUrl,
            backdropThumbhash: detail.boxSet.backdropThumbhash,
            enablesArtworkGlass: true,
            keepsSideSafeArea: true
        ) {
            PhoneDetailPageLayout(scrollState: scrollState) {
                VStack(alignment: .leading, spacing: 32) {
                    phoneHero(detail)
                    phoneMovies(detail)
                }
                .padding(.bottom, 40)
            } paneArtwork: {
                phoneHero(detail, pane: .artwork)
            } paneSidebar: {
                phoneHero(detail, pane: .sidebar)
            } paneContent: {
                VStack(alignment: .leading, spacing: 32) {
                    phoneHero(detail, pane: .overview)
                        .padding(.horizontal, SiloTheme.safePadding)
                    phoneMovies(detail)
                }
                .padding(.bottom, 40)
            }
        }
    }

    private func phoneHero(_ detail: CatalogBoxSetDetail, pane: PhoneDetailHeroPane? = nil) -> some View {
        PhoneDetailHero(
            title: detail.boxSet.title,
            logoUrl: nil,
            posterUrl: detail.boxSet.posterUrl,
            posterThumbhash: detail.boxSet.posterThumbhash,
            backdropUrl: detail.boxSet.backdropUrl,
            backdropThumbhash: detail.boxSet.backdropThumbhash,
            // The compact hero draws no eyebrow; its outlined chip shows in
            // every layout, so the label rides there.
            eyebrow: nil,
            sourceTokens: [],
            ratingChip: "BOX SET",
            overview: detail.boxSet.overview,
            factsLine: detail.factTokens.map { PhoneHeroFactToken.text($0) },
            overlayData: nil,
            enablesArtworkParallax: true,
            pane: pane,
            // A shorter hero than a title's, so the movies start on the
            // first screen.
            compactArtworkHeightFactor: 0.62,
            fitsRegularHeroToContent: true,
            actions: {
                if let movie = detail.nextMovie, let label = detail.playLabel {
                    PhonePrimaryPillButton(
                        icon: "play.fill",
                        title: label,
                        action: { play(movie) },
                        fullWidth: true
                    )
                }
            },
            belowOverview: { EmptyView() }
        )
    }

    private func phoneMovies(_ detail: CatalogBoxSetDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            PhoneSectionHeader(title: "Movies")
            CatalogGrid(
                items: detail.items,
                isLoading: false,
                hasMore: false,
                onItemTap: openMovie,
                onLoadMore: {}
            )
        }
        .padding(.horizontal, SiloTheme.safePadding)
    }
    #endif

    #if os(iOS)
    private var topControls: some View {
        let showsClose = onClose != nil
        let showsBack = !showsClose && (!router.itemDetailPath.isEmpty || !router.path.isEmpty)
        return PhoneDetailTopChrome(
            title: viewModel.detail?.boxSet.title ?? "",
            isScrollGlassEnabled: viewModel.detail != nil,
            scrollState: scrollState,
            leadingSystemName: showsClose ? "xmark" : (showsBack ? "chevron.left" : nil),
            leadingAccessibilityLabel: showsClose ? "Close details" : (showsBack ? "Back" : nil),
            onLeadingTap: { goBackAction?() },
            trailingSystemName: nil,
            onTrailingTap: nil
        )
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private func tvContent(_ detail: CatalogBoxSetDetail) -> some View {
        TVDetailPageSurface(backdropURL: detail.boxSet.backdropUrl) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    TVDetailHero(
                        title: detail.boxSet.title,
                        logoUrl: nil,
                        backdropUrl: detail.boxSet.backdropUrl,
                        backdropThumbhash: detail.boxSet.backdropThumbhash,
                        eyebrow: "Box set",
                        sourceTokens: [],
                        ratingChip: nil,
                        overview: detail.boxSet.overview,
                        factsLine: detail.factTokens.map { TVHeroFactToken.text($0) },
                        starringText: nil,
                        playbackSummary: TVPlaybackSelectionSummary(version: nil, audio: nil, subtitles: nil),
                        showsPlaybackSummary: false,
                        actions: { tvActions(detail) },
                        belowSynopsis: { EmptyView() }
                    )

                    VStack(alignment: .leading, spacing: TVDetailLayout.sectionHeaderSpacing) {
                        TVSectionHeader(title: "Movies")
                        TVCatalogGrid(
                            items: detail.items,
                            isLoading: false,
                            hasMore: false,
                            onItemTap: openMovie,
                            onNearEnd: { _ in },
                            columnCount: 6,
                            cardWidth: 220
                        )
                    }
                    .padding(.horizontal, TVDetailLayout.horizontalInset)
                    .padding(.bottom, TVDetailLayout.pageBottomPadding)
                }
            }
            .ignoresSafeArea()
            // Play is the page's first stop; Down moves into the movies.
            .defaultFocus($playFocused, true, priority: .userInitiated)
        }
    }

    @ViewBuilder
    private func tvActions(_ detail: CatalogBoxSetDetail) -> some View {
        if let movie = detail.nextMovie {
            HStack(spacing: 18) {
                TVPrimaryPillButton(
                    icon: "play.fill",
                    title: detail.playVerb,
                    subtitle: movie.title,
                    stabilizesFocusMotion: true,
                    action: { play(movie) },
                    focused: $playFocused
                )
            }
            .focusSection()
        }
    }
    #endif
}
