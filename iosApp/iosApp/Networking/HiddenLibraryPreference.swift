import Foundation

/// The active profile's `ui.disabled_library_ids`: libraries the profile hid
/// from its own navigation, here (Libraries, or Settings > Interface >
/// Libraries) or in the web app's library settings.
///
/// The server's catalog reads already leave a hidden library's titles out, but
/// `GET /api/v2/user/libraries` still lists the library for a profile without
/// a library limit. The app's library list drops these IDs, as the web app's
/// `filterVisibleLibraries` does, so navigation and library pickers don't
/// offer a library that opens empty. Profile creation's library-access picker
/// grants access rather than navigating, so it keeps the unfiltered list.
///
/// The Apple app has no events-stream subscriber, so a change made on another
/// device arrives with the next library list read: launch, server or profile
/// switch, return to the foreground, or a pull to refresh on Home.
@MainActor
enum HiddenLibraryPreference {
    /// The profile's hidden library IDs. A failed read keeps this profile's
    /// last answer, so a dropped request doesn't bring a hidden library back.
    /// With no answer yet, or on a server that doesn't serve the setting, it
    /// hides nothing, as the web app does.
    static func hiddenLibraryIds(
        defaults: SharedDefaults = .shared,
        requestIdentity: @MainActor () -> HTTPRequestIdentity? = SeekIntervalPreferences.activeRequestIdentity,
        read: (HTTPRequestIdentity?) async throws -> EffectiveSettingValuesResponse = {
            try await SiloAPI.shared.getEffectiveValues(
                keys: [.uiDisabledLibraryIds],
                requestIdentity: $0
            )
        }
    ) async -> Set<Int> {
        let identity = requestIdentity()
        let cacheKey = identity.map(Self.cacheKey(for:))
        do {
            let response = try await read(identity)
            let ids = libraryIds(from: response.value(for: .uiDisabledLibraryIds)?.value ?? .null)
            if let cacheKey, let data = try? JSONEncoder().encode(ids.sorted()) {
                defaults.set(data, forKey: cacheKey)
            }
            return ids
        } catch {
            switch SettingsAPIError.from(error) {
            case .serverUpgradeRequired, .unknownSetting:
                if let cacheKey { defaults.removeObject(forKey: cacheKey) }
                return []
            default:
                return cacheKey.flatMap { cachedIds(for: $0, defaults: defaults) } ?? []
            }
        }
    }

    /// Hides or shows one library for the active profile and returns the
    /// profile's hidden IDs afterwards. The list is read fresh rather than
    /// from the cache, so a library hidden on another device since the last
    /// read stays hidden. A failed read or write throws and changes nothing.
    static func setHidden(
        _ isHidden: Bool,
        libraryId: Int,
        defaults: SharedDefaults = .shared,
        requestIdentity: @MainActor () -> HTTPRequestIdentity? = SeekIntervalPreferences.activeRequestIdentity,
        read: (HTTPRequestIdentity?) async throws -> EffectiveSettingValuesResponse = {
            try await SiloAPI.shared.getEffectiveValues(
                keys: [.uiDisabledLibraryIds],
                requestIdentity: $0
            )
        },
        write: (Set<Int>, HTTPRequestIdentity?) async throws -> Void = { ids, identity in
            try await SiloAPI.shared.putValue(
                key: .uiDisabledLibraryIds,
                scope: .profile,
                value: .array(ids.sorted().map { .int($0) }),
                requestIdentity: identity
            )
        }
    ) async throws -> Set<Int> {
        let identity = requestIdentity()
        let response = try await read(identity)
        let current = libraryIds(from: response.value(for: .uiDisabledLibraryIds)?.value ?? .null)
        let updated = isHidden ? current.union([libraryId]) : current.subtracting([libraryId])
        if updated != current {
            try await write(updated, identity)
        }
        if let cacheKey = identity.map(Self.cacheKey(for:)),
           let data = try? JSONEncoder().encode(updated.sorted()) {
            defaults.set(data, forKey: cacheKey)
        }
        return updated
    }

    /// Re-reads the library list so the tab bar, Libraries and every library
    /// picker drop or regain a library, then reloads Home, whose rows the
    /// server filters by the same setting.
    static func publishChange() async {
        _ = try? await StartupContentPrefetcher.fetchUserLibraries(reusingRecent: false)
        NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
    }

    static func visibleLibraries(_ libraries: [Library], hiding hidden: Set<Int>) -> [Library] {
        libraries.filter { !hidden.contains($0.id) }
    }

    /// Accepts the canonical array value, the legacy JSON-string encoding, or
    /// null (the contract default), matching the web's `parseLibraryIDList`.
    nonisolated static func libraryIds(from value: SettingJSONValue) -> Set<Int> {
        let entries: [SettingJSONValue]
        switch value {
        case .array(let array):
            entries = array
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(SettingJSONValue.self, from: data),
                  let array = decoded.arrayValue else { return [] }
            entries = array
        default:
            return []
        }
        return Set(entries.compactMap(\.intValue).filter { $0 > 0 })
    }

    private static func cachedIds(for key: String, defaults: SharedDefaults) -> Set<Int>? {
        defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([Int].self, from: $0) }
            .map(Set.init)
    }

    private static func cacheKey(for identity: HTTPRequestIdentity) -> String {
        "silo.hiddenLibraryIds.\(identity.serverId).\(identity.profileId)"
    }
}
