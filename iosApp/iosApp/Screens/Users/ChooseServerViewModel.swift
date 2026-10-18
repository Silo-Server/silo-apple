import Foundation

/// What Choose a Server shows for one user (spec §5.3): a row per server
/// with its username when it says something the user's name doesn't, and
/// Active or Sign in again, then Add Server. Pure, built from
/// `SiloUserDirectory`.
struct ChooseServerViewModel: Equatable {
    enum Status: Equatable {
        case none
        /// The server open now, on the current user's rows only. Another
        /// user's last server shows nothing; focus starts on it instead.
        case active
        /// The sign-in expired.
        case signInAgain

        var label: String? {
            switch self {
            case .none: return nil
            case .active: return "Active"
            case .signInAgain: return "Sign in again"
            }
        }
    }

    struct Row: Equatable, Identifiable {
        /// Registry server ID.
        let id: String
        let name: String
        let address: String
        /// Shown under the name; nil when it would only repeat the user's
        /// name (and the user wasn't renamed), or isn't known yet.
        let username: String?
        let status: Status
        /// The saved sign-in, for Sign Out of {server}. Nil for a pending
        /// legacy server.
        let key: SignInKey?
    }

    static let addServerTitle = "Add Server"

    let userID: String
    let userName: String
    let rows: [Row]
    /// The row focus starts on: the one asked for, else the open one (for
    /// another user, its last one) unless it needs signing in again, else
    /// the first.
    let focusServerID: String?

    var title: String { "\(userName)'s servers" }

    /// Nil when the user is gone.
    init?(directory: SiloUserDirectory, userID: String, focusServerID: String? = nil) {
        guard let user = directory.user(userID) else { return nil }
        let isCurrentUser = directory.currentUserID == userID
        let activeID = isCurrentUser ? directory.currentServerID : nil
        let lastID = isCurrentUser ? directory.currentServerID : user.lastServerID
        self.userID = userID
        userName = user.name
        let rows = user.servers.map { server in
            Row(
                id: server.id,
                name: server.name,
                address: server.address,
                username: server.showsUsername ? server.username : nil,
                status: server.needsSignInAgain ? .signInAgain : (server.id == activeID ? .active : .none),
                key: server.key
            )
        }
        self.rows = rows
        let requested = focusServerID.flatMap { id in rows.contains { $0.id == id } ? id : nil }
        self.focusServerID = requested
            ?? rows.first { $0.id == lastID && $0.status != .signInAgain }?.id
            ?? rows.first?.id
    }
}
