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
                    let icon = server.isActive ? "checkmark" : "server.rack"
                    Button {
                        open(server)
                    } label: {
                        // Written out in the label itself: iOS menus read a
                        // second Text there as the item's subtitle, but show
                        // only the first one inside a Label or a helper view.
                        #if os(macOS)
                        Label(Self.oneLine(server.name, server.detail), systemImage: icon)
                        #else
                        Text(server.name)
                        if let detail = server.detail { Text(detail) }
                        Image(systemName: icon)
                        #endif
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
                            #if os(macOS)
                            Label(Self.oneLine(user.name, user.detailLine), systemImage: "person.crop.circle")
                            #else
                            Text(user.name)
                            Text(user.detailLine)
                            Image(systemName: "person.crop.circle")
                            #endif
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

    /// A menu item's title with its detail on the same line, for the Mac's
    /// menus, which draw no second line.
    static func oneLine(_ title: String, _ detail: String?) -> String {
        detail.map { title + SiloUserNaming.separator + $0 } ?? title
    }

    /// The server open now stays open; another one opens its Who's
    /// Watching, or its sign-in screen when it expired.
    private func open(_ server: ServerChipMenuModel.ServerItem) {
        guard !server.isActive, let userID = users.directory.currentUserID else { return }
        Task { await users.openServer(server.id, userID: userID, router: router) }
    }
}
#endif
