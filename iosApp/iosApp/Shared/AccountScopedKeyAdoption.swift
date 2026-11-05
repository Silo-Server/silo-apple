import Foundation
import Synchronization

/// Keys for local data that belongs to one account's profile on one server
/// (spec §5.1), and the one-time move of data saved under the older
/// server-and-profile keys.
///
/// Profile IDs repeat across accounts on one server: every account made
/// before profiles existed has `default`. A key built from the server and
/// profile alone would show one account's data to another, so keys carry
/// the account too, after a version marker:
/// `<prefix>.v2.<server>.<localAccountId>.<profile>`. Server and account IDs
/// never contain ".", so no old key equals a new one, even for a profile ID
/// that does.
///
/// Data saved before accounts belongs to the account `LegacyLocalDataOwner`
/// names for its server. The first time that account finds nothing under a
/// new key, the old key's value moves there, and the old key is deleted
/// once the copy reads back. No other account ever reads an old key.
enum AccountScopedKeyAdoption {
    /// Separates new keys from old ones.
    static let versionMarker = "v2"

    /// The account that owns each server's data from before accounts.
    typealias LegacyOwner = (_ serverId: String) -> String?

    // MARK: - Defaults keys

    /// `<prefix>.v2.<server>.<localAccountId>.<profile>[.<suffix>]`.
    static func key(
        _ prefix: String,
        serverId: String,
        localAccountId: String,
        profileId: String,
        suffix: String? = nil
    ) -> String {
        "\(prefix).\(versionMarker).\(serverId).\(localAccountId).\(profileId)" + (suffix.map { ".\($0)" } ?? "")
    }

    /// `<prefix>.<server>.<profile>[.<suffix>]`, the key from before
    /// accounts. Only adoption reads it.
    static func legacyKey(_ prefix: String, serverId: String, profileId: String, suffix: String? = nil) -> String {
        "\(prefix).\(serverId).\(profileId)" + (suffix.map { ".\($0)" } ?? "")
    }

    /// `key(…)`, after moving the old key's value into it when the account
    /// owns the server's old data and the new key is empty. Stores resolve
    /// their key through this before reading, so the move happens first.
    static func adoptedKey(
        _ prefix: String,
        serverId: String,
        localAccountId: String,
        profileId: String,
        suffix: String? = nil,
        defaults: SharedDefaults,
        legacyOwner: LegacyOwner = LegacyLocalDataOwner.localAccountId(forServer:)
    ) -> String {
        let key = key(prefix, serverId: serverId, localAccountId: localAccountId, profileId: profileId, suffix: suffix)
        adoptValue(
            from: legacyKey(prefix, serverId: serverId, profileId: profileId, suffix: suffix),
            to: key,
            serverId: serverId,
            localAccountId: localAccountId,
            defaults: defaults,
            legacyOwner: legacyOwner
        )
        return key
    }

    /// The key a reader that never writes (Top Shelf) should read: the new
    /// key, or the old one while the new key is empty and the account owns
    /// the server's old data. Nothing moves.
    static func readableKey(
        _ prefix: String,
        serverId: String,
        localAccountId: String,
        profileId: String,
        suffix: String? = nil,
        contains: (String) -> Bool,
        legacyOwner: LegacyOwner = LegacyLocalDataOwner.localAccountId(forServer:)
    ) -> String {
        let key = key(prefix, serverId: serverId, localAccountId: localAccountId, profileId: profileId, suffix: suffix)
        guard !contains(key), legacyOwner(serverId) == localAccountId else { return key }
        return legacyKey(prefix, serverId: serverId, profileId: profileId, suffix: suffix)
    }

    /// Moves the value under `legacyKey` to `key` when `localAccountId` owns
    /// `serverId`'s old data and `key` holds nothing. The old key is deleted
    /// only after the copy reads back; a failed copy leaves both as they
    /// were, and the next read tries again. Returns whether a value moved.
    @discardableResult
    static func adoptValue(
        from legacyKey: String,
        to key: String,
        serverId: String,
        localAccountId: String,
        defaults: SharedDefaults,
        legacyOwner: LegacyOwner = LegacyLocalDataOwner.localAccountId(forServer:)
    ) -> Bool {
        // The owner check comes before any read of the old key, and costs no
        // defaults read for every other account.
        guard legacyKey != key,
              legacyOwner(serverId) == localAccountId,
              !defaults.containsObject(forKey: key),
              let value = defaults.object(forKey: legacyKey) else { return false }
        defaults.setObject(value, forKey: key)
        guard let copied = defaults.object(forKey: key) as? NSObject,
              let original = value as? NSObject,
              copied.isEqual(original) else {
            defaults.removeObject(forKey: key)
            return false
        }
        defaults.removeObject(forKey: legacyKey)
        return true
    }

    // MARK: - Purge

    /// Whether `key` is an account-scoped key (`key(…)`) of `localAccountId`
    /// on `serverId`, for any prefix, profile, and suffix.
    static func isKey(_ key: String, ofAccount localAccountId: String, onServer serverId: String) -> Bool {
        key.contains(".\(versionMarker).\(serverId).\(localAccountId).")
    }

    /// Whether `key` is an old key (`legacyKey(…)`) of `serverId` under one
    /// of `prefixes`.
    static func isLegacyKey(_ key: String, prefixes: [String], serverId: String) -> Bool {
        prefixes.contains { key.hasPrefix("\($0).\(serverId).") }
    }

    // MARK: - Directories

