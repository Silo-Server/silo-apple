import SwiftUI

extension Notification.Name {
    static let homeSectionsShouldRefresh = Notification.Name("homeSectionsShouldRefresh")
}

/// Main home screen. iOS/macOS render resume-first section rows on a flat
/// background; tvOS uses the Skyline focus marquee (§5.4) — a passive
/// billboard previewing whichever card holds focus.
struct HomeView: View {
    var homeFocusRequest: Int = 0
    /// tvOS-only: a pushed detail page has popped and Home should restore the
    /// exact card/row that launched it instead of leaving the focus graph empty.
    var detailReturnFocusRequest: Int = 0
    /// tvOS-only: whether the custom top menu holds focus. Deferred entry
    /// claims are dropped while the user is up in the menu so late data
    /// loads never yank focus.
    var isTopMenuFocused: Bool = false
    var onTopMenuFocusRequest: (() -> Void)? = nil

    @State private var viewModel = HomeViewModel()
    @State private var homeSectionPreferences = HomeSectionPreferences.shared
    #if !os(tvOS)
    @State private var refreshPill = RefreshStatusPillState()
    /// Feeds the glass strip behind the floating header as rows scroll under it.
    @State private var chromeScrollState = PageChromeScrollState()
    #if os(iOS)
    /// Breathing room between the status-bar safe area and the floating
    /// header. Uses the same value as the Libraries and For You top chrome so
    /// the shared action cluster sits at one height on every root page.
    private let headerTopInset: CGFloat = SiloTheme.smallPadding
    /// The LazyVStack already contributes its normal section spacing after the
    /// header runway. Adding a second large header gap pushed the first
    /// visible row far down the screen whenever an earlier Home row was hidden.
    private let headerToContentGap: CGFloat = 0
    #endif
    #endif
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var viewModel = viewModel

