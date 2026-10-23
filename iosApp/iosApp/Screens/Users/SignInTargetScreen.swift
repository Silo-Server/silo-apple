#if !os(tvOS)
import SwiftUI

/// "Sign in to…" on iPhone, iPad, and Mac (spec §5.4): the saved servers a
/// sign-in can use, in server setup's Recent style, then Add a New Server.
struct SignInTargetScreen: View {
    var router: AppRouter
    let context: SignInContext
    /// An auth-state root with no Back: Cancel goes to where the sign-in
    /// started.
    var isRoot = false

    /// The row whose action is running (a server's sign-in, or Cancel), so
    /// a second tap doesn't start another.
    @State private var busyItemID: String?
    /// Each listed server's logo, by address.
    @State private var marks: [String: URL] = [:]

    private var accounts: SiloAccountCoordinator { router.accounts }

    var body: some View {
        let model = SignInTargetViewModel(
            context: context,
            servers: accounts.auth.serverRegistry.sortedEntries
        )
        UserFlowPage(router: router, onCancel: cancel) { _ in
            MarqueeHeadline(title: SignInTargetViewModel.title,
                            lead: Self.lead(for: context, rows: model.rows),
                            alignment: .center)
            if !model.rows.isEmpty {
                UserFlowRowGroup {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { UserFlowRowDivider() }
                        ServerPickerRow(
                            name: row.name,
                            markURL: marks[row.address],
                            detail: ServerBranding.hostLabel(row.address),
                            isConnecting: busyItemID == row.id
                        ) {
                            run(row.id) {
                                _ = await accounts.beginSignIn(serverID: row.id, context: context, router: router)
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
            await accounts.reloadDirectory()
        }
        // Restarted, and the earlier load cancelled, when the servers change.
        .task(id: accounts.auth.serverRegistry.sortedEntries.map(\.url)) {
            let addresses = accounts.auth.serverRegistry.sortedEntries.map(\.url)
            marks = ServerBrandingLoader.cachedMarks(for: addresses)
            await ServerBrandingLoader.loadCurrentMarks(for: addresses) { marks[$0] = $1 }
        }
    }

    /// Cancel on a root that has somewhere to go back to.
    private var cancel: (() -> Void)? {
        guard isRoot, router.signInReturnPoint != nil else { return nil }
        return { run("cancel") { await accounts.cancelSignIn(router: router) } }
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
    static func lead(for context: SignInContext, rows: [SignInTargetViewModel.Row]) -> String {
        switch context {
        case .addAccount:
            return rows.isEmpty
                ? "Add the server the account signs in to."
                : "Choose the server the account signs in to, or add a new one."
        case .firstRun, .signInAgain:
            return rows.isEmpty
                ? "Add the server you use for Silo."
                : "Choose a saved server, or add a new one."
        }
    }
}
#endif
