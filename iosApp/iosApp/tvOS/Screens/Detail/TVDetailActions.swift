#if os(tvOS)
import SwiftUI

/// Sizing shared by the detail hero's glass action buttons.
///
/// The system glass styles add their own padding around the label, so these
/// are the *label* dimensions, not the finished button. The old
/// `TVCircleButtonStyle` drew a fixed 72pt tile with a 28pt glyph; feeding
/// that same 72pt to a system style made the circles noticeably larger while
/// the glyph stayed put, which read as small icons floating in oversized
/// discs. Shrinking the frame and growing the glyph restores the ratio.
enum TVDetailActionMetrics {
    static let circleDiameter: CGFloat = 44
    static let circleGlyphPointSize: CGFloat = 30
    static let expandedLabelSpacing: CGFloat = 14
    static let expandedLabelPointSize: CGFloat = 26
}

// MARK: - Expanding action label

/// A square icon at rest that reveals its title when its owning control is
/// focused. The surrounding `Button`/`Menu` remains the same focus item; only
/// the label's intrinsic content changes. Expansion and title visibility are
/// deliberately separate phases so text never remains visible while the
/// glass is collapsing around it.
private struct TVExpandingDetailActionLabel: View {
    let icon: String
    let title: String
    var prominent = false

    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var showsTitle = false

    var body: some View {
        HStack(spacing: isExpanded ? TVDetailActionMetrics.expandedLabelSpacing : 0) {
            Image(systemName: icon)
                .font(.system(
                    size: prominent ? 32 : TVDetailActionMetrics.circleGlyphPointSize,
                    weight: prominent ? .bold : .semibold
                ))
                .frame(
                    width: TVDetailActionMetrics.circleDiameter,
                    height: TVDetailActionMetrics.circleDiameter
                )
                .contentTransition(.symbolEffect(.replace))

            if isExpanded {
                Text(title)
                    .font(.system(
                        size: prominent ? 28 : TVDetailActionMetrics.expandedLabelPointSize,
                        weight: .semibold
                    ))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .opacity(showsTitle ? 1 : 0)
            }
        }
        .task(id: isFocused) {
            if reduceMotion {
                isExpanded = isFocused
                showsTitle = isFocused
                return
            }

            if isFocused {
                withAnimation(.smooth(duration: 0.26, extraBounce: 0)) {
                    isExpanded = true
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.10)) {
                    showsTitle = true
                }
            } else {
                // Clear the glyphs while the capsule is still full size.
                // Only after that short fade does the empty glass contract.
                withAnimation(.easeOut(duration: 0.06)) {
                    showsTitle = false
                }
                try? await Task.sleep(nanoseconds: 60_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: 0.24, extraBounce: 0)) {
                    isExpanded = false
                }
            }
        }
    }
}

// MARK: - Primary action

/// Primary play button for the detail hero. It rests as a compact play circle
/// and expands into a labelled capsule when focused.
///
/// Uses the system's Liquid Glass button style, which means **tvOS owns
/// the focus appearance**. That is the point: the platform's own focus
/// highlight lenses and brightens the glass, which a hand-rolled
/// `isFocused` fill cannot reproduce. Do not add `.focusEffectDisabled()`
/// here — that is what suppresses it.
///
/// The detail hero sits over a still backdrop, not live video, so
/// backdrop-sampling glass is safe here in a way it is not in the player
/// (see `TVPillButtonStyle`).
struct TVPrimaryPillButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    /// Optional focus binding so the owning detail view can both observe and
    /// claim this button's focus. Combined with `.defaultFocus(…priority:
    /// .userInitiated)` on the scroll container, this is the reliable way to
    /// make Play win initial focus over the geometrically-higher synopsis —
    /// `prefersDefaultFocus(_:in:)` loses to geometry in practice here.
    var focused: FocusState<Bool>.Binding? = nil

    var body: some View {
        Button(action: action) {
            TVExpandingDetailActionLabel(icon: icon, title: title, prominent: true)
        }
        // The label grows inside one stable native control. A capsule is a
        // circle at the resting square size and naturally stretches around
        // the title, allowing the system glass to morph with the content.
        .tvDetailGlassControl(shape: .capsule)
        .accessibilityLabel(title)
        .applyOptionalFocus(focused)
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

    /// Native Buttons already own their focus interaction. Applying
    /// `.focusable(true)` on top replaces that interaction and suppresses the
    /// glass style's visible focus response, so only add a modifier in the
    /// exceptional disabled state.
    @ViewBuilder
    func detailActionFocusDisabled(_ isDisabled: Bool) -> some View {
        if isDisabled {
            self.focusable(false)
        } else {
            self
        }
    }
}

