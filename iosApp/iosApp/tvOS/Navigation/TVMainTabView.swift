enum TVVisibleRootsFocusRearm: Equatable {
    case none
    case topMenu
    case content
}

func tvVisibleRootsFocusRearm(
    menuOwnedFocus: Bool,
    isShowingRoot: Bool,
    selectedRootWasRemoved: Bool
) -> TVVisibleRootsFocusRearm {
    guard isShowingRoot else { return .none }
    if menuOwnedFocus { return .topMenu }
    return selectedRootWasRemoved ? .content : .none
}

#if os(tvOS)
import SwiftUI

private enum TVPersonalRootDestination: Hashable {
    case watchlist
    case favorites
}

/// Root tvOS shell. Owns a custom Skyline top bar instead of relying on
/// `TabView(.sidebarAdaptable)`, so content can use horizontal remote
/// navigation without the system sidebar claiming leftward focus.
///
/// Tabs are content-type-first (Skyline §3.1): `Home · Movies · Series ·
/// Music · Audiobooks · For You · Calendar`, where each library-type tab
/// appears only if the profile can see at least one library of that type.
struct TVMainTabView: View {
    @Bindable var router: AppRouter
    @State private var selectedRoot: TVRootDestination = .home
    /// Watchlist and Favorites are root-shell pages rather than pushed
    /// destinations, so the Skyline bar and profile controls remain present.
    /// The previously selected content root stays underneath and is restored
    /// when the user backs out of the personal page.
    @State private var personalRoot: TVPersonalRootDestination?
    /// Seeded from the startup prefetch so the bar's first frame already
    /// shows the active profile's avatar instead of filling it in late.
    @State private var currentProfile: UserProfile? = {
        guard let profileId = AuthService.shared.profileId,
              let cached: [UserProfile] = ResponseCache.shared.get(CacheKey.profiles) else {
            return nil
        }
        return cached.first(where: { $0.id == profileId })
    }()
    @State private var showServerPicker = false
    @State private var showSignOutConfirm = false
    @State private var registry = ServerRegistry.shared
    /// Local, per-profile tab-visibility prefs (e.g. whether the Audiobooks
    /// tab is opted in). Observed so the bar re-derives `visibleRoots` the
    /// instant a toggle flips in Settings.
    @State private var navPrefs = TVNavPreferences.shared
    @State private var uiCustomization = UICustomizationPreferences.shared
    /// Visible libraries for the active profile; drives which type tabs
    /// exist and which library each type tab scopes to. Seeded from the
    /// startup prefetch so all type tabs are in the bar's first frame —
    /// waiting for `.task` made the library tabs pop in a beat after the
    /// splash lifted.
    @State private var libraries: [Library] =
        ResponseCache.shared.get(CacheKey.userLibraries, as: LibrariesResponse.self)?.libraries ?? []
    @State private var loadedLibraryAuthority: MainTabLibraryAuthority? = {
        let registry = ServerRegistry.shared
        return MainTabLibraryAuthority(
            serverId: registry.activeServerId,
            profileId: registry.activeProfileId
        )
    }()
    /// Per-type pill selection, session-only (§8): it survives tab
    /// switches but cold start always lands on Recommended.
    @State private var pillSelections: [TVLibraryTabType: TVLibraryPill] = [:]
    /// Direct pins own section state by exact library identity. They must not
    /// inherit Movies/Series state, and each pin's one-library cascade remains
    /// independently usable even when its category root is hidden.
    @State private var shortcutPillSelections: [Int: TVLibraryPill] = [:]
    /// Per-type library scope: which single library each multi-library type
    /// is scoped to (§3.1). Seeded from the persisted choice (or the first
    /// library on cold start) via `TVLibraryScopeStore`, and updated +
    /// re-persisted by the cascade selector. Single-library types resolve
    /// trivially and never need an entry.
    @State private var scopeSelections: [TVLibraryTabType: Int] = [:]
    /// The anchored panel currently open from the top bar (cascade or
    /// profile), plus whether focus has descended into it. Owned here so it
    /// renders as a scrimmed overlay over the page (§5.3) — not a pushed
    /// route or full-screen modal.
    @State private var openPanel: TVTopMenuPanel?
    @State private var panelEntersFocus = false
    @State private var panelFocusEntryGeneration = 0
    @State private var panelHasFocus = false
    @State private var panelFocusExitTask: Task<Void, Never>?
    @State private var controlReceiver = TVControlReceiver.shared
    /// Bar element to re-focus after Menu-ing out of a panel — its own
    /// anchor, so focus returns to the dwelled tab/avatar (§7).
    @State private var panelReturnFocus: TVTopMenuPanel?
    @State private var isTopMenuFocused = false
    @State private var isTopMenuFocusSuppressed = true
    /// True while a route pushed *from the bar* (search, profile/For You
    /// panel items) is on the stack. When the stack pops back to root,
    /// focus returns to the bar — the explicit "next owner" choice
    /// (docs/tvos-focus.md); leaving it to the engine landed on an
    /// arbitrary row card. Card-pushed routes (detail pages) never set this;
    /// their pops emit `detailReturnFocusRequest` so the exact launch row/card
    /// explicitly reclaims focus.
    @State private var barOwnsFocusOnPopToRoot = false
    @State private var topMenuFocusRequest = 0
    /// Bumped by the focus watchdog to drop the bar's `@FocusState` when the
    /// engine has already dropped focus without telling it. Re-suppressing is
    /// not enough: the bar nils on the *transition* into suppression, and the
    /// wedge is observed while suppression is already true.
    @State private var topMenuFocusResetRequest = 0
    /// Active focus hand-down generation. Incremented whenever a root is
    /// selected so the freshly-swapped-in content imperatively claims
    /// focus, instead of relying on `prefersDefaultFocus` (which can lose
    /// to geometric proximity, per CLAUDE.md's "tvOS default focus on
    /// d-pad entry"). Starts at 1 so the initial Home content focuses on
    /// first appear.
    @State private var contentFocusRequest = 1
    /// Card-pushed detail routes return to their exact Skyline owner instead
    /// of relying on NavigationStack's best-effort focus restoration.
    @State private var detailReturnFocusRequest = 0
    @Namespace private var tabContentNamespace
    @Environment(AudioPlaybackStore.self) private var audioStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let panelFocusExitCloseDelayNanoseconds: UInt64 = 80_000_000

