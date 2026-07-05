import SwiftUI

struct ContentView: View {
    @State private var router = AppRouter()
    @State private var audioStore = AudioPlaybackStore()
    #if os(iOS)
    @State private var siloControl = SiloControlClient()
    #endif
    @State private var debugPlayContentId: String?
    @State private var didAttemptDebugAutoPlay = false
    @State private var didStartInitialStateCheck = false
    @State private var didFinishStartupSplash = false
    @State private var pendingInitialAuthState: AppRouter.AuthState?
    /// Deep link URL received before the auth state was ready. Drained
    /// on the next `.authenticated` transition so Top Shelf taps during
    /// a cold launch still route to the correct screen.
    @State private var pendingDeepLink: URL?
    /// Shared with every screen that renders cards. Hydrates lazily on
    /// the first .authenticated transition so cards stay visible during
    /// the brief window between sign-in and the overlay-config fetch.
    @StateObject private var overlayPrefs = OverlayPrefsStore.shared
    /// Used to retry overlay hydration on foreground transitions: if the
    /// initial fetch failed transiently, `hydrateIfNeeded()` will retry
    /// because the store left `hasHydrated == false`. Idempotent when
    /// the previous hydration succeeded.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        authContent
        .environment(audioStore)
        #if os(iOS)
        .environment(siloControl)
        #endif
        .environmentObject(overlayPrefs)
        .preferredColorScheme(.dark)
        #if os(iOS)
        // Hold the pairing offer until the startup splash logo finishes so a
        // quickly-discovered TV doesn't pop the card over the animation.
        .companionPairingCard(enabled: didFinishStartupSplash && router.authState != .loading)
        #endif
        .modifier(DebugPlayerPresentationModifier(
            contentId: debugPlayContentId,
            isPresented: debugPlayerPresentation
        ))
        .onReceive(NotificationCenter.default.publisher(for: .continuumDeepLink)) { notification in
            guard let url = notification.userInfo?["url"] as? URL else { return }
            #if os(iOS)
            ApplePushDeepLinkCoordinator.shared.clearPendingDeepLink(matching: url)
            #endif
            handleDeepLink(url)
        }
        .onAppear {
            #if os(iOS)
            if let url = ApplePushDeepLinkCoordinator.shared.consumePendingDeepLink() {
                handleDeepLink(url)
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .continuumSessionExpired)) { _ in
            audioStore.dismissFullPlayer()
            Task { await audioStore.player.close() }
            #if !os(tvOS)
            DownloadManager.shared.clearForSignOut()
            #endif
            router.expiredSession()
        }
        .task {
            // Debug: auto-play from launch argument -debugPlay <contentId>
            if let idx = CommandLine.arguments.firstIndex(of: "-debugPlay"),
               idx + 1 < CommandLine.arguments.count {
                let contentId = CommandLine.arguments[idx + 1]
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                debugPlayContentId = contentId
            }
        }
        .task(id: router.authState) {
            await maybeAutoPlayForDebug()
            if router.authState == .authenticated {
                if let pending = pendingDeepLink {
                    pendingDeepLink = nil
                    handleDeepLink(pending)
                }
                await overlayPrefs.hydrateIfNeeded()
                // Hydrate AI capabilities on a cold relaunch into a restored
                // session — `selectProfile` only refreshes on a fresh sign-in,
                // so without this the metadata-language / on-view-translate
                // features stay hidden until a profile switch. Idempotent and
                // failure-tolerant, so double-calling with `selectProfile` is safe.
                await AICapabilities.shared.refresh()
                await RequestsFeatureStore.shared.refresh()
                #if os(iOS)
                await ApplePushRegistrationCoordinator.shared.prepareForAuthenticatedProfile()
                #endif
                #if !os(tvOS)
                await DownloadManager.shared.onAppActive()
                #endif
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            #if os(iOS)
            switch newPhase {
            case .active:
                siloControl.appDidBecomeActive()
            case .background:
                siloControl.appDidEnterBackground()
                // Keep series monitoring alive while backgrounded; only
                // worth a wake when the profile can download at all.
                if DownloadManager.shared.downloadsEnabled {
                    DownloadBackgroundRefresh.schedule()
                }
            default:
                break
            }
            #endif

            // Cover the transient-failure case Codex flagged on #41:
            // initial overlay hydration runs once in the auth-state
            // task above. If that fetch transiently failed and the
            // user never opens overlay settings, the admin kill
            // switch and baseline stay stale until app restart.
            // Foreground transitions are a natural opportunity to
            // retry — `hydrateIfNeeded()` is a no-op when the
            // previous hydration succeeded, so this costs nothing in
            // the happy path.
            guard newPhase == .active,
                  router.authState == .authenticated else { return }
            Task { await overlayPrefs.hydrateIfNeeded() }
            // Same rationale as overlay hydration above: a transiently-failed
            // capability probe (or one skipped on a cold restore) gets a
            // natural retry on foreground. `refresh()` is idempotent, so the
            // happy path costs nothing.
            Task { await AICapabilities.shared.refresh() }
            Task { await RequestsFeatureStore.shared.refresh() }
            #if os(iOS)
            Task {
                await ApplePushRegistrationCoordinator.shared.prepareForAuthenticatedProfile()
                await ApplePushRegistrationCoordinator.shared.registerCurrentDeviceTokenIfPossible()
            }
            #endif
            #if os(tvOS)
            NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
            #endif
            #if !os(tvOS)
            Task { await DownloadManager.shared.onAppActive() }
            #endif
        }
    }

