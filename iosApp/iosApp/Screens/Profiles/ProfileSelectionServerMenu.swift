#if !os(tvOS)
import SwiftUI

/// The server chip on Who's Watching for iPhone, iPad, and Mac (spec §5.8):
/// this user's servers and Add Server, other users and Add User, and Manage
/// Users…. Before Silo users exist it offers Change server only. WP5
/// finishes it.
struct ProfileSelectionServerMenu: View {
    var router: AppRouter

    private var users: SiloUserCoordinator { router.users }

    var body: some View {
        let serverURL = AuthService.shared.serverUrl
        let branding = ServerBrandingCache.branding(for: serverURL)
        let name = ServerBranding.displayName(branding, serverURL: serverURL)
        let model = ServerChipMenuModel(directory: users.directory)
        Menu {
            if model.showsUsers {
                Section(model.userName ?? ServerBranding.hostLabel(serverURL)) {
                    ForEach(model.servers) { server in
                        Button {
                            guard let userID = users.directory.currentUserID else { return }
                            Task { await users.openServer(server.id, userID: userID, router: router) }
                        } label: {
                            Label(server.needsSignInAgain ? "\(server.name) (Sign in again)" : server.name,
                                  systemImage: server.isActive ? "checkmark" : "server.rack")
                        }
                    }
                    Button {
                        Task { await users.startAddServer(router: router) }
                    } label: {
                        Label(ServerChipMenuModel.addServerTitle, systemImage: "plus")
                    }
                }
                Section {
                    ForEach(model.otherUsers) { user in
                        Button {
                            Task { await users.openUser(user.id, router: router) }
                        } label: {
                            Label("\(user.name) · \(user.detail)", systemImage: "person")
                        }
                    }
                    Button {
                        Task { await users.startAddUser(router: router) }
                    } label: {
                        Label(ServerChipMenuModel.addUserTitle, systemImage: "person.badge.plus")
                    }
                }
                Button {
                    router.navigate(to: .manageUsers)
                } label: {
                    Label(ServerChipMenuModel.manageUsersTitle, systemImage: "person.2")
                }
            } else {
                Section(ServerBranding.hostLabel(serverURL)) {
                    Button {
                        router.navigate(to: .serverList)
                    } label: {
                        Label(ServerChipMenuModel.changeServerTitle, systemImage: "server.rack")
                    }
                }
            }
        } label: {
            MarqueeServerChipLabel(name: name, markURL: branding?.markURL)
        }
        .menuStyle(.button)
        .buttonStyle(.marqueePressable)
        .accessibilityLabel("\(name), server. Double-tap to change.")
    }
}
#endif
