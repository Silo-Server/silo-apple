import SwiftUI

/// Browse/catalog screen with grid display and filters — Plezy style.
struct BrowseView: View {
    let libraryId: Int?
    var title: String? = "Browse"
    var showsSearchShortcut = true
    var libraryType: String? = nil

    @State private var viewModel = BrowseViewModel()
    @State private var showFilters = false
    @Environment(AppRouter.self) private var router

    @ViewBuilder
    var body: some View {
        if let title {
            rootContent
                .navigationTitle(title)
                .continuumNavigationTitleDisplayMode(.large)
        } else {
            rootContent
        }
    }

    private var rootContent: some View {
        Group {
            if !viewModel.items.isEmpty {
                scrollContent
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await viewModel.loadItems(reset: true) } })
            } else if viewModel.isLoading {
                Color.clear
            } else {
                emptyContent
            }
        }
        .continuumBackground()
        .overlay(alignment: .top) {
            // Grid is painted from cache but the server can't be reached —
            // flag the staleness instead of letting refresh fail silently.
            if ConnectionMonitor.shared.isOffline, !viewModel.items.isEmpty {
                ServerUnreachablePill()
                    .padding(.top, ContinuumTheme.padding)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: ConnectionMonitor.shared.isOffline)
        .sheet(isPresented: $showFilters) {
            FilterView(viewModel: viewModel)
        }
        .task(id: BrowseConfigurationID(libraryId: libraryId, libraryType: libraryType)) {
            guard await viewModel.configure(libraryId: libraryId, libraryType: libraryType) else { return }
            await viewModel.loadItems(reset: true)
            await viewModel.loadFacetsIfNeeded()
        }
        .refreshable {
            await viewModel.loadItems(reset: true)
        }
    }

    // MARK: - Content

    private var emptyContent: some View {
        ScrollView {
            VStack(spacing: ContinuumTheme.padding) {
                if showsSearchShortcut {
                    searchBar
                }

                controlBar

                if hasActiveFilters {
                    activeFilterChips
                }

                EmptyStateView(
                    icon: "film",
                    title: "No items found",
                    subtitle: "Try adjusting your filters"
                )
                .frame(minHeight: 320)
                .padding(.horizontal, ContinuumTheme.padding)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: ContinuumTheme.padding) {
                if showsSearchShortcut {
                    searchBar
                }

                controlBar

                if hasActiveFilters {
                    activeFilterChips
                }

                CatalogGrid(
                    items: viewModel.items,
                    isLoading: viewModel.isLoading,
                    hasMore: viewModel.hasMore,
                    onItemTap: { router.navigate(to: .itemDetail(browseItem: $0)) },
                    onLoadMore: {
                        Task { await viewModel.loadItems() }
                    }
                )
                .padding(.horizontal, ContinuumTheme.padding)
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        Button {
            router.navigate(to: .search)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.continuumSecondaryText)
                Text("Search...")
                    .foregroundColor(.continuumSecondaryText)
                Spacer()
            }
            .font(.continuumBody)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius)
                    .fill(Color.continuumSurfaceVariant)
                    .overlay(
                        RoundedRectangle(cornerRadius: ContinuumTheme.cornerRadius)
                            .stroke(Color.continuumOutline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, ContinuumTheme.padding)
    }

    // MARK: - Control bar (Sort + Filter)

    private var controlBar: some View {
        HStack(spacing: 9) {
            sortMenu
            Button { showFilters = true } label: {
                controlChip(
                    icon: "line.3.horizontal.decrease",
                    text: "Filter",
                    badge: viewModel.filterState.activeFacetCount
                )
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ContinuumTheme.padding)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(CatalogSortKey.available(for: viewModel.mediaType), id: \.self) { key in
                Button {
                    Task { await viewModel.setSort(key) }
                } label: {
                    if viewModel.filterState.sort == key {
                        Label(
                            key.label,
                            systemImage: viewModel.filterState.effectiveOrder == .asc ? "arrow.up" : "arrow.down"
                        )
                    } else {
                        Text(key.label)
                    }
                }
            }
        } label: {
            controlChip(
                icon: "arrow.up.arrow.down",
                text: viewModel.filterState.sort.label,
                trailing: viewModel.filterState.sort.directionLabel(for: viewModel.filterState.effectiveOrder)
            )
        }
    }

    private func controlChip(icon: String, text: String, trailing: String? = nil, badge: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.continuumBody)
            if let trailing {
                Text(trailing)
                    .font(.continuumCaption)
                    .foregroundColor(.continuumSecondaryText)
            }
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.continuumBackground)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.continuumOnSurface))
            }
        }
        .foregroundColor(.continuumOnSurface)
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .siloGlass(in: .capsule)
    }

    // MARK: - Active Filters

    private var hasActiveFilters: Bool { viewModel.hasActiveFilters }

    private var activeFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.filterState.activeChips()) { chip in
                    filterChip(label: chip.label) {
                        Task { await viewModel.removeChip(chip) }
                    }
                }
            }
            .padding(.horizontal, ContinuumTheme.padding)
        }
    }

    private func filterChip(label: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.continuumCaption)
                .foregroundColor(.continuumOnSurface)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.continuumSecondaryText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .siloGlass(in: .capsule)
    }
}