    /// Moves `legacy` to `url` when `localAccountId` owns `serverId`'s old
    /// data. When `url` already exists, everything in `legacy` it lacks
    /// moves in, directory by directory; where both hold the same file, the
    /// new one stays and the old one is deleted, since nothing reads the old
    /// place for this account again. An emptied `legacy` is removed. Returns
    /// false when something `url` lacks could not move.
    @discardableResult
    static func adoptDirectory(
        from legacy: URL,
        to url: URL,
        serverId: String,
        localAccountId: String,
        fileManager: FileManager = .default,
        legacyOwner: LegacyOwner = LegacyLocalDataOwner.localAccountId(forServer:)
    ) -> Bool {
        guard legacy.standardizedFileURL.path != url.standardizedFileURL.path,
              legacyOwner(serverId) == localAccountId,
              fileManager.fileExists(atPath: legacy.path) else { return true }
        return merge(legacy, into: url, fileManager: fileManager)
    }

    private static func merge(_ source: URL, into destination: URL, fileManager: FileManager) -> Bool {
        var destinationIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &destinationIsDirectory) else {
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: source, to: destination)
                return true
            } catch {
                // Created meanwhile: merge into it instead.
                guard fileManager.fileExists(atPath: destination.path) else { return false }
                return merge(source, into: destination, fileManager: fileManager)
            }
        }
        var sourceIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory) else { return true }
        switch (sourceIsDirectory.boolValue, destinationIsDirectory.boolValue) {
        case (false, false):
            // The same file in both places: the new copy wins.
            try? fileManager.removeItem(at: source)
            return true
        case (true, true):
            break
        default:
            // A file where the other place has a directory: nothing merges.
            return true
        }
        guard let children = try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else {
            return false
        }
        var complete = true
        for child in children {
            let target = destination.appendingPathComponent(child.lastPathComponent)
            complete = merge(child, into: target, fileManager: fileManager) && complete
        }
        if (try? fileManager.contentsOfDirectory(atPath: source.path))?.isEmpty == true {
            try? fileManager.removeItem(at: source)
        }
        return complete
    }
}

/// Which account on each server takes over local data stored under the old
/// server-and-profile keys: a process-wide copy of
/// `AccountIndex.legacyDataOwners`, so stores can ask on every key lookup
/// without reading the keychain. `AccountStore.shared` publishes it after
/// every index read and write; the first lookup before that reads the index.
enum LegacyLocalDataOwner {
    private static let owners = Mutex<[String: String]?>(nil)

    static func localAccountId(forServer serverId: String) -> String? {
        if let known = owners.withLock({ $0 }) { return known[serverId] }
        // A read error leaves the cache unset, so the next lookup tries
        // again; until then no account adopts anything, and the old keys wait.
        let known: [String: String]
        do { known = try AccountStore.shared.loadIndex()?.legacyDataOwners ?? [:] } catch { return nil }
        publish(known)
        return known[serverId]
    }

    static func publish(_ owners: [String: String]) {
        self.owners.withLock { $0 = owners }
    }
}

/// Which saved server took each merged server's accounts: a process-wide
/// copy of `AccountIndex.mergedServerIds`, published like
/// `LegacyLocalDataOwner` so synchronous readers can resolve a dropped ID.
enum MergedServerIds {
    private static let merged = Mutex<[String: String]?>(nil)

    /// The server `serverId` was merged into, or nil when it never was.
    static func survivor(of serverId: String) -> String? {
        if let known = merged.withLock({ $0 }) { return known[serverId] }
        // Loading the index publishes it; a read error leaves the cache
        // unset and nothing resolves until the next lookup.
        return (try? AccountStore.shared.loadIndex())?.mergedServerIds?[serverId]
    }

    private static let legacyOwners = Mutex<[String: String]?>(nil)

    /// The account that took merged server `serverId`'s data from before
    /// accounts (`AccountIndex.mergedLegacyDataOwners`), or nil.
    static func legacyDataOwner(of serverId: String) -> String? {
        if let known = legacyOwners.withLock({ $0 }) { return known[serverId] }
        return (try? AccountStore.shared.loadIndex())?.mergedLegacyDataOwners?[serverId]
    }

    static func publish(_ ids: [String: String], legacyDataOwners: [String: String]) {
        merged.withLock { $0 = ids }
        legacyOwners.withLock { $0 = legacyDataOwners }
    }
}

/// Which account took each account a server merge removed: a process-wide
/// copy of `AccountIndex.mergedAccountIds`, published like `MergedServerIds`.
enum MergedAccountIds {
    private static let merged = Mutex<[String: String]?>(nil)

    /// The account `localAccountId` was merged into, or nil when it never was.
    static func kept(for localAccountId: String) -> String? {
        if let known = merged.withLock({ $0 }) { return known[localAccountId] }
        return (try? AccountStore.shared.loadIndex())?.mergedAccountIds?[localAccountId]
    }

    static func publish(_ ids: [String: String]) {
        merged.withLock { $0 = ids }
    }
}

extension AccountScope {
    /// The selected account when it is on `serverId`, else nil. For stores
    /// that already know their server and profile.
    static func localAccountId(onServer serverId: String, defaults: SharedDefaults = .shared) -> String? {
        guard let selection = AccountSelection.load(from: defaults), selection.serverId == serverId else {
            return nil
        }
        return selection.localAccountId
    }

    /// `AccountScopedKeyAdoption.adoptedKey` for this scope's profile. Nil
    /// while no profile is selected: an anonymous key would leak one
    /// person's choice into the next profile.
    func adoptedKey(_ prefix: String, suffix: String? = nil, defaults: SharedDefaults) -> String? {
        guard let profileId else { return nil }
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
