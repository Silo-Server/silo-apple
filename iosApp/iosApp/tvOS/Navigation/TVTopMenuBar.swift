#if os(tvOS)
import SwiftUI
import UIKit
import os

enum TVTopMenuLayout {
    /// Vertical clearance needed when a root tvOS page does not render a
    /// full-bleed hero behind the custom top menu.
    static let contentTopInset: CGFloat = 188
}

/// Publishes the on-screen bounds of each panel-bearing bar element so the
/// shell can anchor the cascade / profile panel under it (§5.3 "centered
/// under the tab", §5.8 "under the avatar"). One `Anchor` per element; the
/// shell resolves the open panel's anchor in its own coordinate space.
struct TVTopMenuAnchorKey: PreferenceKey {
    static let defaultValue: [TVTopMenuPanel: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [TVTopMenuPanel: Anchor<CGRect>],
        nextValue: () -> [TVTopMenuPanel: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// A library content type that can surface as a root tab (Skyline §3.1).
/// Tabs represent types, not server libraries — a type's tab appears only
/// if the profile can see at least one library of that type.
enum TVLibraryTabType: String, CaseIterable, Hashable {
    case movies
    case series
    case music
    case audiobooks

    var title: String {
        switch self {
        case .movies: return "Movies"
        case .series: return "Series"
        case .music: return "Music"
        case .audiobooks: return "Audiobooks"
        }
    }

    /// SF Symbol for a library row of this type in the cascade level-1
    /// panel (§5.3). Per-library art isn't fetched there — the icon is a
    /// quiet type cue, mirroring the empty-state glyphs elsewhere.
    var systemImage: String {
        switch self {
        case .movies: return "film.stack"
        case .series: return "tv"
        case .music: return "music.note"
        case .audiobooks: return "book.closed"
        }
    }

    /// Mono section header for the cascade level-1 panel (§5.3), e.g.
    /// `MOVIE LIBRARIES`.
    var librariesHeader: String {
        switch self {
        case .movies: return "MOVIE LIBRARIES"
        case .series: return "SERIES LIBRARIES"
        case .music: return "MUSIC LIBRARIES"
        case .audiobooks: return "AUDIOBOOK LIBRARIES"
        }
    }

    /// Whether a server library belongs under this tab. A mixed library
    /// (movies + series in one folder) belongs to both video tabs — it stays
    /// one browsable library, reachable from either dropdown.
    func matches(_ library: Library) -> Bool {
        switch self {
        case .movies: return library.type == "movies" || library.isMixedLibrary
        case .series: return library.isSeriesLibrary || library.isMixedLibrary
        case .music: return library.type == "music"
        case .audiobooks: return library.isAudiobookLibrary
        }
    }
}

enum TVRootDestination: Hashable {
    case home
    case recommendations
    case libraryType(TVLibraryTabType)
    case libraryShortcut(libraryId: Int, label: String)
    case calendar

    static func == (lhs: TVRootDestination, rhs: TVRootDestination) -> Bool {
        switch (lhs, rhs) {
        case (.home, .home), (.recommendations, .recommendations), (.calendar, .calendar):
            return true
        case (.libraryType(let lhsType), .libraryType(let rhsType)):
            return lhsType == rhsType
        case (.libraryShortcut(let lhsId, _), .libraryShortcut(let rhsId, _)):
            return lhsId == rhsId
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .home:
            hasher.combine(0)
        case .recommendations:
            hasher.combine(1)
        case .libraryType(let type):
            hasher.combine(2)
            hasher.combine(type)
        case .libraryShortcut(let libraryId, _):
            hasher.combine(3)
            hasher.combine(libraryId)
        case .calendar:
            hasher.combine(4)
        }
    }

    var title: String {
        switch self {
        case .home: return "Home"
        case .recommendations: return "For You"
        case .libraryType(let type): return type.title
        case .libraryShortcut(_, let label): return label
        case .calendar: return "Calendar"
        }
    }
}

/// Skyline top bar: wordmark left, search + type-derived tabs centered
/// (search sits just left of Home; the tabs stay screen-centered), profile
/// avatar right (§5.1). The bar is custom on purpose — the system
/// `TabView` sidebar steals leftward focus — and draws no background band;
/// it floats over each page's own scrim and dims to 70% while focus is
/// down in the content zone.
struct TVTopMenuBar: View {
    let roots: [TVRootDestination]
    let selectedRoot: TVRootDestination
    let currentProfile: UserProfile?
    @Binding var isMenuFocused: Bool
    let isFocusSuppressed: Bool
    let focusRequest: Int
    /// Bar element to focus on the next `focusRequest` bump, overriding the
    /// default of the selected tab. The shell sets this so Menu-ing out of a
    /// panel returns focus to the *panel's* tab/avatar (§7), not whatever
    /// root happens to be selected.
    var focusRequestTarget: TVTopMenuPanel? = nil
    /// Which bar element currently has an anchored panel open (the host
    /// owns the panel; the bar only drives the dwell + hand-off). When set
    /// to the focused element, its capsule drops from inverted to
    /// `chrome.selected` once focus descends into the panel.
    let openPanel: TVTopMenuPanel?
    /// True once focus has descended from the bar into the open panel —
    /// the tab/avatar then reads as selected, not focused (§5.1).
    let panelHasFocus: Bool
    /// True while the panel is in focus-owning (entered) mode, as opposed to a
    /// passive dwell preview. Unlike `panelHasFocus` — which flips false for a
    /// frame whenever the panel's row focus is momentarily perturbed and lags
    /// behind the engine by a render pass — this is set once when the host
    /// hands focus in and stays true until the panel closes. The bar uses it
    /// to stay passive: in entered mode a `focusedItem` drop to nil means the
    /// panel claimed focus, so the bar must NOT re-pin to the tab. Re-pinning
    /// there starts a tug-of-war with the panel's own `@FocusState` (the entry
    /// oscillation that made d-pad navigation into the flyout flaky).
    let panelEntersFocus: Bool
    let onSelectRoot: (TVRootDestination) -> Void
    let onSearch: () -> Void
    /// A bar element rested under focus for the dwell interval, or focus
    /// left every dwellable element (`nil` → close any open panel). §5.3.
    let onDwell: (TVTopMenuPanel?) -> Void
    /// D-pad down on a panel-bearing element (library tab or avatar): the
    /// host opens its panel if needed and hands focus in (§5.3). Takes the
    /// element so the host routes to the right panel.
    let onEnterPanel: (TVTopMenuPanel) -> Void
    /// Press on the profile avatar opens the profile panel and enters it
    /// immediately; dwell only previews it.
    let onProfilePressed: () -> Void
    /// Focus left the bar through normal focus movement into page content.
    /// The shell uses this to disable the bar again so later content-row
    /// Up presses can't geometrically jump back to the menu.
    let onContentFocusHandoff: () -> Void
    var onExit: (() -> Void)? = nil

    @FocusState private var focusedItem: TVTopMenuFocus?
    /// Dwell timer keyed on the focused element; cancelled on every focus
    /// move so bar sweeps never open a panel (§5.3, Open-Q5/Q7).
    @State private var dwellTask: Task<Void, Never>?
    /// The last bar element focus actually settled on. Used to restore focus
    /// when opening/closing the dropdown overlay transiently drops it.
    @State private var lastBarFocus: TVTopMenuFocus?
    /// Set when a sideways move closes the open panel: the overlay removal
    /// perturbs focus, so the next nil-drop is spurious and must be re-pinned.
    @State private var refocusAfterClose = false
    /// The element whose panel the user just explicitly closed (Menu/Back).
    /// Focus returns to it, but the dwell timer must NOT auto-reopen the panel
    /// they just dismissed — that's the "closes then immediately reopens"
    /// awkwardness. Cleared the instant focus moves to a *different* element,
    /// so resting here again later still opens it normally.
    @State private var dwellSuppressedElement: TVTopMenuFocus?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "TVFocus"
    )

    var body: some View {
        ZStack(alignment: .top) {
            tabCluster

            HStack(spacing: 0) {
                wordmark

                Spacer(minLength: ContinuumTheme.Skyline.tabSpacing)

                trailingCluster
            }
        }
        .frame(height: ContinuumTheme.Skyline.barHeight)
        .padding(.horizontal, ContinuumTheme.Skyline.safeAreaX)
        .padding(.top, ContinuumTheme.Skyline.barTopInset)
        .frame(maxWidth: .infinity, alignment: .top)
        .ignoresSafeArea(edges: [.top, .horizontal])
        // The bar dims only while focus is down in the content zone (§5.1).
        // An open panel keeps it fully lit — focus has merely descended into
        // the dropdown, and dimming the bar there greys out the panel's own
        // anchor tab and reads as a heavy "everything went dark" state.
        .opacity(isMenuFocused || openPanel != nil ? 1.0 : ContinuumTheme.Skyline.barDimmedOpacity)
        // Reduce Motion snaps the bar dim/restore as focus enters/leaves
        // the content zone (§5.1; §4.2 acceptance: no drift animations).
        .animation(reduceMotion ? nil : .easeInOut(duration: ContinuumTheme.normalDuration), value: isMenuFocused)
        .focusSection()
        .disabled(isFocusSuppressed || panelEntersFocus)
        // Menu handling must not be conditionally wrapped around the focused
        // tab buttons. Toggling an `onExitCommand` ancestor when `openPanel`
        // changes invalidates tvOS focus and produces the preview-open flash.
        .background(
            TVTopMenuExitPressCatcher(
                isActive: shouldCaptureExitPress,
                onExit: handleExitPress
            )
            .frame(width: 0, height: 0)
        )
        .onChange(of: isFocusSuppressed) { _, newValue in
            if newValue {
                focusedItem = nil
                // Focus left the bar for content; a later return to any tab
                // should dwell-open normally, so drop any close-suppression.
                dwellSuppressedElement = nil
            }
        }
        .onChange(of: focusRequest) { _, _ in
            let target = focusRequestTarget.map { String(describing: $0) } ?? "nil"
            Self.logger.debug("topMenu.focusRequest request=\(focusRequest, privacy: .public) suppressed=\(isFocusSuppressed, privacy: .public) target=\(target, privacy: .public)")
            requestMenuFocus()
        }
        .onChange(of: isMenuFocused) { _, newValue in
            // Don't release the bar's own focus when the *panel* is what's
            // taking it (panelHasFocus): the panel claims focus through its
            // own @FocusState and the system clears ours. Nulling here first
            // leaves a frame with nothing focused, which tvOS repairs to the
            // Home tab — the flash / focus reset. Content hand-off still nulls
            // via the isFocusSuppressed handler above.
            if !newValue && !panelHasFocus {
                focusedItem = nil
            }
        }
        .onChange(of: panelHasFocus) { _, newValue in
            isMenuFocused = focusedItem != nil && !newValue
        }
        .onChange(of: focusedItem) { _, newValue in
            let item = newValue.map { String(describing: $0) } ?? "nil"
            Self.logger.debug("topMenu.focus item=\(item, privacy: .public) panelHasFocus=\(panelHasFocus, privacy: .public) panelEntersFocus=\(panelEntersFocus, privacy: .public)")
            if let newValue {
                lastBarFocus = newValue
                refocusAfterClose = false
                isMenuFocused = !panelHasFocus
                scheduleDwell(for: newValue)
                return
            }
            // Focus dropped to nil while the panel is in entered (focus-owning)
            // mode: the panel claimed focus through its own @FocusState, so the
            // bar must stay passive. Re-pinning to the tab here fights the panel
            // for focus — and because `panelHasFocus` lags a render pass and a
            // stale `refocusAfterClose` can still be set from earlier bar
            // navigation, the re-pin fires exactly when it shouldn't, producing
            // the entry oscillation (focus yo-yos tab↔row until the flags
            // converge, dropping any d-pad press made in between). The host
            // closes the panel on a genuine exit via `onPanelFocusChanged`, so
            // nothing is stranded by staying out of it.
            if panelEntersFocus {
                isMenuFocused = false
                dwellTask?.cancel()
                return
            }
            // Opening OR closing the dropdown overlay perturbs the focus graph
            // and makes tvOS drop the bar's @FocusState, repairing to the Home
            // tab (the flash). When that's why we lost focus — a preview panel
            // is open, or a sideways move just closed one — re-pin to the tab
            // the user is actually on in the same transaction. Deferring this by
            // one main-queue turn leaves a visible frame where tvOS repairs
            // focus back to Home. A legit leave (down into the page, Menu out)
            // has neither flag, so it falls through and focus is allowed to go.
            let spuriousFromOpenPreview = openPanel != nil && !panelHasFocus
            if (spuriousFromOpenPreview || refocusAfterClose), let target = lastBarFocus {
                refocusAfterClose = false
                focusedItem = target
                return
            }
            isMenuFocused = false
            scheduleDwell(for: nil)
            if !panelHasFocus {
                onContentFocusHandoff()
            }
        }
        .onDisappear { dwellTask?.cancel() }
    }

    // MARK: - Clusters

    private var wordmark: some View {
        Text("SILO")
            .font(.system(size: ContinuumTheme.Skyline.wordmarkSize, weight: .heavy))
            .tracking(ContinuumTheme.Skyline.wordmarkTracking)
            .foregroundStyle(.white)
            .accessibilityLabel("Silo")
            .accessibilityHidden(true)
    }

    private var tabCluster: some View {
        ViewThatFits(in: .horizontal) {
            centeredTabCluster
            scrollingTabCluster
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: ContinuumTheme.Skyline.barHeight)
    }

    /// Keep the ordinary menu as one native focus row. Besides preserving the
    /// Skyline screen-centered composition, this gives Search and Home direct
    /// focus adjacency instead of separating them with a scroll container.
    private var centeredTabCluster: some View {
        HStack(spacing: ContinuumTheme.Skyline.tabSpacing) {
            searchButton

            ForEach(Array(roots.enumerated()), id: \.element) { index, root in
                rootButton(root, index: index, count: roots.count)
            }

            // Balance Search so the roots themselves remain screen-centered.
            Color.clear
                .frame(
                    width: ContinuumTheme.Skyline.barIconSize,
                    height: ContinuumTheme.Skyline.barIconSize
                )
                .accessibilityHidden(true)
        }
        // `ViewThatFits` must measure the row's intrinsic width so it can
        // select the scrolling fallback only when customization overflows.
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Long customized menus keep Search fixed and scroll only the roots.
    private var scrollingTabCluster: some View {
        HStack(spacing: ContinuumTheme.Skyline.tabSpacing) {
            searchButton

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ContinuumTheme.Skyline.tabSpacing) {
                        ForEach(Array(roots.enumerated()), id: \.element) { index, root in
                            rootButton(root, index: index, count: roots.count)
                                .id(TVTopMenuFocus.root(root))
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollClipDisabled()
                .onChange(of: focusedItem) { _, item in
                    guard let item, case .root = item else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: ContinuumTheme.fastDuration)) {
                        proxy.scrollTo(item, anchor: .center)
                    }
                }
                .onChange(of: selectedRoot) { _, root in
                    proxy.scrollTo(TVTopMenuFocus.root(root), anchor: .center)
                }
            }
        }
        // Search and Profile stay fixed while only the customizable roots
        // scroll through the center lane.
        .padding(.horizontal, 150)
        .frame(maxWidth: .infinity)
    }

    private var trailingCluster: some View {
        profileButton
    }

    // MARK: - Tabs

    private func rootButton(_ root: TVRootDestination, index: Int, count: Int) -> some View {
        // While its panel owns focus the tab reads as selected, not focused
        // (§5.1) — the inverted look transfers to the panel row.
        let panelOwnsFocus = panelHasFocus && openPanel == .root(root)
        let hasFocus = focusedItem == .root(root) && !panelHasFocus
        let isFocused = hasFocus && !panelOwnsFocus
        let isSelected = selectedRoot == root || panelOwnsFocus

        return Button {
            selectRootFromMenu(root)
        } label: {
            Text(root.title)
                .font(.system(size: ContinuumTheme.Skyline.tabLabelSize, weight: .semibold))
                .foregroundStyle(tabForeground(isSelected: isSelected, isFocused: isFocused))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260)
                .padding(.horizontal, ContinuumTheme.Skyline.tabPaddingHorizontal)
                .padding(.vertical, ContinuumTheme.Skyline.tabPaddingVertical)
                .modifier(TVTopMenuCapsuleChrome(isSelected: isSelected, isFocused: isFocused))
        }
        .buttonStyle(.continuumFlat)
        .focused($focusedItem, equals: .root(root))
        // A ScrollView is its own focus region on tvOS. At its leading edge,
        // explicitly hand Left back to the fixed Search anchor.
        .modifier(TVTopMenuLeadingBoundaryHandler(isLeading: index == 0) {
            focusedItem = .search
        })
        // Down opens this tab's cascade panel (if a dwell hasn't already)
        // and hands focus straight into it, so the move never escapes to the
        // page content behind the bar. Fires only when the engine can't move
        // focus within the bar — i.e. the bar is a single row, so down
        // always reaches here.
        // `canOpenPanel` is keyed on the tab *kind* (library and For You tabs
        // can; Home/Calendar never can) — invariant, so opening a panel never
        // restructures this focused button (which dropped focus).
        .modifier(TVTopMenuDownHandler(canOpenPanel: rootPanel(root) != nil) {
            onEnterPanel(.root(root))
        })
        // Panel-bearing tabs publish their bounds so the shell can center the
        // anchored dropdown under them (§5.3); other tabs have no panel.
        .modifier(TVTopMenuAnchorPublisher(panel: rootPanel(root)))
        // Debug-overlay hint: SwiftUI's content→menu section hop lands on
        // the selected tab, but that rule is invisible to the focus
        // engine — the selected tab publishes its frame so the overlay
        // can mark it as the Up destination. Renders nothing when the
        // overlay setting is off; debug builds only.
        #if DEBUG
        .background(TVFocusDebugTabFramePublisher(isSelected: selectedRoot == root))
        #endif
        .accessibilityLabel("\(root.title), tab, \(index + 1) of \(count)")
        .accessibilityHint(rootPanelHint(for: root))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func rootPanel(_ root: TVRootDestination) -> TVTopMenuPanel? {
        switch root {
        case .libraryType:
            return TVLibraryMenuRootKind.category.hasSectionCascade ? .root(root) : nil
        case .libraryShortcut:
            return TVLibraryMenuRootKind.directShortcut.hasSectionCascade ? .root(root) : nil
        case .recommendations:
            return .root(root)
        case .home, .calendar:
            return nil
        }
    }

    private func rootPanelHint(for root: TVRootDestination) -> String {
        switch root {
        case .libraryType:
            return "Rest to choose a library"
        case .libraryShortcut:
            return "Rest to choose a section"
        case .recommendations:
            return "Rest to choose Watchlist, Favorites, or Recommendations"
        case .home, .calendar:
            return ""
        }
    }

    private func tabForeground(isSelected: Bool, isFocused: Bool) -> Color {
        if isFocused { return .continuumBackground }
        if isSelected { return .white }
        return .white.opacity(0.62)
    }

    private func selectRootFromMenu(_ root: TVRootDestination) {
        onSelectRoot(root)
        DispatchQueue.main.async {
            focusedItem = nil
        }
    }

    private func requestMenuFocus() {
        guard !isFocusSuppressed else {
            Self.logger.debug("topMenu.requestMenuFocus blocked suppressed=true")
            return
        }
        switch focusRequestTarget {
        // A non-nil target means focus is returning from an explicit panel
        // close (focusTopMenuIfVisible(focusing:) is only called that way).
        // Mark it so the dwell timer doesn't immediately reopen what the
        // user just dismissed. A target-less request (Up/Menu from content)
        // leaves dwell enabled — resting on a tab there should preview it.
        case .root(let root):
            dwellSuppressedElement = .root(root)
            focusedItem = .root(root)
        case .profile:
            dwellSuppressedElement = .profile
            focusedItem = .profile
        case .none:
            focusedItem = .root(selectedRoot)
        }
        let item = focusedItem.map { String(describing: $0) } ?? "nil"
        Self.logger.debug("topMenu.requestMenuFocus focusedItem=\(item, privacy: .public)")
    }

    // MARK: - Search

    private var searchButton: some View {
        let isFocused = focusedItem == .search && !panelHasFocus

        return Button(action: onSearch) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(isFocused ? Color.continuumBackground : .white.opacity(0.62))
                .frame(
                    width: ContinuumTheme.Skyline.barIconSize,
                    height: ContinuumTheme.Skyline.barIconSize
                )
                .modifier(TVTopMenuCapsuleChrome(isSelected: false, isFocused: isFocused))
        }
        .buttonStyle(.continuumFlat)
        .focused($focusedItem, equals: .search)
        // The inverse boundary keeps Search usable in the scrolling fallback;
        // in the centered layout the native focus graph resolves this first.
        .onMoveCommand { direction in
            guard direction == .right, let firstRoot = roots.first else { return }
            focusedItem = .root(firstRoot)
        }
        .accessibilityLabel("Search")
    }

