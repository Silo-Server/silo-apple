import Foundation

/// Settings › Users (spec §5.7): each user with its servers, each server
/// with Sign Out; Rename and Remove per user; Add User at the end.
struct UsersSettingsViewModel: Equatable {
    struct Server: Equatable, Identifiable {
        /// Registry server ID.
        let id: String
        let name: String
        /// Shown when it differs from the user's name, or the user was
        /// renamed.
        let username: String?
        /// The saved sign-in Sign Out acts on. Nil for a pending legacy
        /// server, which only Remove reaches.
        let key: SignInKey?
        let needsSignInAgain: Bool
    }

    struct User: Equatable, Identifiable {
        let id: String
        let name: String
        /// Pre-fills Rename.
        let baseName: String
        let isCurrent: Bool
        let isLastUsed: Bool
        let servers: [Server]
    }

    static let title = "Users"
    static let addUserTitle = "Add User"
    static let renameTitle = "Rename"
    static let signOutTitle = "Sign Out"

    let users: [User]
    let removeTitle: String

    init(directory: SiloUserDirectory, device: SignOutConfirmationCopy.Device) {
        removeTitle = SignOutConfirmationCopy.removeFromDeviceTitle(device: device)
        users = directory.users.map { user in
            User(
                id: user.id,
                name: user.name,
                baseName: user.baseName,
                isCurrent: user.id == directory.currentUserID,
                isLastUsed: user.isLinked,
                servers: user.servers.map { server in
                    Server(
                        id: server.id,
                        name: server.name,
                        username: server.showsUsername ? server.username : nil,
                        key: server.key,
                        needsSignInAgain: server.needsSignInAgain
                    )
                }
            )
        }
    }
}
