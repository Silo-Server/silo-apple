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
    @State private var currentProfile: UserProfile?
    @State private var isRefreshing = false
    @State private var refreshStartedAt: Date?
    @State private var refreshHideTask: Task<Void, Never>?
    #if os(iOS)
    @State private var isShowingControlPicker = false
    @Environment(SiloControlClient.self) private var siloControl
    /// Breathing room between the status-bar safe area and the floating header,
    /// so the logo + action icons sit comfortably below the Dynamic Island
    /// rather than crowding it (matching Plex's tight-but-relaxed top spacing).
    private let headerTopInset: CGFloat = 4
    /// The LazyVStack already contributes its normal section spacing after the
    /// scroll-owned wordmark. Adding a second large header gap pushed the first
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
        .onReceive(NotificationCenter.default.publisher(for: .homeSectionsShouldRefresh)) { _ in
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

            HStack(spacing: 12) {
                #if os(iOS)
                // The wordmark lives inside the vertical ScrollView and leaves
                // with the page. Only the three glass utilities stay pinned.
                Spacer(minLength: 8)
                #else
                SidebarToggleButton()
                SiloWordmarkView(width: 72)
                Spacer(minLength: 8)
                #endif

                // Trailing action cluster: cast / search / profile, evenly
                // spaced as one group so the gaps between glyphs are uniform
                // (matching Plex's top-right icon row).
                HStack(spacing: ContinuumTheme.topBarIconSpacing) {
                    #if os(iOS)
                    SiloControlModeButton(controller: siloControl, usesGlass: true) {
                        isShowingControlPicker = true
                    }
                    #endif

                    TabTopBarActions(
                        profile: currentProfile,
                        usesGlass: true,
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
            }
            .padding(.horizontal, ContinuumTheme.padding)
            #if os(iOS)
            .padding(.top, headerTopInset)
            #endif
            .padding(.bottom, ContinuumTheme.smallPadding)

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
            }

        }
        .animation(.easeInOut(duration: 0.18), value: isRefreshing)
        .animation(.easeInOut(duration: 0.18), value: ConnectionMonitor.shared.isOffline)
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task {
            homeSectionPreferences.refresh()
            await viewModel.loadSections()
            await loadCurrentProfile()
        }
        .refreshable {
            await refreshHome()
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingControlPicker) {
            SiloControlTargetPickerView(request: nil, controller: siloControl)
        }
        #endif
        #endif
        }
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
                    #if os(iOS)
                    homeScrollIdentityHeader
                        .id(HomeFocusTarget.topSpacer)
                    #else
                    // Preserve the existing non-iOS runway while the iOS
                    // wordmark becomes part of the scrolling feed.
                    Color.clear
                        .frame(height: topRunwaySpacing(topSafeAreaInset: geometry.safeAreaInsets.top))
                        .id(HomeFocusTarget.topSpacer)
                    #endif

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
            #if os(macOS)
            .continuumScrollEdgeEffect()
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
        ContinuumPageBackdrop()
    }

    #if os(iOS)
    /// Scroll-owned Home identity. Its frame exactly replaces the former clear
    /// runway, so first-row spacing is unchanged while the logo can now scroll
    /// away. The fixed utility cluster remains independently overlaid above it.
    private var homeScrollIdentityHeader: some View {
        HStack {
            SiloWordmarkView(width: 72)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, ContinuumTheme.padding)
        // The ScrollView now begins inside the device safe area, exactly like
        // the fixed utility overlay. Matching their top inset keeps the logo
        // on the same row instead of underneath the status clock.
        .padding(.top, headerTopInset)
        .frame(
            height: topRunwaySpacing(topSafeAreaInset: 0),
            alignment: .top
        )
        // A large sheet leaves the status-bar region visible by design. Hide
        // the scroll-owned wordmark while details are presented so it never
        // ghosts above the card's rounded top edge.
        .opacity(router.presentedItemDetail == nil ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: router.presentedItemDetail == nil)
    }
    #endif

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

    /// Load the currently-selected profile so we can render its avatar in
    /// the top bar. Non-fatal on failure — we fall back to a generic icon.
    private func loadCurrentProfile() async {
        guard let profileId = AuthService.shared.profileId else { return }
        do {
            let profiles = try await AuthService.shared.getProfiles()
            currentProfile = profiles.first(where: { $0.id == profileId })
        } catch {
            // Leave currentProfile nil; the top bar renders a fallback.
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
        ContinuumTheme.largePadding
    }

    private func topRunwaySpacing(topSafeAreaInset: CGFloat) -> CGFloat {
        // Mirror the floating header's vertical footprint (icon-frame height +
        // bottom padding) so the first row clears it. LazyVStack supplies the
        // remaining row gap; don't double-count it here.
        var runway = topSafeAreaInset + ContinuumTheme.topBarIconHitSize + ContinuumTheme.smallPadding
        #if os(iOS)
        runway += headerTopInset + headerToContentGap
        #else
        runway += ContinuumTheme.largePadding + ContinuumTheme.smallPadding
        #endif
        return runway
    }
    #endif
}
