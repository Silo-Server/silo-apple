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

    @State private var viewModel: TVLibraryGridViewModel
    @State private var selectedPrefix: String? = nil
    @State private var openPanel: TVBrowsePanel? = nil
    @State private var controlFocusRequest = 0
    @State private var gridFocusRequest = 0
    @State private var lastShellFocusRequest = 0

    @Environment(AppRouter.self) private var router

    init(
        libraryId: Int,
        libraryName: String,
        libraryType: String,
        initialFilter: CatalogFilterState = .none,
        subtitle: String? = nil,
        showsHeader: Bool = true,
        showsAlphabetRail: Bool = true,
        topContentInset: CGFloat = ContinuumTheme.smallPadding,
        focusRequest: Int = 0,
        isTopMenuFocused: Bool = false,
        onTopMenuFocusRequest: (() -> Void)? = nil
    ) {
        self.libraryId = libraryId
        self.libraryName = libraryName
        self.libraryType = libraryType
        self.initialFilter = initialFilter
        self.subtitle = subtitle
        self.showsHeader = showsHeader
        self.showsAlphabetRail = showsAlphabetRail
        self.topContentInset = topContentInset
        self.focusRequest = focusRequest
        self.isTopMenuFocused = isTopMenuFocused
        self.onTopMenuFocusRequest = onTopMenuFocusRequest
        _viewModel = State(initialValue: TVLibraryGridViewModel(
            libraryId: libraryId,
            libraryType: libraryType,
            initialFilter: initialFilter
        ))
        _selectedPrefix = State(initialValue: initialFilter.namePrefix)
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
        .animation(.easeOut(duration: 0.18), value: openPanel)
        .continuumBackground()
        .task {
            if viewModel.items.isEmpty {
                await viewModel.loadInitial()
            }
            await viewModel.loadFacetsIfNeeded()
        }
        .onAppear { noteShellFocusRequest(focusRequest) }
        .onDisappear { viewModel.cancelPosterPrefetch() }
        .onChange(of: focusRequest) { _, request in noteShellFocusRequest(request) }
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
                        .padding(.horizontal, ContinuumTheme.safePadding)
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
                    onFilter: { openPanel = .filter }
                )
                .padding(.horizontal, ContinuumTheme.safePadding)

                if viewModel.items.isEmpty && viewModel.isLoading {
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: 400)
                } else if let error = viewModel.error, viewModel.items.isEmpty {
                    ErrorView(state: error, onRetry: { Task { await viewModel.loadInitial() } })
                } else if viewModel.items.isEmpty {
                    EmptyStateView(
                        icon: emptyGridIcon,
                        title: "No titles match",
                        subtitle: "Try a different letter or filter."
                    )
                    .frame(maxWidth: .infinity, minHeight: 400)
                } else {
                    TVCatalogGrid(
                        items: viewModel.items,
                        isLoading: viewModel.isLoading,
                        hasMore: viewModel.hasMore,
                        onItemTap: { item in
                            router.navigate(to: .itemDetail(browseItem: item))
                        },
                        onNearEnd: { _ in
                            Task { await viewModel.loadMoreIfNeeded() }
                        },
                        focusRequest: gridFocusRequest,
                        onRowVisibilityChange: { range, isVisible in
                            viewModel.setPosterRowVisibility(range, isVisible: isVisible)
                        }
                    )
                    .padding(.horizontal, ContinuumTheme.safePadding)
                }
            }
            .padding(.bottom, 48)
        }
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
                .foregroundColor(.continuumOnSurface)

            if let prefix = selectedPrefix {
                Text(prefix == "#" ? "Titles starting with a number or symbol" : "Titles starting with \(prefix)")
                    .font(.continuumHeadline)
                    .foregroundColor(.continuumSecondaryText)
            } else if let subtitle {
                Text(subtitle)
                    .font(.continuumHeadline)
                    .foregroundColor(.continuumSecondaryText)
            } else if let total = totalLabel {
                Text(total)
                    .font(.continuumHeadline)
                    .foregroundColor(.continuumSecondaryText)
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