    @ViewBuilder
    private var authContent: some View {
        switch router.authState {
        case .loading:
            StartupSplashView {
                didFinishStartupSplash = true
                finishInitialStartupIfReady()
            }
            .task {
                guard !didStartInitialStateCheck else { return }
                didStartInitialStateCheck = true
                await checkInitialState()
            }

        case .needsServerSetup:
            #if os(tvOS)
            TVServerSetupView(router: router)
            #else
            ServerSetupView(router: router)
            #endif

        case .needsLogin:
            NavigationStack(path: $router.path) {
                loginRoot
                    .navigationDestination(for: Route.self) { route in
                        destinationView(for: route)
                    }
            }

        case .needsProfile:
            NavigationStack(path: $router.path) {
                ProfileSelectionView(router: router)
                    .navigationDestination(for: Route.self) { route in
                        profileFlowDestination(for: route)
                    }
            }
            .environment(router)

        case .authenticated:
            #if os(tvOS)
            TVMainTabView(router: router)
            #else
            MainTabView(router: router)
            #endif
        }
    }

    private var debugPlayerPresentation: Binding<Bool> {
        Binding(
            get: { debugPlayContentId != nil },
            set: { if !$0 { debugPlayContentId = nil } }
        )
    }

    /// Resolves a `continuum://` URL to a navigation action. Supported
    /// shapes:
    /// - `continuum://item/{contentId}` — push the detail screen
    /// - `continuum://play/{contentId}` — push the player (resume from
    ///   last known position)
    /// - `continuum://downloads` — select the Downloads tab (local
    ///   download notifications)
    ///
    /// If the auth state isn't ready yet, the link is queued in
    /// `pendingDeepLink` and drained on the next `.authenticated`
    /// transition.
    private func handleDeepLink(_ url: URL) {
        guard let host = url.host else { return }

        if host == "downloads" {
            guard router.authState == .authenticated else {
                pendingDeepLink = url
                return
            }
            // The tab only exists while downloads are enabled — a stale
            // download notification tapped after a profile/capability
            // change must not select a tab that never renders.
            guard DownloadManager.shared.downloadsEnabled else { return }
            // Select the tab rather than pushing the route — a push stacks
            // a duplicate Downloads screen when that tab is already showing,
            // and hides the tab context from anywhere else.
            router.popToRoot()
            router.switchTab(to: .downloads)
            return
        }

        guard !url.pathComponents.isEmpty else { return }
        let contentId = url.pathComponents
            .dropFirst()
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let contentId, !contentId.isEmpty else { return }

        guard router.authState == .authenticated else {
            pendingDeepLink = url
            return
        }

        switch host {
        case "item":
            router.navigate(to: .itemDetail(contentId: contentId))
        case "play":
            Task { await routePlayDeepLink(contentId: contentId) }
        default:
            break
        }
    }