    // MARK: - Profile

    private var profileButton: some View {
        // The avatar keeps its focus ring while the profile panel is open
        // and focus is still on the avatar; once focus descends into the
        // panel the ring drops (the panel rows carry focus then, §5.8).
        let panelOwnsFocus = panelHasFocus && openPanel == .profile
        let isFocused = focusedItem == .profile && !panelHasFocus && !panelOwnsFocus

        return Button {
            // Press opens and enters immediately (§5.8); dwell only previews.
            onProfilePressed()
        } label: {
            ProfileAvatarView(
                avatar: currentProfile?.avatarEmoji,
                imageUrl: currentProfile?.avatarImageUrl,
                name: currentProfile?.name ?? "",
                size: ContinuumTheme.Skyline.barIconSize,
                backgroundColor: Color.white.opacity(0.18),
                textColor: .white
            )
            .overlay {
                Circle()
                    .strokeBorder(Color.white, lineWidth: isFocused ? 3 : 0)
            }
            // Reduce Motion drops the focus scale so the avatar snaps (§4.2).
            .scaleEffect(isFocused && !reduceMotion ? 1.05 : 1.0)
            .focusEffectDisabled()
            .animation(reduceMotion ? nil : ContinuumTheme.springAnimation, value: isFocused)
        }
        .buttonStyle(.continuumFlat)
        .focused($focusedItem, equals: .profile)
        .modifier(TVTopMenuDownHandler(canOpenPanel: true) {
            onEnterPanel(.profile)
        })
        .modifier(TVTopMenuAnchorPublisher(panel: .profile))
        .accessibilityLabel("Profile")
        .accessibilityHint("Rest or press to open the profile menu")
    }

