#if os(tvOS)
import SwiftUI

/// Grid + letter-rail view for a single library on tvOS.
///
/// Can be entered either from the landing page (with a pre-applied filter,
/// e.g. genre=Action) or directly (`TVLibraryFilter.none`) for a full browse.
/// The letter rail always sits on the right and modifies `namePrefix` on the
/// current filter, so "Action / T" is a valid composite state.
struct TVLibraryGridView: View {
    let libraryId: Int
    let libraryName: String
    let libraryType: String
    let mediaScope: LibraryVideoScope?
    let initialFilter: CatalogFilterState
    let subtitle: String?
    /// Pushed full-screen entries render the big library header; Skyline
    /// pill embeds hide it — the top bar + pill row already say where the
    /// user is.
    let showsHeader: Bool
    /// The A–Z jump rail only makes sense for title-sorted browsing; the
    /// Recently Added pill turns it off.
    let showsAlphabetRail: Bool
    /// Top inset before the first content. Pushed entries keep the compact
    /// default; pill embeds pass the Skyline chrome clearance.
    let topContentInset: CGFloat
    /// Focus hand-down token from the root shell. Embedded Browse tabs use this
    /// to land on the control row after the top menu hands focus to content.
    let focusRequest: Int
    /// Deferred focus claims are dropped while the top menu is focused so async
    /// page work never yanks focus back into Browse.
    let isTopMenuFocused: Bool
    /// Boundary hand-up from the control row to the root top menu. Nil for
    /// pushed grid routes where the root menu is not visible.
    let onTopMenuFocusRequest: (() -> Void)?

    @State private var modelSlot = LazyModel<TVLibraryGridViewModel>()
    @State private var selectedPrefix: String? = nil
    @State private var openPanel: TVBrowsePanel? = nil
    @State private var controlFocusRequest = 0
    @State private var gridFocusRequest = 0
    @State private var lastShellFocusRequest = 0
    @State private var shuffleLauncher = ShuffleLauncher()

    @Environment(AppRouter.self) private var router

    init(
        libraryId: Int,
        libraryName: String,
        libraryType: String,
        mediaScope: LibraryVideoScope? = nil,
        initialFilter: CatalogFilterState = .none,
        subtitle: String? = nil,
        showsHeader: Bool = true,
        showsAlphabetRail: Bool = true,
        topContentInset: CGFloat = SiloTheme.smallPadding,
        focusRequest: Int = 0,
        isTopMenuFocused: Bool = false,
        onTopMenuFocusRequest: (() -> Void)? = nil
    ) {
        self.libraryId = libraryId
        self.libraryName = libraryName
        self.libraryType = libraryType
        self.mediaScope = mediaScope
        self.initialFilter = initialFilter
        self.subtitle = subtitle
        self.showsHeader = showsHeader
        self.showsAlphabetRail = showsAlphabetRail
        self.topContentInset = topContentInset
        self.focusRequest = focusRequest
        self.isTopMenuFocused = isTopMenuFocused
        self.onTopMenuFocusRequest = onTopMenuFocusRequest
        _selectedPrefix = State(initialValue: initialFilter.namePrefix)
    }

    private var viewModel: TVLibraryGridViewModel {
        modelSlot.value {
            TVLibraryGridViewModel(
                libraryId: libraryId,
                libraryType: libraryType,
                mediaScope: mediaScope,
                initialFilter: initialFilter
            )
        }
    }

    /// A library shuffle has no media type, so the Movies or Series view of
    /// a mixed library would shuffle titles of both types.
    private var canShuffle: Bool {
        mediaScope == nil
            && ShuffleAvailability.isShuffleLibraryType(libraryType)
            && ShuffleFeatureStore.shared.supports(.library)
    }

    var body: some View {
        ZStack {
            HStack(alignment: .top, spacing: 0) {
                gridColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusSection()

                if showsAlphabetRail {
                    TVAlphabetRail(selected: $selectedPrefix) { prefix in
                        Task { await viewModel.jumpToPrefix(prefix) }
                    }
                    .padding(.trailing, 32)
                }
            }
            // While a panel is open the grid is inert, so focus moves into the
            // panel and returns to the control row when it closes.
            .disabled(openPanel != nil)

            if let panel = openPanel {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                panelOverlay(panel)
            }
        }
        .environment(\.browseLibraryId, libraryId)
        .animation(.easeOut(duration: 0.18), value: openPanel)
        .siloBackground()
        .task {
            if viewModel.items.isEmpty {
                await viewModel.loadInitial()
            }
            await viewModel.loadFacetsIfNeeded()
        }
        .onDisappear { viewModel.cancelPosterPrefetch() }
    }

    @ViewBuilder
    private func panelOverlay(_ panel: TVBrowsePanel) -> some View {
        switch panel {
        case .sort:
            TVBrowseSortPanel(
                mediaType: viewModel.mediaType,
                current: viewModel.filter.sort,
                order: viewModel.filter.effectiveOrder,
                onSelect: { key in
                    Task { await viewModel.setSort(key) }
                    openPanel = nil
                },
                onClose: { openPanel = nil }
            )
        case .filter:
            TVBrowseFilterPanel(
                mediaType: viewModel.mediaType,
                facets: viewModel.facets ?? CatalogFacets(),
                initial: viewModel.filter,
                preserveEnabled: viewModel.preserveEnabled,
                onApply: { state in Task { await viewModel.applyFilter(state) } },
                onPreserveChange: { viewModel.setPreserveEnabled($0) },
                onClose: { openPanel = nil }
            )
        }
    }

    // MARK: - Grid column