        Group {
            // On iOS the header floats over the scroll content, which extends
            // behind the status bar with a semi-transparent fill. On tvOS the
            // app-level top bar (owned by `TVMainTabView`) handles profile +
            // utility actions; Home renders the focus marquee over rows, with
            // the backdrop tracking whichever card holds focus (§5.4).
        #if os(tvOS)
        // The shared Skyline feed uses the same layout component as the
        // library Browse tabs; Home supplies only the server-resolved Home rows.
        Group {
            if !displayedSections.isEmpty {
                TVSkylineSectionFeed(
                    sections: displayedSections,
                    focusRequest: homeFocusRequest,
                    detailReturnFocusRequest: detailReturnFocusRequest,
                    isTopMenuFocused: isTopMenuFocused,
                    onTopMenuFocusRequest: onTopMenuFocusRequest,
                    onItemTap: navigateToDetail,
                    onRemoveFromContinueWatching: dismissContinueWatching,
                    onSetWatched: setWatched
                )
                // Preference edits replace the row band as one stable unit:
                // the next visible row takes the vacated slot at the fixed
                // first-row anchor, and no marquee from a hidden row lingers.
                .id(homeSectionPreferences.layoutRevision)
            } else if let error = viewModel.error {
                ErrorView(
                    state: error,
                    onRetry: { Task { await viewModel.loadSections() } },
                    onManageServers: { router.navigate(to: .serverList) }
                )
            } else if viewModel.isLoading {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tvPageFocusOwner(
                        focusRequest: homeFocusRequest,
                        isTopMenuFocused: isTopMenuFocused,
                        accessibilityLabel: "Loading home",
                        onMoveUp: onTopMenuFocusRequest
                    )
            } else if !viewModel.sections.isEmpty {
                EmptyStateView(
                    icon: "eye.slash",
                    title: "Home sections are hidden",
                    subtitle: "Choose which rows appear in Settings → General → Home Sections."
                )
                .tvPageFocusOwner(
                    focusRequest: homeFocusRequest,
                    isTopMenuFocused: isTopMenuFocused,
                    accessibilityLabel: "Home sections are hidden",
                    onMoveUp: onTopMenuFocusRequest
                )
            } else {
                EmptyStateView(
                    icon: "play.rectangle.on.rectangle",
                    title: "Nothing to watch yet",
                    subtitle: "Add media to your libraries or start watching to see it here."
                )
                .tvPageFocusOwner(
                    focusRequest: homeFocusRequest,
                    isTopMenuFocused: isTopMenuFocused,
                    accessibilityLabel: "Nothing to watch yet",
                    onMoveUp: onTopMenuFocusRequest
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Runs on every appear, so returning from the player refreshes
        // Continue Watching.
        .task {
            homeSectionPreferences.refresh()
            await viewModel.loadSections()
        }
        #else
        ZStack(alignment: .top) {
            SiloPageBackdrop()
                .ignoresSafeArea()

            Group {
                if !displayedSections.isEmpty {
                    scrollContent
                } else if let error = viewModel.error {
                    ErrorView(
                        state: error,
                        onRetry: { Task { await viewModel.loadSections() } },
                        onManageServers: { router.navigate(to: .serverList) }
                    )
                } else if viewModel.isLoading {
                    PosterRowsSkeleton()
                        .padding(.top, topRunwaySpacing(topSafeAreaInset: 0))
                } else if !viewModel.sections.isEmpty {
                    EmptyStateView(
                        icon: "eye.slash",
                        title: "Home sections are hidden",
                        subtitle: "Choose which rows appear in Settings → Interface → Home Sections."
                    )
                } else {
                    EmptyStateView(
                        icon: "play.rectangle.on.rectangle",
                        title: "Nothing to watch yet",
                        subtitle: "Add media to your libraries or start watching to see it here."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(alignment: .center, spacing: 12) {
                SidebarToggleButton()
                // The wordmark is pinned with the utilities so it stays put
                // over the glass strip instead of scrolling away with the feed.
                // It occupies the same 44pt row as the icon buttons so its
                // centre lines up with theirs.
                #if !os(macOS)
                SiloWordmarkView(width: 72)
                    .frame(height: SiloTheme.topBarIconHitSize)
                #endif
                Spacer(minLength: 8)

                // Trailing action cluster shared by every root page.
                TabTopBarActions(
                    onSearch: { router.navigate(to: .search) },
                    onOpenSettings: { router.navigate(to: .settings) },
                    onOpenRequests: { router.navigate(to: .requestsHub) },
                    onSwitchProfile: {
                        router.switchProfile()
                    },
                    onSwitchServer: { router.navigate(to: .serverList) },
                    onSignOut: { router.signOutAndReset() }
                )
            }
            .padding(.horizontal, SiloTheme.padding)
            #if os(iOS)
            .padding(.top, headerTopInset)
            #endif
            .padding(.bottom, SiloTheme.smallPadding)
            // Same scroll-driven glass as the Detail page chrome so the
            // utilities stay legible over bright artwork once rows scroll
            // underneath.
            .background {
                PageChromeGlass(scrollState: chromeScrollState)
            }

            if refreshPill.isVisible {
                RefreshStatusPill()
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            } else if ConnectionMonitor.shared.isOffline, !viewModel.sections.isEmpty {
                // Cached sections are painted but the server can't be
                // reached — say so instead of silently showing stale data.
                ServerUnreachablePill()
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }

        }
        .animation(.easeInOut(duration: 0.18), value: refreshPill.isVisible)
        .animation(.easeInOut(duration: 0.18), value: ConnectionMonitor.shared.isOffline)
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task {
            homeSectionPreferences.refresh()
            await viewModel.loadSections()
        }
        .refreshable {
            await refreshHome()
        }
        #endif
        }
        #if os(iOS) || os(tvOS)
        .onReceive(NotificationCenter.default.publisher(for: .homeSectionsShouldRefresh)) { _ in
            Task { await viewModel.loadSections() }
        }
        #endif
        .alert(
            "Couldn’t Update Item",
            isPresented: $viewModel.isShowingActionError
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.actionError?.message ?? "The item could not be updated. Try again.")
        }
        .personalStateNoticeAlert($viewModel.personalStateNotice)
    }

    // MARK: - Content

    #if os(iOS)
    private var scrollContent: some View {
        feedScrollView(topSafeAreaInset: 0)
    }
    #elseif os(macOS)
    private var scrollContent: some View {
        GeometryReader { geometry in
            feedScrollView(topSafeAreaInset: geometry.safeAreaInsets.top)
                .siloScrollEdgeEffect()
        }
    }
    #endif

    #if !os(tvOS)
    private func feedScrollView(topSafeAreaInset: CGFloat) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: HomeFeedMetrics.sectionSpacing) {
                // Clear runway under the pinned header so the first row
                // starts below the wordmark and utilities.
                Color.clear
                    .frame(height: topRunwaySpacing(topSafeAreaInset: topSafeAreaInset))

                ForEach(displayedSections) { section in
                    HomeFeedRow(
                        section: section,
                        onRemoveFromContinueWatching: dismissContinueWatching,
                        onSetWatched: setWatched
                    )
                    .onAppear { warmRows(after: section) }
                }
            }
            .padding(.bottom, HomeFeedMetrics.bottomRunway)
        }
        .reportsPageChromeScroll(to: chromeScrollState)
    }

    /// Decode the leading cards of the rows below one that appeared, so
    /// scrolling down reveals painted artwork rather than thumbhashes.
    private func warmRows(after section: ResolvedSection) {
        let sections = displayedSections
        guard let index = sections.firstIndex(where: { $0.id == section.id }) else { return }
        let next = sections.dropFirst(index + 1).prefix(ArtworkLookahead.rowsAhead)
        ArtworkLookahead.warmRows(next, items: \.items) { section, item in
            HomeFeedRow.cardArtwork(for: item, in: section)
        }
    }
    #endif

    /// Rows in the profile's Home order with hidden rows removed. Filtering
    /// before layout means a hidden row leaves no gap: the next row takes its
    /// slot.
    private var displayedSections: [ResolvedSection] {
        homeSectionPreferences.arrangedSections(viewModel.sections)
    }

    #if !os(tvOS)
    private func refreshHome() async {
        await refreshPill.run {
            async let homeRefresh: Void = viewModel.loadSections()
            async let libraryRefresh: LibrariesResponse? = try? await StartupContentPrefetcher
                .fetchUserLibraries(reusingRecent: false)
            _ = await (homeRefresh, libraryRefresh)
        }
    }

    #endif

    // MARK: - Navigation

    private func navigateToDetail(_ destinationContentId: String, _ item: SectionItem) {
        router.navigate(
            to: .itemDetail(
                destinationContentId: destinationContentId,
                sectionItem: item
            )
        )
    }

    private func dismissContinueWatching(_ item: SectionItem) {
        Task {
            await viewModel.dismissContinueWatchingItem(item)
        }
    }

    private func setWatched(_ item: SectionItem, played: Bool) async -> Bool {
        await viewModel.setWatched(item, played: played)
    }

    #if !os(tvOS)
    private func topRunwaySpacing(topSafeAreaInset: CGFloat) -> CGFloat {
        // Mirror the floating header's vertical footprint (icon-frame height +
        // bottom padding) so the first row clears it. LazyVStack supplies the
        // remaining row gap; don't double-count it here.
        #if os(macOS)
        // The Mac sidebar carries the logo and utilities, so Home has no
        // floating header to clear, and the feed already starts below the
        // title bar. The stack's section spacing is the only top gap.
        return 0
        #else
        var runway = topSafeAreaInset + SiloTheme.topBarIconHitSize + SiloTheme.smallPadding
        #if os(iOS)
        runway += headerTopInset + headerToContentGap
        #else
        runway += SiloTheme.largePadding + SiloTheme.smallPadding
        #endif
        return runway
        #endif
    }
    #endif
}
