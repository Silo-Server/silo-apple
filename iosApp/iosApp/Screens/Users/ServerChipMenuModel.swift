import Foundation

/// The server chip menu on Who's Watching for iOS, iPadOS, and macOS (spec
/// §5.8): this user's servers and Add Server, other users and Add User, and
/// Manage Users…. Before sign-in migration it offers Change server only, as
/// before users existed.
struct ServerChipMenuModel: Equatable {
    struct ServerItem: Equatable, Identifiable {
        /// Registry server ID.
        let id: String
        let name: String
        let isActive: Bool
        let needsSignInAgain: Bool
    }

    struct UserItem: Equatable, Identifiable {
        /// The user's ID.
        let id: String
        let name: String
        /// "Home Silo", or "2 servers".
        let detail: String
        let needsSignInAgain: Bool
    }

    static let changeServerTitle = "Change server"
    static let addServerTitle = "Add Server"
    static let addUserTitle = "Add User"
    static let manageUsersTitle = "Manage Users…"

    /// The current user's name, as the servers section's title.
    let userName: String?
    let servers: [ServerItem]
    let otherUsers: [UserItem]
    /// False before sign-in migration: the menu offers Change server only.
    let showsUsers: Bool

    init(directory: SiloUserDirectory) {
        showsUsers = directory.isAvailable
        let current = directory.currentUser
        userName = current?.name
        servers = current?.servers.map { server in
            ServerItem(
                id: server.id,
                name: server.name,
                isActive: server.id == directory.currentServerID,
                needsSignInAgain: server.needsSignInAgain
            )
        } ?? []
        otherUsers = directory.otherUsers(than: current?.id).map { user in
            UserItem(
                id: user.id,
                name: user.name,
                detail: ChooseUserViewModel.serverLabel(for: user),
                needsSignInAgain: user.needsSignInAgain
            )
        }
    }
}
