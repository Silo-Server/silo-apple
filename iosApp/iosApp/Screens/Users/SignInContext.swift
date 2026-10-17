import Foundation

/// Why a sign-in is running. It decides the server step ("Sign in to…"),
/// where the new sign-in goes, and which buttons the sign-in screen offers
/// (spec §5.4, §5.4.1, §5.5).
enum SignInContext: Hashable, Sendable {
    /// The device has no users yet.
    case firstRun
    /// Add User. Creates a user unless the account is already saved.
    case addUser
    /// Add Server inside a user. The new sign-in joins that user.
    case addServer(userID: String)
    /// A saved sign-in expired. Signing in again refreshes it.
    case signInAgain(userID: String, key: SignInKey)

    /// The user the sign-in is for. Nil when the sign-in creates a user.
    var userID: String? {
        switch self {
        case .firstRun, .addUser:
            return nil
        case .addServer(let userID), .signInAgain(let userID, _):
            return userID
        }
    }
}
