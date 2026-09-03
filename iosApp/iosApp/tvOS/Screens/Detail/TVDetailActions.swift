#if os(tvOS)
import SwiftUI

// MARK: - Primary pill

/// VidHub-style primary play button. Solid white, large, dominant —
/// this is the one element the eye should land on first in the hero.
struct TVPrimaryPillButton: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var stabilizesFocusMotion = false
    var fixedWidth: CGFloat? = nil
    let action: () -> Void
    /// Optional focus binding so the owning detail view can both observe and
    /// claim this button's focus. Combined with `.defaultFocus(…priority:
    /// .userInitiated)` on the scroll container, this is the reliable way to
    /// make Play win initial focus over the geometrically-higher synopsis —
    /// `prefersDefaultFocus(_:in:)` loses to geometry in practice here.
    var focused: FocusState<Bool>.Binding? = nil

    var body: some View {
        Button(action: action) {
            TVPrimaryPillLabel(
                icon: icon,
                title: title,
                subtitle: subtitle,
                stabilizesFocusMotion: stabilizesFocusMotion
            )
        }
        .buttonStyle(
            TVPillButtonStyle(
                kind: .primary,
                focusTreatment: .compact,
                stabilizesFocusMotion: stabilizesFocusMotion,
                fixedWidth: fixedWidth
            )
        )
        .applyOptionalFocus(focused)
    }
}

private struct TVPrimaryPillLabel: View {
    let icon: String
    let title: String
    let subtitle: String?
    let stabilizesFocusMotion: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 31, weight: .bold))
                .frame(width: 36, height: 36)
            if isFocused || stabilizesFocusMotion {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 29, weight: .semibold))
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .transition(
                    stabilizesFocusMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .leading))
                )
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isFocused)
    }
}

private extension View {
    @ViewBuilder
    func applyOptionalFocus(_ binding: FocusState<Bool>.Binding?) -> some View {
        if let binding {
            self.focused(binding)
        } else {
            self
        }
    }
}

// MARK: - Secondary pill

/// Apple-TV-style dark secondary pill. Sits next to `TVPrimaryPillButton`
/// in the hero row. Filled dark squared tile with white icon + label — Apple
/// uses this for "Play Free Episode" alongside a white "Subscribe"
/// button; we use it for "Start Over" alongside a white "Resume …".
struct TVSecondaryPillButton: View {
    let icon: String
    let title: String
    var collapsesWhenUnfocused: Bool = false
    var stabilizesFocusMotion = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVSecondaryPillLabel(
                icon: icon,
                title: title,
                collapsesWhenUnfocused: collapsesWhenUnfocused,
                stabilizesFocusMotion: stabilizesFocusMotion
            )
        }
        .buttonStyle(TVPillButtonStyle(
            kind: .secondary,
            focusTreatment: .compact,
            collapsesWhenUnfocused: collapsesWhenUnfocused,
            stabilizesFocusMotion: stabilizesFocusMotion
        ))
        .accessibilityLabel(title)
    }
}

private struct TVSecondaryPillLabel: View {
    let icon: String
    let title: String
    let collapsesWhenUnfocused: Bool
    let stabilizesFocusMotion: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .frame(width: 36, height: 36, alignment: .center)
            if !stabilizesFocusMotion && (!collapsesWhenUnfocused || isFocused) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .transition(
                        stabilizesFocusMotion
                            ? .opacity
                            : .opacity.combined(with: .move(edge: .leading))
                    )
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isFocused)
    }
}

// MARK: - Circle menu button

/// Circle-shaped overflow/"more" button that opens a `Menu`. Same visual
/// footprint as `TVCircleActionButton` — used in the hero action row to
/// keep secondary navigation actions (Go to Series, Go to Season, etc.)
/// one tap away without crowding the primary row.
struct TVCircleMenuButton<MenuContent: View>: View {
    let icon: String
    /// Short label revealed while focused ("Versions", "More"). Nil keeps the
    /// button a fixed icon-only circle.
    let title: String?
    let accessibilityLabel: String
    let stabilizesFocusMotion: Bool
    @ViewBuilder let menu: () -> MenuContent

    @FocusState private var isFocused: Bool

