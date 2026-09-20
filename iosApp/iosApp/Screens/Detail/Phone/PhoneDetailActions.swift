#if !os(tvOS)
import SwiftUI

// MARK: - Primary play

/// Solid-white capsule play button. Phone-sized — comfortable 52pt
/// touch target with the play icon and label sitting inline.
///
/// `fullWidth` lets the button expand to its container — used in the
/// Apple-TV-style centered hero where Play is the dominant CTA.
struct PhonePrimaryPillButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    var fullWidth: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.body.bold())
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundColor(.black)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.horizontal, fullWidth ? 24 : 24)
            .padding(.vertical, 12)
            .frame(minHeight: 52)
            .background(Capsule().fill(Color.white))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Circle action button

/// Compact icon-only circle button (favorite, watchlist, watched). Used
/// to the right of the play pills. 44pt circular touch target.
struct PhoneCircleActionButton: View {
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
                .font(.callout.weight(.semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isActive ? 0.18 : 0.10))
                        .overlay(
                            Circle().stroke(
                                Color.white.opacity(isActive ? 0.55 : 0.25),
                                lineWidth: 1
                            )
                        )
                )
                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Circle menu (overflow)

/// Circle button that opens a Menu — used for episode → series/season
/// jumps so we don't crowd the primary action row.
struct PhoneCircleMenuButton<MenuContent: View>: View {
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
                .font(.callout.weight(.semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.10))
                        .overlay(
                            Circle().stroke(Color.white.opacity(0.25), lineWidth: 1)
                        )
                )
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

#endif
