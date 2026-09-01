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
    @State private var currentProfile: UserProfile?
    @State private var homeScrollOffset: CGFloat = 0
    @State private var isRefreshing = false
    @State private var refreshStartedAt: Date?
    @State private var refreshHideTask: Task<Void, Never>?
    private let chromeFadeDistance: CGFloat = 72
    #if os(iOS)
    @State private var isShowingControlPicker = false
    @Environment(SiloControlClient.self) private var siloControl
    /// Breathing room between the status-bar safe area and the floating header,
    /// so the logo + action icons sit comfortably below the Dynamic Island
    /// rather than crowding it (matching Plex's tight-but-relaxed top spacing).
    private let headerTopInset: CGFloat = 4
    /// Gap between the bottom of the floating header and the first content row.
    /// A touch larger than the inter-section spacing so the header reads as a
    /// distinct band above the rows.
    private let headerToContentGap: CGFloat = ContinuumTheme.largePadding + ContinuumTheme.padding
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
                    contentVerticalOffset: 56,
                    focusRequest: homeFocusRequest,
                    detailReturnFocusRequest: detailReturnFocusRequest,
                    isTopMenuFocused: isTopMenuFocused,
                    onTopMenuFocusRequest: onTopMenuFocusRequest,
                    onItemTap: { navigateToDetail($0) },
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
            Color.continuumBackground
                .ignoresSafeArea()

            Group {
                if !displayedSections.isEmpty {
                    scrollContent
                } else if let error = viewModel.error {
                    ErrorView(state: error, onRetry: { Task { await viewModel.loadSections() } })
                } else if viewModel.isLoading {
                    Color.clear
                } else {
                    EmptyStateView(
                        icon: "play.rectangle.on.rectangle",
                        title: "Nothing to watch yet",
                        subtitle: "Add media to your libraries or start watching to see it here."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: .top)

            HStack(spacing: 12) {
                SidebarToggleButton()

                SiloWordmarkView(width: 72)

                Spacer(minLength: 8)

                // Trailing action cluster: cast / search / profile, evenly
                // spaced as one group so the gaps between glyphs are uniform
                // (matching Plex's top-right icon row).
                HStack(spacing: ContinuumTheme.topBarIconSpacing) {
                    #if os(iOS)
                    SiloControlModeButton(controller: siloControl) {
                        isShowingControlPicker = true
                    }
                    #endif

                    TabTopBarActions(
                        profile: currentProfile,
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
            .background {
                homeHeaderChrome
                    .opacity(headerChromeOpacity)
                    .ignoresSafeArea(edges: .top)
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
            }

        }
        .animation(.easeInOut(duration: 0.18), value: isRefreshing)
        .animation(.easeInOut(duration: 0.18), value: ConnectionMonitor.shared.isOffline)
        #if !os(macOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task {
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
                    // No hero — reserve runway for the floating Home header so
                    // the first row doesn't slide under the status-bar chrome.
                    Color.clear
                        .frame(height: topRunwaySpacing(topSafeAreaInset: geometry.safeAreaInsets.top))
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
            .continuumScrollEdgeEffect()
        }
        // Keep the overlay chrome transparent at rest, then fade in a subtle
        // glass surface once content has moved underneath it.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, newValue in
            homeScrollOffset = max(0, newValue)
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
        #if os(tvOS)
        // Filter before the Skyline feed performs layout. A hidden section
        // therefore leaves no placeholder: the next visible section inherits
        // the same fixed row slot and vertical anchor.
        return homeSectionPreferences.arrangedSections(viewModel.regularSections)
        #else
        return viewModel.regularSections
        #endif
    }

    #if !os(tvOS)
    private var headerChromeOpacity: Double {
        let progress = min(max(homeScrollOffset / chromeFadeDistance, 0), 1)
        return Double(progress)
    }

    @ViewBuilder
    private var homeHeaderChrome: some View {
        let borderOpacity = 0.06 + (0.04 * headerChromeOpacity)

        Color.clear
            .siloGlass(in: .rect, tint: Color.black.opacity(0.08))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(borderOpacity))
                    .frame(height: 0.75)
            }
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

    private func navigateToDetail(_ contentId: String) {
        router.navigate(to: .itemDetail(contentId: contentId))
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
        // bottom padding) so the first row always clears it, then add the
        // top inset and the Plex-style gap beneath the header.
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
