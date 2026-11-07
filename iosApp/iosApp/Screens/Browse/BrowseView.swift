import SwiftUI

/// Browse/catalog screen with grid display and filters — Plezy style.
struct BrowseView: View {
    let libraryId: Int?
    var title: LocalizedStringResource? = .libraryBrowse
    var showsSearchShortcut = true
    var libraryType: String? = nil
    var mediaScope: LibraryVideoScope? = nil

    @State private var viewModel = BrowseViewModel()
    @State private var showFilters = false
    @Environment(\.libraryPageReloadRequest) private var reloadRequest
    @State private var shuffleLauncher = ShuffleLauncher()
    #if os(iOS)
    /// Scrolls the grid to a letter's first title.
    @State private var gridCommands = BrowseGridCommands()
    /// The jump waiting for its titles; a later jump replaces it.
    @State private var pendingJump: Task<Void, Never>?
    @Environment(\.libraryPageScrollToTopRequest) private var scrollToTopRequest
    #else
    /// Letter-jump scroll state, kept off this view so scrolling doesn't
    /// redraw the grid.
    @State private var letterJump = LetterJumpState()
    #endif
    /// Read by the letter index only, so marking a letter doesn't redraw
    /// the grid.
    @State private var jumpedLetter = JumpedLetter()
    @Environment(AppRouter.self) private var router
    @Environment(\.locale) private var locale
    @Environment(\.libraryPageDidRefresh) private var pageDidRefresh
    @Environment(\.libraryPageFilteredCount) private var reportFilteredCount
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    var body: some View {
        if let title {
            rootContent
                .navigationTitle(Text(title))
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
        .overlay(alignment: .trailing) {
            #if !os(tvOS)
            // Outside the scroll view, so it stays put while the grid scrolls.
            if showsLetterIndex, let index = viewModel.letterIndex {
                BrowseLetterIndex(
                    available: Set(index.letters.map(\.letter)),
                    jumped: jumpedLetter,
                    onEngage: engageLetterIndex,
                    onPreview: { letter in
                        // Only the iPhone and iPad grid reads by page; the
                        // Mac's jump reads its own window.
                        #if os(iOS)
                        viewModel.prepareJump(to: letter)
                        #endif
                    },
                    onJump: jump(to:)
                )
                .transition(.opacity)
            }
            #endif
        }
        // A new list (sort, filters, refresh) has no jump in it yet.
        .onChange(of: viewModel.letterIndex) { jumpedLetter.letter = nil }
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
        .shuffleFailureAlert(shuffleLauncher)
        .task(id: BrowseConfigurationID(libraryId: libraryId, libraryType: libraryType, mediaScope: mediaScope)) {
            guard await viewModel.configure(libraryId: libraryId, libraryType: libraryType, mediaScope: mediaScope) else { return }
            await viewModel.loadFromTop()
            await viewModel.loadFacetsIfNeeded()
        }
        .refreshable {
            await viewModel.refresh()
            pageDidRefresh?()
        }
        // The iPhone Libraries tab keeps this page alive under its others
        // and asks for a reload when it comes back after a title changed.
        .onChange(of: reloadRequest) {
            Task { await viewModel.refresh() }
        }
        .onChange(of: viewModel.filteredTotal, initial: true) {
            reportFilteredCount?(viewModel.filteredTotal)
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
        .scrollsToTopOnLibraryDockRequest()
        .environment(\.browseLibraryId, libraryId)
    }

    @ViewBuilder
    private var emptyState: some View {
        switch viewModel.emptyReason {
        case .libraryEmpty:
            EmptyStateView(
                icon: emptyLibraryIcon,
                title: AppLanguage.string(.libraryEmpty, locale: locale),
                subtitle: AppLanguage.string(.libraryEmptyBody, locale: locale)
            )
        case .noFilterMatches:
            VStack(spacing: SiloTheme.padding) {
                EmptyStateView(
                    icon: "line.3.horizontal.decrease.circle",
                    title: AppLanguage.string(.libraryNoItemsMatchFilters, locale: locale)
                )
                Button(.libraryClearFilters) {
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

    #if os(iOS)
    /// The whole page in one collection view: the controls, then the grid.
    private var scrollContent: some View {
        BrowseCollectionGrid(
            items: viewModel.items,
            pager: viewModel.pager,
            isLoading: viewModel.isLoading || !viewModel.hasLoaded,
            hasMore: viewModel.hasMore,
            listIdentity: viewModel.listIdentity,
            forcesThreeColumnsOnPhone: libraryId != nil,
            usesSquareArtwork: viewModel.items.first?.isAudiobook ?? (viewModel.mediaType == .audiobook),
            trailingPadding: gridTrailingPadding,
            commands: gridCommands,
            header: { AnyView(gridHeader) },
            onItemTap: { router.navigate(to: .itemDetail(browseItem: $0, libraryId: libraryId)) },
            onLoadMore: {
                Task { await viewModel.loadItems() }
            },
            onRefresh: {
                await viewModel.refresh()
                pageDidRefresh?()
            },
            onUserScroll: { [jumpedLetter] in jumpedLetter.letter = nil }
        )
        .reportsLibraryPageScrollView()
        .environment(\.browseLibraryId, libraryId)
        .onChange(of: scrollToTopRequest) {
            // A letter jump still waiting for its titles would move the page
            // away from the top once they arrive.
            pendingJump?.cancel()
            pendingJump = nil
            gridCommands.scrollToTop()
        }
    }

    private var gridHeader: some View {
        VStack(spacing: SiloTheme.padding) {
            if showsSearchShortcut {
                searchBar
            }

            controlBar

            if hasActiveFilters {
                activeFilterChips
            }
        }
        .frame(maxWidth: .infinity)
    }
    #else
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
                    },
                    hasEarlier: viewModel.hasEarlier,
                    onLoadEarlier: { columns in
                        Task { await viewModel.loadEarlier(columns: columns) }
                    },
                    tracksScrollPosition: letterJump.isEngaged,
                    onColumnCount: { [letterJump] in letterJump.columnCount = $0 }
                )
                .padding(.leading, SiloTheme.padding)
                .padding(.trailing, gridTrailingPadding)
            }
        }
        // Once the letter index is in use, the scroll view follows the card
        // at the top: a jump sets it, and titles loading above it leave it
        // where it is.
        .scrollPosition(id: Bindable(letterJump).cardID, anchor: .top)
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { jumpedLetter.letter = nil }
        }
        .reportsPageChromeScroll()
        .environment(\.browseLibraryId, libraryId)
    }
    #endif

