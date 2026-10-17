import Foundation

/// What Choose a User shows (spec §5.2): one card per user, then Add User,
/// with the hold-to-remove hint. Pure, built from `SiloUserDirectory`.
struct ChooseUserViewModel: Equatable {
    struct Card: Equatable, Identifiable {
        /// The user's ID.
        let id: String
        let name: String
        /// Profiles of the user's last-used server, at most `maxAvatars`.
        let avatars: [SavedSignInProfile]
        /// "Home Silo", or "2 servers".
        let serverLabel: String
        /// The user this Apple TV user (or device) is linked to.
        let isLastUsed: Bool
        /// The last-used sign-in expired.
        let needsSignInAgain: Bool

        /// What VoiceOver reads after the name.
        var accessibilityValue: String {
            ([serverLabel]
                + (isLastUsed ? [ChooseUserViewModel.lastUsedLabel] : [])
                + (needsSignInAgain ? [ChooseUserViewModel.signInAgainLabel] : []))
                .joined(separator: ", ")
        }
    }

    static let title = "Choose a user"
    static let addUserTitle = "Add User"
    static let removeHint = "Press and hold a user to remove it"
    static let lastUsedLabel = "Last used"
    static let signInAgainLabel = "Sign in again"
    static let maxAvatars = 4

    let cards: [Card]
    /// The card focus starts on: the one asked for, else the last-used user,
    /// else the first.
    let focusUserID: String?

    /// The hint shows while there is a user to hold.
    var showsRemoveHint: Bool { !cards.isEmpty }

    init(directory: SiloUserDirectory, focusUserID: String? = nil) {
        let cards = directory.users.map { user in
            Card(
                id: user.id,
                name: user.name,
                avatars: Array((user.lastUsedServer?.profiles ?? []).prefix(Self.maxAvatars)),
                serverLabel: Self.serverLabel(for: user),
                isLastUsed: user.isLinked,
                needsSignInAgain: user.needsSignInAgain
            )
        }
        self.cards = cards
        let requested = focusUserID.flatMap { id in cards.contains { $0.id == id } ? id : nil }
        self.focusUserID = requested ?? cards.first(where: \.isLastUsed)?.id ?? cards.first?.id
    }

    /// The only server's name, or how many servers the user has.
    static func serverLabel(for user: SiloUserDirectory.User) -> String {
        switch user.servers.count {
        case 0: return "No servers"
        case 1: return user.servers[0].name
        default: return "\(user.servers.count) servers"
        }
    }
}
