#if os(tvOS)
import SwiftUI

/// Choose a Server on Apple TV (spec §5.3): this user's servers. A working
/// plain screen: WP4 builds it from the server list's row views.
struct TVChooseServerScreen: View {
    var router: AppRouter
    let userID: String
    var focusServerID: String?

    private var users: SiloUserCoordinator { router.users }
    @FocusState private var focused: Target?

    private enum Target: Hashable {
        case server(String)
        case addServer
    }

    var body: some View {
        let model = ChooseServerViewModel(directory: users.directory, userID: userID, focusServerID: focusServerID)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(model?.title ?? "Servers")
                    .font(.system(size: 52, weight: .heavy))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 12)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model?.rows ?? []) { row in
                        Button {
                            Task { await users.openServer(row.id, userID: userID, router: router) }
                        } label: {
                            HStack(spacing: 18) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(row.name)
                                        .font(.system(size: 28, weight: .semibold))
                                    if let username = row.username {
                                        Text(username)
                                            .font(.system(size: 20))
                                            .opacity(0.62)
                                    }
                                }
                                Spacer(minLength: 16)
                                if let status = row.status.label {
                                    Text(status)
                                        .font(.system(size: 20, weight: .semibold))
                                        .opacity(0.72)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(TVSettingsPaneRowStyle())
                        .focused($focused, equals: .server(row.id))
                        .accessibilityValue(row.status.label ?? "")
                        .contextMenu {
                            if let key = row.key {
                                Button(SignOutConfirmationCopy.signOutOfServerTitle(serverName: row.name),
                                       role: .destructive) {
                                    Task { await users.requestRemoval(.signIn(key), router: router) }
                                }
                            }
                        }
                    }

                    Button {
                        Task { await users.startSignIn(.addServer(userID: userID), router: router) }
                    } label: {
                        Label(ChooseServerViewModel.addServerTitle, systemImage: "plus")
                            .font(.system(size: 26, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .focused($focused, equals: .addServer)
                }
                .focusSection()

                Text("Press and hold a server to sign out of it")
                    .font(.system(size: 20))
                    .opacity(0.55)
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.vertical, 64)
            .frame(maxWidth: .infinity)
        }
        .defaultFocus($focused, model?.focusServerID.map(Target.server) ?? .addServer)
        .task { await users.reloadDirectory() }
        // A user removed while its servers show (its last sign-out): back
        // to where it was opened from. A root goes through the launch rules.
        .onChange(of: users.directory.isAvailable && users.directory.user(userID) == nil) { _, gone in
            if gone, !router.path.isEmpty { router.goBack() }
        }
    }
}
#endif
