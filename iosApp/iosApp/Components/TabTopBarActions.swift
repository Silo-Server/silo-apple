import SwiftUI

/// The shared right-hand action cluster used at the top of tab-root screens:
/// Search, the iOS TV remote control, and a profile-avatar menu with
/// Settings / Switch Profile / Sign Out. Every root page renders the same
/// three controls so the header reads identically across Home, Libraries,
/// For You, and Calendar.
///
/// Each tab renders its own leading content (e.g. library selector on the
/// Libraries tab, the wordmark on Home) and places this view on the
/// trailing side of a single `HStack` row.
struct TabTopBarActions: View {
    let onSearch: () -> Void
    let onOpenSettings: () -> Void
    /// Opens the media-requests hub. The menu row only renders when the
    /// server reports `requests_enabled`, so the closure is inert otherwise.
    let onOpenRequests: () -> Void
    let onSwitchProfile: () -> Void
    let onSwitchServer: () -> Void
    let onSignOut: () -> Void
    /// iOS 26: group Search and Remote in one Liquid Glass capsule, the way
    /// native toolbars group related items. The avatar stays separate.
    var groupsInGlass = false

    /// Shared session cache so switching pages never refetches or flashes
    /// the avatar fallback.
    private let profileStore = CurrentProfileStore.shared
    #if os(iOS)
    @Environment(SiloControlClient.self) private var siloControl
    @State private var isShowingControlPicker = false
    #endif

    var body: some View {
        // Icons spaced evenly, matching the clean top-right cluster used by
        // Plex. Order is fixed: Search, Remote (iOS), Profile.
        HStack(spacing: groupsInGlass ? 10 : SiloTheme.topBarIconSpacing) {
            utilityButtons
                .modifier(TopBarGlassGroup(isEnabled: groupsInGlass))
            ProfileAvatarMenu(
                profile: profileStore.profile,
                onOpenSettings: onOpenSettings,
                onOpenRequests: onOpenRequests,
                onSwitchProfile: onSwitchProfile,
                onSwitchServer: onSwitchServer,
                onSignOut: onSignOut
            )
        }
        #if os(iOS)
        .sheet(isPresented: $isShowingControlPicker) {
            SiloControlTargetPickerView(request: nil, controller: siloControl)
        }
        #endif
        // No-op once cached; covers a page shown before the session-level
        // load finished.
        .task { await profileStore.refresh() }
    }
}

extension TabTopBarActions {
    fileprivate var utilityButtons: some View {
        HStack(spacing: SiloTheme.topBarIconSpacing) {
            TopBarIconButton(
                systemImage: "magnifyingglass",
                accessibilityLabel: "Search",
                action: onSearch
            )
            #if os(iOS)
            SiloControlModeButton(controller: siloControl) {
                isShowingControlPicker = true
            }
            #endif
        }
    }
}

private struct TopBarGlassGroup: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled, #available(iOS 26.0, macOS 26.0, *) {
            content
                .padding(.horizontal, 2)
                .siloGlass(in: Capsule(), interactive: true)
        } else {
            content
        }
    }
}

/// Plain icon button used for utility actions (Search) in the top bar.
/// The 44×44 frame keeps a comfortable tap target while the glyph itself
/// stays small and chrome-free, matching Plex's top-right icons.
private struct TopBarIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.siloOnSurface)
                .frame(width: SiloTheme.topBarIconHitSize, height: SiloTheme.topBarIconHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Profile avatar rendered via `ProfileAvatarView` (which handles DiceBear
/// presets, URLs, emojis, and initials uniformly). Wraps a Menu exposing
/// Settings / Switch Profile / Sign Out so the user can reach app settings
/// and manage their account without leaving the current tab.
private struct ProfileAvatarMenu: View {
    @Environment(AppRouter.self) private var router
    let profile: UserProfile?
    let onOpenSettings: () -> Void
    let onOpenRequests: () -> Void
    let onSwitchProfile: () -> Void
    let onSwitchServer: () -> Void
    let onSignOut: () -> Void

    /// Capability-gated: the Requests row exists only when the server has
    /// the feature enabled (older servers 404 the probe and read as off).
    private var requestsEnabled: Bool {
        RequestsFeatureStore.shared.isEnabled
    }

    var body: some View {
        Menu {
            #if os(iOS) || os(tvOS)
            if WatchPartyEntry.isAvailable {
                Button(WatchPartySession.shared.isEngaged ? "Return to Watch Party" : "Watch Party", systemImage: "person.3") { router.navigate(to: .watchParty) }
            }
            #endif
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
        } label: {
            ProfileAvatarView(
                avatar: profile?.avatarEmoji,
                imageUrl: profile?.avatarImageUrl,
                name: profile?.name ?? "",
                size: 30
            )
            .frame(
                width: SiloTheme.topBarIconHitSize,
                height: SiloTheme.topBarIconHitSize
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Profile menu")
    }
}