    var body: some View {
        ZStack(alignment: .top) {
            NavigationStack(path: $router.path) {
                rootContent
                    .navigationDestination(for: Route.self) { route in
                        routeContent(for: route)
                    }
            }

            if router.path.isEmpty {
                TVTopMenuBar(
                    roots: visibleRoots,
                    selectedRoot: selectedRoot,
                    currentProfile: currentProfile,
                    isMenuFocused: $isTopMenuFocused,
                    isFocusSuppressed: isTopMenuFocusSuppressed,
                    focusRequest: topMenuFocusRequest,
                    focusResetRequest: topMenuFocusResetRequest,
                    focusRequestTarget: panelReturnFocus,
                    openPanel: openPanel,
                    panelHasFocus: panelHasFocus,
                    panelEntersFocus: panelEntersFocus,
                    onSelectRoot: selectRoot(_:),
                    onSearch: { navigateFromBar(.search) },
                    onDwell: handleDwell(_:),
                    onEnterPanel: enterPanelFor,
                    onProfilePressed: openProfilePanelImmediately,
                    onContentFocusHandoff: suppressTopMenuFocusForContentHandoff,
                    onExit: personalRoot != nil
                        ? returnFromPersonalRootInMenu
                        : (selectedRoot == .home ? nil : returnToHomeInMenu)
                )
            }

            if let standbyState = controlReceiver.standbyState {
                TVControlStandbyView(receiver: controlReceiver, state: standbyState)
                    .transition(reduceMotion ? .identity : .opacity)
                    .zIndex(20)
            }
        }
        // The anchored cascade / profile panel renders here (not as a ZStack
        // sibling) so its `overlayPreferenceValue` can see the bar's
        // published anchors and position the panel under the right element.
        .overlayPreferenceValue(TVTopMenuAnchorKey.self) { anchors in
            panelOverlay(anchors: anchors)
        }
        .allowsHitTesting(!showSignOutConfirm)
        .overlay {
            if showSignOutConfirm {
                TVSettingsConfirmationOverlay(
                    title: "Sign Out",
                    message: "Choose whether to keep or remove this server from this Apple TV.",
                    confirmTitle: "Sign Out",
                    additionalDestructiveTitle: "Sign Out & Remove Server",
                    cancel: dismissSignOutConfirmation,
                    confirm: router.signOutAndReset,
                    additionalDestructiveAction: router.signOutRemoveServerAndReset
                )
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: showSignOutConfirm)
        .ignoresSafeArea(edges: [.top, .horizontal])
        .tint(.continuumOnSurface)
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
                prefersLastUsedVersion: payload.prefersLastUsedVersion,
                posterURLHint: payload.posterURL,
                backdropURLHint: payload.backdropURL,
                onPlaybackStarted: {
                    guard let returnToContentId = payload.returnToContentId,
                          router.presentedPlayer?.id == payload.id else { return }
                    router.replaceCurrent(with: .itemDetail(contentId: returnToContentId))
                }
            )
        }
        .confirmationDialog(
            "Switch Server",
            isPresented: $showServerPicker,
            titleVisibility: .visible
        ) {
            ForEach(registry.sortedEntries) { entry in
                Button(serverButtonLabel(entry)) {
                    switchToServer(entry)
                }
            }
            Button("Add Server…") {
                router.navigate(to: .serverSetup)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose a saved server to switch to.")
        }
        // Outside the presentation modifiers so presented covers (audio
        // player) inherit the router — ErrorView requires it and traps
        // when it's absent.
        .environment(router)
        .task {
            // Re-read tab-visibility prefs for the now-known profile (the
            // singleton may hold the previous profile's value after a switch).
            navPrefs.refresh()
            await uiCustomization.refresh()
            controlReceiver.start(router: router)
            await loadCurrentProfile()
        }
        .task(id: currentLibraryAuthority) {
            await loadLibraries(for: currentLibraryAuthority)
        }
        .onChange(of: router.path.isEmpty) { _, isEmpty in
            // Returning from a pushed route (Search, detail, settings)
            // re-mounts the bar with whatever suppression it had when it
            // unmounted — pushing from the bar leaves it *enabled*, so the
            // engine's post-pop focus restore can land on the last bar
            // element (e.g. the search icon) for a frame before the
            // content-boundary Up handler re-pins the selected tab. Content
            // owns focus after a pop, so re-assert the suppressed invariant;
            // Up from content re-arms the bar explicitly as usual.
            if isEmpty {
                suppressTopMenuFocusForContentHandoff()
                if barOwnsFocusOnPopToRoot {
                    barOwnsFocusOnPopToRoot = false
                    // Deferred one turn: the bar re-mounts in this same
                    // transaction, so a synchronous request bump would be
                    // its *initial* value and onChange(focusRequest) would
                    // never fire.
                    DispatchQueue.main.async {
                        focusTopMenuIfVisible()
                    }
                } else {
                    detailReturnFocusRequest += 1
                }
            }
        }
        .onChange(of: router.requestedTab) { _, requestedTab in
            guard let requestedTab else { return }
            router.requestedTab = nil

            // tvOS owns a custom root selector rather than MainTabView's
            // AppTab binding. Settings uses this one-shot request so its
            // final Menu/Back exits to Home regardless of the prior root.
            if requestedTab == .home {
                selectRoot(.home)
            }
        }
        .onChange(of: visibleRoots) { _, _ in
            reconcileVisibleRootsChange()
        }
        .onDisappear {
            controlReceiver.stop()
        }
        .onChange(of: ServerRegistry.shared.activeServerId) {
            controlReceiver.start(router: router)
        }
        .onChange(of: ServerRegistry.shared.activeServer?.displayName) {
            controlReceiver.start(router: router)
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Returning from a suspension can leave the Bonjour listener dead
            // (its state handler nils it out); restart so phones can still
            // find this TV. No-op when the listener is healthy.
            if newPhase == .active {
                controlReceiver.start(router: router)
                let authority = currentLibraryAuthority
                Task { await loadLibraries(for: authority) }
            }
        }
        .tvFocusWatchdog(isActive: focusWatchdogIsActive, onRepair: repairLostFocus)
    }

    /// The watchdog's reading is only actionable while this shell's focus graph
    /// is the one on screen. Covers, dialogs, and the standby overlay own (or
    /// legitimately suspend) focus themselves, and a backgrounded scene has no
    /// focused item by definition.
    private var focusWatchdogIsActive: Bool {
        scenePhase == .active
            && router.presentedPlayer == nil
            && !audioStore.isShowingFullPlayer
            && !showSignOutConfirm
            && !showServerPicker
            && controlReceiver.standbyState == nil
    }

