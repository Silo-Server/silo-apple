#if !os(tvOS)
import SwiftUI

/// "Sign in to…" on iPhone, iPad, and Mac (spec §5.4): saved servers, then
/// Add a New Server. A working plain list: WP5 finishes it.
struct SignInTargetScreen: View {
    var router: AppRouter
    let context: SignInContext
    /// An auth-state root with no Back: Cancel goes to where the sign-in
    /// started.
    var isRoot = false

    @State private var registry = ServerRegistry.shared

    private var users: SiloUserCoordinator { router.users }

    var body: some View {
        let model = SignInTargetViewModel(context: context, servers: registry.sortedEntries, snapshot: users.snapshot)
        List {
            Section {
                ForEach(model.rows) { row in
                    Button {
                        Task { await users.beginSignIn(serverID: row.id, context: context, router: router) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .font(.siloSubheadline)
                                .foregroundColor(.siloOnSurface)
                            Text(row.address)
                                .font(.siloCaption)
                                .foregroundColor(.siloSecondaryText)
                        }
                    }
                }
            }
            Section {
                Button(SignInTargetViewModel.addNewServerTitle) {
                    router.signInContext = context
                    router.navigate(to: .serverSetup)
                }
            }
        }
        .navigationTitle(SignInTargetViewModel.title)
        .toolbar {
            if isRoot, router.signInReturnPoint != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ConfirmationCopy.cancelTitle) {
                        Task { await users.cancelSignIn(router: router) }
                    }
                }
            }
        }
        .task {
            router.signInContext = context
            await users.reloadDirectory()
        }
    }
}
#endif
