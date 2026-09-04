import SwiftUI

/// The Requests hub: search TMDB to request (primary interaction), the
/// user's own requests one glance down, then the discover carousels for
/// lean-back wishlisting. Reached from the profile avatar menu (iOS) or the
/// profile dropdown (tvOS); both entry points are hidden unless the server
/// reports `requests_enabled`.
struct RequestsHubView: View {
    @State private var viewModel = RequestsHubViewModel()
    @State private var uiCustomization = UICustomizationPreferences.shared
    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SiloTheme.largePadding) {
                content
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, SiloTheme.smallPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .siloPageBackground()
        #if os(tvOS)
        .safeAreaPadding(.horizontal, 40)
        #endif
        .navigationTitle("Requests")
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .siloNavigationBarSurfaceBackground()
        .siloSearchable(text: $viewModel.query, prompt: "Search movies & series to request")
        .task {
            await viewModel.load()
        }
        #if !os(tvOS)
        .refreshable {
            await viewModel.load()
        }
        #endif
        .onChange(of: viewModel.query) { _, _ in
            viewModel.onQueryChanged()
        }
        .onChange(of: RequestsEventBus.shared.lastUpdate) { _, update in
            if let update {
                viewModel.applyRequestUpdate(update)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !viewModel.isShowingDiscover {
            searchResults
        } else if let error = viewModel.error {
            ErrorView(state: error, onRetry: { Task { await viewModel.load() } })
        } else if viewModel.isLoading {
            LoadingView(usesPageBackground: true)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else if viewModel.myRequests.isEmpty && viewModel.carousels.isEmpty {
            VStack {
                Spacer(minLength: 80)
                EmptyStateView(
                    icon: "sparkles",
                    title: "Nothing here yet",
                    subtitle: "Search for a movie or series to request it"
                )
            }
            .frame(maxWidth: .infinity)
        } else {
            if !viewModel.myRequests.isEmpty {
                yourRequestsStrip
            }
            ForEach(viewModel.carousels) { carousel in
                carouselRow(carousel)
            }
        }
    }

    // MARK: - Search results

    @ViewBuilder
    private var searchResults: some View {
        if viewModel.isSearching && viewModel.searchResults.isEmpty {
            LoadingView(usesPageBackground: true)
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
        } else if viewModel.hasSearched && viewModel.searchResults.isEmpty {
            VStack {
                Spacer(minLength: 80)
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No matches",
                    subtitle: "Nothing on TMDB matched that search"
                )
            }
            .frame(maxWidth: .infinity)
        } else {
            LazyVGrid(
                columns: [GridItem(
                    .adaptive(
                        minimum: RequestsUI.cardWidth
                            * uiCustomization.cardPresentation.posterSize.scale
                    ),
                    spacing: RequestsUI.railSpacing,
                    alignment: .top
                )],
                alignment: .leading,
                spacing: RequestsUI.railSpacing
            ) {
                ForEach(viewModel.searchResults) { result in
                    RequestMediaCard(result: result, onTap: { router.openRequestResult(result) })
                }
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
    }

    // MARK: - Your requests strip

    private var yourRequestsStrip: some View {
        VStack(alignment: .leading, spacing: RequestsUI.headerSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your requests")
                    .font(.siloHeadline)
                    .foregroundColor(.siloOnSurface)

                Spacer(minLength: 0)

                Button {
                    router.navigate(to: .myRequests)
                } label: {
                    seeAllLabel
                }
                #if os(tvOS)
                .buttonStyle(.plain)
                #else
                .buttonStyle(.borderless)
                #endif
            }

            RequestCardRail(items: viewModel.myRequests) { record in
                RequestMediaCard(record: record, onTap: { router.openRequestRecord(record) })
            }
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    private var seeAllLabel: some View {
        HStack(spacing: 4) {
            Text("See all")
            Image(systemName: "chevron.right")
                .font(.system(size: seeAllChevronSize, weight: .semibold))
        }
        .font(.siloCaption)
        .foregroundColor(.siloSecondaryText)
    }

    // MARK: - Discover carousels

    private func carouselRow(_ carousel: RequestCarousel) -> some View {
        VStack(alignment: .leading, spacing: RequestsUI.headerSpacing) {
            Text(carousel.title)
                .font(.siloHeadline)
                .foregroundColor(.siloOnSurface)

            RequestCardRail(items: carousel.results) { result in
                RequestMediaCard(result: result, onTap: { router.openRequestResult(result) })
            }
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    // MARK: - Metrics

    private var seeAllChevronSize: CGFloat {
        #if os(tvOS)
        18
        #else
        10
        #endif
    }
}
