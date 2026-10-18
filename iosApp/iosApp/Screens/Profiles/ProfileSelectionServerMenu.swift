#if !os(tvOS)
import SwiftUI

/// The server chip on Who's Watching for iPhone, iPad, and Mac (spec §5.8):
/// a menu with this user's servers and Add Server, the other users and Add
/// User, and Manage Users…. Before Silo users exist it offers Change server
/// only, as before.
struct ProfileSelectionServerMenu: View {
    var router: AppRouter

    private var users: SiloUserCoordinator { router.users }

    var body: some View {
        let serverURL = users.auth.serverRegistry.activeServerUrl
        let branding = ServerBrandingCache.branding(for: serverURL)
        let name = ServerBranding.displayName(branding, serverURL: serverURL)
        Menu {
            ServerChipMenuItems(router: router, model: ServerChipMenuModel(directory: users.directory),
                                hostLabel: ServerBranding.hostLabel(serverURL))
        } label: {
            MarqueeServerChipLabel(name: name, markURL: branding?.markURL)
        }
        .menuStyle(.button)
        .buttonStyle(.marqueePressable)
        .accessibilityLabel("\(name), server")
        .accessibilityHint("Shows your servers and the other users on this device.")
    }
}

/// What the chip menu lists, in order (spec §5.8). Kept apart from the
/// `Menu` so its sections can be drawn in rendered checks.
struct ServerChipMenuItems: View {
    var router: AppRouter
    let model: ServerChipMenuModel
    /// Names the servers section before Silo users exist.
    let hostLabel: String

    static let otherUsersTitle = "Other Users"

    private var users: SiloUserCoordinator { router.users }

    var body: some View {
        if model.showsUsers {
            Section(model.userName ?? hostLabel) {
                ForEach(model.servers) { server in
                    Button {
                        open(server)
                    } label: {
                        Label {
                            itemTitle(server.name, detail: server.needsSignInAgain
                                ? ChooseServerViewModel.Status.signInAgain.label : nil)
                        } icon: {
                            Image(systemName: server.isActive ? "checkmark" : "server.rack")
                        }
                    }
                    .accessibilityValue(server.isActive ? "Active" : "")
                }
                Button {
                    Task { await users.startAddServer(router: router) }
                } label: {
                    Label(ServerChipMenuModel.addServerTitle, systemImage: "plus")
                }
            }
            if model.otherUsers.isEmpty {
                Section { addUser }
            } else {
                Section(Self.otherUsersTitle) {
                    ForEach(model.otherUsers) { user in
                        Button {
                            Task { await users.openUser(user.id, router: router) }
                        } label: {
                            Label {
                                itemTitle(user.name, detail: user.needsSignInAgain
                                    ? user.detail + SiloUserNaming.separator + ChooseUserViewModel.signInAgainLabel
                                    : user.detail)
                            } icon: {
                                Image(systemName: "person.crop.circle")
                            }
                        }
                    }
                    addUser
                }
            }
            Section {
                Button {
                    router.navigate(to: .manageUsers)
                } label: {
                    Label(ServerChipMenuModel.manageUsersTitle, systemImage: "person.2")
                }
            }
        } else {
            Section(hostLabel) {
                Button {
                    router.navigate(to: .serverList)
                } label: {
                    Label(ServerChipMenuModel.changeServerTitle, systemImage: "server.rack")
                }
            }
        }
    }

    private var addUser: some View {
        Button {
            Task { await users.startAddUser(router: router) }
        } label: {
            Label(ServerChipMenuModel.addUserTitle, systemImage: "person.badge.plus")
        }
    }

    /// A menu item's title, with a second line where the platform's menus
    /// draw one (iPhone, iPad); the Mac's menus get it on the same line.
    @ViewBuilder
    private func itemTitle(_ title: String, detail: String?) -> some View {
        #if os(macOS)
        Text(detail.map { title + SiloUserNaming.separator + $0 } ?? title)
        #else
        Text(title)
        if let detail { Text(detail) }
        #endif
    }

    /// The server open now stays open; another one opens its Who's
    /// Watching, or its sign-in screen when it expired.
    private func open(_ server: ServerChipMenuModel.ServerItem) {
        guard !server.isActive, let userID = users.directory.currentUserID else { return }
        Task { await users.openServer(server.id, userID: userID, router: router) }
    }
}
#endif