    private var gridColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if showsHeader {
                    header
                        .padding(.horizontal, SiloTheme.safePadding)
                        .padding(.top, topContentInset)
                } else {
                    Color.clear
                        .frame(height: topContentInset)
                }

                TVBrowseControlRow(
                    sortLabel: viewModel.filter.sort.label,
                    sortDirection: viewModel.filter.sort.directionLabel(for: viewModel.filter.effectiveOrder),
                    filterCount: viewModel.filter.activeFacetCount,
                    focusRequest: controlFocusRequest,
                    onMoveUp: onTopMenuFocusRequest,
                    onMoveDown: claimGridFocus,
                    onSort: { openPanel = .sort },
                    onFilter: { openPanel = .filter },
                    onShuffle: canShuffle ? {
                        shuffleLauncher.start(ShuffleScopeRequest(kind: .library, id: String(libraryId)), router: router)
                    } : nil,
                    isShuffleStarting: shuffleLauncher.isStarting
                )
                .padding(.horizontal, SiloTheme.safePadding)
                .shuffleFailureAlert(shuffleLauncher)

                if viewModel.items.isEmpty && viewModel.isLoading {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 40),
                            count: AdaptiveColumns.tvPosterCount(
                                standardCount: 6,
                                posterSize: UICustomizationPreferences.shared.cardPresentation.posterSize
                            )
                        ),
                        spacing: 60
                    ) {
                        ForEach(0..<12, id: \.self) { _ in
                            PosterSkeletonCard()
                        }
                    }
                    .padding(.horizontal, SiloTheme.safePadding)
                } else if let error = viewModel.error, viewModel.items.isEmpty {
                    ErrorView(state: error, onRetry: { Task { await viewModel.loadInitial() } })
                } else if viewModel.items.isEmpty {
                    // A full-width focus section: the centered Clear filters
                    // button sits outside the straight-down path from the
                    // left-aligned Sort/Filter pills, so Down only finds it
                    // by entering this section.
                    emptyState
                        .frame(maxWidth: .infinity, minHeight: 400)
                        .focusSection()
                } else {
                    TVCatalogGrid(
                        items: viewModel.items,
                        isLoading: viewModel.isLoading,
                        hasMore: viewModel.hasMore,
                        onItemTap: { item in
                            router.navigate(to: .itemDetail(browseItem: item, libraryId: libraryId))
                        },
                        onNearEnd: { _ in
                            Task { await viewModel.loadMoreIfNeeded() }
                        },
                        focusRequest: gridFocusRequest,
                        onRowVisibilityChange: { range, isVisible in
                            viewModel.setPosterRowVisibility(range, isVisible: isVisible)
                        }
                    )
                    .padding(.horizontal, SiloTheme.safePadding)
                }
            }
            .padding(.bottom, 48)
        }
        .modifier(TVMenuEntryScroll(request: focusRequest, isTopMenuFocused: isTopMenuFocused, onReady: noteShellFocusRequest))
    }

    // MARK: - Focus routing

    private func noteShellFocusRequest(_ request: Int) {
        guard request > 0, request != lastShellFocusRequest else { return }
        lastShellFocusRequest = request
        guard !isTopMenuFocused else { return }
        controlFocusRequest += 1
    }

    private func claimGridFocus() {
        guard !viewModel.items.isEmpty else { return }
        gridFocusRequest += 1
    }

    // MARK: - Empty state

    /// An empty library has nothing to act on, so it stays inert; the
    /// control row and letter rail keep the page focusable. Filters that
    /// match nothing add one native Clear filters button, which Down from the
    /// control row and Left from the letter rail both reach through the
    /// focus engine.
    @ViewBuilder
    private var emptyState: some View {
        switch viewModel.emptyReason {
        case .libraryEmpty:
            EmptyStateView(
                icon: emptyGridIcon,
                title: "This library is empty",
                subtitle: "There is nothing in this library yet."
            )
        case .noFilterMatches:
            VStack(spacing: 32) {
                EmptyStateView(
                    icon: "line.3.horizontal.decrease.circle",
                    title: "No titles match your filters"
                )
                .fixedSize(horizontal: false, vertical: true)

                Button(action: clearFilters) {
                    HStack(spacing: 10) {
                        Image(systemName: "xmark.circle")
                        Text("Clear filters")
                    }
                    .font(.system(size: 24, weight: .medium))
                }
                .buttonStyle(TVBrowseControlPillStyle())
            }
        }
    }

    private func clearFilters() {
        selectedPrefix = nil
        // The reload removes this button, so hand focus to the control row's
        // first pill instead of leaving the focus engine to guess.
        controlFocusRequest += 1
        Task { await viewModel.clearFilters() }
    }

    private var emptyGridIcon: String {
        if SiloMediaType.isSeries(libraryType) { return "tv" }
        if SiloMediaType.isAudiobook(libraryType) { return "book.closed" }
        return "film.stack"
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(libraryName)
                .font(.system(size: 64, weight: .bold))
                .foregroundColor(.siloOnSurface)

            if let prefix = selectedPrefix {
                Text(prefix == "#" ? "Titles starting with a number or symbol" : "Titles starting with \(prefix)")
                    .font(.siloHeadline)
                    .foregroundColor(.siloSecondaryText)
            } else if let subtitle {
                Text(subtitle)
                    .font(.siloHeadline)
                    .foregroundColor(.siloSecondaryText)
            } else if let total = totalLabel {
                Text(total)
                    .font(.siloHeadline)
                    .foregroundColor(.siloSecondaryText)
            }
        }
    }

    private var totalLabel: String? {
        guard !viewModel.items.isEmpty else { return nil }
        return viewModel.hasMore
            ? "\(viewModel.items.count)+ titles"
            : "\(viewModel.items.count) titles"
    }
}
#endif
