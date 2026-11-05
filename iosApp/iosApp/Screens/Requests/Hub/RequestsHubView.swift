import SwiftUI

/// The Requests hub. On iOS/macOS: search TMDB to request (primary
/// interaction), a status summary and the user's own requests one glance
/// down, then the discover carousels — with the same large-title chrome,
/// section headers, and card grammar as the library pages. On tvOS the hub
/// is a Skyline page (`TVRequestsPage`) in the top bar. Entry points are
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
        .navigationTitle("Requests")
        .siloNavigationTitleDisplayMode(.large)
        .siloToolbarColorSchemeDark()
        .siloSearchable(text: $viewModel.query, prompt: "Search movies & series")
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
            RequestRailSkeleton(title: "Your requests", cardCount: 4)
            RequestRailSkeleton(cardCount: 4)
        } else if viewModel.myRequests.isEmpty && viewModel.carousels.isEmpty {
            EmptyStateView(
                icon: "sparkles",
                title: "Nothing here yet",
                subtitle: "Search for a movie or series to request it"
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
                title: "No matches",
                subtitle: "Nothing on TMDB matched that search"
            )
            .padding(.top, 80)
        } else {
            VStack(alignment: .leading, spacing: SiloTheme.padding) {
                Text("\(viewModel.searchTotal) result\(viewModel.searchTotal == 1 ? "" : "s")")
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
        if count == 0 { return "Your requests need you" }
        return count == 1 ? "1 request in progress" : "\(count) requests in progress"
    }

    private var summaryParts: [(RequestStatusTint, String)] {
        let counts = viewModel.statusCounts
        var parts: [(RequestStatusTint, String)] = []
        if counts.onTheWay > 0 { parts.append((.sky, "\(counts.onTheWay) on the way")) }
        if counts.pending > 0 { parts.append((.amber, "\(counts.pending) pending")) }
        if counts.needsAttention > 0 { parts.append((.rose, "\(counts.needsAttention) need you")) }
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
            RequestsSectionHeader(title: "Your requests", trailing: "See all") {
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
                label: isFirst ? "Discover" : nil,
                title: carousel.title,
                trailing: carousel.seeAll ? "See all" : nil
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
