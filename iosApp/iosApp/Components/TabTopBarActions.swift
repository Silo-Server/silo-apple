import SwiftUI

/// The shared right-hand action cluster used at the top of tab-root screens:
/// Search and a profile-avatar menu with Settings / Switch Profile / Sign Out.
///
/// Each tab renders its own leading content (e.g. library selector on the
/// Libraries tab, a static title on Home) and places this view on the
/// trailing side of a single `HStack` row.
struct TabTopBarActions: View {
    let profile: UserProfile?
    let onSearch: () -> Void
    let onOpenSettings: () -> Void
    /// Opens the media-requests hub. The menu row only renders when the
    /// server reports `requests_enabled`, so the closure is inert otherwise.
    let onOpenRequests: () -> Void
    let onSwitchProfile: () -> Void
    let onSwitchServer: () -> Void
    let onSignOut: () -> Void
    var usesGlassCircles = false

    var body: some View {
        // Plain icon glyphs (no glass chip) spaced evenly, matching the
        // clean top-right cluster used by Plex. The profile avatar is the
        // only filled shape, so it reads as the account control.
        HStack(spacing: ContinuumTheme.topBarIconSpacing) {
            TopBarIconButton(
                systemImage: "magnifyingglass",
                accessibilityLabel: "Search",
                usesGlassCircle: usesGlassCircles,
                action: onSearch
            )
            ProfileAvatarMenu(
                profile: profile,
                onOpenSettings: onOpenSettings,
                onOpenRequests: onOpenRequests,
                onSwitchProfile: onSwitchProfile,
                onSwitchServer: onSwitchServer,
                onSignOut: onSignOut,
                usesGlassCircle: usesGlassCircles
            )
        }
    }
}

/// Plain icon button used for utility actions (Search) in the top bar.
/// The 44×44 frame keeps a comfortable tap target while the glyph itself
/// stays small and chrome-free, matching Plex's top-right icons.
private struct TopBarIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let usesGlassCircle: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            buttonLabel
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var buttonLabel: some View {
        let icon = Image(systemName: systemImage)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(.continuumOnSurface)
            .frame(
                width: ContinuumTheme.topBarIconHitSize,
                height: ContinuumTheme.topBarIconHitSize
            )
            .contentShape(Circle())

        if usesGlassCircle {
            icon.siloGlass(
                in: Circle(),
                tint: Color.black.opacity(0.18),
                interactive: true
            )
        } else {
            icon
        }
    }
}

/// Profile avatar rendered via `ProfileAvatarView` (which handles DiceBear
/// presets, URLs, emojis, and initials uniformly). Wraps a Menu exposing
/// Settings / Switch Profile / Sign Out so the user can reach app settings
/// and manage their account without leaving the current tab.
private struct ProfileAvatarMenu: View {
    let profile: UserProfile?
    let onOpenSettings: () -> Void
    let onOpenRequests: () -> Void
    let onSwitchProfile: () -> Void
    let onSwitchServer: () -> Void
    let onSignOut: () -> Void
    let usesGlassCircle: Bool

    /// Capability-gated: the Requests row exists only when the server has
    /// the feature enabled (older servers 404 the probe and read as off).
    private var requestsEnabled: Bool {
        RequestsFeatureStore.shared.isEnabled
    }

    var body: some View {
        Menu {
            if requestsEnabled {
                Button {
                    onOpenRequests()
                } label: {
                    Label("Requests", systemImage: "sparkles")
                }

                Divider()
            }

            Button {
                onOpenSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Divider()

            Button {
                onSwitchProfile()
            } label: {
                Label("Switch Profile", systemImage: "person.2")
            }
            Button {
                onSwitchServer()
            } label: {
                Label("Switch Server", systemImage: "server.rack")
            }
            Button(role: .destructive) {
                onSignOut()
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: { avatarLabel }
        .menuStyle(.borderlessButton)
    }

    private var avatarLabel: some View {
        ProfileAvatarView(
            avatar: profile?.avatarEmoji,
            imageUrl: profile?.avatarImageUrl,
            name: profile?.name ?? "",
            size: usesGlassCircle ? ContinuumTheme.topBarIconHitSize : 36
        )
    }
}
