import Foundation

/// The server chip menu on Who's Watching for iOS, iPadOS, and macOS (spec
/// §5.8): the device's accounts, Add Account, and Manage Accounts….
struct AccountMenuModel: Equatable {
    struct Item: Equatable, Identifiable {
        let id: SiloAccountRef
        let name: String
        /// The email when known, the server, and "Sign in again" once the
        /// sign-in expired.
        let detail: String?
        let isCurrent: Bool
    }

    static let accountsTitle = "Accounts"
    static let addAccountTitle = "Add Account"
    static let manageAccountsTitle = "Manage Accounts…"
    static let separator = " · "

    let items: [Item]

    init(directory: SiloAccountDirectory) {
        items = directory.accounts.map { account in
            let parts = account.detailLines
                + (account.needsSignInAgain ? [ChooseAccountViewModel.signInAgainLabel] : [])
            return Item(
                id: account.id,
                name: account.name,
                detail: parts.isEmpty ? nil : parts.joined(separator: Self.separator),
                isCurrent: account.id == directory.currentAccountID
            )
        }
    }
}
