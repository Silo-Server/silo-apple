import SwiftUI

/// Browse/catalog screen with grid display and filters — Plezy style.
struct BrowseView: View {
    let libraryId: Int?
    var title: String? = "Browse"
    var showsSearchShortcut = true
    var libraryType: String? = nil
    var mediaScope: LibraryVideoScope? = nil

    @State private var viewModel = BrowseViewModel()
    @State private var showFilters = false
    @State private var shuffleLauncher = ShuffleLauncher()
    @Environment(AppRouter.self) private var router

    @ViewBuilder
    var body: some View {
        if let title {
            rootContent
                .navigationTitle(title)
                .siloNavigationTitleDisplayMode(.large)
        } else {
            rootContent
        }
    }

    private var rootContent: some View {
        Group {
            if viewModel.items.isEmpty, let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await viewModel.loadItems(reset: true) } })
            } else if viewModel.items.isEmpty, viewModel.hasLoaded, !viewModel.isLoading {
                emptyContent
            } else {
                // While the first page loads the grid draws placeholders under
                // the search and sort controls.
                scrollContent
            }
        }
        .siloPageBackground()
        .overlay(alignment: .top) {
            // Grid is painted from cache but the server can't be reached —
            // flag the staleness instead of letting refresh fail silently.
            if ConnectionMonitor.shared.isOffline, !viewModel.items.isEmpty {
                ServerUnreachablePill()
                    .padding(.top, SiloTheme.padding)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: ConnectionMonitor.shared.isOffline)
        .sheet(isPresented: $showFilters) {
            FilterView(viewModel: viewModel)
        }
        .task(id: BrowseConfigurationID(libraryId: libraryId, libraryType: libraryType, mediaScope: mediaScope)) {
            guard await viewModel.configure(libraryId: libraryId, libraryType: libraryType, mediaScope: mediaScope) else { return }
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
            VStack(spacing: SiloTheme.padding) {
                if showsSearchShortcut {
                    searchBar
                }

                controlBar

                if hasActiveFilters {
                    activeFilterChips
                }

                emptyState
                    .frame(minHeight: 320)
                    .padding(.horizontal, SiloTheme.padding)
            }
            .frame(maxWidth: .infinity)
        }
        .reportsPageChromeScroll()
        .environment(\.browseLibraryId, libraryId)
    }

    @ViewBuilder
    private var emptyState: some View {
        switch viewModel.emptyReason {
        case .libraryEmpty:
            EmptyStateView(
                icon: emptyLibraryIcon,
                title: "This library is empty",
                subtitle: "There is nothing in this library yet."
            )
        case .noFilterMatches:
            VStack(spacing: SiloTheme.padding) {
                EmptyStateView(
                    icon: "line.3.horizontal.decrease.circle",
                    title: "No items match your current filters"
                )
                Button("Clear filters") {
                    Task { await viewModel.clearFilters() }
                }
                .siloPrimaryButton()
                .frame(width: 200)
            }
        }
    }

    private var emptyLibraryIcon: String {
        switch viewModel.mediaType {
        case .series: return "tv"
        case .audiobook: return "book.closed"
        case .movie, .mixed: return "film"
        }
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: SiloTheme.padding) {
                if showsSearchShortcut {
                    searchBar
                }

                controlBar

                if hasActiveFilters {
                    activeFilterChips
                }

                CatalogGrid(
                    items: viewModel.items,
                    isLoading: viewModel.isLoading || !viewModel.hasLoaded,
                    hasMore: viewModel.hasMore,
                    forcesThreeColumnsOnPhone: libraryId != nil,
                    onItemTap: { router.navigate(to: .itemDetail(browseItem: $0, libraryId: libraryId)) },
                    onLoadMore: {
                        Task { await viewModel.loadItems() }
                    }
                )
                .padding(.horizontal, SiloTheme.padding)
            }
        }
        .reportsPageChromeScroll()
        .environment(\.browseLibraryId, libraryId)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        Button {
            router.navigate(to: .search)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.siloSecondaryText)
                Text("Search...")
                    .foregroundColor(.siloSecondaryText)
                Spacer()
            }
            .font(.siloBody)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                    .fill(Color.siloSurfaceVariant)
                    .overlay(
                        RoundedRectangle(cornerRadius: SiloTheme.cornerRadius)
                            .stroke(Color.siloOutline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, SiloTheme.padding)
    }

    // MARK: - Control bar (Sort + Filter + Shuffle)

    private var controlBar: some View {
        // At accessibility text sizes the chips no longer fit side by
        // side and SwiftUI broke their labels mid-word; stack them instead.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                sortMenu
                filterButton
                shuffleButton
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 9) {
                sortMenu
                filterButton
                shuffleButton
            }
        }
        .padding(.horizontal, SiloTheme.padding)
        .shuffleFailureAlert(shuffleLauncher)
    }

    /// The library a Shuffle chip plays from; nil where Shuffle isn't offered.
    /// A library shuffle has no media type, so the Movies or Series view of a
    /// mixed library doesn't offer it.
    private var shuffleLibraryId: Int? {
        guard let libraryId, mediaScope == nil,
              ShuffleAvailability.isShuffleLibraryType(libraryType),
              ShuffleFeatureStore.shared.supports(.library) else { return nil }
        return libraryId
    }

    private var filterButton: some View {
        Button { showFilters = true } label: {
            controlChip(
                icon: "line.3.horizontal.decrease",
                text: "Filter",
                badge: viewModel.filterState.activeFacetCount
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var shuffleButton: some View {
        if let shuffleLibraryId {
            Button {
                shuffleLauncher.start(ShuffleScopeRequest(kind: .library, id: String(shuffleLibraryId)), router: router)
            } label: {
                controlChip(icon: "shuffle", text: "Shuffle")
            }
            .buttonStyle(.plain)
            .disabled(shuffleLauncher.isStarting)
            .accessibilityIdentifier("library-shuffle")
        }
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
                .font(.siloBody)
            if let trailing {
                Text(trailing)
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)
            }
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.siloBackground)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.siloOnSurface))
            }
        }
        .foregroundColor(.siloOnSurface)
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
            .padding(.horizontal, SiloTheme.padding)
        }
    }

    private func filterChip(label: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.siloCaption)
                .foregroundColor(.siloOnSurface)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.siloSecondaryText)
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
    let mediaScope: LibraryVideoScope?
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
                        withAnimation(.easeInOut(duration: SiloTheme.normalDuration)) {
                            selectedTab = tab
                        }
                    } label: {
                        Text(tab.title)
                            .font(.siloCaption)
                            .fontWeight(selectedTab == tab ? .semibold : .regular)
                            .foregroundColor(selectedTab == tab ? Color.siloBackground : .siloSecondaryText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(selectedTab == tab ? Color.siloOnSurface : Color.siloSurfaceElevated)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, SiloTheme.padding)
            .padding(.vertical, SiloTheme.smallPadding)
        }
    }
}