// MARK: - Secondary action

/// Secondary detail action with the same icon-to-labelled-capsule behavior as
/// Play, while retaining the quieter secondary typography.
struct TVSecondaryPillButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVExpandingDetailActionLabel(icon: icon, title: title)
        }
        .tvDetailGlassControl(shape: .capsule)
        .accessibilityLabel(title)
    }
}

// MARK: - Version picker placeholder

/// Non-interactive placeholder that reserves the version picker footprint
/// while the next-up episode's playback metadata is loading.
struct TVVersionPillPlaceholder: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 24, weight: .semibold))
            Text("Version")
                .font(.system(size: 26, weight: .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 16, weight: .bold))
                .opacity(0.35)
        }
        .foregroundColor(.white.opacity(0.58))
        .frame(minWidth: 190)
        .padding(.horizontal, 40)
        .padding(.vertical, 22)
        .siloGlass(in: RoundedRectangle(cornerRadius: ContinuumTheme.smallCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ContinuumTheme.smallCornerRadius, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1.2)
        )
        .redacted(reason: .placeholder)
        .focusable(false)
    }
}

// MARK: - Circle menu button

/// Circle-shaped overflow/"more" button that opens a `Menu`. Same visual
/// footprint as `TVCircleActionButton` — used in the hero action row to
/// keep secondary navigation actions (Go to Series, Go to Season, etc.)
/// one tap away without crowding the primary row.
struct TVCircleMenuButton<MenuContent: View>: View {
    let icon: String
    let title: String
    let accessibilityLabel: String
    @ViewBuilder let menu: () -> MenuContent

    init(
        icon: String = "ellipsis",
        title: String = "More",
        accessibilityLabel: String,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) {
        self.icon = icon
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.menu = menu
    }

