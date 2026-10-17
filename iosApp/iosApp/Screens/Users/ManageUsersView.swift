#if !os(tvOS)
import SwiftUI

/// Settings › Users on iPhone, iPad, and Mac (spec §5.7, §5.8 Manage
/// Users…): each user with its servers and Sign Out, Rename, Remove, then
/// Add User. A working plain list: WP5 finishes it.
struct ManageUsersView: View {
    var router: AppRouter

    private var users: SiloUserCoordinator { router.users }

    var body: some View {
        let model = UsersSettingsViewModel(directory: users.directory, device: users.device)
        List {
            ForEach(model.users) { user in
                Section(user.name) {
                    ForEach(user.servers) { server in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                if let username = server.username {
                                    Text(username)
                                        .font(.siloCaption)
                                        .foregroundColor(.siloSecondaryText)
                                }
                            }
                            Spacer()
                            if let key = server.key {
                                Button(server.needsSignInAgain ? "Sign In Again" : UsersSettingsViewModel.signOutTitle) {
                                    Task { await users.requestRemoval(.signIn(key), router: router) }
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    Button(UsersSettingsViewModel.renameTitle) {
                        Task { await users.requestRename(user.id, router: router) }
                    }
                    Button(model.removeTitle, role: .destructive) {
                        Task { await users.requestRemoval(.user(user.id), router: router) }
                    }
                }
            }
            Section {
                Button(UsersSettingsViewModel.addUserTitle) {
                    Task { await users.startAddUser(router: router) }
                }
            }
        }
        .navigationTitle(UsersSettingsViewModel.title)
        .task { await users.reloadDirectory() }
    }
}
#endif