    /// Menu handler for the bar: closes a dwell-open panel first (§5.3
    /// "Menu closes"), otherwise runs the page-level bar exit. This is captured
    /// by `TVTopMenuExitPressCatcher` instead of `.onExitCommand` so changing
    /// `openPanel` never rewrites the focused tab's SwiftUI ancestor chain.
    private var shouldCaptureExitPress: Bool {
        !isFocusSuppressed
            && focusedItem != nil
            && !panelHasFocus
            && (openPanel != nil || isFocusedAwayFromHome || onExit != nil)
    }

    private func handleExitPress() {
        let item = focusedItem.map { String(describing: $0) } ?? "nil"
        Self.logger.debug("topMenu.exitPress focusedItem=\(item, privacy: .public) openPanel=\(openPanel != nil, privacy: .public) selectedRoot=\(String(describing: selectedRoot), privacy: .public)")
        if openPanel != nil {
            onDwell(nil)
            return
        }
        if isFocusedAwayFromHome {
            if selectedRoot == .home {
                focusedItem = .root(.home)
                isMenuFocused = true
            } else {
                onExit?()
            }
            return
        }
        onExit?()
    }

    private var isFocusedAwayFromHome: Bool {
        focusedItem != nil && focusedItem != .root(.home)
    }

    // MARK: - Dwell (§5.3, §5.8)