@Observable
@MainActor
private class LibraryRecommendedViewModel {
    /// Non-featured rows with items, in server order.
    var sections: [ResolvedSection] = []
    var isLoading = false
    var error: ErrorState?
    var scopeIncomplete = false
    private var identity: String?
    private var generation = 0

    func loadSections(libraryId: Int, mediaScope: LibraryVideoScope?) async {
        generation += 1
        let run = generation
        let key = CacheKey.librarySections(libraryId) + (mediaScope.map { ".type-\($0.rawValue)" } ?? "")
        if identity != key {
            identity = key
            sections = []
            scopeIncomplete = false
        }
        if sections.isEmpty {
            if mediaScope != nil,
               let cached: (sections: [ResolvedSection], incomplete: Bool) = ResponseCache.shared.get(key) {
                sections = cached.sections
                scopeIncomplete = cached.incomplete
            } else if mediaScope == nil,
                      let cached: SectionsResponse = ResponseCache.shared.get(key) {
                sections = Self.displayed(cached.sections)
            }
        }
        isLoading = sections.isEmpty
        error = nil
        let writeToken = ResponseCache.shared.writeToken

        do {
            let read = try await StartupContentPrefetcher.fetchLibrarySectionsRead(libraryId: libraryId)
            let rows = read.response.sections.filter { !$0.isFeatured }
            let loaded: [ResolvedSection]
            let incomplete: Bool
            if let mediaScope {
                let scoped = try await mediaScope.refillSections(rows) { (row: ResolvedSection, cursor: APIv2CatalogContinuation?) in
                    guard await SiloAPI.shared.isCurrentOwner(read.auth) else { throw HTTPError.requestIdentityChanged }
                    let page: CatalogListPage
                    if let cursor {
                        page = try await SiloAPI.shared.nextCatalogPage(cursor)
                    } else {
                        var query = APIv2CatalogQuery()
                        query.source = "section"
                        query.scope = "library"
                        query.libraryId = String(libraryId)
                        query.sectionId = row.id
                        query.limit = 100
                        page = try await SiloAPI.shared.catalogPage(query)
                    }
                    guard await SiloAPI.shared.isCurrentOwner(read.auth) else { throw HTTPError.requestIdentityChanged }
                    return LibraryScopedPage(items: page.response.items.map { SectionItem(browseItem: $0) },
                                             next: page.continuation, startsOver: page.startsOver)
                }
                loaded = scoped.map(\.section)
                incomplete = scoped.contains { $0.incomplete }
            } else {
                loaded = rows
                incomplete = false
            }
            guard await SiloAPI.shared.isCurrentOwner(read.auth) else { throw HTTPError.requestIdentityChanged }
            guard run == generation, !Task.isCancelled else { return }
            sections = loaded.filter { !$0.items.isEmpty }
            scopeIncomplete = incomplete
            if mediaScope != nil {
                ResponseCache.shared.set((sections: sections, incomplete: incomplete), for: key, fetchedAt: writeToken)
            }
        } catch {
            guard run == generation, !Task.isCancelled else { return }
            if error is CancellationError { return }
            if case HTTPError.requestIdentityChanged = error { sections = [] }
            if case HTTPError.authorityChanged = error { sections = [] }
            if sections.isEmpty { self.error = ErrorState(error) }
            scopeIncomplete = mediaScope != nil
        }
        isLoading = false
    }