    /// One nudge per detected focus outage (docs/tvos-focus.md: do not fight
    /// the engine). At root the shell owns the hand-down, so clear the bar's
    /// stale focus state and re-arm content entry focus — the same path a tab
    /// selection uses. On a pushed route the shell owns no focus target, so ask
    /// the engine to re-resolve from the window instead of pinning one.
    ///
    /// `rootContent` blocks hit testing while a panel is open, so an open panel
    /// has to come down first or the content focus hand-down lands on nothing.
    private func repairLostFocus() {
        topMenuFocusResetRequest += 1
        if router.path.isEmpty {
            closePanelForContentHandoff()
            suppressTopMenuFocusForContentHandoff()
            contentFocusRequest += 1
        } else {
            TVFocusSystemProbe.requestFocusUpdate()
        }
    }

    private var rootContent: some View {
        ZStack(alignment: .top) {
            Color.continuumBackground
                .ignoresSafeArea()

            Group {
                if let personalRoot {
                    personalRootContent(personalRoot)
                        .id(personalRoot)
                } else {
                    selectedRootContent
                        .id(selectedRoot)
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // §4.2 tab content switch: an explicit 200 ms opacity
                // crossfade keyed on the selected root, so the incoming page
                // fades in and the outgoing one fades out in place (it never
                // slides). The crossfade animation is supplied by `selectRoot`;
                // Reduce Motion snaps via the `.identity` transition.
                .transition(reduceMotion ? .identity : .opacity)
                .focusScope(tabContentNamespace)
                // Keep the page from taking remote/pointer events while a
                // menu floats above it, without writing `\.isEnabled` through
                // the whole content subtree. Using `.disabled(openPanel != nil)`
                // here made every visible button/card redraw in its disabled
                // state when a dwell preview opened, which read as a page flash.
                .allowsHitTesting(openPanel == nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: [.top, .horizontal])
        .onExitCommand {
            if router.path.isEmpty {
                focusTopMenuIfVisible()
            } else {
                // The root remains mounted behind NavigationStack pushes.
                // Its old no-op top-menu request consumed Back/Menu while the
                // bar was absent, stranding detail pages. On a push, Back owns
                // exactly one stack pop so focus can restore to the launch card.
                router.goBack()
            }
        }
    }

    @ViewBuilder
    private var selectedRootContent: some View {
        switch selectedRoot {
        case .home:
            HomeView(
                homeFocusRequest: contentFocusRequest,
                detailReturnFocusRequest: detailReturnFocusRequest,
                isTopMenuFocused: isTopMenuFocused,
                onTopMenuFocusRequest: { focusTopMenuIfVisible() }
            )
        case .recommendations:
            RecommendationsView(
                focusRequest: contentFocusRequest,
                isTopMenuFocused: isTopMenuFocused,
                onTopMenuFocusRequest: { focusTopMenuIfVisible() }
            )
        case .libraryType(let type):
            let active = activeLibrary(for: type)
            TVLibraryTypeTabView(
                type: type,
                libraries: libraries(of: type),
                activeLibrary: active,
                selectedPill: pillSelection(for: type),
                focusRequest: contentFocusRequest,
                isTopMenuFocused: isTopMenuFocused,
                onTopMenuFocusRequest: { focusTopMenuIfVisible() }
            )
            // Re-create the tab body when the type changes so per-type
            // section fetches reset cleanly (pill selection survives in
            // pillSelections).
            .id(type)
        case .libraryShortcut(let libraryId, _):
            if let library = libraries.first(where: { $0.id == libraryId }),
               let type = tabType(for: library) {
                TVLibraryTypeTabView(
                    type: type,
                    libraries: [library],
                    activeLibrary: library,
                    selectedPill: shortcutPillSelection(for: libraryId, categoryType: type),
                    focusRequest: contentFocusRequest,
                    isTopMenuFocused: isTopMenuFocused,
                    onTopMenuFocusRequest: { focusTopMenuIfVisible() }
                )
                .id(library.id)
            } else {
                EmptyStateView(
                    icon: "square.stack.3d.up",
                    title: "Library unavailable",
                    subtitle: "This pinned library is no longer visible to the active profile."
                )
                .padding(.top, TVTopMenuLayout.contentTopInset)
            }
        case .calendar:
            CalendarView(
                focusRequest: contentFocusRequest,
                onTopMenuFocusRequest: { focusTopMenuIfVisible() }
            )
        }
    }

    @ViewBuilder
    private func personalRootContent(_ destination: TVPersonalRootDestination) -> some View {
        switch destination {
        case .watchlist:
            WatchlistView(
                showsNavigationTitle: false,
                usesTVTopMenu: true,
                focusRequest: contentFocusRequest,
                isTopMenuFocused: isTopMenuFocused,
                onTopMenuFocusRequest: { focusTopMenuIfVisible() }
            )
        case .favorites:
            FavoritesView(
                showsNavigationTitle: false,
                usesTVTopMenu: true,
                focusRequest: contentFocusRequest,
                isTopMenuFocused: isTopMenuFocused,
                onTopMenuFocusRequest: { focusTopMenuIfVisible() }
            )
        }
    }

    // MARK: - Anchored panel overlay (§5.3 / §5.8)

    /// The cascade selector or profile menu, rendered as a scrimmed overlay
    /// anchored under its bar element. This is the whole point of Skyline:
    /// scope/profile changes happen in an anchored dropdown over the page,
    /// never a full-screen takeover, and inside the single shared
    /// `NavigationStack`.
    ///
    /// The bar publishes each panel-bearing element's bounds via
    /// `TVTopMenuAnchorKey`; this overlay resolves the open panel's anchor
    /// with the geometry proxy and positions the panel under it (§5.3
    /// "centered under the tab"; §5.8 "under the avatar", right-aligned).
    @ViewBuilder
    private func panelOverlay(anchors: [TVTopMenuPanel: Anchor<CGRect>]) -> some View {
        if router.path.isEmpty {
            GeometryReader { proxy in
                // No page scrim: the menu floats over the page on its own
                // layered shadow (`TVSkylinePanelChrome`) instead of darkening
                // everything behind it. Page hit testing is still blocked
                // while the panel is visible, so nothing behind it is
                // reachable without pushing `\.isEnabled` through the page.
                ZStack(alignment: .topLeading) {
                    ForEach(persistentPanels, id: \.self) { panel in
                        anchoredPanel(panel, anchors: anchors, proxy: proxy)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
            .ignoresSafeArea()
        }
    }

    /// Panels stay mounted while the top bar is visible so hover-open/close
    /// does not insert or remove a focus subtree. tvOS was dropping bar focus
    /// every time the cascade overlay appeared, even when its rows were
    /// passive labels.
    private var persistentPanels: [TVTopMenuPanel] {
        var panels = visibleRoots.compactMap { root -> TVTopMenuPanel? in
            switch root {
            case .libraryType, .libraryShortcut, .recommendations:
                return .root(root)
            case .home, .calendar:
                return nil
            }
        }
        panels.append(.profile)
        return panels
    }

    private func panelIntrinsicWidth(for panel: TVTopMenuPanel) -> CGFloat {
        switch panel {
        case .profile, .root(.recommendations), .root(.libraryShortcut):
            return ContinuumTheme.Skyline.dropdownWidth
        case .root:
            return ContinuumTheme.Skyline.dropdownWidth
                + ContinuumTheme.Skyline.flyoutGap
                + ContinuumTheme.Skyline.flyoutWidth
        }
    }

    private func anchoredPanel(
        _ panel: TVTopMenuPanel,
        anchors: [TVTopMenuPanel: Anchor<CGRect>],
        proxy: GeometryProxy
    ) -> some View {
        let leading = panelLeadingInset(
            panel: panel,
            anchors: anchors,
            proxy: proxy
        )
        let anchorX = panelTransitionAnchorX(
            panel: panel,
            anchors: anchors,
            proxy: proxy,
            leading: leading
        )
        let isActive = openPanel == panel

        return panelBody(for: panel, isActive: isActive)
            .padding(.leading, leading)
            .padding(.top, ContinuumTheme.Skyline.dropdownTopInset)
            .opacity(isActive ? 1 : 0)
            .scaleEffect(
                reduceMotion || isActive ? 1 : ContinuumTheme.Skyline.cascadeOpenScale,
                anchor: UnitPoint(x: anchorX, y: 0)
            )
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .animation(
                reduceMotion ? nil : .easeOut(duration: ContinuumTheme.Skyline.cascadeOpenDuration),
                value: isActive
            )
            .onExitCommand { closePanel() }
    }

    /// Leading inset that places the panel under its anchor. Library
    /// cascades center their level-1 column (width 460) under the tab;
    /// the profile panel right-aligns to `safeArea.x`. Both clamp inside the
    /// safe area so nothing clips.
    private func panelLeadingInset(
        panel: TVTopMenuPanel,
        anchors: [TVTopMenuPanel: Anchor<CGRect>],
        proxy: GeometryProxy
    ) -> CGFloat {
        let safe = ContinuumTheme.Skyline.safeAreaX
        let level1Width = ContinuumTheme.Skyline.dropdownWidth
        let screenWidth = proxy.size.width

        switch panel {
        case .profile:
            // Right-aligned to safeArea.x (§5.8).
            return max(safe, screenWidth - safe - level1Width)
        case .root(.recommendations), .root(.libraryShortcut):
            guard let anchor = anchors[panel] else {
                return safe
            }
            let rect = proxy[anchor]
            let centered = rect.midX - level1Width / 2
            let maxLeading = max(safe, screenWidth - safe - panelIntrinsicWidth(for: panel))
            return min(max(centered, safe), maxLeading)
        case .root:
            guard let anchor = anchors[panel] else {
                // Anchor not published yet — fall back to the safe-area edge.
                return safe
            }
            let rect = proxy[anchor]
            let centered = rect.midX - level1Width / 2
            // The two-level cascade extends level1 + gap + flyout to the
            // right; keep the whole thing on screen while preferring to
            // center level-1 under the tab.
            let totalWidth = level1Width
                + ContinuumTheme.Skyline.flyoutGap
                + ContinuumTheme.Skyline.flyoutWidth
            let maxLeading = max(safe, screenWidth - safe - totalWidth)
            return min(max(centered, safe), maxLeading)
        }
    }

    /// Horizontal origin (0…1) for the open scale animation, so the panel
    /// scales up from under its anchor rather than from its own center.
    private func panelTransitionAnchorX(
        panel: TVTopMenuPanel,
        anchors: [TVTopMenuPanel: Anchor<CGRect>],
        proxy: GeometryProxy,
        leading: CGFloat
    ) -> CGFloat {
        guard let anchor = anchors[panel] else { return 0.5 }
        let rect = proxy[anchor]
        let level1Width = ContinuumTheme.Skyline.dropdownWidth
        let originInPanel = rect.midX - leading
        return min(max(originInPanel / level1Width, 0), 1)
    }

    @ViewBuilder
    private func panelBody(for panel: TVTopMenuPanel, isActive: Bool) -> some View {
        switch panel {
        case .root(let root):
            switch root {
            case .libraryType(let type):
                cascadePanel(for: type, isActive: isActive)
            case .libraryShortcut(let libraryId, let label):
                shortcutCascadePanel(
                    for: .libraryShortcut(libraryId: libraryId, label: label),
                    isActive: isActive
                )
            case .recommendations:
                forYouPanel(isActive: isActive)
            case .home, .calendar:
                EmptyView()
            }
        case .profile:
            profilePanel(isActive: isActive)
        }
    }

    private func cascadePanel(for type: TVLibraryTabType, isActive: Bool) -> some View {
        TVCascadeSelector(
            type: type,
            libraries: libraries(of: type),
            currentScopeId: activeLibrary(for: type)?.id,
            entersPanel: isActive && panelEntersFocus,
            focusEntryGeneration: panelFocusEntryGeneration,
            onCommitLibrary: { commitScope(type: type, library: $0, pill: nil) },
            onCommitSection: { commitScope(type: type, library: $0, pill: $1) },
            onPreviewLibrary: { prefetchLibrarySectionsIfNeeded($0) },
            onClose: { closePanel() },
            onPanelFocusChanged: { handlePanelFocusChanged($0) },
            onExitToContent: { exitPanelToContent() }
        )
    }

    @ViewBuilder
    private func shortcutCascadePanel(
        for root: TVRootDestination,
        isActive: Bool
    ) -> some View {
        if case .libraryShortcut(let libraryId, _) = root,
           let library = libraries.first(where: { $0.id == libraryId }),
           let type = tabType(for: library) {
            TVCascadeSelector(
                type: type,
                libraries: [library],
                currentScopeId: library.id,
                entersPanel: isActive && panelEntersFocus,
                focusEntryGeneration: panelFocusEntryGeneration,
                onCommitLibrary: { commitShortcut(root: root, library: $0, pill: nil) },
                onCommitSection: { commitShortcut(root: root, library: $0, pill: $1) },
                onPreviewLibrary: { prefetchLibrarySectionsIfNeeded($0) },
                onClose: { closePanel() },
                onPanelFocusChanged: { handlePanelFocusChanged($0) },
                onExitToContent: { exitPanelToContent() }
            )
        }
    }

    private func forYouPanel(isActive: Bool) -> some View {
        TVForYouDropdown(
            entersPanel: isActive && panelEntersFocus,
            focusEntryGeneration: panelFocusEntryGeneration,
            onPanelFocusChanged: { handlePanelFocusChanged($0) },
            onClose: { closePanel() },
            onExitToContent: { exitPanelToContent() },
            onWatchlist: { closePanel(then: { navigateFromBar(.watchlist) }) },
            onFavorites: { closePanel(then: { navigateFromBar(.favorites) }) },
            onRecommendations: { closePanel(then: { selectRoot(.recommendations) }) }
        )
    }

    private func profilePanel(isActive: Bool) -> some View {
        TVProfileDropdown(
            profileName: currentProfile?.name ?? "Profile",
            avatar: currentProfile?.avatarEmoji,
            avatarImageUrl: currentProfile?.avatarImageUrl,
            serverHost: ServerRegistry.shared.activeServer?.displayName,
            entersPanel: isActive && panelEntersFocus,
            focusEntryGeneration: panelFocusEntryGeneration,
            onPanelFocusChanged: { handlePanelFocusChanged($0) },
            onSwitchProfile: { closePanel(then: switchProfile) },
            onWatchlist: { closePanel(then: { navigateFromBar(.watchlist) }) },
            onFavorites: { closePanel(then: { navigateFromBar(.favorites) }) },
            onHistory: { closePanel(then: { navigateFromBar(.history) }) },
            onRequests: { closePanel(then: { navigateFromBar(.requestsHub) }) },
            onSettings: { closePanel(then: { navigateFromBar(.settings) }) },
            onSwitchServer: { closePanel(then: { showServerPicker = true }) },
            onSignOut: { closePanel(then: { showSignOutConfirm = true }) }
        )
    }

    private func dismissSignOutConfirmation() {
        showSignOutConfirm = false
        Task { @MainActor in
            await Task.yield()
            focusTopMenuIfVisible(focusing: .profile)
        }
    }

    // MARK: - Panel control (§5.3 / §5.8)

    /// Open (or switch) the anchored panel as a passive preview after dwell.
    /// Focus intentionally stays on the bar element so left/right navigation
    /// can continue across library tabs. D-pad-down or profile press uses
    /// `openPanelAndEnter` to move focus into the rows.
    private func handleDwell(_ panel: TVTopMenuPanel?) {
        guard let panel else {
            closePanel()
            return
        }
        openPanelPreview(panel)
    }

    /// Open (or switch to) an anchored panel as a passive preview: it fades
    /// in below the bar but focus stays on the tab/avatar. This is the dwell
    /// (focus-rest) path — opening on a *settled* focus, with no in-flight
    /// move command, is what lets the tab keep its focus ring without a focus
    /// escape. D-pad-down instead uses `openPanelAndEnter`, which claims a
    /// panel row so the move has a destination.
    private func openPanelPreview(_ panel: TVTopMenuPanel) {
        guard panel != openPanel else { return }

        panelFocusExitTask?.cancel()
        panelFocusExitTask = nil
        panelEntersFocus = false
        panelHasFocus = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: ContinuumTheme.Skyline.cascadeScrimDuration)) {
            openPanel = panel
        }
    }

    /// A deliberate **press** on the avatar (§5.8) opens the profile menu
    /// and moves focus straight into it.
    private func openProfilePanelImmediately() {
        if openPanel != .profile {
            openPanelAndEnter(.profile)
            return
        }
        enterOpenPanel()
    }

    /// Manually refresh panel row focus, used when d-pad-down arrives while
    /// the matching panel is already open.
    private func enterOpenPanel() {
        guard openPanel != nil else { return }
        panelFocusExitTask?.cancel()
        panelFocusExitTask = nil
        panelEntersFocus = true
        panelHasFocus = true
        panelFocusEntryGeneration += 1
    }

    /// Route a d-pad-down on a panel-bearing bar element (§5.3): open its
    /// panel if it isn't already, then move focus into it. The bar no longer
    /// toggles the down handler on `openPanel`, so this can't run while the
    /// focused tab is being rebuilt.
    private func enterPanelFor(_ panel: TVTopMenuPanel) {
        // A d-pad-down is a focus *move* — the engine must send focus
        // somewhere. So down opens the panel (if a dwell hasn't already) AND
        // hands focus into a row in one motion: claiming a panel row via
        // @FocusState gives the move a destination, which stops focus from
        // escaping down into the page content behind it (which is still Home
        // — focusing a tab doesn't switch the page). The bar's
        // `!panelHasFocus` release-guard keeps the tab's focus from emptying
        // out mid-handoff, so this lands cleanly with no Home flash.
        if openPanel != panel {
            openPanelAndEnter(panel)
            return
        }
        enterOpenPanel()
    }

    /// Open an anchored panel and hand focus into it in the same state
    /// transition. This is reserved for explicit entry gestures, not dwell,
    /// so hover-open menus never trap horizontal tab navigation.
    private func openPanelAndEnter(_ panel: TVTopMenuPanel) {
        panelFocusExitTask?.cancel()
        panelFocusExitTask = nil
        panelEntersFocus = true
        panelHasFocus = true
        panelFocusEntryGeneration += 1
        withAnimation(reduceMotion ? nil : .easeOut(duration: ContinuumTheme.Skyline.cascadeScrimDuration)) {
            openPanel = panel
        }
    }

    /// Close the panel without changing scope (Menu/Back, scrim tap, or
    /// focus leaving the bar), optionally running a follow-up action (a
    /// profile-row selection navigates after the panel tears down).
    private func closePanel(then action: (() -> Void)? = nil) {
        guard let panel = openPanel else {
            action?()
            return
        }
        panelFocusExitTask?.cancel()
        panelFocusExitTask = nil
        let wasFocused = panelHasFocus
        withAnimation(reduceMotion ? nil : .easeOut(duration: ContinuumTheme.Skyline.cascadeScrimDuration)) {
            openPanel = nil
        }
        panelEntersFocus = false
        panelHasFocus = false

        // Returning focus to *that panel's* tab/avatar (§7) keeps the remote
        // from stranding. Do it whether or not a follow-up action runs:
        // route-pushing actions tear the bar down (the request is a no-op),
        // but `Switch Server` opens a confirmation dialog and leaves the bar
        // on screen — without re-arming, focus would be lost after dismiss.
        // Re-arm before the action so a route push still wins the focus.
        if wasFocused {
            focusTopMenuIfVisible(focusing: panel)
        }
        action?()
    }

    /// If d-pad down escapes past the last row in an open dropdown, tvOS may
    /// move focus into the page content behind it. That is a valid focus
    /// destination, but the floating menu should leave with the panel focus.
    private func handlePanelFocusChanged(_ hasFocus: Bool) {
        panelFocusExitTask?.cancel()
        panelFocusExitTask = nil

        if hasFocus {
            panelHasFocus = true
            return
        }

        let hadPanelFocus = panelHasFocus
        panelHasFocus = false

        guard hadPanelFocus, openPanel != nil, panelEntersFocus else { return }

        panelFocusExitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.panelFocusExitCloseDelayNanoseconds)
            guard !Task.isCancelled else { return }
            guard openPanel != nil, panelEntersFocus, !panelHasFocus, !isTopMenuFocused else { return }
            closePanelForContentHandoff()
        }
    }

    private func closePanelForContentHandoff() {
        guard openPanel != nil else { return }
        panelFocusExitTask?.cancel()
        panelFocusExitTask = nil
        withAnimation(reduceMotion ? nil : .easeOut(duration: ContinuumTheme.Skyline.cascadeScrimDuration)) {
            openPanel = nil
        }
        panelEntersFocus = false
        panelHasFocus = false
        suppressTopMenuFocusForContentHandoff()
    }

    /// D-pad down past the last cascade row leaves the menu for the page
    /// content (§5.3). Tear the panel down, relinquish the bar's focus, and
    /// actively push focus into the swapped-in content — the same hand-down
    /// `selectRoot` uses, so a later Up press returns to the bar normally.
    /// Without the explicit `contentFocusRequest` bump the remote would strand:
    /// the panel closes but nothing claims focus.
    private func exitPanelToContent() {
        closePanelForContentHandoff()
        contentFocusRequest += 1
    }

    private func prefetchLibrarySectionsIfNeeded(_ library: Library) {
        if TVLibraryTabType.series.matches(library) {
            // This joins the same single-flight section request as the panel
            // preview, then primes one Series hero. Repeated focus visits are
            // cache-only and never fan out across the whole rail.
            StartupContentPrefetcher.prefetchTVSeriesLanding(libraryId: library.id)
            return
        }
        let cached: SectionsResponse? = ResponseCache.shared.get(
            CacheKey.librarySections(library.id)
        )
        guard cached == nil else { return }
        StartupContentPrefetcher.prefetchLibrarySections(libraryId: library.id)
    }

    /// Commit a cascade selection (§5.3, §F): set + persist the tab scope,
    /// preselect the pill (Recommended for a library-row press; the chosen
    /// section for a flyout-row press), select the tab, and tear the panel
    /// down. The page swaps in place via the scope/pill change + the
    /// existing `.id(activeLibrary.id)` crossfade.
    private func commitScope(type: TVLibraryTabType, library: Library, pill: TVLibraryPill?) {
        panelFocusExitTask?.cancel()
        panelFocusExitTask = nil
        scopeSelections[type] = library.id
        TVLibraryScopeStore.shared.setSelectedLibraryId(library.id, for: type)
        pillSelections[type] = pill ?? .recommended

        // Tear down the panel first, then select the tab + hand focus to the
        // swapped-in content. Selecting the root bumps contentFocusRequest,
        // which the new page consumes as its entry generation.
        withAnimation(reduceMotion ? nil : .easeOut(duration: ContinuumTheme.Skyline.cascadeScrimDuration)) {
            openPanel = nil
        }
        panelEntersFocus = false
        panelHasFocus = false
        selectRoot(.libraryType(type))
    }

    private func commitShortcut(
        root: TVRootDestination,
        library: Library,
        pill: TVLibraryPill?
    ) {
        guard case .libraryShortcut(let libraryId, _) = root,
              library.id == libraryId else { return }
        panelFocusExitTask?.cancel()
        panelFocusExitTask = nil
        shortcutPillSelections[libraryId] = pill ?? .recommended

        withAnimation(reduceMotion ? nil : .easeOut(duration: ContinuumTheme.Skyline.cascadeScrimDuration)) {
            openPanel = nil
        }
        panelEntersFocus = false
        panelHasFocus = false
        selectRoot(root)
    }

    // MARK: - Tab derivation

    /// Contract-ordered roots for this TV family. Search and Profile remain
    /// fixed outside this list, which keeps their focus anchors stable while
    /// the user rearranges content tabs.
    private var visibleRoots: [TVRootDestination] {
        var roots: [TVRootDestination] = []
        for item in uiCustomization.resolvedPrimaryMenuItems(availableLibraries: libraries) {
            let root: TVRootDestination?
            switch item {
            case .builtin(.home): root = .home
            case .builtin(.movies): root = availableRoot(for: .movies)
            case .builtin(.series): root = availableRoot(for: .series)
            case .builtin(.music): root = availableRoot(for: .music)
            case .builtin(.audiobooks):
                root = navPrefs.showAudiobooks ? availableRoot(for: .audiobooks) : nil
            case .builtin(.forYou): root = .recommendations
            case .builtin(.calendar): root = .calendar
            case .library(let libraryId, let label):
                root = libraries.contains(where: {
                    $0.id == libraryId && (navPrefs.showAudiobooks || !$0.isAudiobookLibrary)
                })
                    ? .libraryShortcut(libraryId: libraryId, label: label)
                    : nil
            case .section, .collection:
                // The contract can carry these for web and future clients.
                // Apple TV currently has a stable root route only for whole
                // libraries, so unsupported shortcuts stay stored but hidden.
                root = nil
            }
            if let root, !roots.contains(root) { roots.append(root) }
        }
        if !roots.contains(.home) { roots.insert(.home, at: 0) }
        return roots
    }

    private func availableRoot(for type: TVLibraryTabType) -> TVRootDestination? {
        libraries.contains(where: { type.matches($0) }) ? .libraryType(type) : nil
    }

    private func tabType(for library: Library) -> TVLibraryTabType? {
        TVLibraryTabType.allCases.first(where: { $0.matches(library) })
    }

    private func libraries(of type: TVLibraryTabType) -> [Library] {
        libraries
            .filter { type.matches($0) }
            .sorted {
                ($0.sortOrder ?? Int.max, $0.id) < ($1.sortOrder ?? Int.max, $1.id)
            }
    }

    /// The library a type tab is currently scoped to (§3.1): the in-session
    /// selection if it still exists, else the persisted choice, else the
    /// first library by sort order (cold start). Returns `nil` only when the
    /// type has no visible libraries.
    private func activeLibrary(for type: TVLibraryTabType) -> Library? {
        let available = libraries(of: type)
        if let selectedId = scopeSelections[type],
           let match = available.first(where: { $0.id == selectedId }) {
            return match
        }
        return TVLibraryScopeStore.shared.resolvedLibrary(for: type, in: available)
    }

    private func pillSelection(for type: TVLibraryTabType) -> Binding<TVLibraryPill> {
        Binding(
            get: {
                resolvedLibraryRootPill(
                    categorySelection: pillSelections[type] ?? .recommended,
                    directSelection: nil,
                    isDirectLibraryShortcut: false
                )
            },
            set: { pillSelections[type] = $0 }
        )
    }

    private func shortcutPillSelection(
        for libraryId: Int,
        categoryType: TVLibraryTabType
    ) -> Binding<TVLibraryPill> {
        Binding(
            get: {
                resolvedLibraryRootPill(
                    categorySelection: pillSelections[categoryType] ?? .recommended,
                    directSelection: shortcutPillSelections[libraryId],
                    isDirectLibraryShortcut: true
                )
            },
            set: { shortcutPillSelections[libraryId] = $0 }
        )
    }

    private var currentLibraryAuthority: MainTabLibraryAuthority? {
        MainTabLibraryAuthority(
            serverId: registry.activeServerId,
            profileId: registry.activeProfileId
        )
    }

    private func loadLibraries(for authority: MainTabLibraryAuthority?) async {
        if loadedLibraryAuthority != authority {
            loadedLibraryAuthority = authority
            libraries = []
            scopeSelections = [:]
            pillSelections = [:]
            shortcutPillSelections = [:]
            ensureSelectedRootIsVisible()
        }
        guard let authority else { return }

        if libraries.isEmpty,
           let cached: LibrariesResponse = ResponseCache.shared.get(CacheKey.userLibraries) {
            libraries = cached.libraries
            ensureSelectedRootIsVisible()
            prefetchActiveSeriesLanding()
        }

        do {
            let response = try await StartupContentPrefetcher.fetchUserLibraries()
            guard !Task.isCancelled, currentLibraryAuthority == authority else { return }
            loadedLibraryAuthority = authority
            libraries = response.libraries
            shortcutPillSelections = shortcutPillSelections.filter { libraryId, _ in
                response.libraries.contains { $0.id == libraryId }
            }
            ensureSelectedRootIsVisible()
            prefetchActiveSeriesLanding()
        } catch {
            // Keep whatever tabs we already have (cached or none) — Home
            // and Calendar always stay reachable, so a transient failure
            // never strands the user.
        }
    }

    /// Backstop the launch prefetch with the shell's authoritative in-session
    /// scope. This covers a changed Series-library selection without making
    /// any other tab wait for the warmup.
    private func prefetchActiveSeriesLanding() {
        guard let library = activeLibrary(for: .series) else { return }
        StartupContentPrefetcher.prefetchTVSeriesLanding(libraryId: library.id)
    }

    /// The selected root can stop being visible — a library refresh removes
    /// its type (e.g. profile permissions changed), or the user hides its tab
    /// from Settings. Snap back to Home rather than leaving a tab-less content
    /// view on screen. Home is always injected into `visibleRoots`, so this
    /// never strands the user.
    private func ensureSelectedRootIsVisible(requestContentFocus: Bool = true) {
        if !visibleRoots.contains(selectedRoot) {
            selectedRoot = .home
            if requestContentFocus {
                contentFocusRequest += 1
            }
        }
    }

    /// A synced menu edit can remove the bar button that currently owns focus
    /// even when the selected page remains visible. Capture the owner before
    /// closing any panel, then explicitly re-arm that same focus zone after the
    /// graph changes so tvOS never has to repair from an ownerless state.
    private func reconcileVisibleRootsChange() {
        let menuOwnedFocus = !isTopMenuFocusSuppressed || panelEntersFocus
        let isShowingRoot = router.path.isEmpty
        let selectedRootWasRemoved = !visibleRoots.contains(selectedRoot)
        let focusRearm = tvVisibleRootsFocusRearm(
            menuOwnedFocus: menuOwnedFocus,
            isShowingRoot: isShowingRoot,
            selectedRootWasRemoved: selectedRootWasRemoved
        )

        closePanel()
        ensureSelectedRootIsVisible(requestContentFocus: false)

        switch focusRearm {
        case .none:
            break
        case .topMenu:
            focusTopMenuIfVisible()
        case .content:
            suppressTopMenuFocusForContentHandoff()
            contentFocusRequest += 1
        }
    }

    // MARK: - Root selection & focus

    private func selectRoot(_ root: TVRootDestination) {
        let isReselect = root == selectedRoot
        router.popToRoot()

        suppressTopMenuFocusForContentHandoff()
        // Selecting a root closes any open dropdown. Pressing a library tab
        // while its cascade preview is open should navigate to that library
        // *and* dismiss the panel: leaving `openPanel` set orphans the dropdown
        // on screen over the new page, and page hit testing remains blocked
        // while a panel is open, so the content focus hand-off below lands on
        // nothing, stranding the remote. Clearing it here is the single fix
        // for both.
        // Tab content switches crossfade over 200 ms (§4.2); the outgoing
        // view never owns focus here because selection happens from the bar.
        // Reduce Motion snaps (the `.identity` transition + nil animation).
        withAnimation(reduceMotion ? nil : .easeInOut(duration: ContinuumTheme.normalDuration)) {
            selectedRoot = root
            personalRoot = nil
            openPanel = nil
        }
        panelEntersFocus = false
        panelHasFocus = false
        // Push focus into whichever root content is swapping in. Suppressing
        // the menu relinquishes its focus (TVTopMenuBar.onChange(isFocusSuppressed)),
        // so without an active hand-down the new content never claims focus and
        // the remote goes dead until the user blindly swipes.
        if isReselect {
            // Re-selecting the current tab keeps the content view alive (same
            // `.id`), so a synchronous bump lands the row's focus claim in the
            // same transaction as the bar's disable + focus teardown — and the
            // engine's repair from the resigning tab button wins, leaving focus
            // stranded in the menu. Defer one turn so the first card's claim is
            // applied after the bar has fully resigned; a fresh tab doesn't need
            // this because its content mounts a render later and claims in
            // onAppear anyway.
            DispatchQueue.main.async {
                contentFocusRequest += 1
            }
        } else {
            contentFocusRequest += 1
        }
    }

    /// Re-arm the top bar's focus. `focusing` overrides which element the
    /// bar lands on (used by panel-close to return to the panel's anchor,
    /// §7); the default `nil` falls back to the selected tab. Always written
    /// so a prior override can't leak into a later content-exit call.
    private func focusTopMenuIfVisible(focusing target: TVTopMenuPanel? = nil) {
        // The custom top menu only exists on root pages. Pushed detail,
        // player, and settings routes should keep normal navigation-stack
        // back behavior instead of being intercepted by the root shell.
        guard router.path.isEmpty else { return }

        panelReturnFocus = target
        // Claim ownership before the bar's @FocusState lands so content
        // hand-down tokens cannot briefly re-focus rows during an Up return.
        isTopMenuFocused = true

        withAnimation(reduceMotion ? nil : ContinuumTheme.springAnimation) {
            isTopMenuFocusSuppressed = false
        }
        // Let the bar's enabled state commit before asking its @FocusState to
        // claim the selected tab. A swipe-up move can arrive in the same
        // transaction that unsuppresses the bar; writing both together made
        // tvOS occasionally reject the claim, forcing another swipe or Back.
        DispatchQueue.main.async {
            guard router.path.isEmpty,
                  isTopMenuFocused,
                  !isTopMenuFocusSuppressed else { return }
            topMenuFocusRequest += 1
        }
    }

    private func returnToHomeInMenu() {
        selectedRoot = .home
        panelReturnFocus = nil
        withAnimation(reduceMotion ? nil : ContinuumTheme.springAnimation) {
            // Un-suppress before requesting focus: requestMenuFocus drops the
            // request while the menu is suppressed, which could leave the
            // Home button unfocused after the exit-to-home gesture.
            isTopMenuFocusSuppressed = false
            topMenuFocusRequest += 1
        }
    }

    private func returnFromPersonalRootInMenu() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: ContinuumTheme.normalDuration)) {
            personalRoot = nil
        }
    }

    private func suppressTopMenuFocusForContentHandoff() {
        isTopMenuFocused = false
        isTopMenuFocusSuppressed = true
    }

    /// Push a route on behalf of a bar element (search button, profile /
    /// For You panel rows). Marks the stack so popping back to root hands
    /// focus to the bar instead of letting the engine free-resolve into
    /// the row band.
    private func navigateFromBar(_ route: Route) {
        switch route {
        case .watchlist:
            showPersonalRoot(.watchlist)
            return
        case .favorites:
            showPersonalRoot(.favorites)
            return
        default:
            break
        }

        barOwnsFocusOnPopToRoot = true
        router.navigate(to: route)
    }

    private func showPersonalRoot(_ destination: TVPersonalRootDestination) {
        router.popToRoot()
        barOwnsFocusOnPopToRoot = false
        suppressTopMenuFocusForContentHandoff()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: ContinuumTheme.normalDuration)) {
            personalRoot = destination
            openPanel = nil
        }
        panelEntersFocus = false
        panelHasFocus = false
        DispatchQueue.main.async {
            contentFocusRequest += 1
        }
    }

    private func switchProfile() {
        router.switchProfile()
    }

    private func loadCurrentProfile() async {
        guard let profileId = AuthService.shared.profileId else {
            currentProfile = nil
            return
        }

        // Paint the avatar from the startup prefetch immediately; the fetch
        // below reconciles (and joins the prefetch's request when it is
        // still in flight rather than issuing a second one).
        if currentProfile == nil,
           let cached: [UserProfile] = ResponseCache.shared.get(CacheKey.profiles) {
            currentProfile = cached.first(where: { $0.id == profileId })
        }

        do {
            let profiles = try await StartupContentPrefetcher.fetchProfiles()
            currentProfile = profiles.first(where: { $0.id == profileId })
        } catch {
            // Keep the cached avatar on a transient failure; it already
            // matches the active profile id.
        }
    }

    private func serverButtonLabel(_ entry: ServerEntry) -> String {
        entry.id == registry.activeServerId
            ? "\(entry.displayName) (Current)"
            : entry.displayName
    }

    /// Switch to the selected server and snap the auth state machine to
    /// the right screen (login / profile select / home) based on what's
    /// remembered for that server.
    private func switchToServer(_ entry: ServerEntry) {
        guard entry.id != registry.activeServerId else { return }
        Task {
            guard await registry.switchTo(
                serverId: entry.id,
                resolveDestinationProfile: true
            ) else { return }
            await MainActor.run {
                selectedRoot = .home
                personalRoot = nil
                currentProfile = nil
                libraries = []
                loadedLibraryAuthority = nil
                ResponseCache.shared.remove(CacheKey.userLibraries)
                pillSelections = [:]
                shortcutPillSelections = [:]
                // Re-read tab-visibility prefs under the new server+profile
                // key: this path switches in place without rebuilding the
                // shell, so `.task` (the only other caller of refresh) won't
                // re-run and the cached mirror would otherwise stay stale.
                navPrefs.refresh()
                refreshAuthState()
            }
            if AuthService.shared.hasProfile {
                async let profileTask: Void = loadCurrentProfile()
                async let librariesTask: Void = loadLibraries(for: currentLibraryAuthority)
                _ = await (profileTask, librariesTask)
            }
        }
    }

    private func refreshAuthState() {
        router.popToRoot()
        // A server switch can land back on `.authenticated`, which the
        // router's same-value guard drops — so the identity boundary for an
        // engaged PiP video is enforced here, before the reassignment.
        PlayerIdentityBoundary.endEngagedVideoPictureInPicture()
        let auth = AuthService.shared
        if !auth.hasServer {
            router.authState = .needsServerSetup
        } else if !auth.isLoggedIn {
            router.authState = .needsLogin
        } else if !auth.hasProfile {
            router.authState = .needsProfile
        } else {
            router.authState = .authenticated
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
        case .itemDetail(let contentId, let tvSeed):
            ItemDetailView(contentId: contentId, tvSeed: tvSeed)
        case .personDetail(let personId):
            PersonDetailView(personId: personId)
        case .player(let contentId, let startFromBeginning, let resumePosition):
            PlayerView(
                contentId: contentId,
                startFromBeginning: startFromBeginning,
                resumePositionOverride: resumePosition
            )
        case .playerWithFile(let contentId, let fileId, let audioTrackIndex, let subtitleTrackIndex, let startFromBeginning, let resumePosition):
            PlayerView(
                contentId: contentId,
                preferredFileId: fileId,
                preferredAudioTrackIndex: audioTrackIndex,
                preferredSubtitleTrackIndex: subtitleTrackIndex,
                startFromBeginning: startFromBeginning,
                resumePositionOverride: resumePosition
            )
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
        case .search:
            SearchView(usesTVTopMenuInset: false)
        case .settings:
            TVSettingsView()
        case .recommendations:
            RecommendationsView()
        case .serverList:
            ServerListView()
        case .serverSetup:
            // Pushed from the profile menu's "Add Server…" button — staying
            // on the nav stack means the tvOS back button returns to the
            // previous active server instead of dropping the authenticated
            // tree entirely. Successful `connect()` flips authState to
            // `.needsLogin` and replaces this view tree.
            TVServerSetupView(router: router)
        case .tvLibraryGrid(let libraryId, let libraryName, let libraryType, let payload, let subtitle):
            TVLibraryGridView(
                libraryId: libraryId,
                libraryName: libraryName,
                libraryType: libraryType,
                initialFilter: payload.toFilterState(),
                subtitle: subtitle
            )
        default:
            EmptyStateView(icon: "questionmark.circle", title: "Unknown", subtitle: nil)
                .continuumBackground()
        }
    }
}

#endif