    @MainActor
    private func routePlayDeepLink(contentId: String) async {
        do {
            let detail = try await ContinuumAPI.shared.itemDetail(contentId: contentId)
            if detail.isAudiobook {
                audioStore.play(contentId: contentId)
                return
            }
        } catch {
            // Fall through to the existing video route when the type cannot be resolved.
        }

        router.navigate(
            to: .player(
                contentId: contentId,
                startFromBeginning: false,
                resumePosition: nil
            )
        )
    }

    @ViewBuilder
    private var loginRoot: some View {
        #if os(tvOS)
        TVLoginView(router: router)
        #else
        LoginView(router: router)
        #endif
    }

    /// Determine the initial auth state with the smallest launch-time
    /// Keychain surface possible. The registry loads synchronously in `init`;
    /// TokenStore only needs to be retargeted to that active server before the
    /// first authenticated request lazily loads the full token cache.
    private func checkInitialState() async {
        let activeServerId = ServerRegistry.shared.activeServerId
        let hasStoredAccessToken: Bool
        if let activeServerId, !activeServerId.isEmpty {
            hasStoredAccessToken = await TokenStore.shared.hasAccessTokenForActiveServer(serverId: activeServerId)
        } else {
            hasStoredAccessToken = false
        }

        let api = AuthService.shared
        let targetState: AppRouter.AuthState
        if !api.hasServer {
            targetState = .needsServerSetup
        } else if !hasStoredAccessToken {
            targetState = .needsLogin
        } else if !api.hasProfile {
            targetState = .needsProfile
        } else {
            targetState = .authenticated
        }

        StartupContentPrefetcher.prefetchForInitialRoute(targetState)
        pendingInitialAuthState = targetState
        finishInitialStartupIfReady()

        #if DEBUG
        Task.detached(priority: .background) { await Self.logTopShelfDiagnostics() }
        #endif
    }

    private func finishInitialStartupIfReady() {
        guard didFinishStartupSplash, let targetState = pendingInitialAuthState else { return }
        pendingInitialAuthState = nil
        router.authState = targetState
    }

    #if DEBUG
    /// Dumps the state the Top Shelf extension relies on, plus the last
    /// breadcrumb the extension wrote. tvOS captures main-app stdout only,
    /// so this is how we inspect the extension's view of the world
    /// post-hoc. Run off the critical launch path.
    private static func logTopShelfDiagnostics() async {
        let suite = SharedStorage.suite
        let keychain = SharedKeychain()
        let serverUrl = suite.string(forKey: SharedStorage.serverUrlKey) ?? "<nil>"
        let profileId = suite.string(forKey: SharedStorage.profileIdKey) ?? "<nil>"
        let hasAccess = keychain.get(SharedStorage.mirroredAccessTokenAccount) != nil
        let hasProfile = keychain.get(SharedStorage.mirroredProfileTokenAccount) != nil
        let lastRun = suite.string(forKey: SharedStorage.topShelfLastRunAtKey) ?? "<never>"
        let lastStatus = suite.string(forKey: SharedStorage.topShelfLastStatusKey) ?? "<none>"
        print("[TopShelfDiag] suite.serverUrl=\(serverUrl) suite.profileId=\(profileId) mirroredAccess=\(hasAccess) mirroredProfile=\(hasProfile)")
        print("[TopShelfDiag] lastRunAt=\(lastRun) lastStatus=\(lastStatus)")
    }
    #endif

