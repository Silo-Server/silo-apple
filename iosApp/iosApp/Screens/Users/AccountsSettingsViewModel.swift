import Foundation

/// Settings › Accounts (spec §5.7): each account with its username, email,
/// and server; Sign Out (or Sign In Again once it expired) and Remove per
/// account; Add Account at the end.
struct AccountsSettingsViewModel: Equatable {
    struct Row: Equatable, Identifiable {
        let id: SiloAccountRef
        let name: String
        /// The email when known, then the server.
        let detailLines: [String]
        let isCurrent: Bool
        let needsSignInAgain: Bool
        /// A pending legacy account has no saved sign-in to sign out of yet;
        /// only Remove reaches it.
        var canSignOut: Bool { id.signInKey != nil && !needsSignInAgain }
    }

    static let title = "Accounts"
    static let addAccountTitle = "Add Account"
    static let signOutTitle = "Sign Out"
    static let signInAgainTitle = "Sign In Again"
    static let currentLabel = "Current"

    let rows: [Row]
    let removeTitle: String

    init(directory: SiloAccountDirectory, device: SignOutConfirmationCopy.Device) {
        removeTitle = SignOutConfirmationCopy.removeFromDeviceTitle(device: device)
        rows = directory.accounts.map { account in
            Row(
                id: account.id,
                name: account.name,
                detailLines: account.detailLines,
                isCurrent: account.id == directory.currentAccountID,
                needsSignInAgain: account.needsSignInAgain
            )
        }
    }

    /// Only a shared device (Apple TV) says everyone on it shares them, as
    /// the sign-out copy does.
    static func footer(device: SignOutConfirmationCopy.Device) -> String {
        guard device.isShared else {
            return "Signing out keeps an account here so you can sign in again. Removing it forgets it on this \(device.noun)."
        }
        return "Everyone who uses Silo on this \(device.noun) shares these accounts. Signing out of or removing an account affects everyone here."
    }
}
