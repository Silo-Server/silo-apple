import Foundation
import OSLog

extension HTTPRequestIdentity {
    /// The active server's selected account and profile, or nil while no
    /// profile or no account on the active server is selected.
    static func activeProfile() -> HTTPRequestIdentity? {
        guard let server = ServerRegistry.shared.activeServer,
              ServerRegistry.shared.activeServerId == server.id,
              let profileId = AuthService.shared.profileId,
              !profileId.isEmpty,
              let localAccountId = AccountScope.localAccountId(onServer: server.id) else { return nil }
        return HTTPRequestIdentity(
            serverId: server.id,
            serverURL: server.url,
            profileId: profileId,
            clientFamily: AppleDeviceIdentity.current.clientFamily,
            localAccountId: localAccountId
        )
    }

    /// `AccountScopedKeyAdoption.key` for this identity's account and
    /// profile. An identity without an account keys under an empty account,
    /// which no account owns and adoption never fills.
    func accountScopedKey(_ prefix: String, suffix: String? = nil) -> String {
        AccountScopedKeyAdoption.key(
            prefix,
            serverId: serverId,
            localAccountId: localAccountId ?? "",
            profileId: profileId,
            suffix: suffix
        )
    }

    /// `accountScopedKey`, after the account that owns the server's data
    /// from before accounts takes over the old key's value.
    func adoptedAccountScopedKey(_ prefix: String, suffix: String? = nil, defaults: SharedDefaults) -> String {
        guard let localAccountId else { return accountScopedKey(prefix, suffix: suffix) }
        return AccountScopedKeyAdoption.adoptedKey(
            prefix,
            serverId: serverId,
            localAccountId: localAccountId,
            profileId: profileId,
            suffix: suffix,
            defaults: defaults
        )
    }
}

/// Everything this device keeps for one account outside the keychain:
/// account-scoped preferences and caches (`AccountScopedKeyAdoption` keys),
/// player settings scopes and their queued writes, response snapshots, and
/// the onboarding retry marker. Downloads and push state have their own
/// owners.
enum AccountLocalData {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "AccountLocalData"
    )

    /// Prefixes of the stores whose keys from before accounts were
    /// `<prefix>.<server>.<profile>…`. Adoption moves them to the legacy
    /// owner's keys; purge deletes what is left when that owner goes.
    static var legacyKeyPrefixes: [String] {
        var prefixes = [
            TitleArtPreferences.cachePrefix,
            SeekIntervalPreferences.cachePrefix,
            EpisodeSpoilerCache.prefix,
            HiddenLibraryPreference.cachePrefix,
            UICustomizationPreferences.cachePrefix,
            AppNavPreferences.storagePrefix,
            BrowsePrefsStore.platformPrefix,
        ]
        #if os(tvOS)
        prefixes.append(TVLibraryScopeStore.prefix)
        #endif
        return prefixes
    }

    /// Deletes every preference, cache entry, and snapshot this device keeps
    /// for `localAccountId` on `serverId`. When the account owned the
    /// server's data from before accounts (`ownedLegacyData`; nil asks
    /// `LegacyLocalDataOwner`, so call this before `AccountStore.signOut`
    /// drops the ownership, or pass the answer read before it), the old
    /// server-and-profile entries not yet adopted go too.
    ///
    /// In-memory copies (`ResponseCache`, loaded stores) are the caller's:
    /// sign-out already resets them.
    @MainActor
    static func purge(localAccountId: String, serverId: String, ownedLegacyData: Bool? = nil) {
        guard Account.isValidServerId(serverId), Account.isValidLocalAccountId(localAccountId) else {
            logger.error("Refusing to purge local data for a malformed account scope.")
            return
        }
        let includingLegacy = ownedLegacyData
            ?? (LegacyLocalDataOwner.localAccountId(forServer: serverId) == localAccountId)
        let defaults = SharedDefaults.shared
        let prefixes = legacyKeyPrefixes
        for key in defaults.allKeys {
            if AccountScopedKeyAdoption.isKey(key, ofAccount: localAccountId, onServer: serverId)
                || (includingLegacy && AccountScopedKeyAdoption.isLegacyKey(key, prefixes: prefixes, serverId: serverId)) {
                defaults.removeObject(forKey: key)
            }
        }
        PlayerSettings.purgeLocalData(localAccountId: localAccountId, serverId: serverId, includingLegacy: includingLegacy)
        ResponseSnapshotStore.removeAll(ofAccount: localAccountId, onServer: serverId, includingLegacy: includingLegacy)
        UnrenderableOnboardingTourSuppression.purge(
            localAccountId: localAccountId,
            serverId: serverId,
            includingLegacy: includingLegacy
        )
    }
}