    private func maybeAutoPlayForDebug() async {
        guard router.authState == .authenticated else { return }
        guard !didAttemptDebugAutoPlay else { return }

        if let searchQuery = debugPlaySearchQuery {
            didAttemptDebugAutoPlay = true

            do {
                debugPlayContentId = try await resolveDebugSearchContentId(query: searchQuery)
            } catch {
                print("[DebugPlaySearch] Failed to resolve '\(searchQuery)': \(error)")
            }
            return
        }

        guard CommandLine.arguments.contains("-debugPlayFirst") else { return }
        didAttemptDebugAutoPlay = true

        do {
            let sections = try await ContinuumAPI.shared.homeSections()
            guard let contentId = sections.sections.lazy
                .compactMap({ $0.items.first?.contentId })
                .first else {
                return
            }
            debugPlayContentId = contentId
        } catch {
            print("[DebugPlayFirst] Failed to fetch home sections: \(error)")
        }
    }

    private var debugPlaySearchQuery: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "-debugPlaySearch"),
              index + 1 < CommandLine.arguments.count else {
            return nil
        }
        return CommandLine.arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resolveDebugSearchContentId(query: String) async throws -> String {
        let response = try await ContinuumAPI.shared.catalog(query: [
            "source": "query",
            "q": query,
            "limit": "20",
            "offset": "0",
        ])

        let normalizedQuery = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let preferredItem = response.items.first { item in
            item.type == "series" &&
            item.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedQuery
        } ?? response.items.first { item in
            item.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == normalizedQuery
        } ?? response.items.first

        guard let preferredItem else {
            throw DebugAutoPlayError.noSearchResults(query: query)
        }

        if preferredItem.type == "series" {
            let seasons = try await ContinuumAPI.shared.seasons(seriesId: preferredItem.contentId)
            guard let firstSeason = seasons.seasons.sorted(by: { $0.seasonNumber < $1.seasonNumber }).first else {
                throw DebugAutoPlayError.noPlayableEpisode(seriesTitle: preferredItem.title)
            }

            let episodes = try await ContinuumAPI.shared.episodes(
                seriesId: preferredItem.contentId,
                seasonNumber: firstSeason.seasonNumber
            )
            guard let firstEpisode = episodes.episodes
                .sorted(by: { $0.episodeNumber < $1.episodeNumber })
                .first else {
                throw DebugAutoPlayError.noPlayableEpisode(seriesTitle: preferredItem.title)
            }

            print(
                "[DebugPlaySearch] Resolved '\(query)' to series=\(preferredItem.title) " +
                "season=\(firstSeason.seasonNumber) episode=\(firstEpisode.episodeNumber) contentId=\(firstEpisode.contentId)"
            )
            return firstEpisode.contentId
        }

        print("[DebugPlaySearch] Resolved '\(query)' to \(preferredItem.type) contentId=\(preferredItem.contentId)")
        return preferredItem.contentId
    }

    @ViewBuilder
    private func destinationView(for route: Route) -> some View {
        switch route {
        case .serverNeedsSetup:
            #if os(tvOS)
            EmptyStateView(icon: "gearshape.2", title: "Finish setup in your browser", subtitle: nil)
                .continuumBackground()
            #else
            ServerNeedsSetupView(router: router)
            #endif
        case .signup:
            #if os(tvOS)
            EmptyStateView(icon: "person.badge.plus", title: "Sign up from a phone or the web", subtitle: nil)
                .continuumBackground()
            #else
            SignupView(router: router)
            #endif
        case .login:
            loginRoot
        case .serverSetup:
            #if os(tvOS)
            TVServerSetupView(router: router)
            #else
            ServerSetupView(router: router)
            #endif
        default:
            // Routes handled inside the authenticated tab view
            EmptyStateView(
                icon: "hammer.fill",
                title: "Coming Soon",
                subtitle: "This screen is under construction."
            )
            .continuumBackground()
        }
    }

    /// Destinations reachable from the profile-selection stack. The
    /// "Change Server" chip pushes `.serverList`; from there the user
    /// can swap active servers or dive into `.serverSetup` to add a
    /// new one. Auth-flow routes are included so an "Add Server" tap
    /// on tvOS — which stays inside this stack rather than flipping
    /// `authState` — still lands on a real view.
    @ViewBuilder
    private func profileFlowDestination(for route: Route) -> some View {
        switch route {
        case .serverList:
            ServerListView()
        case .serverSetup:
            #if os(tvOS)
            TVServerSetupView(router: router)
            #else
            ServerSetupView(router: router)
            #endif
        case .login:
            #if os(tvOS)
            TVLoginView(router: router)
            #else
            LoginView(router: router)
            #endif
        case .serverNeedsSetup:
            #if os(tvOS)
            EmptyStateView(icon: "gearshape.2", title: "Finish setup in your browser", subtitle: nil)
                .continuumBackground()
            #else
            ServerNeedsSetupView(router: router)
            #endif
        case .signup:
            #if os(tvOS)
            EmptyStateView(icon: "person.badge.plus", title: "Sign up from a phone or the web", subtitle: nil)
                .continuumBackground()
            #else
            SignupView(router: router)
            #endif
        default:
            EmptyStateView(icon: "questionmark.circle", title: "Unknown", subtitle: nil)
                .continuumBackground()
        }
    }
}

