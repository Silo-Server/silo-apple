#if os(tvOS)
import SwiftUI

// MARK: - Primary pill

/// VidHub-style primary play button. Solid white, large, dominant —
/// this is the one element the eye should land on first in the hero.
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
        .buttonStyle(TVPillButtonStyle(kind: .primary, focusTreatment: .compact))
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
        .buttonStyle(TVPillButtonStyle(kind: .secondary, focusTreatment: .compact))
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
        .background(RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous).fill(Color.black.opacity(0.42)))
        .overlay(
            RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1.2)
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
                .font(.system(size: 28, weight: .semibold))
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
                .font(.system(size: 28, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(TVCircleButtonStyle())
        .accessibilityLabel(accessibilityLabel)
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
                RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous).stroke(
                    innerBorderColor,
                    lineWidth: innerBorderWidth
                )
            )
            .background(
                RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous).fill(background)
            )
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius + 2, style: .continuous)
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
                color: Color.siloOnSurface.opacity(focusGlowOpacity),
                radius: focusGlowRadius,
                y: 0
            )
            .focusEffectDisabled()
            .animation(SiloTheme.springAnimation, value: isFocused)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
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
            .frame(width: 72, height: 72)
            .background(
                RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous).fill(
                    isFocused ? .white : Color.white.opacity(0.10)
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius, style: .continuous).stroke(
                    isFocused ? Color.black.opacity(0.12) : Color.white.opacity(0.34),
                    lineWidth: isFocused ? 1.6 : 1.4
                )
            )
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: SiloTheme.smallCornerRadius + 2, style: .continuous)
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
                color: Color.siloOnSurface.opacity(isFocused ? 0.15 : 0),
                radius: isFocused ? 10 : 0,
                y: 0
            )
            .focusEffectDisabled()
            .animation(SiloTheme.springAnimation, value: isFocused)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
    }

    private var scale: CGFloat {
        let base: CGFloat = isFocused ? 1.1 : 1.0
        return configuration.isPressed ? base * 0.95 : base
    }
}
#endif
