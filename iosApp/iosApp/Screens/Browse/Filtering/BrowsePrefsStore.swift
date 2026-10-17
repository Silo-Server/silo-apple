import Foundation

/// Per-library, per-profile persistence of browse sort + filters, gated by a
/// user-facing "Preserve sort & filters" toggle (default on). Mirrors the
/// `AppNavPreferences` / `TVLibraryScopeStore` pattern: `SharedDefaults`
/// keyed by platform + server + account + profile + library, so a phone's
/// filters never leak to the TV, to another profile, or to another account's
/// profile with the same ID, and an anonymous (no-profile) state is never
/// persisted.
struct BrowsePrefsStore {
    /// The server, account, and profile keys belong to. The account is nil
    /// for a server's own session from before saved sign-ins.
    struct Scope: Equatable, Sendable {
        let serverID: String
        let accountID: String?
        let profileID: String
    }

    static let shared = BrowsePrefsStore()

    private let defaults: SharedDefaults
    private let scope: @Sendable () -> Scope?

    init(defaults: SharedDefaults = .shared, scope: @escaping @Sendable () -> Scope? = BrowsePrefsStore.activeScope) {
        self.defaults = defaults
        self.scope = scope
    }

    /// Whether sort + filters are remembered for this library. Default true.
    func preserveEnabled(libraryId: Int?, mediaScope: String? = nil) -> Bool {
        guard let key = preserveKey(libraryId: libraryId, mediaScope: mediaScope) else { return true }
        guard defaults.containsObject(forKey: key) else { return true }
        return defaults.bool(forKey: key)
    }

    /// Set the preserve preference. Turning it off also drops any saved state.
    func setPreserveEnabled(_ enabled: Bool, libraryId: Int?, mediaScope: String? = nil) {
        guard let key = preserveKey(libraryId: libraryId, mediaScope: mediaScope) else { return }
        defaults.set(enabled, forKey: key)
        if !enabled { clearState(libraryId: libraryId, mediaScope: mediaScope) }
    }

    /// The saved state for a library, or `nil` when preserve is off or
    /// nothing is stored.
    func savedState(libraryId: Int?, mediaScope: String? = nil) -> CatalogFilterState? {
        guard preserveEnabled(libraryId: libraryId, mediaScope: mediaScope),
              let key = stateKey(libraryId: libraryId, mediaScope: mediaScope),
              let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(CatalogFilterState.self, from: data)
        else { return nil }
        return state
    }

    /// Persist the committed state (minus the transient A–Z `namePrefix`).
    /// No-op when preserve is off.
    func saveState(_ state: CatalogFilterState, libraryId: Int?, mediaScope: String? = nil) {
        guard preserveEnabled(libraryId: libraryId, mediaScope: mediaScope),
              let key = stateKey(libraryId: libraryId, mediaScope: mediaScope) else { return }
        var toSave = state
        toSave.namePrefix = nil
        guard let data = try? JSONEncoder().encode(toSave) else { return }
        defaults.set(data, forKey: key)
    }

    func clearState(libraryId: Int?, mediaScope: String? = nil) {
        guard let key = stateKey(libraryId: libraryId, mediaScope: mediaScope) else { return }
        defaults.removeObject(forKey: key)
    }

    // MARK: - Keys

    static func activeScope() -> Scope? {
        guard let profileId = AuthService.shared.profileId, !profileId.isEmpty else { return nil }
        guard let serverId = ServerRegistry.shared.activeServerId else {
            return Scope(serverID: "default", accountID: nil, profileID: profileId)
        }
        return Scope(serverID: serverId, accountID: AccountScopeReader.currentAccountID(), profileID: profileId)
    }

    /// `<platform>.v2.<server>.<account>.<profile>.<library>[.type-<scope>].<field>`,
    /// or the key from before accounts while the account is unknown, after
    /// the legacy owner takes over the value saved before accounts.
    private func key(_ field: String, libraryId: Int?, mediaScope: String?) -> String? {
        guard let scope = scope() else { return nil }
        let lib = libraryId.map(String.init) ?? "all"
        let suffix = lib + (mediaScope.map { ".type-\($0)" } ?? "") + ".\(field)"
        return AccountScopedKeyAdoption.adoptedKey(
            Self.platformPrefix,
            serverID: scope.serverID,
            accountID: scope.accountID,
            profileID: scope.profileID,
            suffix: suffix,
            defaults: defaults
        )
    }

    private func stateKey(libraryId: Int?, mediaScope: String? = nil) -> String? {
        key("state", libraryId: libraryId, mediaScope: mediaScope)
    }

    private func preserveKey(libraryId: Int?, mediaScope: String? = nil) -> String? {
        key("preserve", libraryId: libraryId, mediaScope: mediaScope)
    }

    private static var platformPrefix: String {
        #if os(tvOS)
        "tv.browsePrefs"
        #elseif os(iOS)
        "ios.browsePrefs"
        #elseif os(macOS)
        "mac.browsePrefs"
        #else
        "apple.browsePrefs"
        #endif
    }
}