private struct DebugPlayerPresentationModifier: ViewModifier {
    let contentId: String?
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.sheet(isPresented: $isPresented) {
            player
        }
        #else
        content.fullScreenCover(isPresented: $isPresented) {
            player
        }
        #endif
    }

    @ViewBuilder
    private var player: some View {
        if let contentId {
            PlayerView(contentId: contentId)
        }
    }
}

private enum DebugAutoPlayError: LocalizedError {
    case noPlayableEpisode(seriesTitle: String)
    case noSearchResults(query: String)

    var errorDescription: String? {
        switch self {
        case .noPlayableEpisode(let seriesTitle):
            return "No playable episode found for \(seriesTitle)"
        case .noSearchResults(let query):
            return "No search results found for \(query)"
        }
    }
}

// MARK: - Zoom transition namespace

/// Carries the `@Namespace.ID` used by the iOS 26 poster → detail zoom
/// transition. Published by `MainTabView` so card components (the
/// `.matchedTransitionSource` sources) and the central
/// `navigationDestination` (the `.navigationTransition(.zoom)` destination)
/// can share one namespace without routing it through `Route`/`router.path`.
/// `nil` when unset (e.g. tvOS / macOS) so callers fall back to a plain push.
struct ZoomNamespaceEnvironmentKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceEnvironmentKey.self] }
        set { self[ZoomNamespaceEnvironmentKey.self] = newValue }
    }
}

// MARK: - Main Tab View

struct MainTabView: View {
    @Bindable var router: AppRouter
    @State private var selectedTab: AppTab = .home
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Shared namespace for the poster → detail zoom transition. Injected into
    /// the environment (`\.zoomNamespace`) so both the cards and the central
    /// detail destination resolve the same identity.
    @Namespace private var zoomNamespace
    @Environment(AudioPlaybackStore.self) private var audioStore
    #if os(iOS)
    @Environment(SiloControlClient.self) private var siloControl
    #endif
    #if !os(macOS)
    @Environment(\.horizontalSizeClass) private var hSize
    #endif

