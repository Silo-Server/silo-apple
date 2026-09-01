import SwiftUI

/// Full-screen search with debounced query and grid results — Plezy style.
struct SearchView: View {
    @State private var viewModel = SearchViewModel()
    @State private var requestsViewModel = RequestSearchSectionViewModel()
    @State private var navPrefs = AppNavPreferences.shared
    @Environment(AppRouter.self) private var router
    #if os(iOS)
    @FocusState private var isSearchFieldFocused: Bool
    #endif
    private let usesTVTopMenuInset: Bool

    init(usesTVTopMenuInset: Bool = true) {
        self.usesTVTopMenuInset = usesTVTopMenuInset
    }

    var body: some View {
        ScrollView {
            VStack(spacing: ContinuumTheme.padding) {
                if shouldShowFilters {
                    mediaTypeFilter
                    #if os(tvOS)
                        .padding(.horizontal, ContinuumTheme.padding)
                        // The picker is a centered 760pt pill inside a
                        // 1600pt column. Stretch its focus section across
                        // the full row so up-moves from the grid's outer
                        // columns land here instead of skipping straight
                        // to the search field above.
                        .frame(maxWidth: .infinity)
                        .focusSection()
                    #elseif os(macOS)
                        .padding(.horizontal, ContinuumTheme.padding)
                    #endif
                }

                content

                // TMDB titles the library can't answer — the request
                // system's organic entry point. Renders nothing when the
                // server has requests disabled.
                RequestSearchSectionView(viewModel: requestsViewModel)
            }
            .padding(.horizontal, ContinuumTheme.padding)
            #if os(tvOS)
            .padding(.top, usesTVTopMenuInset ? TVTopMenuLayout.contentTopInset : ContinuumTheme.padding)
            #else
            .padding(.top, ContinuumTheme.smallPadding)
            #endif
#if os(tvOS)
            .continuumFormWidth(tvSearchContentWidth)
#endif
        }
        .continuumBackground()
        #if os(tvOS)
        .safeAreaPadding(.horizontal, tvSearchSafeHorizontalPadding)
        #endif
        .navigationTitle("Search")
        .continuumNavigationTitleDisplayMode(.inline)
        .continuumToolbarColorSchemeDark()
        .continuumNavigationBarSurfaceBackground()
        .continuumSearchable(text: $viewModel.query, prompt: searchPrompt)
        #if os(iOS)
        .searchFocused($isSearchFieldFocused)
        .task {
            await focusSearchField()
        }
        #endif
        .onChange(of: viewModel.query) { _, _ in
            viewModel.onQueryChanged()
            requestsViewModel.onQueryChanged(viewModel.query)
        }
        .onChange(of: viewModel.selectedMediaType) { _, _ in
            Task { await viewModel.applyMediaType() }
        }
        .onAppear {
            navPrefs.refresh()
            refreshAudiobookAvailability()
        }
        .onChange(of: navPrefs.showAudiobooks) {
            refreshAudiobookAvailability(applySearch: true)
        }
    }

    /// Whether audiobooks take part in search. On tvOS this mirrors the
    /// Audiobooks tab — an audiobook library exists and the user has opted to
    /// show it — so a hidden audiobook library produces neither a filter chip
    /// nor results under "All". iOS has the same user-facing setting, but
    /// keeps the prior default of showing audiobooks.
    private var audiobooksAvailable: Bool {
        #if os(tvOS)
        guard navPrefs.showAudiobooks else { return false }
        guard let cached: LibrariesResponse = ResponseCache.shared.get(CacheKey.userLibraries) else {
            return false
        }
        return cached.libraries.contains { $0.isAudiobookLibrary }
        #elseif os(iOS)
        return navPrefs.showAudiobooks
        #else
        return true
        #endif
    }

    private var searchPrompt: String {
        audiobooksAvailable
            ? "Search movies, series, audiobooks..."
            : "Search movies and series..."
    }

    private func refreshAudiobookAvailability(applySearch: Bool = false) {
        let previous = viewModel.audiobooksEnabled
        viewModel.audiobooksEnabled = audiobooksAvailable
        guard applySearch, previous != viewModel.audiobooksEnabled else { return }
        Task { await viewModel.applyMediaType() }
    }

    #if os(iOS)
    @MainActor
    private func focusSearchField() async {
        await Task.yield()
        isSearchFieldFocused = true
    }
    #endif

    // MARK: - Shared Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isSearching && viewModel.results.isEmpty {
            Color.clear
        } else if let error = viewModel.error {
            ErrorView(state: error, onRetry: { Task { await viewModel.performSearch() } })
        } else if viewModel.hasSearched && viewModel.results.isEmpty {
            VStack {
                Spacer(minLength: 80)
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No results",
                    subtitle: "Try a different search term"
                )
            }
        } else if viewModel.results.isEmpty {
            VStack {
                Spacer(minLength: 80)
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Search Silo",
                    subtitle: "Find movies and series"
                )
            }
        } else {
            VStack(alignment: .leading, spacing: ContinuumTheme.padding) {
                Text("\(viewModel.total) result\(viewModel.total == 1 ? "" : "s")")
                    .font(.continuumCaption)
                    .foregroundColor(.continuumSecondaryText)

#if os(tvOS)
                TVCatalogGrid(
                    items: viewModel.results,
                    isLoading: viewModel.isSearching,
                    hasMore: viewModel.hasMore,
                    onItemTap: { router.navigate(to: .itemDetail(browseItem: $0)) },
                    onNearEnd: { _ in
                        Task { await viewModel.loadMore() }
                    },
                    columnCount: 6,
                    cardWidth: 220,
                    prefersDefaultFocusOnFirstItem: true
                )
#else
                CatalogGrid(
                    items: viewModel.results,
                    isLoading: viewModel.isSearching,
                    hasMore: viewModel.hasMore,
                    onItemTap: { router.navigate(to: .itemDetail(browseItem: $0)) },
                    onLoadMore: {
                        Task { await viewModel.loadMore() }
                    }
                )
#endif
            }
        }
    }

    private var shouldShowFilters: Bool {
        !viewModel.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder
    private var mediaTypeFilter: some View {
        #if os(iOS)
        HStack {
            SearchMediaTypeMenu(
                selectedMediaType: $viewModel.selectedMediaType,
                availableTypes: viewModel.availableMediaTypes
            )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #else
        mediaTypePicker
        #endif
    }

    private var mediaTypePicker: some View {
        Picker("Media Type", selection: $viewModel.selectedMediaType) {
            ForEach(viewModel.availableMediaTypes) { mediaType in
                Text(mediaType.title)
                    .tag(mediaType)
            }
        }
        .pickerStyle(.segmented)
#if os(tvOS)
        .continuumFormWidth(tvFilterWidth)
#endif
    }

#if os(tvOS)
    /// Search needs a balanced horizontal inset so the page body clears the
    /// collapsed sidebar without shifting the whole screen right.
    private var tvSearchSafeHorizontalPadding: CGFloat { 110 }

    /// Search needs a centered column so the segmented media-type pill and
    /// the poster grid stay visually aligned while still clearing the
    /// collapsed sidebar affordance.
    private var tvSearchContentWidth: CGFloat { 1600 }

    /// Narrower than the results column so the segmented control reads as a
    /// centered pill rather than stretching across the whole search page.
    private var tvFilterWidth: CGFloat { 760 }
#endif
}
