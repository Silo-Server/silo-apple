import Foundation

/// Which credential `TokenStore` serves for the active server.
enum CredentialSelection: Equatable, Sendable {
    /// No credential: a sign-in screen or a chooser is showing.
    case none
    /// The server's old per-server sign-in, before migration or while the
    /// server is a pending legacy server.
    case legacy(serverID: String)
    case signIn(SignInKey)
}
