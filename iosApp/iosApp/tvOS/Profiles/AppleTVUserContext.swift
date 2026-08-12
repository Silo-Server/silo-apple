#if os(tvOS)
import TVServices

/// User-facing context for the current tvOS storage persona.
///
/// tvOS 16 deprecated the APIs that exposed system-user identifiers and the
/// all-users profile mapping panel. Runs-as-Current-User now owns that
/// separation, while this remaining signal tells us whether the Apple TV has
/// multiple users for whom separate preferences should be explained.
struct AppleTVUserContext: Equatable, Sendable {
    static let current = AppleTVUserContext(
        storesSeparateUserPreferences: TVUserManager()
            .shouldStorePreferencesForCurrentUser
    )

    let storesSeparateUserPreferences: Bool

    var pairingDescription: String {
        if storesSeparateUserPreferences {
            "Silo keeps a separate profile pairing for each Apple TV user. Switch users in Control Center to view or change another pairing."
        } else {
            "This Apple TV currently has one user. Add users in Apple TV Settings to give each person a separate Silo profile pairing."
        }
    }
}
#endif