    var body: some View {
        Group {
            if prefersSidebarLayout {
                sidebarLayout
            } else {
                tabLayout
            }
        }
        .tint(.continuumOnSurface)
        #if !os(tvOS)
        // Mirror Android's offline start-destination: launching with no
        // network but playable local downloads lands on Downloads instead of
        // a Home screen that can't load anything.
        .task {
            await ConnectionMonitor.shared.waitForInitialPath()
            guard !ConnectionMonitor.shared.isDeviceOnline else { return }
            // The auth-state task hydrates DownloadManager via onAppActive()
            // only after several awaited network refreshes, which is too late
            // for this check on an offline cold launch. Loading the scope
            // here is disk-only and idempotent — onAppActive() will skip the
            // reload when it eventually runs.
            _ = await DownloadManager.shared.activateScopeIfNeeded()
            guard DownloadManager.shared.downloadsEnabled,
                  DownloadManager.shared.records.contains(where: { $0.isPlayableOffline }),
                  // Don't clobber a tab the user (or a deep link) already
                  // selected while this task was waiting.
                  selectedTab == .home, router.requestedTab == nil
            else { return }
            selectedTab = .downloads
        }
        #endif
        #if os(iOS)
        // Cold-launch path for silent remote-control resume: scenePhase may
        // already be .active when the authenticated UI first appears, so the
        // scenePhase onChange alone would miss it. Idempotent — the controller
        // guards against duplicate probes.
        .task { siloControl.attemptAutoResumeIfIdle() }
        #endif
        .onChange(of: router.requestedTab) { _, tab in
            guard let tab else { return }
            selectedTab = tab
            router.requestedTab = nil
        }
        #if !os(macOS)
        .fullScreenCover(isPresented: Binding(
            get: { audioStore.isShowingFullPlayer },
            set: { if !$0 { audioStore.dismissFullPlayer() } }
        )) {
            AudioFullPlayerView()
        }
        .fullScreenCover(item: $router.presentedPlayer) { payload in
            PlayerView(
                contentId: payload.contentId,
                preferredFileId: payload.fileId,
                preferredAudioTrackIndex: payload.audioTrackIndex,
                preferredSubtitleTrackIndex: payload.subtitleTrackIndex,
                startFromBeginning: payload.startFromBeginning,
                resumePositionOverride: payload.resumePosition,
                offlineDownloadId: payload.offlineDownloadId,
                posterURLHint: payload.posterURL,
                backdropURLHint: payload.backdropURL,
                viewModel: hostedPlayerViewModel
            )
        }
        #if os(iOS)
        .sheet(isPresented: Binding(
            get: { siloControl.isShowingRemoteControl },
            set: { if !$0 { siloControl.hideRemoteControl() } }
        )) {
            SiloControlRemoteView(controller: siloControl)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        #endif
        #endif
        // Outside the presentation modifiers so presented covers (audio
        // player, video player) inherit the router — ErrorView requires
        // it and traps when it's absent.
        .environment(router)
    }

    /// On iOS the player view model is owned by the router's
    /// `PlaybackSessionHost` so the session can outlive the cover during
    /// Picture in Picture. Other platforms let `PlayerView` own its own.
    private var hostedPlayerViewModel: PlayerViewModel? {
        #if os(iOS)
        router.playbackHost.viewModel
        #else
        nil
        #endif
    }

    private var prefersSidebarLayout: Bool {
        #if os(macOS)
        true
        #else
        hSize == .regular
        #endif
    }

    /// Visible tabs, plus a Downloads tab when the server advertises the
    /// downloads capability for this profile. Reading
    /// `DownloadManager.shared.downloadsEnabled` here registers the tab bar
    /// as an observer, so the tab appears as soon as capability loads.
    private var visibleTabs: [AppTab] {
        var tabs = AppTab.visibleCases
        #if !os(tvOS)
        if DownloadManager.shared.downloadsEnabled {
            tabs.append(.downloads)
        }
        #endif
        return tabs
    }

    /// iPhone + iPad compact width: bottom tab bar, single navigation stack.
    private var tabLayout: some View {
        NavigationStack(path: $router.path) {
            TabView(selection: $selectedTab) {
                ForEach(visibleTabs) { tab in
                    #if os(tvOS)
                    // Text-only tabs on tvOS keep the top bar compact — adding an
                    // icon blows up each tab's focus pill. The value-based `Tab`
                    // initializer requires an image on tvOS, so this arm stays on
                    // the `.tabItem { Text }` form to preserve the text-only look.
                    tabContent(for: tab)
                        .tabItem { Text(tab.rawValue) }
                        .tag(tab)
                    #else
                    Tab(
                        tab.rawValue,
                        systemImage: selectedTab == tab ? tab.selectedIcon : tab.icon,
                        value: tab
                    ) {
                        tabContent(for: tab)
                    }
                    #endif
                }
            }
            .navigationDestination(for: Route.self) { route in
                routeContent(for: route)
            }
            #if os(iOS)
            .tabBarMinimizeBehavior(.onScrollDown)
            .modifier(NowPlayingShelfAttachment())
            #endif
        }
        .environment(\.zoomNamespace, zoomNamespace)
    }

    /// iPad regular width: sidebar list + detail pane.
    /// Selection drives both the highlighted row and the detail content.
    ///
    /// Home / Libraries / Recommendations hide the nav bar (so SwiftUI's
    /// default sidebar toggle isn't visible on those screens). We inject a
    /// toggle closure through `\.sidebarToggle` instead — each custom header
    /// renders a `SidebarToggleButton` on its leading edge, which collapses
    /// and re-expands the sidebar. Video playback doesn't overlap the sidebar
    /// because the player is presented via `fullScreenCover` on
    /// `router.presentedPlayer` rather than pushed into the detail pane.
    private var sidebarLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: Binding<AppTab?>(
                get: { selectedTab },
                set: { if let v = $0 { selectedTab = v } }
            )) {
                ForEach(visibleTabs) { tab in
                    Label(
                        tab.rawValue,
                        systemImage: selectedTab == tab ? tab.selectedIcon : tab.icon
                    )
                    .tag(tab)
                }
            }
            .navigationTitle("Silo")
        } detail: {
            NavigationStack(path: $router.path) {
                tabContent(for: selectedTab)
                    .navigationDestination(for: Route.self) { route in
                        routeContent(for: route)
                    }
            }
        }
        .environment(\.sidebarToggle, toggleSidebar)
        .environment(\.zoomNamespace, zoomNamespace)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NowPlayingShelf(style: .card)
        }
    }

    /// Collapses or re-expands the sidebar. Animated so the detail pane
    /// slides into place rather than snapping.
    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.25)) {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    @ViewBuilder
    private func tabContent(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            HomeView()

        case .libraries:
            LibrariesTabView()

        case .search:
            SearchView()

        case .recommendations:
            RecommendationsView()

        case .calendar:
            CalendarView()

        case .downloads:
            #if os(tvOS)
            EmptyView()
            #else
            DownloadsView()
            #endif

        case .settings:
            SettingsView()

        case .switchProfile, .switchServer:
            // tvOS-only sidebar shortcuts; filtered out of iOS visibleCases.
            EmptyView()
        }
    }

    @ViewBuilder
    private func routeContent(for route: Route) -> some View {
        switch route {
        case .library(let libraryId, let title):
            LibraryDetailView(libraryId: libraryId, initialTitle: title)
        case .libraryCollection(let libraryId, let collectionId, let title, let kind):
            LibraryCollectionDetailView(
                libraryId: libraryId,
                collectionId: collectionId,
                title: title,
                kind: kind
            )
        case .itemDetail(let contentId):
            ItemDetailView(contentId: contentId)
                #if os(iOS)
                // Destination half of the iOS 26 poster → detail zoom. Keys off
                // the unique per-card source id the tapped card recorded in
                // `pendingZoomSourceID` (falling back to `contentId`), so the
                // zoom animates from the exact card even when the same item is
                // visible in two rows. SwiftUI falls back to a normal push when
                // no matching source is on screen.
                .navigationTransition(.zoom(sourceID: router.pendingZoomSourceID ?? contentId, in: zoomNamespace))
                #endif
        case .personDetail(let personId):
            PersonDetailView(personId: personId)
        case .player(let contentId, let startFromBeginning, let resumePosition):
            #if os(macOS)
            PlayerView(
                contentId: contentId,
                startFromBeginning: startFromBeginning,
                resumePositionOverride: resumePosition
            )
            #else
            // Player is presented as a full-screen cover (see MainTabView)
            // so it isn't boxed into the iPad detail pane. This route arm
            // exists only so switch exhaustiveness holds.
            EmptyView()
            #endif
        case .playerWithFile(
            let contentId,
            let fileId,
            let audioTrackIndex,
            let subtitleTrackIndex,
            let startFromBeginning,
            let resumePosition
        ):
            #if os(macOS)
            PlayerView(
                contentId: contentId,
                preferredFileId: fileId,
                preferredAudioTrackIndex: audioTrackIndex,
                preferredSubtitleTrackIndex: subtitleTrackIndex,
                startFromBeginning: startFromBeginning,
                resumePositionOverride: resumePosition
            )
            #else
            EmptyView()
            #endif
        case .favorites:
            FavoritesView()
        case .watchlist:
            WatchlistView()
        case .history:
            HistoryView()
        case .collections:
            CollectionsView()
        case .collectionDetail(let id):
            CollectionDetailView(collectionId: id)
        case .browse(let libraryId):
            BrowseView(libraryId: libraryId)
        case .requestsHub:
            RequestsHubView()
        case .requestDetail(let mediaType, let tmdbId):
            RequestDetailView(mediaType: mediaType, tmdbId: tmdbId)
        case .myRequests:
            MyRequestsView()
        case .admin:
            AdminDashboardView()
        case .search:
            SearchView()
        case .settings:
            SettingsView()
        case .recommendations:
            RecommendationsView()
        case .serverList:
            ServerListView()
        case .downloads:
            #if os(tvOS)
            EmptyStateView(icon: "questionmark.circle", title: "Unknown", subtitle: nil)
                .continuumBackground()
            #else
            DownloadsView()
            #endif
        case .offlinePlayer(let downloadId, let contentId, let startFromBeginning, let resumePosition):
            #if os(macOS)
            PlayerView(
                contentId: contentId,
                startFromBeginning: startFromBeginning,
                resumePositionOverride: resumePosition,
                offlineDownloadId: downloadId
            )
            #else
            // Presented as a full-screen cover (see MainTabView). This arm
            // exists only for switch exhaustiveness.
            EmptyView()
            #endif
        case .offlineSeriesBrowse(let seriesId):
            #if os(tvOS)
            EmptyStateView(icon: "questionmark.circle", title: "Unknown", subtitle: nil)
                .continuumBackground()
            #else
            OfflineSeriesBrowseView(seriesId: seriesId)
            #endif
        case .offlineDownloadDetail(let downloadId):
            #if os(tvOS)
            EmptyStateView(icon: "questionmark.circle", title: "Unknown", subtitle: nil)
                .continuumBackground()
            #else
            OfflineDownloadDetailView(downloadId: downloadId)
            #endif
        default:
            EmptyStateView(icon: "questionmark.circle", title: "Unknown", subtitle: nil)
                .continuumBackground()
        }
    }

    private var settingsPlaceholder: some View {
        List {
            Section {
                Button("Switch Profile") {
                    AuthService.shared.profileId = nil
                    router.showProfileSelection()
                }
                .foregroundColor(.continuumOnSurface)
            }

            Section {
                Button("Sign Out") {
                    router.signOutAndReset()
                }
                .foregroundColor(.continuumError)
            }
        }
        .continuumScrollContentBackgroundHidden()
        .background(Color.continuumBackground)
        .navigationTitle("Settings")
        .continuumToolbarColorSchemeDark()
    }
}
