import Foundation
@testable import Silo

/// Builds the accounts directory the screens read, from accounts described
/// in a line each, for the pure view-model tests.
enum SiloAccountDirectoryFixture {
    static let home = ServerRegistry.serverId(for: "https://home.example")
    static let friend = ServerRegistry.serverId(for: "https://friend.example")

    static let servers = [
        ServerEntry(id: home, url: "https://home.example", fetchedName: "Home Silo", lastUsedAt: Date()),
        ServerEntry(id: friend, url: "https://friend.example", fetchedName: "Friend's Silo", lastUsedAt: Date()),
    ]

    /// A saved sign-in, or with `accountID` nil a pending legacy account.
    struct Account {
        let serverID: String
        var accountID: String?
        var username: String?
        var email: String?
        var isSignedIn = true
        var profiles: [String] = []

        var ref: SiloAccountRef {
            accountID.map { .signIn(SignInKey.make(serverID, $0)) } ?? .pendingLegacy(serverID: serverID)
        }
    }

    static func snapshot(_ accounts: [Account]) -> SiloAccountDirectorySnapshot {
        let summaries = accounts.enumerated().compactMap { offset, account -> SignInSummary? in
            guard let key = account.ref.signInKey else { return nil }
            return SignInSummary(
                key: key,
                username: account.username,
                email: account.email,
                isSignedIn: account.isSignedIn,
                profiles: account.profiles.map {
                    SavedSignInProfile(id: $0, name: $0.capitalized, avatarEmoji: nil, avatarImageUrl: nil,
                                       hasPin: false, isChild: false)
                },
                addedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(offset))
            )
        }
        return SiloAccountDirectorySnapshot(index: SiloAccountIndex(accounts: accounts.map(\.ref)), signIns: summaries)
    }

    static func directory(
        _ accounts: [Account],
        state: ProfileLaunchState = ProfileLaunchState(),
        current: SiloAccountRef? = nil,
        servers: [ServerEntry] = SiloAccountDirectoryFixture.servers
    ) -> SiloAccountDirectory {
        SiloAccountDirectory(snapshot: snapshot(accounts), servers: servers, state: state, currentAccountID: current)
    }
}
