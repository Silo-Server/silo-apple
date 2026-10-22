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

/// Profile avatar opening the account menu: who is signed in and to which
/// server, then Watch Party, Requests, Settings, Switch Profile, Switch Server
/// and Sign Out.
///
/// On iPhone and iPad the menu is a panel (``ProfileMenuPanel``), because a
/// system menu cannot show the profile picture or a bold name over the
/// server. The Mac keeps the system menu.
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

    #if os(iOS)
    @State private var isPanelPresented = false
    /// Runs once the panel has closed, so navigation never starts under it.
    @State private var pendingAction: (() -> Void)?
    #endif

    /// Capability-gated: the Requests row exists only when the server has
    /// the feature enabled (older servers 404 the probe and read as off).
    private var requestsEnabled: Bool {
        RequestsFeatureStore.shared.isEnabled
    }

    private var serverName: String? {
        ServerRegistry.shared.activeServer?.displayName
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
        #if os(iOS)
        Button {
            isPanelPresented = true
        } label: {
            avatarLabel
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPanelPresented, arrowEdge: .top) {
            ProfileMenuPanel(
                profile: profile,
                serverName: serverName,
                sections: panelSections,
                choose: { row in
                    pendingAction = row.action
                    isPanelPresented = false
                }
            )
            .presentationCompactAdaptation(.popover)
        }
        .onChange(of: isPanelPresented) { _, isPresented in
            guard !isPresented, let action = pendingAction else { return }
            pendingAction = nil
            action()
        }
        .accessibilityLabel("Profile menu")
        #else
        Menu {
            // Who and where, as the Apple TV profile menu shows them. Not an
            // action: Switch Profile and Switch Server sit below.
            Section {
                Button {} label: {
                    Text(profile?.name ?? "Profile")
                    if let serverName {
                        Text(serverName)
                    }
                }
                .disabled(true)
            }

            #if os(tvOS)
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
            avatarLabel
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
        #endif
    }

    private var avatarLabel: some View {
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

    #if os(iOS)
    /// The panel's rows, grouped as the system menu groups them.
    private var panelSections: [[ProfileMenuPanel.Row]] {
        var features: [ProfileMenuPanel.Row] = []
        if WatchPartyEntry.isAvailable {
            features.append(.init(
                title: WatchPartySession.shared.isEngaged ? "Return to Watch Party" : "Watch Party",
                systemImage: "person.3"
            ) { router.navigate(to: .watchParty) })
        }
        if requestsEnabled {
            features.append(.init(title: "Requests", systemImage: "sparkles", action: onOpenRequests))
        }
        return [
            features,
            [.init(title: "Settings", systemImage: "gearshape", action: onOpenSettings)],
            [
                .init(title: "Switch Profile", systemImage: "person.2", action: onSwitchProfile),
                .init(title: "Switch Server", systemImage: "server.rack", action: onSwitchServer),
                .init(
                    title: "Sign Out",
                    systemImage: "rectangle.portrait.and.arrow.right",
                    isDestructive: true,
                    action: onSignOut
                ),
            ],
        ].filter { !$0.isEmpty }
    }
    #endif
}

#if os(iOS)
/// The account menu on iPhone and iPad: the profile picture beside a bold
/// profile name with the server underneath, as on Apple TV, then the actions.
struct ProfileMenuPanel: View {
    struct Row: Identifiable {
        let title: String
        let systemImage: String
        var isDestructive = false
        let action: () -> Void

        var id: String { title }
    }

    let profile: UserProfile?
    let serverName: String?
    let sections: [[Row]]
    let choose: (Row) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ForEach(Array(sections.enumerated()), id: \.offset) { _, rows in
                Divider()
                ForEach(rows) { row in
                    Button {
                        choose(row)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: row.systemImage)
                                .frame(width: 24)
                            Text(row.title)
                            Spacer(minLength: 0)
                        }
                        .font(.body)
                        .foregroundStyle(row.isDestructive ? Color.siloErrorInk : Color.siloOnSurface)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 290)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ProfileAvatarView(
                avatar: profile?.avatarEmoji,
                imageUrl: profile?.avatarImageUrl,
                name: profile?.name ?? "",
                size: 44,
                backgroundColor: .siloIconTile
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(profile?.name ?? "Profile")
                    .font(.headline)
                    .foregroundStyle(Color.siloOnSurface)
                    .lineLimit(1)
                if let serverName {
                    Text(serverName)
                        .font(.subheadline)
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
#endif
