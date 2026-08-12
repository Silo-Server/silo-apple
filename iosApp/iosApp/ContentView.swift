import SwiftUI
#if os(iOS) || os(tvOS)
import UIKit
#endif

struct ContentView: View {
    @State private var router = AppRouter()
    @State private var serverRegistry = ServerRegistry.shared
    @State private var audioStore = AudioPlaybackStore()
    #if os(iOS)
    @State private var siloControl = SiloControlClient()
    #endif
    @State private var debugPlayContentId: String?
    @State private var didAttemptDebugAutoPlay = false
    @State private var didStartInitialStateCheck = false
    @State private var didFinishStartupSplash = false
    @State private var pendingInitialAuthState: AppRouter.AuthState?
    #if os(iOS) || os(tvOS)
    @State private var diagnosticsModel = DiagnosticsViewModel()
    #endif
    /// Deep link URL received before the auth state was ready. Content links
    /// drain on the next `.authenticated` transition; invitation links drain
    /// immediately after startup commits its initial auth route.
    @State private var pendingDeepLink: URL?
    /// Shared with every screen that renders cards. Hydrates lazily on
    /// the first .authenticated transition so cards stay visible during
    /// the brief window between sign-in and the overlay-config fetch.
    @StateObject private var overlayPrefs = OverlayPrefsStore.shared
    /// Server-synced navigation and card presentation for this client family.
    /// The store paints its offline cache first, then reconciles whenever the
    /// authenticated server/profile boundary changes.
    @State private var uiCustomization = UICustomizationPreferences.shared
    /// Used to retry overlay hydration on foreground transitions: if the
    /// initial fetch failed transiently, `hydrateIfNeeded()` will retry
    /// because the store left `hasHydrated == false`. Idempotent when
    /// the previous hydration succeeded.
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        authContent
        // A server change is a hard data boundary even when both servers map
        // to the same auth state. Re-key the routed subtree so profile, home,
        // library, focus, and modal state cannot survive from the old server.
        .id(serverRegistry.activeServerId)
        .environment(audioStore)
        #if os(iOS)
        .environment(siloControl)
        #endif
        .environmentObject(overlayPrefs)
        .preferredColorScheme(.dark)
        #if os(tvOS) && DEBUG
        .modifier(TVFocusDebugActivationModifier())
        #endif
        #if os(iOS)
        // Hold the pairing offer until the startup splash logo finishes so a
        // quickly-discovered TV doesn't pop the card over the animation.
        .companionPairingCard(
            enabled: didFinishStartupSplash && router.authState != .loading,
            authState: router.authState
        )
        #endif
        .modifier(DebugPlayerPresentationModifier(
            contentId: debugPlayContentId,
            isPresented: debugPlayerPresentation
        ))
        #if os(iOS) || os(tvOS)
        .modifier(DiagnosticsPromptPresentationModifier(
            model: diagnosticsModel,
            isEnabled: router.authState == .authenticated
        ))
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .continuumDeepLink)) { notification in
            guard let url = notification.userInfo?["url"] as? URL else { return }
            #if os(iOS)
            ApplePushDeepLinkCoordinator.shared.clearPendingDeepLink(matching: url)
            #endif
            handleDeepLink(url)
        }
        .onAppear {
            #if os(tvOS)
            ExitSentinel.shared.appDidEnterForeground()
            #endif
            #if os(iOS)
            if let url = ApplePushDeepLinkCoordinator.shared.consumePendingDeepLink() {
                handleDeepLink(url)
            }
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .continuumSessionExpired)) { notification in
            guard let event = notification.object as? SessionExpiryEvent,
                  event.disposition == .persistentSessionCleared else { return }
            Task { @MainActor in
                // Delivery is asynchronous. Revalidate at the destructive
                // consumer so a same-server login that replaced this epoch
                // after posting cannot be routed back to login.
                guard await TokenStore.shared.shouldConsumeSessionExpiryEvent(event) else { return }
                audioStore.dismissFullPlayer()
                Task { await audioStore.player.close() }
                #if !os(tvOS)
                DownloadManager.shared.clearForSignOut()
                #endif
                router.expiredSession()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .continuumProfileSelectionRequired)) { _ in
            guard shouldPresentProfileSelectionAfterRecovery(
                isLoggedIn: AuthService.shared.isLoggedIn,
                activeProfileID: AuthService.shared.profileId
            ) else { return }
            router.showProfileSelection()
        }
        #if os(iOS) || os(tvOS)
        .onReceive(NotificationCenter.default.publisher(for: .diagnosticsPendingReportCreated)) { _ in
            guard router.authState == .authenticated else { return }
            Task { await diagnosticsModel.handleForeground() }
        }
        #endif
        #if os(tvOS)
        .onReceive(NotificationCenter.default.publisher(for: .temporaryRemoteAuthExpired)) { notification in
            guard let event = notification.object as? SessionExpiryEvent,
                  event.disposition == .temporarySessionExpired else { return }
            Task { @MainActor in
                guard await TokenStore.shared.shouldConsumeSessionExpiryEvent(event) else { return }
                TVControlReceiver.shared.temporaryAuthExpired(expected: event)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            ExitSentinel.shared.appWillTerminate()
        }
        #endif
        .task {
            // Debug: auto-play from launch argument -debugPlay <contentId>
            if let idx = CommandLine.arguments.firstIndex(of: "-debugPlay"),
               idx + 1 < CommandLine.arguments.count {
                let contentId = CommandLine.arguments[idx + 1]
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                debugPlayContentId = contentId
            }
        }
        #if DEBUG
        .task {
            await maybeDebugAutoLogin()
        }
        #endif
        .task(id: router.authState) {
            #if os(iOS) || os(tvOS)
            if router.authState != .authenticated {
                // The initial `.loading` state is not an identity boundary.
                // Keep the previous run's persisted breadcrumbs and playback
                // sessions intact until tvOS can capture any abnormal-exit
                // leftover after restored authentication resolves. Explicit
                // profile/server switches and sign-out own their destructive
                // cleanup paths separately.
                DiagnosticsCoordinator.authenticationStateBecameUnavailable()
                diagnosticsModel.reset()
            }
            #endif
            await maybeAutoPlayForDebug()
            if router.authState == .authenticated {
                if let pending = pendingDeepLink {
                    pendingDeepLink = nil
                    handleDeepLink(pending)
                }
                #if os(tvOS)
                await ExitSentinel.shared.captureLeftoverIfNeeded()
                #endif
                #if os(iOS) || os(tvOS)
                await diagnosticsModel.handleForeground()
                #endif
                await overlayPrefs.hydrateIfNeeded()
                // Hydrate AI capabilities on a cold relaunch into a restored
                // session — `selectProfile` only refreshes on a fresh sign-in,
                // so without this the metadata-language / on-view-translate
                // features stay hidden until a profile switch. Idempotent and
                // failure-tolerant, so double-calling with `selectProfile` is safe.
                await AICapabilities.shared.refresh()
                await RequestsFeatureStore.shared.refresh()
                await SubtitleProvidersStore.shared.refresh()
                await uiCustomization.refresh()
                #if os(iOS)
                await ApplePushRegistrationCoordinator.shared.prepareForAuthenticatedProfile()
                #endif
                #if !os(tvOS)
                await DownloadManager.shared.onAppActive()
                #endif
            }
        }
        .task(id: serverRegistry.activeServerId) {
            // ServerRegistry publishes the destination ID while its identity
            // transition lease is still held. Wait before reading or
            // retargeting any server-scoped state so this task cannot race the
            // final token commit. A superseded SwiftUI task is cancelled while
            // queued and must perform no work for the stale destination.
            guard await HTTPClient.shared.waitForRequestDispatchOpen() else { return }
            guard !Task.isCancelled else { return }
            #if os(iOS) || os(tvOS)
            diagnosticsModel.reset()
            #endif
            // `activeServerId` changes before ServerRegistry finishes its
            // async token retarget. Complete that boundary here before any
            // server-scoped overlay request, then clear and rehydrate even
            // when the destination remains `.authenticated`.
            await TokenStore.shared.switchActiveServer(
                serverId: serverRegistry.activeServerId ?? ""
            )
            overlayPrefs.clear()
            guard !Task.isCancelled else { return }
            Task { await AuthService.shared.refreshActiveServerName() }
            if router.authState == .authenticated {
                await uiCustomization.refresh()
                await overlayPrefs.hydrateIfNeeded()
                #if os(iOS) || os(tvOS)
                await diagnosticsModel.handleForeground()
                #endif
            }
        }
        .task(id: serverRegistry.activeProfileId) {
            #if os(iOS) || os(tvOS)
            diagnosticsModel.reset()
            #endif
            if router.authState == .authenticated {
                await uiCustomization.refresh()
                #if os(iOS) || os(tvOS)
                await diagnosticsModel.handleForeground()
                #endif
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            #if os(iOS) || os(tvOS)
            DiagnosticsCoordinator.recordBreadcrumb(
                category: .lifecycle,
                tag: "Scene",
                message: "scene phase changed",
                attrs: ["state": .string(Self.diagnosticsScenePhase(newPhase))]
            )
            #endif
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
            #if os(tvOS)
            switch newPhase {
            case .active:
                ExitSentinel.shared.appDidEnterForeground()
            case .background:
                ExitSentinel.shared.appDidEnterBackground()
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
            #if os(tvOS)
            Task {
                await ExitSentinel.shared.captureLeftoverIfNeeded()
                await diagnosticsModel.handleForeground()
            }
            #elseif os(iOS)
            Task { await diagnosticsModel.handleForeground() }
            #endif
            Task { await overlayPrefs.hydrateIfNeeded() }
            // Same rationale as overlay hydration above: a transiently-failed
            // capability probe (or one skipped on a cold restore) gets a
            // natural retry on foreground. `refresh()` is idempotent, so the
            // happy path costs nothing.
            Task { await AICapabilities.shared.refresh() }
            Task { await RequestsFeatureStore.shared.refresh() }
            Task { await SubtitleProvidersStore.shared.refresh() }
            Task { await uiCustomization.refresh() }
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

    #if os(iOS) || os(tvOS)
    private static func diagnosticsScenePhase(_ phase: ScenePhase) -> String {
        switch phase {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }
    #endif

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
                ProfileSelectionView(
                    router: router,
                    journeyLabels: router.profileJourneyLabels ?? ["Server", "Account", "Profile"]
                )
                    .navigationDestination(for: Route.self) { route in
                        profileFlowDestination(for: route)
                    }
            }
            .environment(router)

        case .authenticated:
            #if os(tvOS)
            TVMainTabView(router: router)
                .onboardingTourGate(router: router)
            #else
            MainTabView(router: router)
                .onboardingTourGate(router: router)
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
    /// `pendingDeepLink` until startup commits its initial route.
    private func handleDeepLink(_ url: URL) {
        if let invitation = InvitationClaimLink(url: url) {
            #if os(tvOS)
            // Invitation claiming is not implemented on tvOS. Ignore the
            // route without disturbing an existing authenticated session.
            return
            #else
            // The startup task owns auth-state routing while `.loading`.
            // Defer this invite until that task commits so its older result
            // cannot overwrite the claim route on a cold launch.
            guard router.authState != .loading else {
                pendingDeepLink = url
                return
            }
            router.path = NavigationPath()
            router.authState = .needsLogin
            router.navigate(to: .inviteClaim(endpoint: invitation.endpoint, token: invitation.token))
            return
            #endif
        }

        guard url.scheme?.lowercased() == "continuum",
              let host = url.host?.lowercased() else { return }

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
        } else {
            targetState = await api.resolveActiveProfileForSession()
                ? .authenticated
                : .needsProfile
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
        #if !os(tvOS)
        if let pendingDeepLink,
           InvitationClaimLink(url: pendingDeepLink) != nil {
            self.pendingDeepLink = nil
            handleDeepLink(pendingDeepLink)
        }
        #endif
    }

    #if DEBUG
    /// Dumps the state the Top Shelf extension relies on, plus the last
    /// breadcrumb the extension wrote. tvOS captures main-app stdout only,
    /// so this is how we inspect the extension's view of the world
    /// post-hoc. Run off the critical launch path.
    private static func logTopShelfDiagnostics() async {
        let suite = SharedStorage.suite
        let accountKeychain = SharedKeychain(audience: .userIndependent)
        let profileKeychain = SharedKeychain(audience: .currentUser)
        let hasServerURL = suite.string(forKey: SharedStorage.serverUrlKey) != nil
        let hasProfileID = suite.string(forKey: SharedStorage.profileIdKey) != nil
        let hasAccess = accountKeychain.get(SharedStorage.mirroredAccessTokenAccount) != nil
        let hasProfile = profileKeychain.get(SharedStorage.mirroredProfileTokenAccount) != nil
        let lastRun = suite.string(forKey: SharedStorage.topShelfLastRunAtKey) ?? "<never>"
        let hasLastStatus = suite.string(forKey: SharedStorage.topShelfLastStatusKey) != nil
        print("[TopShelfDiag] hasServerURL=\(hasServerURL) hasProfileID=\(hasProfileID) mirroredAccess=\(hasAccess) mirroredProfile=\(hasProfile)")
        print("[TopShelfDiag] lastRunAt=\(lastRun) hasLastStatus=\(hasLastStatus)")
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

    #if DEBUG
    private func debugLaunchArgValue(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name),
              index + 1 < CommandLine.arguments.count else {
            return nil
        }
        return CommandLine.arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Debug: sign in from launch arguments
    /// `-debugServer <url> -debugUsername <user> -debugPassword <pass>`,
    /// selecting the primary (or only) PIN-less profile. Simulator-driven
    /// end-to-end runs use this to reach `.authenticated` without UI input.
    private func maybeDebugAutoLogin() async {
        guard router.authState != .authenticated,
              let server = debugLaunchArgValue("-debugServer"),
              let username = debugLaunchArgValue("-debugUsername"),
              let password = debugLaunchArgValue("-debugPassword") else {
            return
        }
        do {
            _ = try await AuthService.shared.checkServer(url: server)
            try await AuthService.shared.login(username: username, password: password)
            let profiles = try await StartupContentPrefetcher.fetchProfiles()
            guard let profile = profiles.first(where: \.isPrimary)
                ?? (profiles.count == 1 ? profiles.first : nil) else {
                print("[DebugAutoLogin] no selectable profile")
                return
            }
            try await AuthService.shared.selectProfile(
                profileId: profile.id,
                requiresPIN: profile.hasPin
            )
            StartupContentPrefetcher.prefetchAuthenticatedContent()
            await PlayerSettings.shared.refreshFromServer()
            router.resetToHome()
            print("[DebugAutoLogin] signed in and selected profile")
        } catch {
            print("[DebugAutoLogin] failed: \(error)")
        }
    }
    #endif

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
        case .inviteClaim(let endpoint, let token):
            #if os(tvOS)
            EmptyStateView(icon: "envelope.badge.person.crop", title: "Open your invite on a phone or the web", subtitle: nil)
                .continuumBackground()
            #else
            InviteClaimView(router: router, endpoint: endpoint, token: token)
            #endif
        case .onboardingTour:
            #if os(tvOS)
            EmptyStateView(icon: "sparkles", title: "Take the tour on your phone or the web", subtitle: nil)
                .continuumBackground()
            #else
            OnboardingTourView(router: router)
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

func shouldPresentProfileSelectionAfterRecovery(
    isLoggedIn: Bool,
    activeProfileID: String?
) -> Bool {
    isLoggedIn && activeProfileID == nil
}

#if os(iOS)
/// SwiftUI treats `navigationSplitViewColumnWidth` as a preference on iPad.
/// Pin the backing UIKit split controller to the same width so its divider
/// cannot resize the overlay while retaining the system sidebar presentation.
private struct FixedPrimarySplitViewWidth: UIViewControllerRepresentable {
    let width: CGFloat
    let sidebarIsHidden: Bool
    let onSwipeLeft: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller(width: width, onSwipeLeft: onSwipeLeft)
        controller.sidebarIsHidden = sidebarIsHidden
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.width = width
        controller.sidebarIsHidden = sidebarIsHidden
        controller.onSwipeLeft = onSwipeLeft
        controller.applyWidthLock()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: Void) {
        controller.tearDown()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var width: CGFloat
        var sidebarIsHidden = false
        var onSwipeLeft: () -> Void
        private var dragStartOffset: CGFloat = 0
        private var isDismissAnimationRunning = false
        private weak var managedSplitViewController: UISplitViewController?
        private weak var dragPresentationView: UIView?
        private weak var dragDimmingView: UIView?
        private var dimmingBaseAlpha: CGFloat = 1
        private weak var swipeHostView: UIView?
        private lazy var swipeLeftRecognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleSwipeLeft(_:))
            )
            recognizer.maximumNumberOfTouches = 1
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        init(width: CGFloat, onSwipeLeft: @escaping () -> Void) {
            self.width = width
            self.onSwipeLeft = onSwipeLeft
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyWidthLock()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyWidthLock()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            applyWidthLock()
            resetStrandedSidebarTransformIfNeeded()
        }

        /// `sidebarPresentationView` walks one level of private hierarchy; if
        /// an iPadOS release reshuffles it, or an interrupted animation leaks
        /// a translation, a stale transform would leave the sidebar visually
        /// offset with no gesture in flight. Layout passes are the safety net:
        /// when nothing owns the view, force it back to identity.
        private func resetStrandedSidebarTransformIfNeeded() {
            guard !isDragActive, !isDismissAnimationRunning,
                  let strandedView = dragPresentationView,
                  strandedView.transform != .identity,
                  strandedView.layer.animationKeys()?.isEmpty != false
            else { return }
            strandedView.transform = .identity
            dragPresentationView = nil
            releaseDimmingView(restoring: true)
        }

        func applyWidthLock() {
            guard let splitViewController = splitViewControllerAncestor else { return }
            managedSplitViewController = splitViewController
            // While the sidebar is visible the direct-touch pan below is the
            // sole interactive transition owner: keeping UIKit's built-in pan
            // enabled would let both recognizers move the same primary column
            // simultaneously. While the sidebar is hidden our recognizer only
            // accepts leftward swipes, so the system edge swipe stays enabled
            // to reveal the sidebar.
            splitViewController.presentsWithGesture = sidebarIsHidden
            if splitViewController.preferredPrimaryColumnWidth != width {
                splitViewController.preferredPrimaryColumnWidth = width
            }
            if splitViewController.minimumPrimaryColumnWidth != width {
                splitViewController.minimumPrimaryColumnWidth = width
            }
            if splitViewController.maximumPrimaryColumnWidth != width {
                splitViewController.maximumPrimaryColumnWidth = width
            }
            installSwipeRecognizer(in: splitViewController)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let panGesture = gestureRecognizer as? UIPanGestureRecognizer else {
                return true
            }
            let velocity = panGesture.velocity(in: swipeHostView)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * 1.1
        }

        @objc private func handleSwipeLeft(_ gestureRecognizer: UIPanGestureRecognizer) {
            guard let splitViewController = splitViewControllerAncestor else { return }

            let presentationView: UIView
            if gestureRecognizer.state == .began {
                guard let resolvedView = sidebarPresentationView(in: splitViewController) else {
                    return
                }
                presentationView = resolvedView
                dragPresentationView = resolvedView
            } else {
                guard let activeView = dragPresentationView else { return }
                presentationView = activeView
            }

            switch gestureRecognizer.state {
            case .began:
                let visibleTransform = presentationView.layer
                    .presentation()?
                    .affineTransform() ?? presentationView.transform
                presentationView.layer.removeAllAnimations()
                UIView.performWithoutAnimation {
                    presentationView.transform = visibleTransform
                }
                dragStartOffset = visibleTransform.tx
                // The dismiss/restore animations also own the scrim's alpha.
                // Strip that animation alongside the transform one, or the
                // shared animation transaction outlives the re-grab and its
                // delayed completion can hide the column mid-drag.
                if let dimmingView = dragDimmingView {
                    let visibleAlpha = dimmingView.layer.presentation()?.opacity
                        ?? Float(dimmingView.alpha)
                    dimmingView.layer.removeAllAnimations()
                    UIView.performWithoutAnimation {
                        dimmingView.alpha = CGFloat(visibleAlpha)
                    }
                }
                resolveDimmingView(
                    in: splitViewController,
                    excluding: presentationView
                )

            case .changed:
                let translation = gestureRecognizer.translation(in: splitViewController.view)
                let horizontalOffset = max(
                    -width,
                    min(0, dragStartOffset + translation.x)
                )
                presentationView.transform = CGAffineTransform(
                    translationX: horizontalOffset,
                    y: 0
                )
                updateDimming(forSidebarOffset: horizontalOffset)

            case .ended:
                let translation = gestureRecognizer.translation(in: splitViewController.view)
                let velocity = gestureRecognizer.velocity(in: splitViewController.view)
                let horizontalOffset = max(
                    -width,
                    min(0, dragStartOffset + translation.x)
                )
                let shouldDismiss = horizontalOffset <= -(width * 0.25) || velocity.x <= -700
                dragStartOffset = 0

                if shouldDismiss {
                    isDismissAnimationRunning = true
                    UIView.animate(
                        withDuration: 0.18,
                        delay: 0,
                        options: [.curveEaseOut, .beginFromCurrentState]
                    ) {
                        presentationView.transform = CGAffineTransform(
                            translationX: -self.width,
                            y: 0
                        )
                        self.dragDimmingView?.alpha = 0
                    } completion: { finished in
                        self.isDismissAnimationRunning = false
                        // A new drag re-owns the view mid-animation; leave its
                        // state alone. Any other interruption (rotation, split
                        // relayout) must still complete the hide, or the
                        // sidebar stays "visible" while translated off-screen
                        // with no toggle button rendered to recover it.
                        guard finished || !self.isDragActive else { return }
                        UIView.performWithoutAnimation {
                            splitViewController.hide(.primary)
                            self.onSwipeLeft()
                            presentationView.transform = .identity
                            // The hide dismantles the overlay presentation,
                            // but UIKit may reuse the scrim next time the
                            // sidebar opens — leave it at its resting alpha,
                            // not the zero we faded it to.
                            self.releaseDimmingView(restoring: true)
                            splitViewController.view.layoutIfNeeded()
                            self.dragPresentationView = nil
                        }
                    }
                } else {
                    restoreSidebarPosition(presentationView)
                }

            case .cancelled, .failed:
                dragStartOffset = 0
                restoreSidebarPosition(presentationView)

            default:
                break
            }
        }

        /// UIKit's overlay presentation dims the detail pane behind the
        /// sidebar but knows nothing about our interactive drag, so the dim
        /// would stay opaque until dismissal completes and then pop off. Track
        /// the dimming view (identified structurally: a full-size, non-opaque
        /// scrim under the sidebar surface) and fade it with the drag. If the
        /// hierarchy doesn't match, everything degrades to the old pop.
        private func resolveDimmingView(
            in splitViewController: UISplitViewController,
            excluding presentationView: UIView
        ) {
            guard dragDimmingView == nil else { return }
            guard let dimmingView = findDimmingView(
                from: splitViewController.view,
                excluding: presentationView,
                depth: 0
            ) else {
                #if DEBUG
                logSidebarHierarchy(splitViewController.view, presentationView: presentationView)
                #endif
                return
            }
            dragDimmingView = dimmingView
            dimmingBaseAlpha = dimmingView.alpha
        }

        #if DEBUG
        /// One-shot dump of the split view's subtree when no scrim was found,
        /// so a mismatched iPadOS hierarchy is diagnosable from device logs.
        private static var didLogSidebarHierarchy = false
        private func logSidebarHierarchy(_ root: UIView, presentationView: UIView) {
            guard !Self.didLogSidebarHierarchy else { return }
            Self.didLogSidebarHierarchy = true
            func describe(_ view: UIView, indent: String) -> String {
                let marker = view === presentationView ? " <sidebar-surface>" : ""
                let color = view.backgroundColor.map { " bg=\($0)" } ?? ""
                var lines = "\(indent)\(type(of: view)) frame=\(view.frame) alpha=\(view.alpha)\(color)\(marker)\n"
                guard indent.count < 12 else { return lines }
                for subview in view.subviews {
                    lines += describe(subview, indent: indent + "  ")
                }
                return lines
            }
            DiagLog.d(
                .other,
                "SidebarDrag",
                "No dimming view found; hierarchy:\n\(describe(root, indent: ""))"
            )
        }
        #endif

        /// The scrim is identified by class name ("Dimming"), the same way
        /// UIKit names it across releases (`UIDimmingView`, knockout backdrop
        /// variants). The sidebar surface's own subtree is excluded so we
        /// never fade something that slides with the drag.
        private func findDimmingView(
            from root: UIView,
            excluding presentationView: UIView,
            depth: Int
        ) -> UIView? {
            guard depth <= 6 else { return nil }
            for candidate in root.subviews {
                guard candidate !== presentationView else { continue }
                if !candidate.isHidden,
                   String(describing: type(of: candidate))
                       .localizedCaseInsensitiveContains("dimming") {
                    return candidate
                }
                if let nested = findDimmingView(
                    from: candidate,
                    excluding: presentationView,
                    depth: depth + 1
                ) {
                    return nested
                }
            }
            return nil
        }

        private func updateDimming(forSidebarOffset horizontalOffset: CGFloat) {
            guard let dimmingView = dragDimmingView, width > 0 else { return }
            let visibleFraction = max(0, min(1, 1 + horizontalOffset / width))
            dimmingView.alpha = dimmingBaseAlpha * visibleFraction
        }

        private func releaseDimmingView(restoring: Bool = false) {
            if restoring {
                dragDimmingView?.alpha = dimmingBaseAlpha
            }
            dragDimmingView = nil
        }

        /// Whether a pan is actively re-owning the sidebar mid-animation.
        private var isDragActive: Bool {
            switch swipeLeftRecognizer.state {
            case .began, .changed: return true
            default: return false
            }
        }

        private func restoreSidebarPosition(_ presentationView: UIView) {
            UIView.animate(
                withDuration: 0.25,
                delay: 0,
                usingSpringWithDamping: 0.9,
                initialSpringVelocity: 0,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                presentationView.transform = .identity
                self.dragDimmingView?.alpha = self.dimmingBaseAlpha
            } completion: { finished in
                if finished {
                    self.dragPresentationView = nil
                    self.releaseDimmingView(restoring: true)
                }
            }
        }

        private func sidebarPresentationView(
            in splitViewController: UISplitViewController
        ) -> UIView? {
            guard let primaryView = splitViewController
                .viewController(for: .primary)?
                .view
            else { return nil }

            // On iPadOS the navigation controller is wrapped by a clipping
            // view and then by the adaptive column surface that owns the
            // sidebar's glass background and shadow. Move that complete
            // fixed-width surface when it matches the primary geometry;
            // otherwise fall back to the public primary view.
            guard let columnView = primaryView.superview?.superview,
                  columnView !== splitViewController.view,
                  abs(columnView.bounds.width - width) <= 1,
                  abs(columnView.bounds.height - primaryView.bounds.height) <= 1
            else { return primaryView }
            return columnView
        }

        private func installSwipeRecognizer(in splitViewController: UISplitViewController) {
            guard let primaryView = splitViewController
                .viewController(for: .primary)?
                .view,
                  swipeHostView !== primaryView
            else { return }

            swipeHostView?.removeGestureRecognizer(swipeLeftRecognizer)
            primaryView.addGestureRecognizer(swipeLeftRecognizer)
            swipeHostView = primaryView
        }

        func tearDown() {
            dragPresentationView?.layer.removeAllAnimations()
            dragPresentationView?.transform = .identity
            dragPresentationView = nil
            releaseDimmingView(restoring: true)
            swipeHostView?.layer.removeAllAnimations()
            swipeHostView?.transform = .identity
            swipeHostView?.removeGestureRecognizer(swipeLeftRecognizer)
            swipeHostView = nil
            managedSplitViewController?.presentsWithGesture = true
            managedSplitViewController = nil
        }

        private var splitViewControllerAncestor: UISplitViewController? {
            var ancestor = parent
            while let controller = ancestor {
                if let splitViewController = controller as? UISplitViewController {
                    return splitViewController
                }
                ancestor = controller.parent
            }
            return nil
        }
    }
}
#endif

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

enum MainTabDestinationID: Hashable {
    case app(AppTab)
    case libraryCategory(PrimaryMenuBuiltin)
    case library(Int)
}

struct MainTabDestination: Identifiable, Equatable {
    let id: MainTabDestinationID
    let title: String
    let icon: String
    let selectedIcon: String

    static func app(_ tab: AppTab) -> MainTabDestination {
        .init(id: .app(tab), title: tab.rawValue, icon: tab.icon, selectedIcon: tab.selectedIcon)
    }

    static func library(
        id: Int,
        label: String,
        icon: String = "rectangle.stack",
        selectedIcon: String = "rectangle.stack.fill"
    ) -> MainTabDestination {
        .init(
            id: .library(id),
            title: label,
            icon: icon,
            selectedIcon: selectedIcon
        )
    }

    static func libraryCategory(_ category: PrimaryMenuBuiltin) -> MainTabDestination {
        return .init(
            id: .libraryCategory(category),
            title: category.title,
            icon: category.navigationIcon,
            selectedIcon: category.navigationIcon
        )
    }
}

private struct MainTabSidebarDestination: Identifiable {
    let destination: MainTabDestination
    let isNestedLibrary: Bool

    var id: MainTabDestinationID { destination.id }
}

/// Projects the cross-client menu into roots this Apple shell can navigate
/// without discarding destination identity. Sections and collections remain
/// stored in the synced document, but stay hidden until this shell has a
/// destination-specific root for them.
func projectedMainTabDestinations(
    primaryMenu: PrimaryMenuPreference?,
    availableLibraries: [Library] = [],
    showAudiobooks: Bool = true
) -> [MainTabDestination] {
    guard let primaryMenu else {
        return AppTab.visibleCases.map(MainTabDestination.app)
    }

    let menuItems = primaryMenu.items.count == 1 && primaryMenu.items[0].isHome
        ? appleDefaultPrimaryMenuItems()
        : primaryMenu.items
    var destinations: [MainTabDestination] = []
    for item in menuItems {
        guard mainTabSupportsDestination(
            item,
            availableLibraries: availableLibraries,
            showAudiobooks: showAudiobooks
        ) else {
            continue
        }
        let destination: MainTabDestination?
        switch item {
        case .builtin(.home): destination = .app(.home)
        case .builtin(.movies): destination = .libraryCategory(.movies)
        case .builtin(.series): destination = .libraryCategory(.series)
        case .builtin(.audiobooks): destination = .libraryCategory(.audiobooks)
        case .builtin(.music): destination = nil
        case .builtin(.forYou): destination = .app(.recommendations)
        case .builtin(.calendar): destination = .app(.calendar)
        case .library(let libraryId, let label):
            let library = availableLibraries.first(where: { $0.id == libraryId })
            destination = .library(
                id: libraryId,
                label: library?.name ?? label,
                icon: library?.navigationIcon ?? "rectangle.stack",
                selectedIcon: library?.selectedNavigationIcon ?? "rectangle.stack.fill"
            )
        case .section, .collection:
            destination = nil
        }
        if let destination,
           !destinations.contains(where: { $0.id == destination.id }) {
            destinations.append(destination)
        }
    }
    if !destinations.contains(where: { $0.id == .app(.home) }) {
        destinations.insert(.app(.home), at: 0)
    }
    if destinations.count == 1, destinations[0].id == .app(.home) {
        var defaults: [MainTabDestination] = [.app(.home)]
        if availableLibraries.contains(where: {
            libraryMatchesPrimaryMenuCategory($0, category: .movies)
        }) {
            defaults.append(.libraryCategory(.movies))
        }
        if availableLibraries.contains(where: {
            libraryMatchesPrimaryMenuCategory($0, category: .series)
        }) {
            defaults.append(.libraryCategory(.series))
        }
        defaults.append(contentsOf: [
            .app(.recommendations),
            .app(.calendar),
        ])
        return defaults
    }
    return destinations
}

/// Runtime/editor capability gate for the non-tvOS Apple main shell. The
/// synced document remains untouched; roots that the active profile cannot
/// currently open simply stay out of the rendered navigation and editor.
func mainTabSupportsDestination(
    _ item: PrimaryMenuItem,
    availableLibraries: [Library],
    showAudiobooks: Bool = true
) -> Bool {
    switch item {
    case .builtin(.movies):
        return availableLibraries.contains {
            libraryMatchesPrimaryMenuCategory($0, category: .movies)
        }
    case .builtin(.series):
        return availableLibraries.contains {
            libraryMatchesPrimaryMenuCategory($0, category: .series)
        }
    case .builtin(.audiobooks):
        return showAudiobooks && availableLibraries.contains {
            libraryMatchesPrimaryMenuCategory($0, category: .audiobooks)
        }
    case .builtin(.music):
        return false
    case .builtin(.home), .builtin(.forYou), .builtin(.calendar):
        return true
    case .library(let libraryId, _):
        return availableLibraries.contains {
            $0.id == libraryId && (showAudiobooks || !$0.isAudiobookLibrary)
        }
    case .section, .collection:
        return false
    }
}

func resolvedVisibleMainTabDestination(
    _ requestedDestination: MainTabDestinationID,
    visibleDestinations: [MainTabDestination]
) -> MainTabDestinationID {
    visibleDestinations.contains { $0.id == requestedDestination }
        ? requestedDestination
        : .app(.home)
}

func resolvedRequestedMainTabDestination(
    _ requestedTab: AppTab,
    visibleDestinations: [MainTabDestination]
) -> MainTabDestinationID {
    if requestedTab == .libraries,
       !visibleDestinations.contains(where: { $0.id == .app(.libraries) }),
       let authoredLibraryRoot = visibleDestinations.first(where: {
           switch $0.id {
           case .libraryCategory, .library:
               return true
           case .app:
               return false
           }
       }) {
        return authoredLibraryRoot.id
    }
    return resolvedVisibleMainTabDestination(
        .app(requestedTab),
        visibleDestinations: visibleDestinations
    )
}

struct MainTabLibraryAuthority: Hashable {
    let serverId: String
    let profileId: String

    init?(serverId: String?, profileId: String?) {
        guard let serverId, !serverId.isEmpty,
              let profileId, !profileId.isEmpty else { return nil }
        self.serverId = serverId
        self.profileId = profileId
    }
}

struct MainTabLibrarySnapshot: Equatable {
    let authority: MainTabLibraryAuthority?
    let libraries: [Library]

    func availableLibraries(
        for currentAuthority: MainTabLibraryAuthority?
    ) -> [Library] {
        guard let currentAuthority, authority == currentAuthority else { return [] }
        return libraries
    }

    @MainActor
    static func cachedForCurrentAuthority() -> Self {
        let registry = ServerRegistry.shared
        let authority = MainTabLibraryAuthority(
            serverId: registry.activeServerId,
            profileId: registry.activeProfileId
        )
        let libraries = ResponseCache.shared.get(
            CacheKey.userLibraries,
            as: LibrariesResponse.self
        )?.libraries ?? []
        return .init(authority: authority, libraries: libraries)
    }
}

struct MainTabView: View {
    @Bindable var router: AppRouter
    @State private var selectedDestinationID: MainTabDestinationID = .app(.home)
    @State private var uiCustomization = UICustomizationPreferences.shared
    /// The local audiobook opt-in is a final visibility gate even when a
    /// synced/custom menu contains an Audiobooks destination.
    @State private var navPrefs = AppNavPreferences.shared
    @State private var serverRegistry = ServerRegistry.shared
    /// Tagged with the server/profile that authorized the library list. A
    /// profile transition fails direct roots closed immediately, even before
    /// its cache invalidation and network refresh finish.
    @State private var librarySnapshot = MainTabLibrarySnapshot.cachedForCurrentAuthority()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var iPadColumnVisibility: NavigationSplitViewVisibility = .detailOnly
    /// Shared namespace for the poster → detail zoom transition. Injected into
    /// the environment (`\.zoomNamespace`) so both the cards and the central
    /// detail destination resolve the same identity.
    @Namespace private var zoomNamespace
    @Environment(AudioPlaybackStore.self) private var audioStore
    @Environment(\.scenePhase) private var scenePhase
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
        .task(id: currentLibraryAuthority) {
            await loadVisibleLibraries(for: currentLibraryAuthority)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            let authority = currentLibraryAuthority
            Task { await loadVisibleLibraries(for: authority) }
        }
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
                  selectedDestinationID == .app(.home), router.requestedTab == nil
            else { return }
            selectedDestinationID = .app(.downloads)
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
            selectedDestinationID = resolvedRequestedMainTabDestination(
                tab,
                visibleDestinations: visibleDestinations
            )
            router.requestedTab = nil
        }
        .onChange(of: uiCustomization.primaryMenu) { _, _ in
            selectedDestinationID = resolvedVisibleMainTabDestination(
                selectedDestinationID,
                visibleDestinations: visibleDestinations
            )
        }
        .onChange(of: navPrefs.showAudiobooks) { _, _ in
            selectedDestinationID = resolvedVisibleMainTabDestination(
                selectedDestinationID,
                visibleDestinations: visibleDestinations
            )
        }
        .onChange(of: librarySnapshot) { _, _ in
            selectedDestinationID = resolvedVisibleMainTabDestination(
                selectedDestinationID,
                visibleDestinations: visibleDestinations
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .userLibrariesDidRefresh)) {
            notification in
            guard let authority = currentLibraryAuthority,
                  let response = notification.object as? LibrariesResponse
            else { return }
            librarySnapshot = .init(authority: authority, libraries: response.libraries)
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
                backdropURLHint: payload.backdropURL
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
    private var visibleDestinations: [MainTabDestination] {
        var destinations = projectedMainTabDestinations(
            primaryMenu: uiCustomization.primaryMenu,
            availableLibraries: librarySnapshot.availableLibraries(
                for: currentLibraryAuthority
            ),
            showAudiobooks: navPrefs.showAudiobooks
        )
        #if !os(tvOS)
        if DownloadManager.shared.downloadsEnabled,
           !destinations.contains(where: { $0.id == .app(.downloads) }) {
            destinations.append(.app(.downloads))
        }
        #endif
        return destinations
    }

    private var currentLibraryAuthority: MainTabLibraryAuthority? {
        MainTabLibraryAuthority(
            serverId: serverRegistry.activeServerId,
            profileId: serverRegistry.activeProfileId
        )
    }

    private func loadVisibleLibraries(for authority: MainTabLibraryAuthority?) async {
        let retainedLibraries = librarySnapshot.authority == authority
            ? librarySnapshot.libraries
            : []
        librarySnapshot = .init(authority: authority, libraries: retainedLibraries)
        guard let authority else { return }
        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries()
            guard !Task.isCancelled, currentLibraryAuthority == authority else { return }
            librarySnapshot = .init(authority: authority, libraries: response.libraries)
        } catch {
            // Keep the active-profile cache, or fail closed with no direct
            // library roots when there is no safe offline routing metadata.
        }
    }

    private var selectedDestination: MainTabDestination {
        visibleDestinations.first(where: { $0.id == selectedDestinationID })
            ?? .app(.home)
    }

    private var sidebarTitle: String {
        serverRegistry.activeServer?.displayName ?? "Silo"
    }

    /// iPhone + iPad compact width: bottom tab bar, single navigation stack.
    private var tabLayout: some View {
        NavigationStack(path: $router.path) {
            TabView(selection: $selectedDestinationID) {
                ForEach(visibleDestinations) { destination in
                    #if os(tvOS)
                    // Text-only tabs on tvOS keep the top bar compact — adding an
                    // icon blows up each tab's focus pill. The value-based `Tab`
                    // initializer requires an image on tvOS, so this arm stays on
                    // the `.tabItem { Text }` form to preserve the text-only look.
                    destinationContent(for: destination)
                        .tabItem { Text(destination.title) }
                        .tag(destination.id)
                    #else
                    Tab(
                        destination.title,
                        systemImage: selectedDestinationID == destination.id
                            ? destination.selectedIcon
                            : destination.icon,
                        value: destination.id
                    ) {
                        destinationContent(for: destination)
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

    /// iPad regular width: the native sidebar overlays the detail pane without
    /// changing its original system material or row-selection appearance.
    /// macOS keeps the standard side-by-side split-view layout.
    ///
    /// Home / Libraries / Recommendations hide the nav bar (so SwiftUI's
    /// default sidebar toggle isn't visible on those screens). We inject a
    /// toggle closure through `\.sidebarToggle` instead — each custom header
    /// renders a `SidebarToggleButton` on its leading edge while the overlay is
    /// closed. Video playback doesn't overlap the sidebar because the player is
    /// presented via `fullScreenCover` on `router.presentedPlayer` rather than
    /// pushed into the detail pane.
    private var sidebarLayout: some View {
        Group {
            #if os(iOS)
            iPadSidebarLayout
                .environment(
                    \.sidebarToggle,
                    iPadColumnVisibility == .detailOnly ? toggleSidebar : nil
                )
                .environment(\.reservesSidebarToggleSpace, true)
            #else
            macSidebarLayout
                .environment(\.sidebarToggle, toggleSidebar)
            #endif
        }
        .environment(\.zoomNamespace, zoomNamespace)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NowPlayingShelf(style: .card)
        }
    }

    #if os(iOS)
    private let iPadSidebarWidth: CGFloat = 320

    private var iPadSidebarLayout: some View {
        NavigationSplitView(columnVisibility: $iPadColumnVisibility) {
            sidebarList(
                dismissAfterSelection: true,
                nestsPinnedLibraries: true
            )
                .background {
                    FixedPrimarySplitViewWidth(
                        width: iPadSidebarWidth,
                        sidebarIsHidden: iPadColumnVisibility == .detailOnly,
                        onSwipeLeft: finishInteractiveSidebarDismissal
                    )
                        .frame(width: 0, height: 0)
                }
                .navigationSplitViewColumnWidth(
                    min: iPadSidebarWidth,
                    ideal: iPadSidebarWidth,
                    max: iPadSidebarWidth
                )
                .toolbar(removing: .sidebarToggle)
                .toolbar(.hidden, for: .navigationBar)
                .safeAreaInset(edge: .top, spacing: 0) {
                    iPadSidebarHeader
                }
        } detail: {
            sidebarDetailContent
                .toolbar(removing: .sidebarToggle)
        }
        .navigationSplitViewStyle(.prominentDetail)
    }

    /// Custom sidebar header replacing the navigation bar so the server name
    /// and close button can sit lower than the system bar allows.
    private var iPadSidebarHeader: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(
                    width: ContinuumTheme.topBarIconHitSize,
                    height: ContinuumTheme.topBarIconHitSize
                )
                .accessibilityHidden(true)

            Text(sidebarTitle)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)

            Button(action: dismissSidebar) {
                Image(systemName: "arrow.left")
                    .font(.body.weight(.semibold))
                    .frame(
                        width: ContinuumTheme.topBarIconHitSize,
                        height: ContinuumTheme.topBarIconHitSize
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close sidebar")
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    #else
    private var macSidebarLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarList(
                dismissAfterSelection: false,
                nestsPinnedLibraries: false
            )
                .navigationTitle(sidebarTitle)
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 280)
        } detail: {
            sidebarDetailContent
        }
    }
    #endif

    private var sidebarDetailContent: some View {
        NavigationStack(path: $router.path) {
            destinationContent(for: selectedDestination)
                .id(selectedDestination.id)
                .navigationDestination(for: Route.self) { route in
                    routeContent(for: route)
                        #if os(iOS)
                        .toolbar {
                            if routeNeedsSidebarToggle(route) {
                                ToolbarItem(placement: .topBarLeading) {
                                    SidebarToggleButton()
                                }
                            }
                        }
                        #endif
                }
        }
    }

    private func sidebarList(
        dismissAfterSelection: Bool,
        nestsPinnedLibraries: Bool
    ) -> some View {
        List(selection: Binding<MainTabDestinationID?>(
            get: { selectedDestinationID },
            set: { value in
                guard let value else { return }
                selectSidebarDestination(value)
                if dismissAfterSelection {
                    dismissSidebar()
                }
            }
        )) {
            ForEach(sidebarDestinations(nestingPinnedLibraries: nestsPinnedLibraries)) { item in
                let destination = item.destination
                Label(
                    destination.title,
                    systemImage: selectedDestinationID == destination.id
                        ? destination.selectedIcon
                        : destination.icon
                )
                .padding(.leading, item.isNestedLibrary ? 24 : 0)
                .tag(destination.id)
            }
        }
        // The sidebar's few rows rarely overflow; without this the list
        // still rubber-bands on drag, visually dragging the whole bar.
        .scrollBounceBehavior(.basedOnSize)
    }

    private func sidebarDestinations(
        nestingPinnedLibraries: Bool
    ) -> [MainTabSidebarDestination] {
        guard nestingPinnedLibraries else {
            return visibleDestinations.map {
                MainTabSidebarDestination(destination: $0, isNestedLibrary: false)
            }
        }

        let availableLibraries = librarySnapshot.availableLibraries(
            for: currentLibraryAuthority
        )
        return groupPinnedLibrariesUnderMediaTypes(
            visibleDestinations,
            libraries: availableLibraries,
            libraryID: { destination in
                guard case .library(let libraryID) = destination.id else { return nil }
                return libraryID
            },
            mediaTypeCategory: { destination in
                guard case .libraryCategory(let category) = destination.id else {
                    return nil
                }
                return category
            }
        ).map {
            MainTabSidebarDestination(
                destination: $0.element,
                isNestedLibrary: $0.isNestedLibrary
            )
        }
    }

    /// Collapses or re-expands the sidebar without moving the detail content.
    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.25)) {
            #if os(iOS)
            iPadColumnVisibility = iPadColumnVisibility == .detailOnly ? .all : .detailOnly
            #else
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            #endif
        }
    }

    /// Sidebar rows are root destinations, even when the same row is already
    /// selected beneath a pushed screen. Clear the detail stack first so, for
    /// example, tapping Home while Search is open actually returns to Home.
    private func selectSidebarDestination(_ destinationID: MainTabDestinationID) {
        router.popToRoot()
        selectedDestinationID = destinationID
    }

    private func dismissSidebar() {
        #if os(iOS)
        guard iPadColumnVisibility != .detailOnly else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            iPadColumnVisibility = .detailOnly
        }
        #endif
    }

    #if os(iOS)
    private func finishInteractiveSidebarDismissal() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            iPadColumnVisibility = .detailOnly
        }
    }
    #endif

    @ViewBuilder
    private func destinationContent(for destination: MainTabDestination) -> some View {
        switch destination.id {
        case .app(let tab):
            tabContent(for: tab)
        case .libraryCategory(let category):
            LibrariesTabView(
                category: category,
                libraryAuthority: currentLibraryAuthority,
                onLibrariesLoaded: acceptLoadedLibraries
            )
        case .library(let libraryId):
            LibrariesTabView(
                fixedLibraryId: libraryId,
                libraryAuthority: currentLibraryAuthority,
                onLibrariesLoaded: acceptLoadedLibraries
            )
        }
    }

    private func acceptLoadedLibraries(
        authority: MainTabLibraryAuthority?,
        libraries: [Library]
    ) {
        guard let authority, authority == currentLibraryAuthority else { return }
        librarySnapshot = .init(authority: authority, libraries: libraries)
    }

    @ViewBuilder
    private func tabContent(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            HomeView()

        case .libraries:
            LibrariesTabView(
                libraryAuthority: currentLibraryAuthority,
                onLibrariesLoaded: acceptLoadedLibraries
            )

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
                // The iOS 26 poster → detail zoom transition
                // (`.navigationTransition(.zoom(sourceID:in:))`, keyed off
                // `pendingZoomSourceID`) is intentionally NOT applied here.
                // On iOS 26 the zoom transition keeps the pushed detail bound
                // to the source card's portal geometry; rotating the device
                // while the detail is up recomputes that transform against
                // stale geometry, leaving the whole page scaled up ("zoomed
                // in") after rotating back and the source card stuck on
                // screen. Deep-linked pushes (no zoom source) never showed
                // the bug. Restore the modifier once Apple fixes the
                // regression (see forums thread 807208).
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

    #if os(iOS)
    private func routeNeedsSidebarToggle(_ route: Route) -> Bool {
        switch route {
        case .downloads, .recommendations:
            false
        default:
            true
        }
    }
    #endif

    private var settingsPlaceholder: some View {
        List {
            Section {
                Button("Switch Profile") {
                    router.switchProfile()
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
