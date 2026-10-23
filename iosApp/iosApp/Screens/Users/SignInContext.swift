import Foundation

/// Why a sign-in is running. It decides the server step ("Sign in to…") and
/// which buttons the sign-in screen offers (spec §5.4, §5.5). Where the
/// sign-in goes never depends on it: an account already saved is refreshed,
/// any other is added.
enum SignInContext: Hashable, Sendable {
    /// The device has no accounts yet.
    case firstRun
    /// Add Account.
    case addAccount
    /// A saved account's sign-in expired. Signing in again refreshes it.
    case signInAgain(SignInKey)
}