private struct BrowseConfigurationID: Hashable {
    let libraryId: Int?
    let libraryType: String?
}

enum LibraryPageTab: String, CaseIterable, Identifiable {
    case recommended
    case library
    case collections

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommended:
            return "Recommended"
        case .library:
            return "Library"
        case .collections:
            return "Collections"
        }
    }
}

/// Plezy-style chip tab selector for the Recommended/Library/Collections
/// pages. Extracted so screens like `LibrariesTabView` can hoist it into a
/// shared top-chrome `safeAreaInset` overlay.
struct LibraryPageTabSelector: View {
    @Binding var selectedTab: LibraryPageTab

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryPageTab.allCases) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: ContinuumTheme.normalDuration)) {
                            selectedTab = tab
                        }
                    } label: {
                        Text(tab.title)
                            .font(.continuumCaption)
                            .fontWeight(selectedTab == tab ? .semibold : .regular)
                            .foregroundColor(selectedTab == tab ? Color.continuumBackground : .continuumSecondaryText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(selectedTab == tab ? Color.continuumOnSurface : Color.continuumSurfaceElevated)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, ContinuumTheme.padding)
            .padding(.vertical, ContinuumTheme.smallPadding)
        }
    }
}

struct LibraryDetailView: View {
    let libraryId: Int
    let initialTitle: String?
    let initialLibraryType: String?
    let showsNavigationTitle: Bool

    @State private var selectedTab: LibraryPageTab = .recommended
    @State private var title: String
    @State private var libraryType: String?

    init(
        libraryId: Int,
        initialTitle: String?,
        initialLibraryType: String? = nil,
        showsNavigationTitle: Bool = true
    ) {
        self.libraryId = libraryId
        self.initialTitle = initialTitle
        self.initialLibraryType = initialLibraryType
        self.showsNavigationTitle = showsNavigationTitle
        _title = State(initialValue: initialTitle ?? "Library")
        _libraryType = State(initialValue: initialLibraryType)
    }

    var body: some View {
        content
            .modifier(LibraryDetailTitleModifier(title: title, isEnabled: showsNavigationTitle))
    }

    private var content: some View {
        VStack(spacing: 0) {
            LibraryPageTabSelector(selectedTab: $selectedTab)

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .continuumBackground()
        .task {
            await loadLibraryMetadataIfNeeded()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .recommended:
            LibraryRecommendedView(libraryId: libraryId)
        case .library:
            BrowseView(libraryId: libraryId, title: nil, showsSearchShortcut: false, libraryType: libraryType)
        case .collections:
            LibraryCollectionsView(libraryId: libraryId)
        }
    }

    private func loadLibraryMetadataIfNeeded() async {
        guard initialTitle == nil || libraryType == nil else { return }

        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries()
            if let matchedLibrary = response.libraries.first(where: { $0.id == libraryId }) {
                if initialTitle == nil {
                    title = matchedLibrary.name
                }
                libraryType = matchedLibrary.type
            }
        } catch {
            // Fall back to the generic title if library metadata is unavailable.
        }
    }
}