    init(
        icon: String = "ellipsis",
        title: String? = nil,
        accessibilityLabel: String,
        stabilizesFocusMotion: Bool = false,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) {
        self.icon = icon
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.stabilizesFocusMotion = stabilizesFocusMotion
        self.menu = menu
    }

    var body: some View {
        TVCirclePillSurface(
            icon: icon,
            title: title,
            isFocused: isFocused,
            isPressed: false,
            stabilizesFocusMotion: stabilizesFocusMotion
        )
        .overlay {
            // The Menu is only the focus/press host. Its UIKit-backed button
            // applies label size changes without animating them, so it must
            // not own the pill's geometry; the surface above does.
            Menu {
                menu()
            } label: {
                Color.clear
            }
            .menuStyle(.button)
            .buttonStyle(TVCircleFocusHostButtonStyle(isPressed: nil))
            .focused($isFocused)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Circle button

/// Compact secondary action circle: icon-only at rest so the primary play
/// button dominates, expanding to icon + title while focused. Used for
/// Start Over / Watchlist in the hero row.
struct TVCircleActionButton: View {
    let icon: String
    let iconActive: String?
    let isActive: Bool
    let title: String
    let accessibilityLabel: String
    let stabilizesFocusMotion: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var isPressed = false

    init(
        icon: String,
        iconActive: String? = nil,
        isActive: Bool = false,
        title: String,
        accessibilityLabel: String,
        stabilizesFocusMotion: Bool = false,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.iconActive = iconActive
        self.isActive = isActive
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.stabilizesFocusMotion = stabilizesFocusMotion
        self.action = action
    }

    private var resolvedIcon: String {
        if isActive, let iconActive { return iconActive }
        return icon
    }

    var body: some View {
        TVCirclePillSurface(
            icon: resolvedIcon,
            title: title,
            isFocused: isFocused,
            isPressed: isPressed,
            stabilizesFocusMotion: stabilizesFocusMotion
        )
        .overlay {
            Button(action: action) {
                Color.clear
            }
            .buttonStyle(TVCircleFocusHostButtonStyle(isPressed: $isPressed))
            .focused($isFocused)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }
}

/// The visible pill for `TVCircleMenuButton` / `TVCircleActionButton`.
/// Icon-only circle at rest; while focused the title fades in beside the
/// icon and the capsule widens to fit, reflowing the row with it.
///
/// Pure SwiftUI on purpose: the focusable control sits in an overlay so no
/// UIKit-backed host can snap the width. `isFocused` drives an `isExpanded`
/// state written inside `withAnimation`, which puts the width change and
/// the neighbours' reflow into one transaction.
private struct TVCirclePillSurface: View {
    let icon: String
    let title: String?
    let isFocused: Bool
    let isPressed: Bool
    let stabilizesFocusMotion: Bool

    @State private var isExpanded = false

    private var canExpand: Bool {
        guard let title else { return false }
        return !title.isEmpty
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 31, weight: .semibold))
                .frame(width: 38, height: 38, alignment: .center)
                .contentTransition(.symbolEffect(.replace))
            if isExpanded, let title {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    // Fade in once the capsule has started opening; fade out
                    // fast so no text is visible while it closes. The clip
                    // below is the backstop.
                    .transition(
                        .asymmetric(
                            insertion: .opacity.animation(
                                TVCircleFocusMotion.reveal.delay(0.06)
                            ),
                            removal: .opacity.animation(TVCircleFocusMotion.dismiss)
                        )
                    )
            }
        }
        .padding(.horizontal, isExpanded ? 28 : 0)
        .foregroundColor(isFocused ? .black : .white)
        // A 76×76 capsule is a circle; the title widens it into a pill
        // without changing the row height.
        .frame(minWidth: 76)
        .frame(height: 76)
        .background(
            Capsule().fill(
                isFocused ? .white : Color.white.opacity(0.10)
            )
        )
        .clipShape(Capsule())
        .scaleEffect(scale)
        .shadow(
            color: .black.opacity(isFocused ? 0.34 : 0.0),
            radius: isFocused ? 16 : 0,
            y: isFocused ? 6 : 0
        )
        .animation(TVCircleFocusMotion.resize, value: isFocused)
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isPressed)
        .onChange(of: isFocused, initial: true) { _, focused in
            let expanded = focused && canExpand
            guard expanded != isExpanded else { return }
            withAnimation(TVCircleFocusMotion.resize) {
                isExpanded = expanded
            }
        }
    }

