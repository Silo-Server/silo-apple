//
//  EpisodeSpoilerCache.swift
//  Silo (iOS + tvOS + macOS + Top Shelf)
//
//  Where the app keeps the spoiler switches the server last confirmed for
//  each server and profile. The cache lives in the App Group, so the Top
//  Shelf extension can honor the image switch without asking the server.
//  EpisodeSpoilerPreferences writes it.
//

import Foundation

enum EpisodeSpoilerCache {
    static func key(serverId: String, profileId: String) -> String {
        "silo.episodeSpoilers.\(serverId).\(profileId)"
    }

    /// Whether the profile's last confirmed answer hides unwatched episode
    /// images. False without an answer, like the app before its first read.
    static func hidesImages(
        serverId: String?,
        profileId: String?,
        in defaults: UserDefaults = SharedStorage.suite
    ) -> Bool {
        guard let serverId, let profileId, !profileId.isEmpty,
              let data = defaults.data(forKey: key(serverId: serverId, profileId: profileId)),
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