    var body: some View {
        Menu {
            menu()
        } label: {
            TVExpandingDetailActionLabel(icon: icon, title: title)
        }
        .menuStyle(.button)
        .tvDetailGlassControl(shape: .capsule)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Circle button

/// Compact icon-only secondary action circle. Infuse keeps these small
/// and quiet so the primary play button dominates; we do the same. Used
/// for Favorite / Watchlist / Info in the hero row.
struct TVCircleActionButton: View {
    let icon: String
    let iconActive: String?
    let isActive: Bool
    let title: String
    let accessibilityLabel: String
    let action: () -> Void

    init(
        icon: String,
        iconActive: String? = nil,
        isActive: Bool = false,
        title: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.iconActive = iconActive
        self.isActive = isActive
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    private var resolvedIcon: String {
        if isActive, let iconActive { return iconActive }
        return icon
    }

    var body: some View {
        Button(action: action) {
            TVExpandingDetailActionLabel(icon: resolvedIcon, title: title)
        }
        .tvDetailGlassControl(shape: .capsule)
        // No tint override: default glass in both states. The filled SF
        // Symbol variant (`heart.fill`, `bookmark.fill`,
        // `checkmark.circle.fill`) is what carries the active state, so an
        // accent wash on top was redundant colour in an otherwise neutral row.
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Detail action row

/// Shared native focus row for movie, episode, season and series detail pages.
/// The only imperative focus work is a bounded page-entry retry for Play;
/// directional movement remains owned by the tvOS focus engine.
struct TVDetailActionRow<MoreMenu: View>: View {
    enum InitialFocusScope: Equatable {
        case page
        case season(key: String?)
    }

    private enum ActionID: Hashable {
        case play
        case startOver
        case favorite
        case watchlist
        case watched
        case more
    }

    let playTitle: String?
    let onPlay: () -> Void
    let onStartOver: (() -> Void)?
    let isFavorite: Bool
    let onToggleFavorite: () -> Void
    let inWatchlist: Bool
    let onToggleWatchlist: () -> Void
    let isWatched: Bool
    let watchedLabelMark: String
    let watchedLabelUnmark: String
    let onToggleWatched: () -> Void
    let initialFocusScope: InitialFocusScope
    let focusNamespace: Namespace.ID
    let playFocused: FocusState<Bool>.Binding
    let rowFocused: FocusState<Bool>.Binding
    /// While Version owns focus below this row, Play is the sole eligible Up
    /// destination. The selector delays releasing this state until the focus
    /// move has landed, avoiding a transient all-buttons redraw.
    let routesVersionUpToPlay: Bool
    @ViewBuilder let moreMenu: () -> MoreMenu

    @Environment(\.resetFocus) private var resetFocus
    @State private var didResetInitialPlayFocus = false
    @State private var initialFocusSeasonKey: String?
    @State private var initialPlayFocusTask: Task<Void, Never>?
    @FocusState private var focusedAction: ActionID?

    var body: some View {
        // Each control owns an independent native glass surface. A shared
        // GlassEffectContainer couples the interactive highlight while two
        // adjacent buttons resize during a focus handoff, making inactive
        // controls flash in one direction or the other.
        HStack(spacing: 36) {
            if let playTitle {
                TVPrimaryPillButton(
                    icon: "play.fill",
                    title: playTitle,
                    action: onPlay,
                    focused: playFocused
                )
                .focused($focusedAction, equals: .play)
                .onGeometryChange(for: Bool.self) { proxy in
                    proxy.size.width > 0 && proxy.size.height > 0
                } action: { isLaidOut in
                    guard isLaidOut else { return }
                    resetInitialPlayFocus()
                }

                if let onStartOver {
                    TVCircleActionButton(
                        icon: "arrow.counterclockwise",
                        title: "Start Over",
                        accessibilityLabel: "Start Over",
                        action: onStartOver
                    )
                    .detailActionFocusDisabled(routesVersionUpToPlay)
                    .focused($focusedAction, equals: .startOver)
                }
            }

            TVCircleActionButton(
                icon: "heart",
                iconActive: "heart.fill",
                isActive: isFavorite,
                title: "Favorite",
                accessibilityLabel: isFavorite ? "Remove from favorites" : "Add to favorites",
                action: onToggleFavorite
            )
            .detailActionFocusDisabled(routesVersionUpToPlay)
            .focused($focusedAction, equals: .favorite)

            TVCircleActionButton(
                icon: "bookmark",
                iconActive: "bookmark.fill",
                isActive: inWatchlist,
                title: "Watchlist",
                accessibilityLabel: inWatchlist ? "Remove from watchlist" : "Add to watchlist",
                action: onToggleWatchlist
            )
            .detailActionFocusDisabled(routesVersionUpToPlay)
            .focused($focusedAction, equals: .watchlist)

            TVCircleActionButton(
                icon: "checkmark.circle",
                iconActive: "checkmark.circle.fill",
                isActive: isWatched,
                title: "Watched",
                accessibilityLabel: isWatched ? watchedLabelUnmark : watchedLabelMark,
                action: onToggleWatched
            )
            .detailActionFocusDisabled(routesVersionUpToPlay)
            .focused($focusedAction, equals: .watched)

            moreMenu()
                .detailActionFocusDisabled(routesVersionUpToPlay)
                .focused($focusedAction, equals: .more)
        }
        .focused(rowFocused)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .onChange(of: focusedAction) { oldAction, newAction in
            TVDetailFocusDiagnostics.record(
                "action.focusChanged",
                target: actionName(newAction),
                action: newAction == nil ? "lost" : "focused",
                state: "from=\(actionName(oldAction)) to=\(actionName(newAction)) "
                    + "playFocused=\(playFocused.wrappedValue)"
            )
        }
        .onChange(of: playFocused.wrappedValue) { _, isFocused in
            guard isFocused else { return }
            TVDetailFocusDiagnostics.record(
                "play.focusGained",
                target: "play",
                action: "focused",
                state: "rowTarget=\(actionName(focusedAction))",
                essential: true
            )
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
            var lastFocusedAction = actionFocus.wrappedValue
            for attempt in 0..<3 {
                if Task.isCancelled { return }
                if playFocused.wrappedValue { return }

                let focusedNow = actionFocus.wrappedValue
                if lastFocusedAction != nil, focusedNow != lastFocusedAction {
                    return
                }
                lastFocusedAction = focusedNow

                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if Task.isCancelled { return }
                }
                TVDetailFocusDiagnostics.record(
                    "play.defaultReset",
                    target: "play",
                    action: "resetFocus",
                    state: "attempt=\(attempt + 1) current=\(actionName(focusedNow))",
                    essential: true
                )
                resetFocus(in: focusNamespace)
                await Task.yield()
            }
        }
    }

    private func actionName(_ action: ActionID?) -> String {
        guard let action else { return "none" }
        switch action {
        case .play: return "play"
        case .startOver: return "startOver"
        case .favorite: return "favorite"
        case .watchlist: return "watchlist"
        case .watched: return "watched"
        case .more: return "more"
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

    init(kind: Kind, focusTreatment: FocusTreatment = .hero) {
        self.kind = kind
        self.focusTreatment = focusTreatment
    }

    func makeBody(configuration: Configuration) -> some View {
        TVPillButtonBody(configuration: configuration, kind: kind, focusTreatment: focusTreatment)
    }
}

private struct TVPillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: TVPillButtonStyle.Kind
    let focusTreatment: TVPillButtonStyle.FocusTreatment

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundColor(foreground)
            .padding(.horizontal, kind == .primary ? 54 : 40)
            .padding(.vertical, kind == .primary ? 26 : 22)
            .overlay(
                RoundedRectangle(cornerRadius: ContinuumTheme.smallCornerRadius, style: .continuous).stroke(
                    innerBorderColor,
                    lineWidth: innerBorderWidth
                )
            )
            // Deliberately NOT glass. This style is shared with the player
            // HUD (`PlayerView`, `TVPlayerControls`), which draws over live
            // video — backdrop-sampling glass there is the documented
            // frame-rate spike on A12-class Apple TVs. See `SiloGlass.swift`.
            // The detail row's glass buttons use the system styles instead.
            .background(
                RoundedRectangle(cornerRadius: ContinuumTheme.smallCornerRadius, style: .continuous).fill(background)
            )
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: ContinuumTheme.smallCornerRadius + 2, style: .continuous)
                        .stroke(focusOutlineColor, lineWidth: focusOutlineWidth)
                        .padding(-focusOutlineInset)
                }
            }
            .scaleEffect(scale)
            .shadow(
                color: .black.opacity(shadowOpacity),
                radius: shadowRadius,
                y: shadowY
            )
            .shadow(
                color: Color.continuumOnSurface.opacity(focusGlowOpacity),
                radius: focusGlowRadius,
                y: 0
            )
            .focusEffectDisabled()
            .animation(ContinuumTheme.springAnimation, value: isFocused)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .black
        case .secondary: return isFocused ? .black : .white
        }
    }

