#if os(tvOS)
import SwiftUI

// MARK: - Primary pill

/// VidHub-style primary play button. Solid white, large, dominant —
/// this is the one element the eye should land on first in the hero.
struct TVPrimaryPillButton: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    let action: () -> Void
    /// Optional focus binding so the owning detail view can both observe and
    /// claim this button's focus. Combined with `.defaultFocus(…priority:
    /// .userInitiated)` on the scroll container, this is the reliable way to
    /// make Play win initial focus over the geometrically-higher synopsis —
    /// `prefersDefaultFocus(_:in:)` loses to geometry in practice here.
    var focused: FocusState<Bool>.Binding? = nil

    var body: some View {
        Button(action: action) {
            TVPrimaryPillLabel(icon: icon, title: title, subtitle: subtitle)
        }
        .buttonStyle(TVPillButtonStyle(kind: .primary, focusTreatment: .compact))
        .applyOptionalFocus(focused)
    }
}

private struct TVPrimaryPillLabel: View {
    let icon: String
    let title: String
    let subtitle: String?

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 31, weight: .bold))
                .frame(width: 36, height: 36)
            if isFocused {
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
                    .transition(.opacity.combined(with: .move(edge: .leading)))
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVSecondaryPillLabel(
                icon: icon,
                title: title,
                collapsesWhenUnfocused: collapsesWhenUnfocused
            )
        }
        .buttonStyle(TVPillButtonStyle(
            kind: .secondary,
            focusTreatment: .compact,
            collapsesWhenUnfocused: collapsesWhenUnfocused
        ))
    }
}

private struct TVSecondaryPillLabel: View {
    let icon: String
    let title: String
    let collapsesWhenUnfocused: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .semibold))
                .frame(width: 36, height: 36, alignment: .center)
            if !collapsesWhenUnfocused || isFocused {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isFocused)
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
        .background(RoundedRectangle(cornerRadius: ContinuumTheme.smallCornerRadius, style: .continuous).fill(Color.black.opacity(0.42)))
        .overlay(
            RoundedRectangle(cornerRadius: ContinuumTheme.smallCornerRadius, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1.2)
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
                .font(.system(size: 31, weight: .semibold))
                .frame(width: 38, height: 38, alignment: .center)
                .contentTransition(.symbolEffect(.replace))
        }
        .menuStyle(.button)
        .buttonStyle(TVCircleButtonStyle())
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
            TVExpandingCircleLabel(icon: resolvedIcon, title: title)
        }
        .buttonStyle(TVPillButtonStyle(
            kind: .secondary,
            focusTreatment: .compact,
            collapsesWhenUnfocused: true
        ))
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct TVExpandingCircleLabel: View {
    let icon: String
    let title: String

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 31, weight: .semibold))
                .frame(width: 36, height: 36, alignment: .center)
                .contentTransition(.symbolEffect(.replace))
            if isFocused {
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isFocused)
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
    let playSubtitle: String?
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
    /// Stable identity for the detail page. A newly opened content page gets
    /// one bounded Play-focus claim; changing seasons within that page does
    /// not steal focus back from the season row.
    let focusResetKey: String
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
                    subtitle: playSubtitle,
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
                    TVSecondaryPillButton(
                        icon: "backward.end.fill",
                        title: "Start Over",
                        collapsesWhenUnfocused: true,
                        action: onStartOver
                    )
                    .focused($focusedAction, equals: .startOver)
                }
            }

            TVCircleActionButton(
                icon: "heart",
                iconActive: "heart.fill",
                isActive: isFavorite,
                title: isFavorite ? "Remove Favorite" : "Favorites",
                accessibilityLabel: isFavorite ? "Remove from favorites" : "Add to favorites",
                action: onToggleFavorite
            )
            .focused($focusedAction, equals: .favorite)

            TVCircleActionButton(
                icon: "bookmark",
                iconActive: "bookmark.fill",
                isActive: inWatchlist,
                title: inWatchlist ? "Remove from Watchlist" : "Watchlist",
                accessibilityLabel: inWatchlist ? "Remove from watchlist" : "Add to watchlist",
                action: onToggleWatchlist
            )
            .focused($focusedAction, equals: .watchlist)

            TVCircleActionButton(
                icon: "checkmark.circle",
                iconActive: "checkmark.circle.fill",
                isActive: isWatched,
                title: isWatched ? watchedLabelUnmark : watchedLabelMark,
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

    init(
        kind: Kind,
        focusTreatment: FocusTreatment = .hero,
        collapsesWhenUnfocused: Bool = false
    ) {
        self.kind = kind
        self.focusTreatment = focusTreatment
        self.collapsesWhenUnfocused = collapsesWhenUnfocused
    }

    func makeBody(configuration: Configuration) -> some View {
        TVPillButtonBody(
            configuration: configuration,
            kind: kind,
            focusTreatment: focusTreatment,
            collapsesWhenUnfocused: collapsesWhenUnfocused
        )
    }
}

private struct TVPillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: TVPillButtonStyle.Kind
    let focusTreatment: TVPillButtonStyle.FocusTreatment
    let collapsesWhenUnfocused: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundColor(foreground)
            .padding(.horizontal, horizontalPadding)
            .frame(height: 76)
            .overlay(
                Capsule().stroke(
                    innerBorderColor,
                    lineWidth: innerBorderWidth
                )
            )
            .background(
                Capsule().fill(background)
            )
            .overlay {
                if isFocused {
                    Capsule()
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
        case .primary: return isFocused ? 70 : 20
        case .secondary: return collapsesWhenUnfocused && !isFocused ? 20 : 40
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

// MARK: - Circle ButtonStyle

struct TVCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TVCircleButtonBody(configuration: configuration)
    }
}

private struct TVCircleButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundColor(isFocused ? .black : .white)
            .frame(width: 76, height: 76)
            .background(
                Circle().fill(
                    isFocused ? .white : Color.white.opacity(0.10)
                )
            )
            .overlay(
                Circle().stroke(
                    isFocused ? Color.black.opacity(0.12) : Color.white.opacity(0.34),
                    lineWidth: isFocused ? 1.6 : 1.4
                )
            )
            .overlay {
                if isFocused {
                    Circle()
                        .stroke(Color.white.opacity(0.96), lineWidth: 3)
                        .padding(-5)
                }
            }
            .scaleEffect(scale)
            .shadow(
                color: .black.opacity(isFocused ? 0.34 : 0.0),
                radius: isFocused ? 16 : 0,
                y: isFocused ? 6 : 0
            )
            .shadow(
                color: Color.continuumOnSurface.opacity(isFocused ? 0.15 : 0),
                radius: isFocused ? 10 : 0,
                y: 0
            )
            .focusEffectDisabled()
            .animation(.easeInOut(duration: 0.18), value: isFocused)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: configuration.isPressed)
    }

    private var scale: CGFloat {
        let base: CGFloat = isFocused ? 1.1 : 1.0
        return configuration.isPressed ? base * 0.95 : base
    }
}
#endif
