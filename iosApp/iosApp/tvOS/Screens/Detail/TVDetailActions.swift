#if os(tvOS)
import SwiftUI
import UIKit

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
    /// make Play win initial focus over any geometrically-higher control —
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 36, height: 36, alignment: .center)
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .buttonStyle(TVPillButtonStyle(kind: .secondary, focusTreatment: .compact))
        .accessibilityLabel(title)
    }
}

// MARK: - Circle menu button

/// Circle-shaped button that opens an app-owned `TVActionPopoverMenu`
/// anchored below it. Same visual footprint as `TVCircleActionButton`.
///
/// This deliberately does not use the system `Menu`: on tvOS that is a
/// context-menu interaction with ~1 s present and ~1.2 s dismiss springs,
/// and it swallows d-pad input until the dismiss completes. The popover
/// closes synchronously and hands focus straight back to this button.
struct TVCircleMenuButton: View {
    let icon: String
    /// Short label revealed while focused ("Versions", "More"). Nil keeps the
    /// button a fixed icon-only circle.
    let title: String?
    let accessibilityLabel: String
    let stabilizesFocusMotion: Bool
    /// Header shown inside the popover. Defaults to `title`.
    let menuTitle: String?
    let items: () -> [TVActionPopoverItem]
    let onSelect: (TVActionPopoverItem) -> Void

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @State private var isPresented = false
    @State private var presentationId = UUID()
    @State private var isPressed = false
    @State private var focusReturn: Task<Void, Never>?

    init(
        icon: String = "ellipsis",
        title: String? = nil,
        accessibilityLabel: String,
        stabilizesFocusMotion: Bool = false,
        menuTitle: String? = nil,
        items: @escaping () -> [TVActionPopoverItem],
        onSelect: @escaping (TVActionPopoverItem) -> Void
    ) {
        self.icon = icon
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.stabilizesFocusMotion = stabilizesFocusMotion
        self.menuTitle = menuTitle
        self.items = items
        self.onSelect = onSelect
    }

    var body: some View {
        TVCirclePillSurface(
            icon: icon,
            title: title,
            isFocused: isFocused || isPresented,
            isPressed: isPressed,
            stabilizesFocusMotion: stabilizesFocusMotion
        )
        .accessibilityHidden(true)
        .overlay {
            // The Button is only the focus/press host so the surface owns
            // the pill's geometry. It stays the accessibility element so
            // VoiceOver activation opens the popover.
            Button(action: open) {
                Color.clear
            }
            .buttonStyle(TVCircleFocusHostButtonStyle(isPressed: $isPressed))
            .focused($isFocused)
            .accessibilityLabel(accessibilityLabel)
        }
        // The popover itself is drawn by the page-level `tvActionPopoverHost()`
        // so it escapes the hero clip and paints above the rest of the page.
        // Only the request travels up; focus returns here via `isFocused`.
        .anchorPreference(key: TVActionPopoverPreferenceKey.self, value: .bounds) { anchor in
            guard isPresented else { return [] }
            return [
                TVActionPopoverRequest(
                    id: presentationId,
                    anchor: anchor,
                    title: menuTitle ?? title ?? accessibilityLabel,
                    items: items(),
                    onSelect: { item in
                        close()
                        onSelect(item)
                    },
                    onClose: close
                )
            ]
        }
        .onDisappear {
            focusReturn?.cancel()
            isPresented = false
        }
    }

    private func open() {
        guard isEnabled, !isPresented else { return }
        presentationId = UUID()
        isPresented = true
    }

    private func close() {
        guard isPresented else { return }
        isPresented = false
        returnFocus()
    }

    /// The page is disabled while the popover is open and re-enables one
    /// render after the request clears, so a synchronous focus write here
    /// is dropped. Re-assert across a few turns until it sticks.
    private func returnFocus() {
        focusReturn?.cancel()
        focusReturn = Task { @MainActor in
            for attempt in 0..<8 {
                if attempt == 0 {
                    await Task.yield()
                } else {
                    try? await Task.sleep(for: .milliseconds(32))
                }
                if Task.isCancelled || isFocused || isPresented { return }
                isFocused = true
            }
        }
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
        .accessibilityHidden(true)
        .overlay {
            // The Button stays the accessibility element so VoiceOver
            // activation runs `action`; the surface is decorative.
            Button(action: action) {
                Color.clear
            }
            .buttonStyle(TVCircleFocusHostButtonStyle(isPressed: $isPressed))
            .focused($isFocused)
            .accessibilityLabel(accessibilityLabel)
        }
    }
}