    private static func displayed(_ sections: [ResolvedSection]) -> [ResolvedSection] {
        sections.filter { !$0.isFeatured && !$0.items.isEmpty }
    }
}

struct LibraryRecommendedView: View {
    let libraryId: Int
    var mediaScope: LibraryVideoScope? = nil

    @State private var viewModel = LibraryRecommendedViewModel()
    @State private var refreshPill = RefreshStatusPillState()
    @Environment(AppRouter.self) private var router

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if !viewModel.sections.isEmpty {
                    content
                } else if let error = viewModel.error {
                    ErrorView(state: error, onRetry: { Task { await viewModel.loadSections(libraryId: libraryId, mediaScope: mediaScope) } })
                } else if viewModel.isLoading {
                    PosterRowsSkeleton()
                        .padding(.top, SiloTheme.padding)
                } else if viewModel.scopeIncomplete {
                    scopeNotice
                } else {
                    EmptyStateView(
                        icon: "rectangle.stack.fill",
                        title: "No recommendations yet",
                        subtitle: "This library does not have any recommended rows right now."
                    )
                }
            }

            if refreshPill.isVisible {
                RefreshStatusPill()
                    .padding(.top, SiloTheme.padding)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            } else if ConnectionMonitor.shared.isOffline, !viewModel.sections.isEmpty {
                ServerUnreachablePill()
                    .padding(.top, SiloTheme.padding)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: refreshPill.isVisible)
        .animation(.easeInOut(duration: 0.18), value: ConnectionMonitor.shared.isOffline)
        .siloPageBackground()
        .task(id: "\(libraryId):\(mediaScope?.rawValue ?? "all")") {
            await viewModel.loadSections(libraryId: libraryId, mediaScope: mediaScope)
        }
        .refreshable {
            await refreshRecommendations()
        }
    }

    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: SiloTheme.largePadding) {
                if viewModel.scopeIncomplete { scopeNotice }
                ForEach(viewModel.sections) { section in
                    SectionRow(
                        section: section,
                        onItemTap: { destinationContentId, item in
                            router.navigate(
                                to: .itemDetail(
                                    destinationContentId: destinationContentId,
                                    sectionItem: item,
                                    libraryId: libraryId
                                )
                            )
                        }
                    )
                }
            }
            .padding(.bottom, SiloTheme.largePadding)
        }
        .siloScrollEdgeEffect()
        .reportsPageChromeScroll()
        .environment(\.browseLibraryId, libraryId)
    }

    private var scopeNotice: some View {
        VStack(spacing: SiloTheme.smallPadding) {
            Text("Some shelves could not be fully loaded. Retry or open Library to browse all titles.")
                .font(.siloCaption)
                .foregroundStyle(Color.siloSecondaryText)
            Button("Retry") { Task { await viewModel.loadSections(libraryId: libraryId, mediaScope: mediaScope) } }
        }
        .padding(SiloTheme.padding)
    }

    private func refreshRecommendations() async {
        await refreshPill.run {
            await viewModel.loadSections(libraryId: libraryId, mediaScope: mediaScope)
        }
    }
}
