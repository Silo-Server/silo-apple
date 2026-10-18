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
        /// The server's host, when another of the user's servers shares its
        /// name.
        let host: String?
        let isActive: Bool
        let needsSignInAgain: Bool

        /// The item's second line: the host when it tells the server apart,
        /// and "Sign in again" once the sign-in expired.
        var detail: String? {
            let parts = [host, needsSignInAgain ? ChooseServerViewModel.Status.signInAgain.label : nil].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: SiloUserNaming.separator)
        }
    }

    struct UserItem: Equatable, Identifiable {
        /// The user's ID.
        let id: String
        let name: String
        /// "Home Silo", or "2 servers".
        let detail: String
        let needsSignInAgain: Bool

        /// The item's second line, with "Sign in again" once the user's
        /// last sign-in expired.
        var detailLine: String {
            needsSignInAgain ? detail + SiloUserNaming.separator + ChooseUserViewModel.signInAgainLabel : detail
        }
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
        let hosts = SiloUserNaming.hostsTellingApart(
            (current?.servers ?? []).map { (id: $0.id, name: $0.name, address: $0.address) })
        servers = current?.servers.map { server in
            ServerItem(
                id: server.id,
                name: server.name,
                host: hosts[server.id],
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