/// The viewer's own 1-to-5 star rating, shown to the right of More.
///
/// One composite focus control, not five buttons: the whole field takes focus
/// as a unit, Select opens it, and only then does left/right choose a rating.
/// Collapsed it owns no axis, so the action row's own left/right movement is
/// untouched; `docs/tvos-focus.md` describes this pattern and `TVCascadeSelector`
/// is the local example it points at.
struct TVStarRatingControl: View {
    static let maximumStars = 5

    let rating: Int?
    /// nil clears the rating.
    let onRate: (Int?) -> Void

    /// Open state lives with the row: while the control owns left and right,
    /// the row disables its other actions so the focus engine has nowhere to
    /// move and the move command reaches this control instead.
    @Binding var isEditing: Bool

    @FocusState private var isFocused: Bool
    @State private var pending = 0

    /// Stars shown filled: the pending choice while open, the saved rating
    /// otherwise.
    private var shown: Int { isEditing ? pending : (rating ?? 0) }

    var body: some View {
        HStack(spacing: isEditing ? 10 : 6) {
            ForEach(1...Self.maximumStars, id: \.self) { star in
                Image(systemName: star <= shown ? "star.fill" : "star")
                    .font(.system(size: isEditing ? 40 : 26, weight: .semibold))
                    .foregroundStyle(star <= shown
                        ? AnyShapeStyle(.yellow)
                        : AnyShapeStyle(.white.opacity(0.45)))
                    .scaleEffect(isEditing && star == pending ? 1.18 : 1)
            }
        }
        .padding(.horizontal, isEditing ? 26 : 16)
        .padding(.vertical, isEditing ? 14 : 9)
        .background {
            Capsule().fill(.white.opacity(isFocused ? 0.22 : 0.08))
        }
        .overlay {
            // While open the control owns left/right, so it says so plainly.
            Capsule().strokeBorder(.yellow.opacity(isEditing ? 0.9 : 0), lineWidth: 3)
        }
        .scaleEffect(isEditing ? 1 : (isFocused ? 1.06 : 1))
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isFocused)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isEditing)
        .animation(.easeOut(duration: 0.12), value: pending)
        .contentShape(Capsule())
        .focusable()
        .focused($isFocused)
        .onTapGesture(perform: activate)
        .onMoveCommand(perform: move)
        .onExitCommand(perform: isEditing ? cancel : nil)
        .onChange(of: isFocused) { _, focused in
            // Focus left the control, so an open editor has no owner. Close it
            // without writing: the viewer moved on rather than chose.
            if !focused { isEditing = false }
        }
        .accessibilityElement()
        .accessibilityLabel("Your rating")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(isEditing
            ? "Left and right choose a rating. Select to save."
            : "Select to rate this title.")
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityValue: String {
        if isEditing {
            return pending == 0 ? "No rating" : "\(pending) of \(Self.maximumStars) stars"
        }
        guard let rating else { return "Not rated" }
        return "\(rating) of \(Self.maximumStars) stars"
    }

    /// Select opens the control, then commits the pending choice.
    private func activate() {
        if isEditing {
            onRate(pending == 0 ? nil : pending)
            isEditing = false
            return
        }
        pending = rating ?? 0
        isEditing = true
    }

    /// Left and right choose a rating while open. Zero is the "no rating"
    /// position, which is how an existing rating is cleared without a second
    /// control. Up and down are left to the focus engine so the viewer can
    /// still leave the row.
    private func move(_ direction: MoveCommandDirection) {
        guard isEditing else { return }
        switch direction {
        case .left:
            pending = max(0, pending - 1)
        case .right:
            pending = min(Self.maximumStars, pending + 1)
        default:
            break
        }
    }

    /// Menu closes the editor and keeps the saved rating. The handler is only
    /// installed while the editor is open, because an installed handler
    /// consumes Menu whether or not it acts on it: a closed control that kept
    /// one would swallow the press and strand the viewer on the screen.
    private func cancel() {
        isEditing = false
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
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: isPressed)
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
    var isPlaybackLoading = false
    var allowsInitialPlayFocus = true
    var tracksInitialFocusNavigation = false
    /// The viewer's own rating, 1 to 5 stars, or nil when unrated. The stars
    /// render only when `onRate` is supplied, so a screen that cannot rate
    /// shows the row exactly as before.
    var userRating: Int? = nil
    var onRate: ((Int?) -> Void)? = nil
    @ViewBuilder let playbackSelectors: () -> PlaybackSelectors
    @ViewBuilder let moreMenu: () -> MoreMenu

    @Environment(\.resetFocus) private var resetFocus
    @State private var didResetInitialPlayFocus = false
    @State private var initialFocusSeasonKey: String?
    @State private var initialPlayFocusTask: Task<Void, Never>?
    @FocusState private var focusedAction: ActionID?
    @FocusState private var playbackSelectorsFocused: Bool
    @State private var isRatingEditing = false

    var body: some View {
        HStack(spacing: stabilizesFocusMotion ? 18 : 36) {
            // Disabled views are not focusable, so while the rating editor is
            // open Left has nowhere to go and reaches its move handler. The
            // focus engine resolves a move before any handler runs, so simply
            // consuming the command in the control is not enough.
            Group {
            if playTitle != nil || stabilizesFocusMotion {
                TVPrimaryPillButton(
                    icon: "play.fill",
                    title: playTitle ?? (isPlaybackLoading ? "Loading episodes…" : "Play"),
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

                if let onStartOver {
                    TVCircleActionButton(
                        icon: "backward.end.fill",
                        title: "Start Over",
                        accessibilityLabel: "Start Over",
                        stabilizesFocusMotion: stabilizesFocusMotion,
                        action: onStartOver
                    )
                    .focused($focusedAction, equals: .startOver)
                }

                playbackSelectors()
                    .focused($playbackSelectorsFocused)
            }

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

            moreMenu()
                .focused($focusedAction, equals: .more)
            }
            .disabled(isRatingEditing)

            if let onRate {
                TVStarRatingControl(
                    rating: userRating,
                    onRate: onRate,
                    isEditing: $isRatingEditing
                )
            }
        }
        .focused(rowFocused)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        // Attaching the handler consumes Up at this hard top boundary of a
        // pushed detail page, keeping focus on the action row; Up must never
        // behave like Back/Menu or pop the page to the root.
        .onMoveCommand { _ in }
        .onChange(of: allowsInitialPlayFocus) { _, allowed in
            if !allowed {
                didResetInitialPlayFocus = true
                cancelInitialPlayFocusRetry()
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
            didResetInitialPlayFocus = !allowsInitialPlayFocus
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

    private var seasonKey: String? {
        guard case .season(let key) = initialFocusScope else { return nil }
        return key
    }

    private func resetInitialPlayFocus() {
        guard allowsInitialPlayFocus, !didResetInitialPlayFocus else { return }
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
                    if !tracksInitialFocusNavigation, let focusedNow = actionFocus.wrappedValue,
                       focusedNow != .play {
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                    if Task.isCancelled { return }
                    if playFocused.wrappedValue { return }
                    if !tracksInitialFocusNavigation, let focusedNow = actionFocus.wrappedValue,
                       focusedNow != .play {
                        return
                    }
                }
                resetFocus(in: focusNamespace)
                await Task.yield()
                if attempt > 0, !tracksInitialFocusNavigation,
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
    let stabilizesFocusMotion: Bool
    let fixedWidth: CGFloat?

    init(
        kind: Kind,
        focusTreatment: FocusTreatment = .hero,
        stabilizesFocusMotion: Bool = false,
        fixedWidth: CGFloat? = nil
    ) {
        self.kind = kind
        self.focusTreatment = focusTreatment
        self.stabilizesFocusMotion = stabilizesFocusMotion
        self.fixedWidth = fixedWidth
    }

    func makeBody(configuration: Configuration) -> some View {
        TVPillButtonBody(
            configuration: configuration,
            kind: kind,
            focusTreatment: focusTreatment,
            stabilizesFocusMotion: stabilizesFocusMotion,
            fixedWidth: fixedWidth
        )
    }
}

private struct TVPillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: TVPillButtonStyle.Kind
    let focusTreatment: TVPillButtonStyle.FocusTreatment
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
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
    }

    private var foreground: Color { isFocused ? .black : .white }

    private var horizontalPadding: CGFloat {
        switch kind {
        case .primary:
            if stabilizesFocusMotion { return 22 }
            return isFocused ? 70 : 20
        case .secondary:
            return stabilizesFocusMotion ? 20 : 40
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
