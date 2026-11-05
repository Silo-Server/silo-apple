import Foundation

/// Per-library, per-profile persistence of browse sort + filters, gated by a
/// user-facing "Preserve sort & filters" toggle (default on). Mirrors the
/// `AppNavPreferences` / `TVLibraryScopeStore` pattern: `SharedDefaults`
/// keyed by platform + server + account + profile + library, so a phone's
/// filters never leak to the TV, to another profile, or to another account's
/// profile with the same ID, and an anonymous (no-profile) state is never
/// persisted.
struct BrowsePrefsStore {
    static let shared = BrowsePrefsStore()

    private let defaults: SharedDefaults

    init(defaults: SharedDefaults = .shared) {
        self.defaults = defaults
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

    /// `<platform>.v2.<server>.<account>.<profile>.<library>[.type-<scope>].<field>`,
    /// after the legacy owner takes over the value saved before accounts.
    private func key(_ field: String, libraryId: Int?, mediaScope: String?) -> String? {
        let lib = libraryId.map(String.init) ?? "all"
        let suffix = lib + (mediaScope.map { ".type-\($0)" } ?? "") + ".\(field)"
        return AccountScope.current?.adoptedKey(Self.platformPrefix, suffix: suffix, defaults: defaults)
    }

    private func stateKey(libraryId: Int?, mediaScope: String? = nil) -> String? {
        key("state", libraryId: libraryId, mediaScope: mediaScope)
    }

    private func preserveKey(libraryId: Int?, mediaScope: String? = nil) -> String? {
        key("preserve", libraryId: libraryId, mediaScope: mediaScope)
    }

    static var platformPrefix: String {
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
