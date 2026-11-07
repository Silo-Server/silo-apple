import SwiftUI

/// The Requests hub. On iOS/macOS: search TMDB to request (primary
/// interaction), a status summary and the user's own requests one glance
/// down, then the discover carousels — with the same large-title chrome,
/// section headers, and card grammar as the library pages. On tvOS the hub
/// is a Skyline page (`TVRequestsPage`) that the profile menu opens under the
/// top bar (`TVMainTabView`). Entry points are
/// hidden unless the server reports `requests_enabled`.
struct RequestsHubView: View {
    var body: some View {
        #if os(tvOS)
        TVRequestsPage(mode: .hub)
        #else
        PhoneRequestsHubView()
        #endif
    }
}

#if !os(tvOS)
private struct PhoneRequestsHubView: View {
    @Environment(\.locale) private var locale
    @State private var viewModel = RequestsHubViewModel()
    @Environment(AppRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SiloTheme.largePadding) {
                content
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.top, SiloTheme.smallPadding)
            .padding(.bottom, SiloTheme.largePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .siloPageBackground()
        .navigationTitle(.requestsTitle)
        .siloNavigationTitleDisplayMode(.large)
        .siloToolbarColorSchemeDark()
        .siloSearchable(text: $viewModel.query, prompt: AppLanguage.string(.requestsSearchPlaceholder))
        .task {
            await viewModel.load()
        }
        .refreshable {
            await viewModel.load()
        }
        .onChange(of: viewModel.query) { _, _ in
            viewModel.onQueryChanged()
        }
        .onChange(of: RequestsEventBus.shared.lastUpdate) { _, update in
            if let update {
                viewModel.applyRequestUpdate(update)
            }
        }
        .onChange(of: RequestsEventBus.shared.lastTitleState) { _, update in
            if let update {
                viewModel.applyTitleState(update)
            }
        }
        .onChange(of: RequestsEventBus.shared.lastRemoval) { _, removed in
            guard let removed else { return }
            viewModel.applyRemoval(removed)
            // Cards may show the removed request's state; the read is the
            // only source for what the title shows now.
            Task { await viewModel.load() }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !viewModel.isShowingDiscover {
            searchResults
        } else if let error = viewModel.error {
            ErrorView(state: error, onRetry: { Task { await viewModel.load() } })
                .padding(.top, 60)
        } else if viewModel.isLoading {
            RequestRailSkeleton(title: AppLanguage.string(.requestsYourRequests), cardCount: 4)
            RequestRailSkeleton(cardCount: 4)
        } else if viewModel.myRequests.isEmpty && viewModel.carousels.isEmpty {
            EmptyStateView(
                icon: "sparkles",
                title: AppLanguage.string(.requestsEmpty),
                subtitle: AppLanguage.string(.requestsHubEmptyBody)
            )
            .padding(.top, 80)
        } else {
            if !viewModel.statusCounts.isEmpty {
                summaryRow
            }
            if !viewModel.myRequests.isEmpty {
                yourRequestsStrip
            }
            ForEach(Array(viewModel.carousels.enumerated()), id: \.element.id) { index, carousel in
                carouselRow(carousel, isFirst: index == 0)
            }
        }
    }

    // MARK: - Search results

    @ViewBuilder
    private var searchResults: some View {
        if viewModel.isSearching && viewModel.searchResults.isEmpty {
            searchGrid(placeholderCount: 9)
        } else if viewModel.hasSearched && viewModel.searchResults.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: AppLanguage.string(.requestsSearchEmptyTitle),
                subtitle: AppLanguage.string(.requestsSearchEmptyBody)
            )
            .padding(.top, 80)
        } else {
            VStack(alignment: .leading, spacing: SiloTheme.padding) {
                Text(.requestsSearchResultCount(count: viewModel.searchTotal, LocaleFormat.integer(viewModel.searchTotal)))
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)
                searchGrid(placeholderCount: 0)
            }
        }
    }

    /// Results, or quiet placeholders in the same cells while a search runs.
    private func searchGrid(placeholderCount: Int) -> some View {
        RequestPosterGrid(results: viewModel.searchResults, placeholderCount: placeholderCount)
    }

    // MARK: - Summary

    /// One glanceable card for the user's requests on the move; opens My
    /// Requests.
    private var summaryRow: some View {
        summaryCard(
            title: summaryTitle,
            parts: summaryParts,
            action: { router.navigate(to: .myRequests) }
        )
    }

    private var summaryTitle: String {
        let count = viewModel.statusCounts.inProgress
        if count == 0 { return AppLanguage.string(.requestsSummaryNeedYouTitle) }
        return AppLanguage.string(.requestsSummaryInProgress(count: count, LocaleFormat.integer(count)))
    }

    private var summaryParts: [(RequestStatusTint, String)] {
        let counts = viewModel.statusCounts
        var parts: [(RequestStatusTint, String)] = []
        if counts.onTheWay > 0 {
            parts.append((.sky, AppLanguage.string(.requestsSummaryOnTheWay(count: counts.onTheWay, LocaleFormat.integer(counts.onTheWay)))))
        }
        if counts.pending > 0 {
            parts.append((.amber, AppLanguage.string(.requestsSummaryPending(count: counts.pending, LocaleFormat.integer(counts.pending)))))
        }
        if counts.needsAttention > 0 {
            parts.append((.rose, AppLanguage.string(.requestsSummaryNeedYou(count: counts.needsAttention, LocaleFormat.integer(counts.needsAttention)))))
        }
        return parts
    }

    private func summaryCard(title: String, parts: [(RequestStatusTint, String)], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.siloOnSurface)
                    if !parts.isEmpty {
                        HStack(spacing: 12) {
                            ForEach(parts, id: \.1) { tint, text in
                                HStack(spacing: 5) {
                                    Circle().fill(tint.color).frame(width: 6, height: 6)
                                    Text(text)
                                }
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.siloSecondaryText)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.siloSecondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.siloChromeRestingFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.siloChromeRestingBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rails

    private var yourRequestsStrip: some View {
        VStack(alignment: .leading, spacing: RequestsUI.headerSpacing) {
            RequestsSectionHeader(title: AppLanguage.string(.requestsYourRequests), trailing: AppLanguage.string(.requestsSeeAll)) {
                router.navigate(to: .myRequests)
            }

            RequestCardRail(items: viewModel.myRequests) { record in
                RequestMediaCard(record: record, onTap: { router.openRequestRecord(record) })
            }
        }
    }

    private func carouselRow(_ carousel: RequestCarousel, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: RequestsUI.headerSpacing) {
            // Only the server's own rows page; the merged carousels an older
            // server gets have no single row behind them.
            RequestsSectionHeader(
                label: isFirst ? AppLanguage.string(.requestsHubDiscover) : nil,
                title: carousel.title,
                trailing: carousel.seeAll ? AppLanguage.string(.requestsSeeAll) : nil
            ) {
                router.navigate(to: .requestDiscoverRow(key: carousel.id, title: carousel.title))
            }

            RequestCardRail(items: carousel.results) { result in
                RequestMediaCard(result: result, onTap: { router.openRequestResult(result) })
            }
        }
    }
}
#endif
