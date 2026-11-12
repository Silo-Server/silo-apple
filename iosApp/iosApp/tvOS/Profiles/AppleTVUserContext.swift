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
}
#endif
