import Foundation

/// The active profile's `ui.disabled_library_ids`: libraries the profile hid
/// from its own navigation in the web app's library settings.
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