@Observable
@MainActor
private class LibraryRecommendedViewModel {
    var sections: [ResolvedSection] = []
    var isLoading = false
    var isRefreshing = false
    var error: ErrorState?

    var regularSections: [ResolvedSection] {
        sections.filter { !$0.isFeatured && !$0.items.isEmpty }
    }

    func loadSections(libraryId: Int) async {
        let key = CacheKey.librarySections(libraryId)
        if sections.isEmpty,
           let cached: SectionsResponse = ResponseCache.shared.get(key) {
            sections = cached.sections.filter { !$0.items.isEmpty }
        }
        if sections.isEmpty {
            isLoading = true
        } else {
            isRefreshing = true
        }
        error = nil

        do {
            let response = try await StartupContentPrefetcher.fetchLibrarySections(libraryId: libraryId)
            sections = response.sections.filter { !$0.items.isEmpty }
        } catch let err {
            if sections.isEmpty {
                error = ErrorState(err)
            }
        }

        isLoading = false
        isRefreshing = false
    }
}

struct LibraryRecommendedView: View {
    let libraryId: Int

    @State private var viewModel = LibraryRecommendedViewModel()
    @State private var isRefreshing = false
    @State private var refreshStartedAt: Date?
    @State private var refreshHideTask: Task<Void, Never>?
    @Environment(AppRouter.self) private var router

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if !viewModel.regularSections.isEmpty {
                    content
                } else if let error = viewModel.error {
                    ErrorView(state: error, onRetry: { Task { await viewModel.loadSections(libraryId: libraryId) } })
                } else if viewModel.isLoading {
                    Color.clear
                } else {
                    EmptyStateView(
                        icon: "rectangle.stack.fill",
                        title: "No recommendations yet",
                        subtitle: "This library does not have any recommended rows right now."
                    )
                }
            }

            if isRefreshing {
                RefreshStatusPill()
                    .padding(.top, refreshStatusTopPadding)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            } else if ConnectionMonitor.shared.isOffline, !viewModel.regularSections.isEmpty {
                ServerUnreachablePill()
                    .padding(.top, refreshStatusTopPadding)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isRefreshing)
        .animation(.easeInOut(duration: 0.18), value: ConnectionMonitor.shared.isOffline)
        .continuumBackground()
        .task(id: libraryId) {
            await viewModel.loadSections(libraryId: libraryId)
        }
        .refreshable {
            await refreshRecommendations()
        }
    }

    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: ContinuumTheme.largePadding) {
                ForEach(viewModel.regularSections) { section in
                    SectionRow(
                        section: section,
                        onItemTap: { destinationContentId, item in
                            router.navigate(
                                to: .itemDetail(
                                    destinationContentId: destinationContentId,
                                    sectionItem: item
                                )
                            )
                        }
                    )
                }
            }
            .padding(.bottom, ContinuumTheme.largePadding)
        }
        .continuumScrollEdgeEffect()
    }

    private var refreshStatusTopPadding: CGFloat {
        ContinuumTheme.padding
    }

    private func refreshRecommendations() async {
        await MainActor.run {
            showRefreshStatus()
        }

        await viewModel.loadSections(libraryId: libraryId)

        await MainActor.run {
            scheduleRefreshStatusHide()
        }
    }

    private func showRefreshStatus() {
        refreshHideTask?.cancel()
        refreshStartedAt = Date()
        isRefreshing = true
    }

    private func scheduleRefreshStatusHide() {
        let elapsed = Date().timeIntervalSince(refreshStartedAt ?? Date())
        let remaining = RefreshStatusPill.minimumVisibleDuration - elapsed
        refreshHideTask?.cancel()
        refreshHideTask = Task { @MainActor in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }

            isRefreshing = false
            refreshStartedAt = nil
            refreshHideTask = nil
        }
    }
}

/// Applies the library's name as the navigation title when the detail view is
/// the top-of-stack view. Disabled when embedded inside another screen (e.g.
/// the Libraries tab, which owns its own title).
private struct LibraryDetailTitleModifier: ViewModifier {
    let title: String
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .navigationTitle(title)
                .continuumNavigationTitleDisplayMode(.large)
        } else {
            content
        }
    }
}
