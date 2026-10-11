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
        let account = AuthService.shared.accountID
        let cacheKey = identity.map { Self.cacheKey(for: $0, account: account) }
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

    /// The save in flight. Each save reads the whole list and writes it back,
    /// so the next one waits for it; two at once could undo each other.
    private static var lastSave: Task<Void, Never>?

    /// Hides or shows one library for the active profile and returns the
    /// profile's hidden IDs afterwards. The list is read fresh rather than
    /// from the cache, so a library hidden on another device since the last
    /// read stays hidden. The save goes ahead only when the server's
    /// settings contract supports the key and the read returns its value; a
    /// read without it would otherwise turn into an empty list and the write
    /// would show every other hidden library. A failed check, read or write
    /// throws and changes nothing. A profile or account switch while the
    /// save waits or before it writes cancels it: profile IDs are unique only
    /// within an account, and requests go out with the current account's
    /// credentials.
    static func setHidden(
        _ isHidden: Bool,
        libraryId: Int,
        defaults: SharedDefaults = .shared,
        requestIdentity: @escaping @MainActor () -> HTTPRequestIdentity? = SeekIntervalPreferences.activeRequestIdentity,
        accountID: @escaping @MainActor () -> String? = { AuthService.shared.accountID },
        capabilities: @escaping (HTTPRequestIdentity) async -> SettingsCapabilitiesResult = {
            await SiloAPI.shared.getContractCapabilities(requestIdentity: $0)
        },
        read: @escaping (HTTPRequestIdentity?) async throws -> EffectiveSettingValuesResponse = {
            try await SiloAPI.shared.getEffectiveValues(
                keys: [.uiDisabledLibraryIds],
                requestIdentity: $0
            )
        },
        write: @escaping (Set<Int>, HTTPRequestIdentity?) async throws -> Void = { ids, identity in
            try await SiloAPI.shared.putValue(
                key: .uiDisabledLibraryIds,
                scope: .profile,
                value: .array(ids.sorted().map { .int($0) }),
                requestIdentity: identity
            )
        }
    ) async throws -> Set<Int> {
        guard let identity = requestIdentity() else { throw CancellationError() }
        let account = accountID()
        let isCurrent = { requestIdentity() == identity && accountID() == account }
        let previous = lastSave
        let save = Task { @MainActor in
            await previous?.value
            guard isCurrent() else { throw CancellationError() }
            try requireSupport(await capabilities(identity))
            let response = try await read(identity)
            guard let stored = response.value(for: .uiDisabledLibraryIds) else {
                throw SettingsAPIError.unknownSetting(key: SettingKey.uiDisabledLibraryIds.rawValue)
            }
            let current = libraryIds(from: stored.value)
            let updated = isHidden ? current.union([libraryId]) : current.subtracting([libraryId])
            if updated != current {
                guard isCurrent() else { throw CancellationError() }
                try await write(updated, identity)
            }
            if let data = try? JSONEncoder().encode(updated.sorted()) {
                defaults.set(data, forKey: cacheKey(for: identity, account: account))
            }
            return updated
        }
        lastSave = Task { _ = try? await save.value }
        return try await save.value
    }

    private static func requireSupport(_ result: SettingsCapabilitiesResult) throws {
        switch result {
        case .available(let contract) where contract.supports(.uiDisabledLibraryIds):
            return
        case .available, .unavailable:
            throw SettingsAPIError.unknownSetting(key: SettingKey.uiDisabledLibraryIds.rawValue)
        case .serverUpgradeRequired:
            throw SettingsAPIError.serverUpgradeRequired
        case .failed(let error):
            throw error
        }
    }

    /// Re-reads the library list so the tab bar, Libraries and every library
    /// picker drop or regain a library, then drops the lists the server
    /// filters by the same setting (Home, For You, library pages) and
    /// reloads Home. `hiddenIds` is what the save returned: if the re-read
    /// fails, the last list is split by it so navigation still matches the
    /// saved setting.
    static func publishChange(
        hiddenIds: Set<Int>,
        requestIdentity: @MainActor () -> HTTPRequestIdentity? = SeekIntervalPreferences.activeRequestIdentity,
        accountID: @MainActor () -> String? = { AuthService.shared.accountID }
    ) async {
        let identity = requestIdentity()
        let account = accountID()
        let cached: LibrariesResponse? = ResponseCache.shared.get(CacheKey.userLibraries)
        // A read that started before the save carries the old list.
        StartupContentPrefetcher.invalidateUserLibrariesInFlight()
        do {
            _ = try await StartupContentPrefetcher.fetchUserLibraries(reusingRecent: false)
        } catch {
            guard requestIdentity() == identity, accountID() == account, let cached else { return }
            let all = inServerOrder(cached.libraries + (cached.hiddenLibraries ?? []))
            let response = LibrariesResponse(
                libraries: visibleLibraries(all, hiding: hiddenIds),
                hiddenLibraries: all.filter { hiddenIds.contains($0.id) }
            )
            ResponseCache.shared.set(response, for: CacheKey.userLibraries)
            NotificationCenter.default.post(name: .userLibrariesDidRefresh, object: response)
        }
        guard requestIdentity() == identity, accountID() == account else { return }
        dropListsFilteredByHiddenLibraries()
    }

    /// Drops what the server filtered by the old hidden set: Calendar,
    /// filter vocabularies, and the lists `invalidateDerivedLists` covers.
    /// The refresh that posts reloads Home, the hubs and an open Calendar.
    static func dropListsFilteredByHiddenLibraries() {
        ResponseCache.shared.removeAll(withPrefix: "calendar:")
        FacetLoader.shared.invalidateAll()
        PersonalStateSync.invalidateDerivedLists()
    }

    /// The server lists libraries by `sort_order`, then ID; the visible and
    /// hidden halves merge back in that order.
    static func inServerOrder(_ libraries: [Library]) -> [Library] {
        libraries.sorted { ($0.sortOrder ?? .max, $0.id) < ($1.sortOrder ?? .max, $1.id) }
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

    /// Profile IDs are unique only within an account (`SessionOwner`), so
    /// the account scopes the cache too.
    private static func cacheKey(for identity: HTTPRequestIdentity, account: String?) -> String {
        "silo.hiddenLibraryIds.\(identity.serverId).\(account ?? "-").\(identity.profileId)"
    }
}
