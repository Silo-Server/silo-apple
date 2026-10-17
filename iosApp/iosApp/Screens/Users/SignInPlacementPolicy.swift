import Foundation

/// Where a finished sign-in goes, or what to ask first (spec §5.4.1, §5.5).
enum SignInPlacementDecision: Equatable, Sendable {
    /// Install it there without asking.
    case place(SignInPlacementPolicy.Placement)
    /// The account is already saved in a user: refresh that sign-in, revoke
    /// its old session, and open the user. Nothing is created.
    case switchToExisting(key: SignInKey, userID: String)
    /// Ask first. Cancel revokes the new session and saves nothing.
    case ask(SignInPromptKind)
}

/// The two questions a sign-in can raise (spec §5.4.1).
enum SignInPromptKind: Equatable, Sendable {
    /// The account is saved in another user. Switch to {user} refreshes that
    /// sign-in and opens its user; the sign-in never moves.
    case switchToUser(userID: String, key: SignInKey)
    /// The user already has a different account on this server, and a user
    /// holds one sign-in per server. Add {username} as a Separate User
    /// creates a user for the new account. `newUsername` is nil when the
    /// sign-in didn't report one, as with phone pairing.
    case separateUser(existingUserID: String, newUsername: String?)

    /// What accepting installs. Cancel installs nothing.
    var acceptedPlacement: SignInPlacementPolicy.Placement {
        switch self {
        case .switchToUser(_, let key):
            return .refresh(key)
        case .separateUser:
            return .newUser
        }
    }
}

/// Decides where a sign-in goes before anything is saved (plan §2.9).
/// Usernames never match sign-ins: only the server account ID says whether
/// an account is already saved.
enum SignInPlacementPolicy {
    /// Mirrors `TokenStore`'s install placement case for case, so callers
    /// map it one to one.
    enum Placement: Equatable, Sendable {
        /// The account is already saved: new tokens and epoch, same user.
        case refresh(SignInKey)
        /// A new sign-in in an existing user.
        case join(userID: String)
        /// A new user holding only this sign-in.
        case newUser
    }

    /// Nil when the server or account ID can't form a sign-in key; the
    /// caller discards the session.
    static func decide(
        context: SignInContext,
        serverID: String,
        accountID: String,
        username: String?,
        directory: SiloUserDirectorySnapshot
    ) -> SignInPlacementDecision? {
        guard let key = SignInKey(serverID: serverID, accountID: accountID) else { return nil }
        let owner = directory.user(owning: key)

        switch context {
        case .firstRun, .addUser:
            return newUserDecision(key: key, owner: owner)

        // Sign in again behaves as Add Server inside the expired sign-in's
        // user: the same account refreshes it, and anything else asks.
        case .addServer(let userID), .signInAgain(let userID, _):
            // A user removed while signing in: the sign-in still counts, so
            // place it as Add User would.
            guard let user = directory.user(withID: userID) else {
                return newUserDecision(key: key, owner: owner)
            }
            if let owner {
                return owner.id == userID
                    ? .place(.refresh(key))
                    : .ask(.switchToUser(userID: owner.id, key: key))
            }
            // A pending legacy server counts as a different account, because
            // its account isn't known yet. If the person adds a separate user
            // and the account was the same, the pending server's binding later
            // finds the saved sign-in and drops the pending server.
            if SignInTargetList.serverIDs(in: user).contains(serverID) {
                return .ask(.separateUser(existingUserID: userID, newUsername: username))
            }
            return .place(.join(userID: userID))
        }
    }

    private static func newUserDecision(key: SignInKey, owner: SiloUser?) -> SignInPlacementDecision {
        if let owner {
            return .switchToExisting(key: key, userID: owner.id)
        }
        return .place(.newUser)
    }
}