    private var background: Color {
        switch kind {
        case .primary:
            return isFocused ? .white : Color.white.opacity(0.76)
        case .secondary:
            return isFocused ? .white : Color.black.opacity(0.52)
        }
    }

    private var innerBorderColor: Color {
        if isFocused {
            return Color.black.opacity(kind == .primary ? 0.18 : 0.12)
        }
        switch kind {
        case .primary:
            return Color.white.opacity(0.12)
        case .secondary:
            return Color.white.opacity(0.24)
        }
    }

    private var innerBorderWidth: CGFloat {
        if isFocused {
            return kind == .primary ? 1.8 : 1.5
        }
        return kind == .primary ? 0.8 : 1.2
    }

    private var focusOutlineColor: Color {
        kind == .primary ? Color.white.opacity(0.94) : Color.white.opacity(0.98)
    }

    private var focusOutlineWidth: CGFloat {
        if focusTreatment == .compact { return 2.5 }
        return kind == .primary ? 4 : 3.5
    }

    private var focusOutlineInset: CGFloat {
        if focusTreatment == .compact { return 3 }
        return kind == .primary ? 7 : 6
    }

    private var scale: CGFloat {
        let base: CGFloat = isFocused
            ? focusedScale
            : 1.0
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

    private var focusGlowOpacity: Double {
        if focusTreatment == .compact {
            return isFocused ? 0.08 : 0
        }
        return isFocused ? 0.18 : 0
    }

    private var focusGlowRadius: CGFloat {
        if focusTreatment == .compact {
            return isFocused ? 6 : 0
        }
        return isFocused ? (kind == .primary ? 14 : 12) : 0
    }
}

#endif
