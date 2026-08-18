#if os(tvOS)
import Foundation

/// Persists the selected library scope for each multi-library type tab
/// (Skyline §3.1, §8).
///
/// Library scope is the one navigation state Skyline keeps **across
/// launches** — unlike the selected pill, which is session-only. A
/// multi-library type is always scoped to exactly one library (the
/// merged `All <Type>` view was dropped in Rev 3); this store remembers
/// which one per profile, per type, so reopening a tab lands on the user's
/// last choice instead of snapping back to the first library.
///
/// Single-library types need no entry here — their scope is trivially the
/// only library, resolved without touching persistence.
///
/// Keying: `skyline.libraryScope.<serverId>.<profileId>.<type>`. Server +
/// profile scoping keeps two profiles (or two servers) from clobbering each
/// other's choices when they share the same library type. Reads/writes go
/// through `SharedDefaults` so the value survives the same way other Skyline
/// preferences do.
struct TVLibraryScopeStore {
    static let shared = TVLibraryScopeStore()

    private let defaults: SharedDefaults

    init(defaults: SharedDefaults = .shared) {
        self.defaults = defaults
    }

    /// The persisted library id for `type` under the active profile, or
    /// `nil` if nothing has been chosen yet (cold start).
    func selectedLibraryId(for type: TVLibraryTabType) -> Int? {
        guard let key = key(for: type) else { return nil }
        // `integer(forKey:)` can't distinguish "0" from "absent", so gate
        // on object presence — library ids are positive but be defensive.
        guard defaults.containsObject(forKey: key) else { return nil }
        let stored = defaults.integer(forKey: key)
        return stored
    }

    /// Persist `libraryId` as the scope for `type` under the active profile.
    func setSelectedLibraryId(_ libraryId: Int, for type: TVLibraryTabType) {
        guard let key = key(for: type) else { return }
        defaults.set(libraryId, forKey: key)
    }

    /// Resolve the effective scope for a type given the libraries available
    /// to the current profile (already ordered by sort order). Returns the
    /// persisted choice if it still exists, else the first library by sort
    /// order (cold start / the persisted library disappeared), else `nil`
    /// when the type has no libraries.
    func resolvedLibrary(
        for type: TVLibraryTabType,
        in libraries: [Library]
    ) -> Library? {
        guard !libraries.isEmpty else { return nil }
        if let storedId = selectedLibraryId(for: type),
           let match = libraries.first(where: { $0.id == storedId }) {
            return match
        }
        return libraries.first
    }

    // MARK: - Keying

    private func key(for type: TVLibraryTabType) -> String? {
        // No profile → nothing to scope. Persisting under an anonymous key
        // would leak one user's choice into the next signed-in profile.
        guard let profileId = AuthService.shared.profileId, !profileId.isEmpty else {
            return nil
        }
        let serverId = ServerRegistry.shared.activeServerId ?? "default"
        return "skyline.libraryScope.\(serverId).\(profileId).\(type.rawValue)"
    }
}

private extension SharedDefaults {
    /// Integer read mirroring `SharedDefaults`' suite-then-standard fallback.
    func integer(forKey key: String) -> Int {
        if suite.object(forKey: key) != nil { return suite.integer(forKey: key) }
        return UserDefaults.standard.integer(forKey: key)
    }

    /// Integer write mirrored to both the App Group suite and `.standard`,
    /// matching the string/bool setters already on `SharedDefaults`.
    func set(_ value: Int, forKey key: String) {
        suite.set(value, forKey: key)
        UserDefaults.standard.set(value, forKey: key)
    }
}
#endif
