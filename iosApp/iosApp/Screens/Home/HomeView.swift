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
    #if os(tvOS)
    @State private var homeSectionPreferences = HomeSectionPreferences.shared
    #endif
    #if !os(tvOS)
    @State private var homeSectionPreferences = HomeSectionPreferences.shared
    @State private var isRefreshing = false
    @State private var refreshStartedAt: Date?
    @State private var refreshHideTask: Task<Void, Never>?
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
                ErrorView(state: error, onRetry: { Task { await viewModel.loadSections() } })
            } else if viewModel.isLoading {
                Color.clear
            } else if !viewModel.regularSections.isEmpty {
                EmptyStateView(
                    icon: "eye.slash",
                    title: "Home sections are hidden",
                    subtitle: "Choose which rows appear in Settings → General → Home Sections."
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
        .task {
            homeSectionPreferences.refresh()
            await viewModel.loadSections()
        }
        .onAppear {
            // Refresh on return (e.g. after player dismiss) so
            // Continue Watching reflects new progress. Skip the
            // very first appear — `.task` handles the initial
            // load and we don't want two concurrent fetches.
            guard !viewModel.sections.isEmpty else { return }
            Task { await viewModel.loadSections() }
        }
        #else
        ZStack(alignment: .top) {
            homeFeedBackground
                .ignoresSafeArea()

            Group {
                if !displayedSections.isEmpty {
                    scrollContent
                } else if let error = viewModel.error {
                    ErrorView(state: error, onRetry: { Task { await viewModel.loadSections() } })
                } else if viewModel.isLoading {
                    Color.clear
                } else if !viewModel.regularSections.isEmpty {
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
                #if !os(iOS)
                SidebarToggleButton()
                #endif
                // The wordmark is pinned with the utilities so it stays put
                // over the glass strip instead of scrolling away with the feed.
                // It occupies the same 44pt row as the icon buttons so its
                // centre lines up with theirs.
                SiloWordmarkView(width: 72)
                    .frame(height: SiloTheme.topBarIconHitSize)
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

            if isRefreshing {
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
            } else if ConnectionMonitor.shared.isServerUpdateRequired {
                // The server is reachable but v1-only: pilot v2 operations
                // are refused until it is updated.
                ServerUpdateRequiredPill()
                    .padding(.top, 64)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }

        }
        .animation(.easeInOut(duration: 0.18), value: isRefreshing)
        .animation(.easeInOut(duration: 0.18), value: ConnectionMonitor.shared.isOffline)
        .animation(.easeInOut(duration: 0.18), value: ConnectionMonitor.shared.isServerUpdateRequired)
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
    }

    // MARK: - Content

    #if !os(tvOS)
    private var scrollContent: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: HomeFeedMetrics.sectionSpacing) {
                    // Clear runway under the pinned header so the first row
                    // starts below the wordmark and utilities.
                    Color.clear
                        .frame(height: topRunwaySpacing(topSafeAreaInset: runwaySafeAreaInset(geometry)))
                        .id(HomeFocusTarget.topSpacer)

                    ForEach(displayedSections) { section in
                        HomeFeedRow(
                            section: section,
                            onRemoveFromContinueWatching: dismissContinueWatching,
                            onSetWatched: setWatched
                        )
                        .id(HomeFocusTarget.row(section.id))
                    }
                }
                .padding(.bottom, HomeFeedMetrics.bottomRunway)
            }
            .reportsPageChromeScroll(to: chromeScrollState)
            #if os(macOS)
            .siloScrollEdgeEffect()
            #endif
        }
    }
    #endif

    private enum HomeFocusTarget: Hashable {
        case topSpacer
        case row(String)
    }

    /// Rows for the vertical list, in server Home order after filtering empty
    /// and featured sections. Recommendations stay in the For You tab.
    private var displayedSections: [ResolvedSection] {
        #if os(tvOS) || os(iOS)
        // Filter before the Skyline feed performs layout. A hidden section
        // therefore leaves no placeholder: the next visible section inherits
        // the same fixed row slot and vertical anchor.
        return homeSectionPreferences.arrangedSections(viewModel.regularSections)
        #else
        return viewModel.regularSections
        #endif
    }

    #if !os(tvOS)
    /// Home uses the same fixed canvas as the rest of the signed-in app.
    private var homeFeedBackground: some View {
        SiloPageBackdrop()
    }


    private func refreshHome() async {
        await MainActor.run {
            showRefreshStatus()
        }

        async let homeRefresh: Void = viewModel.loadSections()
        async let libraryRefresh: LibrariesResponse? = try? await StartupContentPrefetcher
            .fetchUserLibraries()
        _ = await (homeRefresh, libraryRefresh)

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
    private var sectionSpacing: CGFloat {
        SiloTheme.largePadding
    }

    /// On iOS the ScrollView already starts inside the safe area, so the
    /// runway must not count the status-bar inset a second time.
    private func runwaySafeAreaInset(_ geometry: GeometryProxy) -> CGFloat {
        #if os(iOS)
        return 0
        #else
        return geometry.safeAreaInsets.top
        #endif
    }

    private func topRunwaySpacing(topSafeAreaInset: CGFloat) -> CGFloat {
        // Mirror the floating header's vertical footprint (icon-frame height +
        // bottom padding) so the first row clears it. LazyVStack supplies the
        // remaining row gap; don't double-count it here.
        var runway = topSafeAreaInset + SiloTheme.topBarIconHitSize + SiloTheme.smallPadding
        #if os(iOS)
        runway += headerTopInset + headerToContentGap
        #else
        runway += SiloTheme.largePadding + SiloTheme.smallPadding
        #endif
        return runway
    }
    #endif
}
