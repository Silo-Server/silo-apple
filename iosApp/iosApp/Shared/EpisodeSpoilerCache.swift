//
//  EpisodeSpoilerCache.swift
//  Silo (iOS + tvOS + macOS + Top Shelf)
//
//  Where the app keeps the spoiler switches the server last confirmed for
//  each server, account, and profile. The cache lives in the App Group, so
//  the Top Shelf extension can honor the image switch without asking the
//  server. EpisodeSpoilerPreferences writes it.
//

import Foundation

enum EpisodeSpoilerCache {
    static let prefix = "silo.episodeSpoilers"

    /// `silo.episodeSpoilers.v2.<server>.<account>.<profile>`, or the key
    /// from before accounts while the account is unknown.
    static func key(serverId: String, accountId: String?, profileId: String) -> String {
        AccountScopedKeyAdoption.key(prefix, serverID: serverId, accountID: accountId, profileID: profileId)
    }

    /// Whether the profile's last confirmed answer hides unwatched episode
    /// images. False without an answer, like the app before its first read.
    /// Never writes: until the app moves an answer saved before accounts,
    /// only the account that owns it (`legacyOwner`) reads the old key.
    static func hidesImages(
        serverId: String?,
        accountId: String?,
        profileId: String?,
        legacyOwner: AccountScopedKeyAdoption.LegacyOwner = LegacyLocalDataOwner.accountID(forServerID:),
        in defaults: UserDefaults = SharedStorage.suite
    ) -> Bool {
        guard let serverId, let profileId, !profileId.isEmpty else { return false }
        let key = AccountScopedKeyAdoption.readableKey(
            prefix,
            serverID: serverId,
            accountID: accountId,
            profileID: profileId,
            contains: { defaults.object(forKey: $0) != nil },
            legacyOwner: legacyOwner
        )
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return false }
        return stored.values.hidesImages
    }

    /// The image switch inside the store's cache record.
    private struct Stored: Decodable {
        struct Values: Decodable {
            let hidesImages: Bool
        }

        let values: Values
    }
}