    /// Restart the dwell timer whenever focus settles on a new bar
    /// element. A library tab or the profile avatar opens its panel after
    /// the dwell interval; any other element (or losing focus) closes any
    /// open panel immediately. Cancelled on every focus move so a sweep
    /// across the bar never opens a panel (Open-Q5/Q7).
    private func scheduleDwell(for item: TVTopMenuFocus?) {
        dwellTask?.cancel()

        // Moving focus to a *different bar element* — another tab, or the
        // search button — closes the open panel right away (§5.3: "moving
        // sideways to another tab closes it"), so it doesn't linger during
        // the new element's dwell. Once the panel is expected to own focus,
        // ignore top-bar repairs: tvOS may briefly re-home to Home while
        // the panel row focus claim is being applied.
        if let openPanel, !panelHasFocus, let item, !item.matches(panel: openPanel) {
            onDwell(nil)
            // Closing the panel removes its overlay, which perturbs focus and
            // drops the tab we just moved to; flag it so the nil-drop re-pins.
            refocusAfterClose = true
        }

        // Don't auto-reopen a panel the user just explicitly closed: Menu/Back
        // returns focus to its tab, and resting there would otherwise re-trip
        // the dwell. Once focus has moved on to a *different* element, drop the
        // suppression so normal dwell resumes.
        if let suppressed = dwellSuppressedElement {
            if suppressed == item { return }
            dwellSuppressedElement = nil
        }

        guard let target = dwellTarget(for: item) else { return }

        dwellTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: ContinuumTheme.Skyline.cascadeDwellMilliseconds * 1_000_000
            )
            guard !Task.isCancelled else { return }
            // Confirm focus is still on the same element before opening —
            // a late move that didn't cancel in time must not fire.
            guard focusedItem == item else { return }
            onDwell(target)
        }
    }

    /// Maps a focused bar element to the panel it should dwell-open, or
    /// `nil` for elements with no panel (wordmark/search/non-library tabs).
    private func dwellTarget(for item: TVTopMenuFocus?) -> TVTopMenuPanel? {
        switch item {
        case .root(let root):
            return rootPanel(root)
        case .profile:
            return .profile
        case .search, .none:
            return nil
        }
    }
}

