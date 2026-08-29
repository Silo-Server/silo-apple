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
}

// MARK: - Primary pill

/// Primary play button for the detail hero — the one element the eye should
/// land on first.
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
            HStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .bold))
                Text(title)
                    .font(.system(size: 30, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        // Plain `.glass`, not `.glassProminent`. Prominent needs an explicit
        // tint to stay legible — the app's global monochrome tint renders it
        // white-on-white — and an accent-tinted slab made Play the only
        // coloured element in the row. Clear glass keeps it the same material
        // as the action buttons beside it; its width and label are what mark
        // it as primary.
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: ContinuumTheme.smallCornerRadius))
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
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: ContinuumTheme.smallCornerRadius))
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
    let accessibilityLabel: String
    @ViewBuilder let menu: () -> MenuContent

    init(
        icon: String = "ellipsis",
        accessibilityLabel: String,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) {
        self.icon = icon
        self.accessibilityLabel = accessibilityLabel
        self.menu = menu
    }

    var body: some View {
        Menu {
            menu()
        } label: {
            Image(systemName: icon)
                .font(.system(size: TVDetailActionMetrics.circleGlyphPointSize, weight: .semibold))
                .frame(width: TVDetailActionMetrics.circleDiameter, height: TVDetailActionMetrics.circleDiameter)
                .contentTransition(.symbolEffect(.replace))
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
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
    let accessibilityLabel: String
    let action: () -> Void

    init(
        icon: String,
        iconActive: String? = nil,
        isActive: Bool = false,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.iconActive = iconActive
        self.isActive = isActive
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    private var resolvedIcon: String {
        if isActive, let iconActive { return iconActive }
        return icon
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: resolvedIcon)
                .font(.system(size: TVDetailActionMetrics.circleGlyphPointSize, weight: .semibold))
                .frame(width: TVDetailActionMetrics.circleDiameter, height: TVDetailActionMetrics.circleDiameter)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
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
    @ViewBuilder let moreMenu: () -> MoreMenu

    @Environment(\.resetFocus) private var resetFocus
    @State private var didResetInitialPlayFocus = false
    @State private var initialFocusSeasonKey: String?
    @State private var initialPlayFocusTask: Task<Void, Never>?
    @FocusState private var focusedAction: ActionID?

    var body: some View {
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
                    // Icon-only: next to a wide Play, a second labelled pill
                    // competed with it for the eye. The counterclockwise
                    // arrow is the platform's restart glyph, and the action
                    // stays named for VoiceOver.
                    TVCircleActionButton(
                        icon: "arrow.counterclockwise",
                        accessibilityLabel: "Start Over",
                        action: onStartOver
                    )
                    .focused($focusedAction, equals: .startOver)
                }
            }

            TVCircleActionButton(
                icon: "heart",
                iconActive: "heart.fill",
                isActive: isFavorite,
                accessibilityLabel: isFavorite ? "Remove from favorites" : "Add to favorites",
                action: onToggleFavorite
            )
            .focused($focusedAction, equals: .favorite)

            TVCircleActionButton(
                icon: "bookmark",
                iconActive: "bookmark.fill",
                isActive: inWatchlist,
                accessibilityLabel: inWatchlist ? "Remove from watchlist" : "Add to watchlist",
                action: onToggleWatchlist
            )
            .focused($focusedAction, equals: .watchlist)

            TVCircleActionButton(
                icon: "checkmark.circle",
                iconActive: "checkmark.circle.fill",
                isActive: isWatched,
                accessibilityLabel: isWatched ? watchedLabelUnmark : watchedLabelMark,
                action: onToggleWatched
            )
            .focused($focusedAction, equals: .watched)

            moreMenu()
                .focused($focusedAction, equals: .more)
        }
        .focused(rowFocused)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
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
                resetFocus(in: focusNamespace)
                await Task.yield()
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
