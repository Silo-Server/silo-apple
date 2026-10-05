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

    /// Shared session cache so switching pages never refetches or flashes
    /// the avatar fallback.
    private let profileStore = CurrentProfileStore.shared
    #if os(iOS)
    @Environment(SiloControlClient.self) private var siloControl
    @State private var isShowingControlPicker = false
    #endif

    var body: some View {
        #if os(macOS)
        // The Mac sidebar carries Search and the profile menu.
        EmptyView()
        #else
        // Icons spaced evenly. Order is fixed: Search, Remote (iOS), Profile.
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
        #endif
    }
}

/// Plain icon button used for utility actions (Search) in the top bar.
/// The 44×44 frame keeps a comfortable tap target while the glyph itself
/// stays small and chrome-free.
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

/// Profile avatar opening the account menu (Watch Party, Requests, Settings,
/// Switch Profile, Switch Server, Sign Out).
struct ProfileAvatarMenu: View {
    @Environment(AppRouter.self) private var router
    let profile: UserProfile?
    /// Shows the profile name beside the avatar as a full-width row, for the
    /// Mac sidebar. The top-bar cluster keeps the avatar alone.
    var showsName = false
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

    private var avatarSize: CGFloat {
        #if os(macOS)
        SiloTheme.macSidebarAvatarSize
        #else
        30
        #endif
    }

    /// The default avatar fill is as dark as the Mac sidebar, so the row
    /// there uses the lighter tile grey to keep the circle visible.
    private var avatarFill: Color {
        showsName ? .siloIconTile : .siloSurfaceVariant
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
            HStack(spacing: SiloTheme.smallPadding) {
                ProfileAvatarView(
                    avatar: profile?.avatarEmoji,
                    imageUrl: profile?.avatarImageUrl,
                    name: profile?.name ?? "",
                    size: avatarSize,
                    backgroundColor: avatarFill
                )
                .frame(
                    width: showsName ? nil : SiloTheme.topBarIconHitSize,
                    height: SiloTheme.topBarIconHitSize
                )
                if showsName {
                    Text(profile?.name ?? "")
                        .font(.siloHeadline)
                        .foregroundStyle(Color.siloOnSurface)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
        }
        #if os(macOS)
        // The borderless style flattens a Mac menu label to bare text; the
        // plain button style keeps the avatar-and-name row.
        .menuStyle(.button)
        .buttonStyle(.plain)
        #else
        .menuStyle(.borderlessButton)
        #endif
        .accessibilityLabel("Profile menu")
    }
}
