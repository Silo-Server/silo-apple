import Foundation

/// Per-library, per-profile persistence of browse sort + filters, gated by a
/// user-facing "Preserve sort & filters" toggle (default on). Mirrors the
/// `AppNavPreferences` / `TVLibraryScopeStore` pattern: `SharedDefaults`
/// keyed by platform + server + profile + library, so a phone's filters
/// never leak to the TV or to another profile, and an anonymous (no-profile)
/// state is never persisted.
struct BrowsePrefsStore {
    static let shared = BrowsePrefsStore()

    private let defaults: SharedDefaults

    init(defaults: SharedDefaults = .shared) {
        self.defaults = defaults
    }

    /// Whether sort + filters are remembered for this library. Default true.
    func preserveEnabled(libraryId: Int?) -> Bool {
        guard let key = preserveKey(libraryId: libraryId) else { return true }
        guard defaults.containsObject(forKey: key) else { return true }
        return defaults.bool(forKey: key)
    }

    /// Set the preserve preference. Turning it off also drops any saved state.
    func setPreserveEnabled(_ enabled: Bool, libraryId: Int?) {
        guard let key = preserveKey(libraryId: libraryId) else { return }
        defaults.set(enabled, forKey: key)
        if !enabled { clearState(libraryId: libraryId) }
    }

    /// The saved state for a library, or `nil` when preserve is off or
    /// nothing is stored.
    func savedState(libraryId: Int?) -> CatalogFilterState? {
        guard preserveEnabled(libraryId: libraryId),
              let key = stateKey(libraryId: libraryId),
              let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(CatalogFilterState.self, from: data)
        else { return nil }
        return state
    }

    /// Persist the committed state (minus the transient A–Z `namePrefix`).
    /// No-op when preserve is off.
    func saveState(_ state: CatalogFilterState, libraryId: Int?) {
        guard preserveEnabled(libraryId: libraryId),
              let key = stateKey(libraryId: libraryId) else { return }
        var toSave = state
        toSave.namePrefix = nil
        guard let data = try? JSONEncoder().encode(toSave) else { return }
        defaults.set(data, forKey: key)
    }

    func clearState(libraryId: Int?) {
        guard let key = stateKey(libraryId: libraryId) else { return }
        defaults.removeObject(forKey: key)
    }

    // MARK: - Keys

    private func base(libraryId: Int?) -> String? {
        guard let profileId = AuthService.shared.profileId, !profileId.isEmpty else { return nil }
        let serverId = ServerRegistry.shared.activeServerId ?? "default"
        let lib = libraryId.map(String.init) ?? "all"
        return "\(Self.platformPrefix).\(serverId).\(profileId).\(lib)"
    }

    private func stateKey(libraryId: Int?) -> String? {
        base(libraryId: libraryId).map { "\($0).state" }
    }

    private func preserveKey(libraryId: Int?) -> String? {
        base(libraryId: libraryId).map { "\($0).preserve" }
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
