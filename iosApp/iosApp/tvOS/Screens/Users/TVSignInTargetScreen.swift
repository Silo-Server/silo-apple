#if os(tvOS)
import SwiftUI

/// "Sign in to…" on Apple TV (spec §5.4): saved servers, then Add a New
/// Server. A working plain screen: WP4 builds it from the server list's row
/// views.
struct TVSignInTargetScreen: View {
    var router: AppRouter
    let context: SignInContext
    /// An auth-state root, where Menu would leave the app: Cancel goes back
    /// to where the sign-in started instead.
    var isRoot = false

    private var users: SiloUserCoordinator { router.users }
    @State private var registry = ServerRegistry.shared
    @FocusState private var focused: Target?

    private enum Target: Hashable {
        case server(String)
        case addNewServer
        case cancel
    }

    private var canCancel: Bool { router.signInReturnPoint != nil }

    var body: some View {
        let model = SignInTargetViewModel(context: context, servers: registry.sortedEntries, snapshot: users.snapshot)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(SignInTargetViewModel.title)
                    .font(.system(size: 52, weight: .heavy))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 12)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.rows) { row in
                        Button {
                            Task { await users.beginSignIn(serverID: row.id, context: context, router: router) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(row.name)
                                    .font(.system(size: 28, weight: .semibold))
                                Text(row.address)
                                    .font(.system(size: 19))
                                    .opacity(0.62)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(TVSettingsPaneRowStyle())
                        .focused($focused, equals: .server(row.id))
                    }

                    Button {
                        router.signInContext = context
                        router.navigate(to: .serverSetup)
                    } label: {
                        Label(SignInTargetViewModel.addNewServerTitle, systemImage: "plus")
                            .font(.system(size: 26, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .focused($focused, equals: .addNewServer)

                    if canCancel {
                        Button {
                            Task { await users.cancelSignIn(router: router) }
                        } label: {
                            Text(ConfirmationCopy.cancelTitle)
                                .font(.system(size: 24))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(TVSettingsPaneRowStyle())
                        .focused($focused, equals: .cancel)
                    }
                }
                .focusSection()
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.vertical, 64)
            .frame(maxWidth: .infinity)
        }
        .defaultFocus($focused, model.rows.first.map { Target.server($0.id) } ?? .addNewServer)
        .onExitCommand(perform: isRoot && canCancel ? { Task { await users.cancelSignIn(router: router) } } : nil)
        .task {
            router.signInContext = context
            await users.reloadDirectory()
        }
    }
}
#endif