    private var scale: CGFloat {
        let base: CGFloat = isFocused && !stabilizesFocusMotion ? 1.1 : 1.0
        return isPressed ? base * 0.95 : base
    }
}

/// Invisible, full-size focus and press host laid over `TVCirclePillSurface`.
/// Suppresses the system focus halo (the surface paints its own) and mirrors
/// the press state out so the surface can react to it.
private struct TVCircleFocusHostButtonStyle: ButtonStyle {
    let isPressed: Binding<Bool>?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Capsule())
            .focusEffectDisabled()
            .onChange(of: configuration.isPressed) { _, pressed in
                isPressed?.wrappedValue = pressed
            }
    }
}

/// One motion vocabulary for the expanding circles so the capsule, the
/// row reflow, and the title all move together.
enum TVCircleFocusMotion {
    /// Capsule width and neighbor reflow. A plain smooth ease; springs read
    /// as wobble on a 10-foot UI.
    static let resize = Animation.smooth(duration: 0.28, extraBounce: 0)
    /// Title arriving with the capsule.
    static let reveal = Animation.easeOut(duration: 0.18)
    /// Title leaving ahead of the capsule shrink.
    static let dismiss = Animation.easeIn(duration: 0.08)
}

// MARK: - Detail action row

/// Shared native focus row for movie, episode, season and series detail pages.
/// The only imperative focus work is a bounded page-entry retry for Play;
/// directional movement remains owned by the tvOS focus engine.
struct TVDetailActionRow<PlaybackSelectors: View, MoreMenu: View>: View {
    enum InitialFocusScope: Equatable {
        case page
        case season(key: String?)
    }

    private enum ActionID: Hashable {
        case play
        case startOver
        case playbackSelectors
        case watchlist
        case more
    }

    let playTitle: String?
    let playSubtitle: String?
    let onPlay: () -> Void
    let onStartOver: (() -> Void)?
    let inWatchlist: Bool
    let onToggleWatchlist: () -> Void
    /// Stable identity for the detail page. A newly opened content page gets
    /// one bounded Play-focus claim; changing seasons within that page does
    /// not steal focus back from the season row.
    let focusResetKey: String
    let initialFocusScope: InitialFocusScope
    let focusNamespace: Namespace.ID
    let playFocused: FocusState<Bool>.Binding
    let rowFocused: FocusState<Bool>.Binding
    /// Opt-in treatment used by the redesigned Movie and Series pages. Play
    /// stays a labeled pill and no control scales on focus; secondary circles
    /// still widen to reveal their title, reflowing the row horizontally only.
    var stabilizesFocusMotion = false
    /// Series reserves one compact width across Play/Resume episode labels.
    /// Movies leave this nil so short labels use their natural pill width.
    var primaryButtonWidth: CGFloat? = nil
    @ViewBuilder let playbackSelectors: () -> PlaybackSelectors
    @ViewBuilder let moreMenu: () -> MoreMenu

    @Environment(\.resetFocus) private var resetFocus
    @State private var didResetInitialPlayFocus = false
    @State private var initialFocusSeasonKey: String?
    @State private var initialPlayFocusTask: Task<Void, Never>?
    @FocusState private var focusedAction: ActionID?
    @FocusState private var playbackSelectorsFocused: Bool

