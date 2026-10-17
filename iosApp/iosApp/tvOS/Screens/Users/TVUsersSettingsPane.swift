#if os(tvOS)
import SwiftUI

/// Settings › Users on Apple TV (spec §5.7): each user with its servers and
/// Sign Out, Rename, Remove from This Apple TV, then Add User. A working
/// plain screen: WP4 moves it into Settings as a category.
struct TVUsersSettingsPane: View {
    var router: AppRouter

    private var users: SiloUserCoordinator { router.users }

    var body: some View {
        let model = UsersSettingsViewModel(directory: users.directory, device: users.device)
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(UsersSettingsViewModel.title)
                    .font(.system(size: 38, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 18)

                ForEach(model.users) { user in
                    TVSettingsSectionHeader(user.name.uppercased())
                    ForEach(user.servers) { server in
                        Button {
                            if let key = server.key {
                                Task { await users.requestRemoval(.signIn(key), router: router) }
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(server.name)
                                        .font(.system(size: 26))
                                    if let username = server.username {
                                        Text(username)
                                            .font(.system(size: 19))
                                            .opacity(0.62)
                                    }
                                }
                                Spacer(minLength: 16)
                                Text(server.needsSignInAgain ? "Sign in again" : UsersSettingsViewModel.signOutTitle)
                                    .font(.system(size: 20, weight: .semibold))
                                    .opacity(0.72)
                            }
                        }
                        .buttonStyle(TVSettingsPaneRowStyle())
                        .disabled(server.key == nil)
                    }
                    Button(UsersSettingsViewModel.renameTitle) {
                        Task { await users.requestRename(user.id, router: router) }
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    Button(model.removeTitle) {
                        Task { await users.requestRemoval(.user(user.id), router: router) }
                    }
                    .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
                }

                TVSettingsSectionHeader(" ")
                Button {
                    Task { await users.startAddUser(router: router) }
                } label: {
                    Label(UsersSettingsViewModel.addUserTitle, systemImage: "plus")
                        .font(.system(size: 26))
                }
                .buttonStyle(TVSettingsPaneRowStyle())
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.vertical, 64)
            .frame(maxWidth: .infinity)
            .focusSection()
        }
        .background(SettingsBackdrop())
        .task { await users.reloadDirectory() }
    }
}
#endif
