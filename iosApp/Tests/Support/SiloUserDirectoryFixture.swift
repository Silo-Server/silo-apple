import Foundation
@testable import Silo

/// Builds the users directory the screens read, from users described in a
/// line each, for the pure view-model tests.
enum SiloUserDirectoryFixture {
    static let home = ServerRegistry.serverId(for: "https://home.example")
    static let friend = ServerRegistry.serverId(for: "https://friend.example")

    static let servers = [
        ServerEntry(id: home, url: "https://home.example", fetchedName: "Home Silo", lastUsedAt: Date()),
        ServerEntry(id: friend, url: "https://friend.example", fetchedName: "Friend's Silo", lastUsedAt: Date()),
    ]

    struct SignIn {
        let serverID: String
        let accountID: String
        var username: String?
        var isSignedIn = true
        var profiles: [String] = []
    }

    struct User {
        let id: String
        var displayName: String?
        var signIns: [SignIn]
        var pendingLegacyServerIDs: [String]? = nil
    }

    static func directory(
        _ users: [User],
        state: ProfileLaunchState = ProfileLaunchState(),
        currentUserID: String? = nil,
        currentServerID: String? = nil
    ) -> SiloUserDirectory {
        var summaries: [SignInSummary] = []
        let index = SiloUserIndex(users: users.map { user in
            let keys = user.signIns.map { SignInKey.make($0.serverID, $0.accountID) }
            for (offset, signIn) in user.signIns.enumerated() {
                summaries.append(SignInSummary(
                    key: keys[offset],
                    userID: user.id,
                    username: signIn.username,
                    isSignedIn: signIn.isSignedIn,
                    profiles: signIn.profiles.map {
                        SavedSignInProfile(id: $0, name: $0.capitalized, avatarEmoji: nil, avatarImageUrl: nil,
                                           hasPin: false, isChild: false)
                    },
                    addedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(offset))
                ))
            }
            return SiloUser(id: user.id, createdAt: Date(), displayName: user.displayName, signIns: keys,
                            pendingLegacyServerIDs: user.pendingLegacyServerIDs)
        })
        return SiloUserDirectory(
            snapshot: SiloUserDirectorySnapshot(index: index, signIns: summaries),
            servers: servers,
            state: state,
            currentUserID: currentUserID,
            currentServerID: currentServerID
        )
    }
}