    var body: some View {
        HStack(spacing: stabilizesFocusMotion ? 18 : 36) {
            if playTitle != nil || stabilizesFocusMotion {
                actionSlot {
                    TVPrimaryPillButton(
                        icon: "play.fill",
                        title: playTitle ?? "Play",
                        subtitle: playSubtitle,
                        stabilizesFocusMotion: stabilizesFocusMotion,
                        fixedWidth: primaryButtonWidth,
                        action: onPlay,
                        focused: playFocused
                    )
                    .disabled(playTitle == nil)
                    .focused($focusedAction, equals: .play)
                    .onGeometryChange(for: Bool.self) { proxy in
                        proxy.size.width > 0 && proxy.size.height > 0
                    } action: { isLaidOut in
                        // Series mounts a disabled placeholder while its first
                        // playable episode is still loading. Do not consume
                        // the page's one-shot focus claim until Play is live.
                        guard isLaidOut, playTitle != nil else { return }
                        resetInitialPlayFocus()
                    }
                }

                if let onStartOver {
                    actionSlot {
                        TVCircleActionButton(
                            icon: "backward.end.fill",
                            title: "Start Over",
                            accessibilityLabel: "Start Over",
                            stabilizesFocusMotion: stabilizesFocusMotion,
                            action: onStartOver
                        )
                        .focused($focusedAction, equals: .startOver)
                    }
                }

                actionSlot {
                    playbackSelectors()
                        .focused($playbackSelectorsFocused)
                }
            }

            actionSlot {
                TVCircleActionButton(
                    icon: "bookmark",
                    iconActive: "bookmark.fill",
                    isActive: inWatchlist,
                    title: stabilizesFocusMotion
                        ? "Watchlist"
                        : (inWatchlist ? "Remove from Watchlist" : "Watchlist"),
                    accessibilityLabel: inWatchlist ? "Remove from watchlist" : "Add to watchlist",
                    stabilizesFocusMotion: stabilizesFocusMotion,
                    action: onToggleWatchlist
                )
                .focused($focusedAction, equals: .watchlist)
            }

            actionSlot {
                moreMenu()
                    .focused($focusedAction, equals: .more)
            }
        }
        .focused(rowFocused)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .onMoveCommand { direction in
            // This is a hard top boundary for a pushed detail page. Consuming
            // Up here keeps focus on the action row; it must never behave like
            // Back/Menu or pop the movie/series page to the root.
            if direction == .up {
                return
            }
        }
        .onChange(of: playbackSelectorsFocused) { _, isFocused in
            if isFocused {
                focusedAction = .playbackSelectors
            } else if focusedAction == .playbackSelectors {
                focusedAction = nil
            }
        }
        .task(id: focusResetKey) {
            cancelInitialPlayFocusRetry()
            didResetInitialPlayFocus = false
            initialFocusSeasonKey = seasonKey
            await Task.yield()
            guard playTitle != nil else { return }
            resetInitialPlayFocus()
        }
        .onChange(of: playTitle, initial: true) { _, title in
            guard title != nil else { return }
            resetInitialPlayFocus()
        }
        .onChange(of: seasonKey, initial: true) { _, seasonKey in
            guard let seasonKey else { return }
            if initialFocusSeasonKey == nil {
                initialFocusSeasonKey = seasonKey
            } else if initialFocusSeasonKey != seasonKey {
                didResetInitialPlayFocus = true
                cancelInitialPlayFocusRetry()
            }
        }
        .onDisappear {
            cancelInitialPlayFocusRetry()
        }
    }

    @ViewBuilder
    private func actionSlot<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
    }

    private var seasonKey: String? {
        guard case .season(let key) = initialFocusScope else { return nil }
        return key
    }

    private func resetInitialPlayFocus() {
        guard !didResetInitialPlayFocus else { return }
        if case .season = initialFocusScope {
            guard let seasonKey else { return }
            if initialFocusSeasonKey == nil {
                initialFocusSeasonKey = seasonKey
            }
            guard initialFocusSeasonKey == seasonKey else { return }
        }
        didResetInitialPlayFocus = true

        let actionFocus = $focusedAction
        initialPlayFocusTask = Task { @MainActor in
            for attempt in 0..<3 {
                if Task.isCancelled { return }
                if playFocused.wrappedValue { return }

                if attempt > 0 {
                    if let focusedNow = actionFocus.wrappedValue,
                       focusedNow != .play {
                        return
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if Task.isCancelled { return }
                    if playFocused.wrappedValue { return }
                    if let focusedNow = actionFocus.wrappedValue,
                       focusedNow != .play {
                        return
                    }
                }
                resetFocus(in: focusNamespace)
                await Task.yield()
                if attempt > 0,
                   let focusedNow = actionFocus.wrappedValue,
                   focusedNow != .play {
                    return
                }
                actionFocus.wrappedValue = .play
                playFocused.wrappedValue = true
            }
        }
    }

    private func cancelInitialPlayFocusRetry() {
        initialPlayFocusTask?.cancel()
        initialPlayFocusTask = nil
    }
}

