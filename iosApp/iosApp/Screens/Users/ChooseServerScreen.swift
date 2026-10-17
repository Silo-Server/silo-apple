#if !os(tvOS)
import SwiftUI

/// Choose a Server on iPhone, iPad, and Mac (spec §5.3): this user's
/// servers. A working plain list: WP5 builds it from the server list's row
/// views.
struct ChooseServerScreen: View {
    var router: AppRouter
    let userID: String
    var focusServerID: String?

    private var users: SiloUserCoordinator { router.users }

    var body: some View {
        let model = ChooseServerViewModel(directory: users.directory, userID: userID, focusServerID: focusServerID)
        List {
            Section {
                ForEach(model?.rows ?? []) { row in
                    Button {
                        Task { await users.openServer(row.id, userID: userID, router: router) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.name)
                                    .font(.siloSubheadline)
                                    .foregroundColor(.siloOnSurface)
                                if let username = row.username {
                                    Text(username)
                                        .font(.siloCaption)
                                        .foregroundColor(.siloSecondaryText)
                                }
                            }
                            Spacer()
                            if let status = row.status.label {
                                Text(status)
                                    .font(.siloCaption)
                                    .foregroundColor(.siloSecondaryText)
                            }
                        }
                    }
                    .contextMenu {
                        if let key = row.key {
                            Button(SignOutConfirmationCopy.signOutOfServerTitle(serverName: row.name),
                                   role: .destructive) {
                                Task { await users.requestRemoval(.signIn(key), router: router) }
                            }
                        }
                    }
                }
            }
            Section {
                Button(ChooseServerViewModel.addServerTitle) {
                    Task { await users.startSignIn(.addServer(userID: userID), router: router) }
                }
            }
        }
        .navigationTitle(model?.title ?? "Servers")
        .task { await users.reloadDirectory() }
        // A user removed while its servers show (its last sign-out): back
        // to where it was opened from. A root goes through the launch rules.
        .onChange(of: users.directory.isAvailable && users.directory.user(userID) == nil) { _, gone in
            if gone, !router.path.isEmpty { router.goBack() }
        }
    }
}
#endif