    /// Leaves the letter index its own column beside the posters wherever it
    /// can appear, so the posters don't shift when it does.
    private var gridTrailingPadding: CGFloat {
        #if os(tvOS)
        SiloTheme.padding
        #else
        viewModel.filterState.sort == .title && viewModel.offersLetterIndex
            ? BrowseLetterIndex.reservedWidth
            : SiloTheme.padding
        #endif
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        Button {
            router.navigate(to: .search)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.siloSecondaryText)
                Text(.librarySearchShortcut)
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
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // At accessibility text sizes the chips no longer fit side
                // by side and SwiftUI broke their labels mid-word (#625);
                // stack them along the page's leading edge instead.
                VStack(alignment: .leading, spacing: 9) {
                    sortMenu
                    filterButton
                    shuffleButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // One row when the chips fit. A long sort name ("Latest
                // Episode Air Date") or a longer translation takes its own
                // line, with Filter and Shuffle wrapped below it along the
                // leading edge (#899). Only a name too long for a line of
                // its own ends in an ellipsis.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 9) {
                        sortMenu
                        filterButton
                        shuffleButton
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        sortMenu
                        HStack(spacing: 9) {
                            filterButton
                            shuffleButton
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, SiloTheme.padding)
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
                text: .libraryFilterPill,
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
                controlChip(icon: "shuffle", text: .libraryShufflePill)
            }
            .buttonStyle(.plain)
            .disabled(shuffleLauncher.isStarting)
            .accessibilityIdentifier("library-shuffle")
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(
                CatalogSortKey.available(
                    for: CatalogSortKey.sortMediaType(viewModel.mediaType, mediaScope: viewModel.filterState.mediaScope),
                    shownRatingSources: RatingSourcesStore.shared.shown,
                    current: viewModel.filterState.sort
                ),
                id: \.self
            ) { key in
                Button {
                    Task { await viewModel.setSort(key) }
                } label: {
                    if viewModel.filterState.sort == key {
                        Label {
                            Text(key.label)
                        } icon: {
                            Image(systemName: viewModel.filterState.effectiveOrder == .asc ? "arrow.up" : "arrow.down")
                        }
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

    private func controlChip(icon: String, text: LocalizedStringResource, trailing: LocalizedStringResource? = nil, badge: Int? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.siloBody)
                .lineLimit(1)
                .truncationMode(.tail)
            if let trailing {
                Text(trailing)
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
            if let badge, badge > 0 {
                Text("\(badge)")
                    .fixedSize()
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

    // MARK: - Letter jump

    /// The index jumps by list position, which only title order has.
    private var showsLetterIndex: Bool {
        viewModel.filterState.sort == .title && !viewModel.items.isEmpty
            && (viewModel.letterIndex?.total ?? 0) > 0
    }

    #if os(iOS)
    private func engageLetterIndex() {}

    /// The grid already has a place for every title, so a jump is one
    /// scroll, made once the letter's titles are read or a moment has passed.
    private func jump(to letter: String) {
        pendingJump?.cancel()
        let commands = gridCommands
        let list = viewModel.listIdentity
        pendingJump = Task {
            guard let position = await viewModel.position(forJumpTo: letter), !Task.isCancelled,
                  // A sort, filter or library change while the jump waited
                  // put a different list in the grid.
                  viewModel.listIdentity == list else { return }
            commands.scroll(toPosition: position)
        }
    }
    #else
    private func engageLetterIndex() {
        letterJump.isEngaged = true
    }

    private func jump(to letter: String) {
        letterJump.isEngaged = true
        let state = letterJump
        Task {
            guard let card = await viewModel.jump(to: letter, columns: state.columnCount) else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { state.cardID = card }
        }
    }
    #endif

    // MARK: - Active Filters

    private var hasActiveFilters: Bool { viewModel.hasActiveFilters }

    private var activeFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.filterState.activeChips(locale: locale)) { chip in
                    filterChip(label: chip.label) {
                        Task { await viewModel.removeChip(chip) }
                    }
                }
            }
            .padding(.horizontal, SiloTheme.padding)
            .mouseDragScrolling()
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

#if !os(iOS)
/// Scroll state of the letter index. The scroll view writes `cardID` on
/// every scroll, and nothing draws from it, so scrolling redraws nothing.
@Observable
@MainActor
final class LetterJumpState {
    /// The card at the top of the grid, bound to the scroll position.
    var cardID: String?
    /// Set on the first touch of the letter index; turns on scroll-position
    /// tracking, which plain browsing doesn't pay for.
    var isEngaged = false
    @ObservationIgnored var columnCount = 1
}
#endif

/// The letter the index last jumped to, marked on the index until the grid
/// is scrolled by hand or shows another list.
@Observable
@MainActor
final class JumpedLetter {
    var letter: String?
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

    var title: LocalizedStringResource {
        switch self {
        case .recommended:
            return .libraryRecommended
        case .library:
            return .libraryLibraryTab
        case .collections:
            return .libraryCollections
        }
    }
}

/// Plezy-style chip tab selector for the Recommended/Library/Collections
/// pages. Extracted so screens like `LibrariesTabView` can hoist it into a
/// shared top-chrome `safeAreaInset` overlay.
struct LibraryPageTabSelector: View {
    @Binding var selectedTab: LibraryPageTab
    /// Off when the caller has already made sure every chip fits.
    var scrolls = true

    var body: some View {
        if scrolls {
            ScrollView(.horizontal, showsIndicators: false) {
                chips.mouseDragScrolling()
            }
        } else {
            chips
        }
    }

    private var chips: some View {
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
    @Environment(AppRouter.self) private var router
    @Environment(\.locale) private var locale
    @Environment(\.libraryPageDidRefresh) private var pageDidRefresh

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
                        title: AppLanguage.string(.libraryNoRecommendations, locale: locale),
                        subtitle: AppLanguage.string(.libraryNoRecommendedRowsBody, locale: locale)
                    )
                }
            }

            if ConnectionMonitor.shared.isOffline, !viewModel.sections.isEmpty {
                ServerUnreachablePill()
                    .padding(.top, SiloTheme.padding)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: ConnectionMonitor.shared.isOffline)
        .siloPageBackground()
        .task(id: "\(libraryId):\(mediaScope?.rawValue ?? "all")") {
            await viewModel.loadSections(libraryId: libraryId, mediaScope: mediaScope)
        }
        .refreshable {
            await viewModel.loadSections(libraryId: libraryId, mediaScope: mediaScope)
            pageDidRefresh?()
        }
        // The Libraries tab keeps this page alive under its others, so a
        // title marked watched elsewhere would otherwise keep its old card
        // in Continue Watching and Next Up. Home reloads on the same signal.
        .onReceive(NotificationCenter.default.publisher(for: .homeSectionsShouldRefresh)) { _ in
            Task { await viewModel.loadSections(libraryId: libraryId, mediaScope: mediaScope) }
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
                        },
                        onExploreAll: {
                            router.navigate(to: .sectionCatalog(SectionCatalogTarget(
                                section, scope: .library(libraryId), mediaScope: mediaScope
                            )))
                        }
                    )
                }
            }
            .padding(.bottom, SiloTheme.largePadding)
        }
        .siloScrollEdgeEffect()
        .reportsPageChromeScroll()
        .scrollsToTopOnLibraryDockRequest()
        .environment(\.browseLibraryId, libraryId)
    }

    private var scopeNotice: some View {
        VStack(spacing: SiloTheme.smallPadding) {
            Text(.libraryErrorSomeShelves)
                .font(.siloCaption)
                .foregroundStyle(Color.siloSecondaryText)
            Button(.commonRetry) { Task { await viewModel.loadSections(libraryId: libraryId, mediaScope: mediaScope) } }
        }
        .padding(SiloTheme.padding)
    }
}
