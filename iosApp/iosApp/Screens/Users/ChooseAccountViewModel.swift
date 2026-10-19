import Foundation

/// What Choose an Account shows (spec §5.2): one card per account, then Add
/// Account, with the hold-to-remove hint. Pure, built from
/// `SiloAccountDirectory`.
struct ChooseAccountViewModel: Equatable {
    struct Card: Equatable, Identifiable {
        let id: SiloAccountRef
        /// The username, else the server's name.
        let name: String
        /// The email when known, then the server's name.
        let detailLines: [String]
        /// The account's cached profiles, at most `maxAvatars`.
        let avatars: [SavedSignInProfile]
        /// The server's address, for avatars stored as paths on it.
        let serverAddress: String
        /// The account this Apple TV user (or device) is linked to.
        let isLastUsed: Bool
        /// The sign-in expired.
        let needsSignInAgain: Bool

        /// What VoiceOver reads after the name.
        var accessibilityValue: String {
            (detailLines
                + (isLastUsed ? [ChooseAccountViewModel.lastUsedLabel] : [])
                + (needsSignInAgain ? [ChooseAccountViewModel.signInAgainLabel] : []))
                .joined(separator: ", ")
        }
    }

    static let title = "Choose an account"
    static let addAccountTitle = "Add Account"
    static let removeHint = "Press and hold an account to sign out or remove it"
    static let lastUsedLabel = "Last used"
    static let signInAgainLabel = "Sign in again"
    static let maxAvatars = 4

    let cards: [Card]
    /// The card focus starts on: the one asked for, else the last-used
    /// account, else the first.
    let focus: SiloAccountRef?

    /// The hint shows while there is an account to hold.
    var showsRemoveHint: Bool { !cards.isEmpty }

    init(directory: SiloAccountDirectory, focus: SiloAccountRef? = nil) {
        let cards = directory.accounts.map { account in
            Card(
                id: account.id,
                name: account.name,
                detailLines: account.detailLines,
                avatars: Array(account.profiles.prefix(Self.maxAvatars)),
                serverAddress: account.serverAddress,
                isLastUsed: account.isLinked,
                needsSignInAgain: account.needsSignInAgain
            )
        }
        self.cards = cards
        let requested = focus.flatMap { id in cards.contains { $0.id == id } ? id : nil }
        self.focus = requested ?? cards.first(where: \.isLastUsed)?.id ?? cards.first?.id
    }
}