/// Which bar element an anchored panel is attached to (§5.3/§5.8).
enum TVTopMenuPanel: Hashable {
    case root(TVRootDestination)
    case profile
}

private enum TVTopMenuFocus: Hashable {
    case root(TVRootDestination)
    case search
    case profile

    /// Whether this focused element is the anchor of the given open panel —
    /// i.e. focus is still "on" that panel's tab/avatar, not a sibling.
    func matches(panel: TVTopMenuPanel) -> Bool {
        switch (self, panel) {
        case let (.root(a), .root(b)): return a == b
        case (.profile, .profile): return true
        default: return false
        }
    }
}

/// Capsule chrome for top-bar tabs and the search button (§5.1):
/// resting = bare label, selected = `chrome.selected` capsule, focused =
/// inverted white capsule. Focus inversion is the platform grammar — no
/// outline ring, no system halo.
private struct TVTopMenuCapsuleChrome: ViewModifier {
    let isSelected: Bool
    let isFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(fillColor))
            .overlay {
                Capsule().strokeBorder(borderColor, lineWidth: 1)
            }
            .focusEffectDisabled()
            // Reduce Motion snaps the tab/search capsule inversion (§4.2).
            .animation(reduceMotion ? nil : ContinuumTheme.springAnimation, value: isFocused)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSelected)
    }

    private var fillColor: Color {
        if isFocused { return .white }
        if isSelected { return .continuumChromeSelectedFill }
        return .clear
    }

    private var borderColor: Color {
        if isFocused { return .clear }
        if isSelected { return .continuumChromeSelectedBorder }
        return .clear
    }
}

