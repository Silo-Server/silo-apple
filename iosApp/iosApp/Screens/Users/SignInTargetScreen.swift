#if !os(tvOS)
import SwiftUI

/// "Sign in to…" on iPhone, iPad, and Mac (spec §5.4): the saved servers a
/// sign-in can use, in server setup's Recent style, then Add a New Server.
/// Add Server leaves out the user's own servers; Add User lists them all.
struct SignInTargetScreen: View {
    var router: AppRouter
    let context: SignInContext
    /// An auth-state root with no Back: Cancel goes to where the sign-in
    /// started.
    var isRoot = false

    /// The row whose action is running (a server's sign-in, or Cancel), so
    /// a second tap doesn't start another.
    @State private var busyItemID: String?

    private var users: SiloUserCoordinator { router.users }

    var body: some View {
        let model = SignInTargetViewModel(
            context: context,
            servers: users.auth.serverRegistry.sortedEntries,
            snapshot: users.snapshot
        )
        UserFlowPage(router: router, onCancel: cancel) { _ in
            MarqueeHeadline(title: SignInTargetViewModel.title,
                            lead: Self.lead(for: context, rows: model.rows, directory: users.directory),
                            alignment: .center)
            if !model.rows.isEmpty {
                UserFlowRowGroup {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { UserFlowRowDivider() }
                        ServerPickerRow(
                            name: row.name,
                            markName: row.name,
                            markURL: ServerBrandingCache.branding(for: row.address)?.markURL,
                            detail: ServerBranding.hostLabel(row.address),
                            isConnecting: busyItemID == row.id
                        ) {
                            run(row.id) {
                                _ = await users.beginSignIn(serverID: row.id, context: context, router: router)
                            }
                        }
                    }
                }
                .padding(.top, 32)
            }
            Button {
                router.signInContext = context
                router.navigate(to: .serverSetup)
            } label: {
                UserFlowAdditionLabel(title: SignInTargetViewModel.addNewServerTitle)
            }
            .buttonStyle(UserFlowCardButtonStyle(isAddition: true))
            .padding(.top, model.rows.isEmpty ? 32 : 12)
        } footer: {
            EmptyView()
        }
        .disabled(busyItemID != nil)
        .task {
            router.signInContext = context
            MarqueeScene.shared.showGeneric()
            await users.reloadDirectory()
        }
    }

    /// Cancel on a root that has somewhere to go back to.
    private var cancel: (() -> Void)? {
        guard isRoot, router.signInReturnPoint != nil else { return nil }
        return { run("cancel") { await users.cancelSignIn(router: router) } }
    }

    private func run(_ itemID: String, _ action: @escaping () async -> Void) {
        guard busyItemID == nil else { return }
        busyItemID = itemID
        Task {
            await action()
            busyItemID = nil
        }
    }

    /// What the sign-in is for, under the title.
    static func lead(for context: SignInContext, rows: [SignInTargetViewModel.Row],
                     directory: SiloUserDirectory) -> String {
        switch context {
        case .addUser:
            return rows.isEmpty
                ? "Add the server the new user signs in to."
                : "Choose the server the new user signs in to."
        case .addServer(let userID):
            let name = directory.user(userID)?.name
            if rows.isEmpty {
                return name.map { "Add a server for \($0)." } ?? "Add a server."
            }
            return name.map { "Choose a server to add to \($0)." } ?? "Choose a server to add."
        case .firstRun, .signInAgain:
            return rows.isEmpty
                ? "Add the server you use for Silo."
                : "Choose a saved server, or add a new one."
        }
    }
}
#endif
