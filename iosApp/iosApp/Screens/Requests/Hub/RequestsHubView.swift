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
    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var gridWidth: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
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
        .onChange(of: RequestsEventBus.shared.lastModeration) { _, _ in
            viewModel.applyModeration()
        }
        .onChange(of: RequestsFeatureStore.shared.canModerate) { _, _ in
            // Moderation can be confirmed after the hub's first load.
            viewModel.applyModeration()
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
            if viewModel.pendingApprovals > 0 || !viewModel.statusCounts.isEmpty {
                summaryRows
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

    // Library search's grid (`CatalogGrid`): the shared phone/pad column
    // counts, 8pt gutters, and posters that fill their column.
    private static let gridSpacing: CGFloat = 8
    private static let gridRowSpacing: CGFloat = 12

    private var searchColumns: [GridItem] {
        if let fit = widePhonePosterFit {
            return fit.columns
        }
        return AdaptiveColumns.posters(
            for: horizontalSizeClass,
            posterSize: uiCustomization.cardPresentation.posterSize,
            spacing: Self.gridSpacing
        )
    }

    /// A phone window too wide for the standard counts (the iPhone Duo's
    /// inner display) adds columns rather than stretching posters.
    private var widePhonePosterFit: AdaptiveColumns.PosterGridFit? {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return nil }
        return AdaptiveColumns.widePhonePosterFit(
            containerWidth: gridWidth,
            posterSize: uiCustomization.cardPresentation.posterSize,
            verticalSizeClass: verticalSizeClass
        )
        #else
        return nil
        #endif
    }

    private var searchCardWidth: CGFloat {
        // Before the first measurement, a standard poster: the uncapped fit
        // below would return its infinite maximum.
        guard gridWidth > 0 else { return SiloTheme.posterCardWidth }
        #if os(macOS)
        // The Mac grid is one adaptive column that repeats to fit, so the
        // column count says nothing about the cell. Work the cell out the
        // way the grid does.
        let minimumWidth = SiloTheme.posterCardWidth * uiCustomization.cardPresentation.posterSize.scale
        return AdaptiveColumns.widthFittedPosters(
            containerWidth: gridWidth,
            minimumCardWidth: minimumWidth,
            spacing: Self.gridSpacing,
            minimumColumns: 1
        )?.cardWidth ?? SiloTheme.posterCardWidth
        #else
        if let fit = widePhonePosterFit { return fit.cardWidth }
        return AdaptiveColumns.fittedPosterWidth(
            containerWidth: gridWidth,
            columnCount: searchColumns.count,
            spacing: Self.gridSpacing,
            maximumWidth: .greatestFiniteMagnitude
        )
        #endif
    }

    /// Results, or quiet placeholders in the same cells while a search runs.
    private func searchGrid(placeholderCount: Int) -> some View {
        LazyVGrid(columns: searchColumns, alignment: .leading, spacing: Self.gridRowSpacing) {
            if placeholderCount > 0 {
                ForEach(0..<placeholderCount, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 7) {
                        RequestsSkeleton.block(
                            width: nil,
                            height: searchCardWidth * (SiloTheme.posterCardHeight / SiloTheme.posterCardWidth),
                            cornerRadius: SiloTheme.cornerRadius
                        )
                        RequestsSkeleton.bar(width: searchCardWidth * 0.7, height: 10, opacity: 0.14)
                    }
                }
            } else {
                ForEach(viewModel.searchResults) { result in
                    RequestMediaCard(result: result, onTap: { router.openRequestResult(result) })
                        .cardWidth(searchCardWidth)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            guard abs(width - gridWidth) >= 0.5 else { return }
            gridWidth = width
        }
        .accessibilityHidden(placeholderCount > 0)
    }

    // MARK: - Summary

    /// One glanceable card per thing worth knowing: requests on the move
    /// (opens My Requests) and, for admins, requests waiting on them.
    private var summaryRows: some View {
        VStack(spacing: 10) {
            if !viewModel.statusCounts.isEmpty {
                summaryCard(
                    title: summaryTitle,
                    parts: summaryParts,
                    action: { router.navigate(to: .myRequests) }
                )
            }
            if viewModel.pendingApprovals > 0 {
                summaryCard(
                    title: viewModel.pendingApprovals == 1
                        ? "1 request needs your approval"
                        : "\(viewModel.pendingApprovals) requests need your approval",
                    parts: [],
                    action: { router.navigate(to: .requestApprovals) }
                )
            }
        }
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
            RequestsSectionHeader(label: isFirst ? "Discover" : nil, title: carousel.title)

            RequestCardRail(items: carousel.results) { result in
                RequestMediaCard(result: result, onTap: { router.openRequestResult(result) })
            }
        }
    }
}
#endif