/// Shared surface for every Skyline anchored menu (§5.3 cascade + flyout,
/// §5.8 profile) so they read as one family. A frosted material base under
/// a near-opaque vertical tint — lighter at the top, as if lit from above —
/// finished with a gradient hairline that brightens along the top lip and a
/// two-layer shadow (a tight contact shadow under a broad ambient one) so
/// the panel floats over the page on its own depth rather than needing a
/// page scrim to darken everything behind it.
struct TVSkylinePanelChrome: ViewModifier {
    var cornerRadius: CGFloat = ContinuumTheme.Skyline.dropdownCornerRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(.regularMaterial))
            .background(
                shape.fill(
                    LinearGradient(
                        colors: [
                            Color(hex: "#23252C").opacity(0.92),
                            Color(hex: "#141519").opacity(0.95),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            )
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.22),
                            Color.white.opacity(0.05),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            .shadow(color: .black.opacity(0.55), radius: 40, y: 24)
    }
}

/// Hands d-pad **down** on a panel-bearing bar element (library tab or
/// avatar) to the host, which opens the element's panel if needed and moves
/// focus into it (§5.3). Attachment is keyed on the element's *kind*
/// (`canOpenPanel`, invariant) — never on whether its panel is currently
/// open. Toggling the attachment on a *focused* button rebuilds its subtree
/// and drops `@FocusState`, which bounced focus back to the Home tab; keeping
/// it invariant fixes that. The live open/enter decision is in the closure.
private struct TVTopMenuDownHandler: ViewModifier {
    let canOpenPanel: Bool
    let onDown: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if canOpenPanel {
            content.onMoveCommand { direction in
                if direction == .down { onDown() }
            }
        } else {
            content
        }
    }
}

/// The scrolling overflow layout puts its roots in a separate focus region
/// from the fixed Search button. This boundary reconnects the two regions
/// without taking ownership of ordinary movement inside either one.
private struct TVTopMenuLeadingBoundaryHandler: ViewModifier {
    let isLeading: Bool
    let onMoveLeft: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isLeading {
            content.onMoveCommand { direction in
                if direction == .left { onMoveLeft() }
            }
        } else {
            content
        }
    }
}

/// Publishes a bar element's bounds into `TVTopMenuAnchorKey` so the shell
/// can anchor its panel. A `nil` panel publishes nothing (elements with no
/// panel).
private struct TVTopMenuAnchorPublisher: ViewModifier {
    let panel: TVTopMenuPanel?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let panel {
            content.anchorPreference(key: TVTopMenuAnchorKey.self, value: .bounds) {
                [panel: $0]
            }
        } else {
            content
        }
    }
}

/// Window-level Menu capture for the top bar. A SwiftUI `.onExitCommand`
/// modifier would need to appear and disappear as a panel opens, which rebuilds
/// the ancestor chain around the currently focused tab. This recognizer stays
/// mounted and simply declines the press when the bar has nothing to handle, so
/// the system Menu behavior still passes through on Home.
private struct TVTopMenuExitPressCatcher: UIViewRepresentable {
    var isActive: Bool
    var onExit: () -> Void

    func makeUIView(context: Context) -> TVTopMenuExitPressUIView {
        let view = TVTopMenuExitPressUIView()
        apply(to: view)
        return view
    }

    func updateUIView(_ uiView: TVTopMenuExitPressUIView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: TVTopMenuExitPressUIView) {
        view.isActive = isActive
        view.onExit = onExit
    }
}

private final class TVTopMenuExitPressUIView: UIView, UIGestureRecognizerDelegate {
    var isActive = false
    var onExit: () -> Void = {}