// MARK: - Pill ButtonStyle

/// Shared ButtonStyle for the hero's pill controls. Owns all focus
/// appearance via `@Environment(\.isFocused)` — critical on tvOS, where
/// using `.buttonStyle(.plain)` with an external `@FocusState` still
/// lets the system paint its default white focus halo around the
/// button's bounds. A custom `ButtonStyle` fully suppresses that.
struct TVPillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    enum FocusTreatment { case hero, compact }

    let kind: Kind
    let focusTreatment: FocusTreatment
    let collapsesWhenUnfocused: Bool
    let stabilizesFocusMotion: Bool
    let fixedWidth: CGFloat?

    init(
        kind: Kind,
        focusTreatment: FocusTreatment = .hero,
        collapsesWhenUnfocused: Bool = false,
        stabilizesFocusMotion: Bool = false,
        fixedWidth: CGFloat? = nil
    ) {
        self.kind = kind
        self.focusTreatment = focusTreatment
        self.collapsesWhenUnfocused = collapsesWhenUnfocused
        self.stabilizesFocusMotion = stabilizesFocusMotion
        self.fixedWidth = fixedWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        TVPillButtonBody(
            configuration: configuration,
            kind: kind,
            focusTreatment: focusTreatment,
            collapsesWhenUnfocused: collapsesWhenUnfocused,
            stabilizesFocusMotion: stabilizesFocusMotion,
            fixedWidth: fixedWidth
        )
    }
}

private struct TVPillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: TVPillButtonStyle.Kind
    let focusTreatment: TVPillButtonStyle.FocusTreatment
    let collapsesWhenUnfocused: Bool
    let stabilizesFocusMotion: Bool
    let fixedWidth: CGFloat?

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundColor(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(width: fixedWidth, height: 76)
            .background(
                Capsule().fill(background)
            )
            .scaleEffect(scale)
            .shadow(
                color: .black.opacity(shadowOpacity),
                radius: shadowRadius,
                y: shadowY
            )
            .focusEffectDisabled()
            .animation(.easeInOut(duration: 0.18), value: isFocused)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return isFocused ? .black : .white
        case .secondary: return isFocused ? .black : .white
        }
    }

    private var horizontalPadding: CGFloat {
        switch kind {
        case .primary:
            if stabilizesFocusMotion { return 22 }
            return isFocused ? 70 : 20
        case .secondary:
            if stabilizesFocusMotion { return 20 }
            return collapsesWhenUnfocused && !isFocused ? 20 : 40
        }
    }

    private var background: Color {
        switch kind {
        case .primary:
            return isFocused ? .white : Color.white.opacity(0.10)
        case .secondary:
            return isFocused ? .white : Color.black.opacity(0.52)
        }
    }

    private var scale: CGFloat {
        let base: CGFloat = isFocused && !stabilizesFocusMotion ? focusedScale : 1.0
        return configuration.isPressed ? base * 0.98 : base
    }

    private var focusedScale: CGFloat {
        if focusTreatment == .compact { return 1.025 }
        return kind == .primary ? 1.085 : 1.06
    }

    private var shadowOpacity: Double {
        if focusTreatment == .compact {
            return isFocused ? 0.24 : 0.14
        }
        switch kind {
        case .primary: return isFocused ? 0.42 : 0.20
        case .secondary: return isFocused ? 0.36 : 0.18
        }
    }

    private var shadowRadius: CGFloat {
        if focusTreatment == .compact {
            return isFocused ? 10 : 4
        }
        switch kind {
        case .primary: return isFocused ? 24 : 6
        case .secondary: return isFocused ? 20 : 4
        }
    }

    private var shadowY: CGFloat {
        if focusTreatment == .compact {
            return isFocused ? 4 : 2
        }
        return isFocused ? 10 : 2
    }

}

#endif
