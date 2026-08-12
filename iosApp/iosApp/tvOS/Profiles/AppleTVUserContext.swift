#if os(tvOS)
import TVServices

/// User-facing context for the current tvOS storage persona.
///
/// tvOS 16 deprecated the APIs that exposed system-user identifiers and the
/// all-users profile mapping panel. Runs-as-Current-User now owns that
/// separation, while this remaining signal tells us whether apps should retain
/// preferences for the current user context.
struct AppleTVUserContext: Equatable, Sendable {
    static let current = AppleTVUserContext(
        shouldStorePreferencesForCurrentUser: TVUserManager()
            .shouldStorePreferencesForCurrentUser
    )

    let shouldStorePreferencesForCurrentUser: Bool

    var pairingDescription: String {
        if shouldStorePreferencesForCurrentUser {
            "Silo keeps a separate profile pairing for this Apple TV user. Switch users in Control Center to view or change the pairing available to another user."
        } else {
            "This Apple TV user context is not set to keep separate app preferences. Silo uses the profile pairing available to the current app context, and you can change it here at any time."
        }
    }
}
#endif
