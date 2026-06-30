import SwiftUI

/// Browse/catalog screen with grid display and filters — Plezy style.
struct BrowseView: View {
    let libraryId: Int?
    var title: String? = "Browse"
    var showsSearchShortcut = true

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
                EmptyStateView(
                    icon: "film",
                    title: "No items found",
                    subtitle: "Try adjusting your filters"
                )
            }
        }
        .continuumBackground()
        .toolbar {
            #if os(macOS)
            ToolbarItem {
                Button {
                    showFilters = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundColor(hasActiveFilters ? .continuumOnSurface : .continuumSecondaryText)
                }
            }
            #else
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showFilters = true
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundColor(hasActiveFilters ? .continuumOnSurface : .continuumSecondaryText)
                }
            }
            #endif
        }
        .sheet(isPresented: $showFilters) {
            FilterView(
                selectedGenre: $viewModel.selectedGenre,
                sortBy: $viewModel.sortBy,
                onApply: {
                    Task { await viewModel.loadItems(reset: true) }
                }
            )
        }
        .task {
            viewModel.configure(libraryId: libraryId)
            await viewModel.loadItems(reset: true)
        }
        .refreshable {
            await viewModel.loadItems(reset: true)
        }
    }

    // MARK: - Content

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: ContinuumTheme.padding) {
                if showsSearchShortcut {
                    searchBar
                }

                if hasActiveFilters {
                    activeFilterChips
                }

                CatalogGrid(
                    items: viewModel.items,
                    isLoading: viewModel.isLoading,
                    hasMore: viewModel.hasMore,
                    onItemTap: { router.navigate(to: .itemDetail(contentId: $0)) },
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

    // MARK: - Active Filters

    private var hasActiveFilters: Bool {
        viewModel.selectedGenre != nil || viewModel.sortBy != "title"
    }

    private var activeFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let genre = viewModel.selectedGenre {
                    filterChip(label: genre) {
                        Task { await viewModel.applyGenre(nil) }
                    }
                }
                if viewModel.sortBy != "title" {
                    filterChip(label: "Sort: \(viewModel.sortBy.capitalized)") {
                        Task { await viewModel.applySort("title") }
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
    let showsNavigationTitle: Bool

    @State private var selectedTab: LibraryPageTab = .recommended
    @State private var title: String

    init(libraryId: Int, initialTitle: String?, showsNavigationTitle: Bool = true) {
        self.libraryId = libraryId
        self.initialTitle = initialTitle
        self.showsNavigationTitle = showsNavigationTitle
        _title = State(initialValue: initialTitle ?? "Library")
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
            await loadLibraryTitleIfNeeded()
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .recommended:
            LibraryRecommendedView(libraryId: libraryId)
        case .library:
            BrowseView(libraryId: libraryId, title: nil, showsSearchShortcut: false)
        case .collections:
            LibraryCollectionsView(libraryId: libraryId)
        }
    }

    private func loadLibraryTitleIfNeeded() async {
        guard initialTitle == nil else { return }

        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries()
            if let matchedLibrary = response.libraries.first(where: { $0.id == libraryId }) {
                title = matchedLibrary.name
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
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isRefreshing)
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
                        onItemTap: { router.navigate(to: .itemDetail(contentId: $0)) }
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