    private weak var attachedWindow: UIWindow?
    private var recognizer: UITapGestureRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachRecognizerIfNeeded()
    }

    deinit {
        detachRecognizer()
    }

    private func attachRecognizerIfNeeded() {
        guard attachedWindow !== window else { return }
        detachRecognizer()

        guard let window else { return }
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleMenuPress(_:)))
        recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = self

        window.addGestureRecognizer(recognizer)
        attachedWindow = window
        self.recognizer = recognizer
    }

    private func detachRecognizer() {
        if let recognizer, let attachedWindow {
            attachedWindow.removeGestureRecognizer(recognizer)
        }
        recognizer = nil
        attachedWindow = nil
    }

    @objc private func handleMenuPress(_ recognizer: UITapGestureRecognizer) {
        guard isActive, recognizer.state == .ended else { return }
        onExit()
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isActive
    }
}

// MARK: - For You dropdown

private enum TVForYouAction: Hashable {
    case watchlist
    case favorites
    case recommendations
}

/// Anchored For You dropdown: a single-level menu under the For You root
/// tab, matching the top-bar dwell/down focus contract used by library
/// cascades.
struct TVForYouDropdown: View {
    let entersPanel: Bool
    let focusEntryGeneration: Int
    let onPanelFocusChanged: (Bool) -> Void
    let onClose: () -> Void
    let onExitToContent: () -> Void
    let onWatchlist: () -> Void
    let onFavorites: () -> Void
    let onRecommendations: () -> Void

    @FocusState private var focusedAction: TVForYouAction?
    @State private var lastAppliedEntryGeneration = 0

    var body: some View {
        panel
            .onChange(of: focusEntryGeneration) { _, generation in
                applyEntryGeneration(generation)
            }
            .onChange(of: focusedAction) { _, newValue in
                onPanelFocusChanged(newValue != nil)
            }
            .onChange(of: entersPanel) { _, entered in
                if !entered { focusedAction = nil }
            }
            .onAppear {
                if entersPanel { applyEntryGeneration(focusEntryGeneration) }
            }
    }

    private func applyEntryGeneration(_ generation: Int) {
        guard entersPanel,
              generation > 0,
              generation != lastAppliedEntryGeneration else { return }
        lastAppliedEntryGeneration = generation
        focusedAction = .watchlist
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            panelHeader

            actionButton("Watchlist", systemImage: "bookmark.fill", id: .watchlist, action: onWatchlist)
                .modifier(TVDropdownBoundaryMoveHandler(onMoveUp: onClose, onMoveDown: nil))
            actionButton("Favorites", systemImage: "heart.fill", id: .favorites, action: onFavorites)
            actionButton("Recommendations", systemImage: "sparkles", id: .recommendations, action: onRecommendations)
                .modifier(TVDropdownBoundaryMoveHandler(onMoveUp: nil, onMoveDown: onExitToContent))

            panelFooter
        }
        .padding(ContinuumTheme.Skyline.dropdownPadding)
        .frame(width: ContinuumTheme.Skyline.dropdownWidth, alignment: .leading)
        .modifier(TVSkylinePanelChrome())
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("For You menu")
    }

    private var panelHeader: some View {
        Text("FOR YOU")
            .font(.system(size: ContinuumTheme.Skyline.dropdownHeaderSize, design: .monospaced))
            .tracking(ContinuumTheme.Skyline.dropdownHeaderSize * 0.26)
            .foregroundStyle(Color.white.opacity(0.38))
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .accessibilityHidden(true)
    }

    private var panelFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Color.continuumDivider)
                .frame(height: 1)
                .padding(.horizontal, 12)
                .padding(.top, 6)

            Text("Press opens the section · Menu closes")
                .font(.system(size: ContinuumTheme.Skyline.dropdownHeaderSize, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.34))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        systemImage: String,
        id: TVForYouAction,
        action: @escaping () -> Void
    ) -> some View {
        let label = HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 30)

            Text(title)
                .font(.system(size: ContinuumTheme.Skyline.dropdownRowTextSize, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 0)
        }

        if entersPanel {
            Button(action: action) {
                label
            }
            .buttonStyle(TVProfileMenuButtonStyle(isDestructive: false))
            .focused($focusedAction, equals: id)
        } else {
            label
                .foregroundStyle(.white.opacity(0.86))
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
    }
}

private struct TVDropdownBoundaryMoveHandler: ViewModifier {
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if onMoveUp != nil || onMoveDown != nil {
            content.onMoveCommand { direction in
                switch direction {
                case .up:
                    onMoveUp?()
                case .down:
                    onMoveDown?()
                default:
                    break
                }
            }
        } else {
            content
        }
    }
}

// MARK: - Profile dropdown

private enum TVProfileAction: Hashable {
    case switchProfile
    case watchlist
    case favorites
    case history
    case requests
    case settings
    case switchServer
    case signOut
}

/// Anchored profile dropdown panel (§5.8): the same `glass.strong` level-1
/// panel as the cascade, hosted by the shell under the avatar. The shell
/// owns the scrim and Menu-to-close; this view owns only its rows and the
/// focus hand-off when the host bumps `focusEntryGeneration`.
struct TVProfileDropdown: View {
    let profileName: String
    let avatar: String?
    /// Server-resolved avatar image URL (`avatar_url`), preferred over the
    /// raw `avatar` ref when present.
    var avatarImageUrl: String? = nil
    /// Display name of the active server, shown under the profile name in
    /// the §5.8 mono header style.
    let serverHost: String?
    /// Whether focus has entered the panel.
    let entersPanel: Bool
    /// Bumped by the host when focus should enter — lands on the first row.
    let focusEntryGeneration: Int
    /// Reports whether any row currently holds focus, so the host can drop
    /// the avatar's focus ring once focus descends (§5.8).
    let onPanelFocusChanged: (Bool) -> Void
    let onSwitchProfile: () -> Void
    let onWatchlist: () -> Void
    let onFavorites: () -> Void
    let onHistory: () -> Void
    let onRequests: () -> Void
    let onSettings: () -> Void
    let onSwitchServer: () -> Void
    let onSignOut: () -> Void

    @FocusState private var focusedAction: TVProfileAction?
    @State private var lastAppliedEntryGeneration = 0

    /// Capability-gated: the Requests row only exists (and only takes a
    /// focus slot) when the server reports `requests_enabled`.
    private var showRequests: Bool {
        RequestsFeatureStore.shared.isEnabled
    }

    var body: some View {
        panel
            // Dwell previews render passive labels; rows become focusable
            // only after the host explicitly hands focus into the panel.
            .onChange(of: focusEntryGeneration) { _, generation in
                applyEntryGeneration(generation)
            }
            .onChange(of: focusedAction) { _, newValue in
                onPanelFocusChanged(newValue != nil)
            }
            .onChange(of: entersPanel) { _, entered in
                if !entered { focusedAction = nil }
            }
            .onAppear {
                if entersPanel { applyEntryGeneration(focusEntryGeneration) }
            }
    }

    private func applyEntryGeneration(_ generation: Int) {
        guard entersPanel,
              generation > 0,
              generation != lastAppliedEntryGeneration else { return }
        lastAppliedEntryGeneration = generation
        focusedAction = .switchProfile
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            actionButton("Switch Profile", systemImage: "person.2.fill", id: .switchProfile, action: onSwitchProfile)
            actionButton("Watchlist", systemImage: "bookmark.fill", id: .watchlist, action: onWatchlist)
            actionButton("Favorites", systemImage: "heart.fill", id: .favorites, action: onFavorites)
            actionButton("History", systemImage: "clock.fill", id: .history, action: onHistory)
            if showRequests {
                actionButton("Requests", systemImage: "sparkles", id: .requests, action: onRequests)
            }

            divider

            actionButton("Settings", systemImage: "gearshape.fill", id: .settings, action: onSettings)
            // The guide marks Switch Server as Android-only (§5.8), but tvOS
            // already ships multi-server switching — dropping it here would
            // regress existing users.
            actionButton("Switch Server", systemImage: "server.rack", id: .switchServer, action: onSwitchServer)
            actionButton("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", id: .signOut, isDestructive: true, action: onSignOut)

            divider

            Text("Press Menu to close")
                .font(.system(size: ContinuumTheme.Skyline.dropdownHeaderSize, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.white.opacity(0.38))
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
                .accessibilityHidden(true)
        }
        .padding(ContinuumTheme.Skyline.dropdownPadding)
        .frame(width: ContinuumTheme.Skyline.dropdownWidth, alignment: .leading)
        .modifier(TVSkylinePanelChrome())
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Profile menu")
    }

    private var header: some View {
        HStack(spacing: 14) {
            ProfileAvatarView(
                avatar: avatar,
                imageUrl: avatarImageUrl,
                name: profileName,
                size: 44,
                backgroundColor: Color.white.opacity(0.16),
                textColor: .white
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(profileName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let serverHost, !serverHost.isEmpty {
                    Text(serverHost.uppercased())
                        .font(.system(size: ContinuumTheme.Skyline.dropdownHeaderSize, design: .monospaced))
                        .tracking(1.4)
                        .foregroundStyle(Color.white.opacity(0.38))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.continuumDivider)
            .frame(height: 1)
            .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        systemImage: String,
        id: TVProfileAction,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let label = HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 30)

            Text(title)
                .font(.system(size: ContinuumTheme.Skyline.dropdownRowTextSize, weight: .semibold))
                .lineLimit(1)

            Spacer(minLength: 0)
        }

        if entersPanel {
            Button(action: action) {
                label
            }
            .buttonStyle(TVProfileMenuButtonStyle(isDestructive: isDestructive))
            .focused($focusedAction, equals: id)
        } else {
            label
                .foregroundStyle(isDestructive ? .red.opacity(0.9) : .white.opacity(0.86))
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
    }
}

private struct TVProfileMenuButtonStyle: ButtonStyle {
    let isDestructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        TVProfileMenuButtonBody(
            configuration: configuration,
            isDestructive: isDestructive
        )
    }
}

private struct TVProfileMenuButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isDestructive: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused ? Color.white : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .focusEffectDisabled()
            // Reduce Motion snaps the profile-menu row inversion (§4.2).
            .animation(reduceMotion ? nil : ContinuumTheme.springAnimation, value: isFocused)
            .animation(reduceMotion ? nil : .easeOut(duration: ContinuumTheme.fastDuration), value: configuration.isPressed)
    }

    private var foregroundColor: Color {
        if isFocused { return .continuumBackground }
        if isDestructive { return .red.opacity(0.9) }
        return .white.opacity(0.86)
    }
}
#endif
