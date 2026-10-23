import Foundation

/// Keys for local data that belongs to one account's profile on one server
/// (spec §8.3), and the one-time move of data saved under the older
/// server-and-profile keys.
///
/// Profile IDs repeat across accounts on one server: every account made
/// before profiles existed has `default`. A key built from the server and
/// profile alone would show one account's data to another, so keys carry
/// the account too, after a version marker:
/// `<prefix>.v2.<server>.<account>.<profile>`. Server and account IDs never
/// contain ".", so no old key equals a new one, even for a profile ID that
/// does.
///
/// Data saved before accounts belongs to the account `LegacyLocalDataOwner`
/// names for its server. The first time that account finds nothing under a
/// new key, the old key's value moves there, and the old key is deleted
/// once the copy reads back. No other account ever reads an old key. While
/// the account is unknown (a server's own session from before saved
/// sign-ins), stores keep using the old keys, as before.
enum AccountScopedKeyAdoption {
    /// Separates new keys from old ones.
    static let versionMarker = "v2"

    /// The account that owns each server's data from before accounts.
    typealias LegacyOwner = (_ serverID: String) -> String?

    // MARK: - Defaults keys

    /// `<prefix>.v2.<server>.<account>.<profile>[.<suffix>]`, or the old
    /// `<prefix>.<server>.<profile>[.<suffix>]` while the account is unknown.
    static func key(
        _ prefix: String,
        serverID: String,
        accountID: String?,
        profileID: String,
        suffix: String? = nil
    ) -> String {
        let tail = suffix.map { ".\($0)" } ?? ""
        guard let accountID else { return "\(prefix).\(serverID).\(profileID)\(tail)" }
        return "\(prefix).\(versionMarker).\(serverID).\(accountID).\(profileID)\(tail)"
    }

    /// `key(…)`, after moving the old key's value into it when the account
    /// owns the server's old data and the new key is empty. Stores resolve
    /// their key through this before reading, so the move happens first.
    static func adoptedKey(
        _ prefix: String,
        serverID: String,
        accountID: String?,
        profileID: String,
        suffix: String? = nil,
        defaults: SharedDefaults,
        legacyOwner: LegacyOwner = LegacyLocalDataOwner.accountID(forServerID:)
    ) -> String {
        let key = key(prefix, serverID: serverID, accountID: accountID, profileID: profileID, suffix: suffix)
        if let accountID {
            adoptValue(
                from: self.key(prefix, serverID: serverID, accountID: nil, profileID: profileID, suffix: suffix),
                to: key,
                serverID: serverID,
                accountID: accountID,
                defaults: defaults,
                legacyOwner: legacyOwner
            )
        }
        return key
    }

    /// The key a reader that never writes (Top Shelf) should read: the new
    /// key, or the old one while the new key is empty and the account owns
    /// the server's old data. Nothing moves.
    static func readableKey(
        _ prefix: String,
        serverID: String,
        accountID: String?,
        profileID: String,
        suffix: String? = nil,
        contains: (String) -> Bool,
        legacyOwner: LegacyOwner
    ) -> String {
        let key = key(prefix, serverID: serverID, accountID: accountID, profileID: profileID, suffix: suffix)
        guard let accountID, !contains(key), legacyOwner(serverID) == accountID else { return key }
        return self.key(prefix, serverID: serverID, accountID: nil, profileID: profileID, suffix: suffix)
    }

    /// Moves the value under `legacyKey` to `key` when `accountID` owns
    /// `serverID`'s old data and `key` holds nothing. The old key is deleted
    /// only after the copy reads back; a failed copy leaves both as they
    /// were, and the next read tries again. Returns whether a value moved.
    @discardableResult
    static func adoptValue(
        from legacyKey: String,
        to key: String,
        serverID: String,
        accountID: String,
        defaults: SharedDefaults,
        legacyOwner: LegacyOwner = LegacyLocalDataOwner.accountID(forServerID:)
    ) -> Bool {
        // The owner check comes before any read of the old key.
        guard legacyKey != key,
              !defaults.containsObject(forKey: key),
              legacyOwner(serverID) == accountID,
              defaults.containsObject(forKey: legacyKey) else { return false }
        guard copyValue(from: legacyKey, to: key, in: defaults) else {
            defaults.removeObject(forKey: key)
            return false
        }
        defaults.removeObject(forKey: legacyKey)
        return true
    }

    /// Copies one value with the setter its type needs, and reads it back.
    private static func copyValue(from source: String, to destination: String, in defaults: SharedDefaults) -> Bool {
        if let data = defaults.data(forKey: source) {
            defaults.set(data, forKey: destination)
            return defaults.data(forKey: destination) == data
        }
        guard let object = defaults.suite.object(forKey: source) else { return false }
        if let number = object as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            defaults.set(number.boolValue, forKey: destination)
            return defaults.containsObject(forKey: destination) && defaults.bool(forKey: destination) == number.boolValue
        }
        if let string = object as? String {
            defaults.set(string, forKey: destination)
            return defaults.string(forKey: destination) == string
        }
        // Numbers and other property-list values.
        defaults.suite.set(object, forKey: destination)
        guard let copied = defaults.suite.object(forKey: destination) as? NSObject,
              let original = object as? NSObject else { return false }
        return copied.isEqual(original)
    }

    // MARK: - Directories

    /// Moves `legacy` to `url` when `accountID` owns `serverID`'s old data.
    /// When `url` already exists, everything in `legacy` it lacks moves in,
    /// directory by directory; where both hold the same file, the new one
    /// stays and the old one is deleted, since nothing reads the old place
    /// for this account again. An emptied `legacy` is removed. Returns false
    /// when something `url` lacks could not move, so the caller can avoid
    /// writing over data still in the old place.
    @discardableResult
    static func adoptDirectory(
        from legacy: URL,
        to url: URL,
        serverID: String,
        accountID: String,
        fileManager: FileManager = .default,
        legacyOwner: LegacyOwner = LegacyLocalDataOwner.accountID(forServerID:)
    ) -> Bool {
        guard legacy.standardizedFileURL.path != url.standardizedFileURL.path,
              legacyOwner(serverID) == accountID,
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
                // Created meanwhile (a transfer parking into its download
                // directory, say): merge into it instead.
                guard fileManager.fileExists(atPath: destination.path) else { return false }
                return merge(source, into: destination, fileManager: fileManager)
            }
        }
        var sourceIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory) else { return true }
        switch (sourceIsDirectory.boolValue, destinationIsDirectory.boolValue) {
        case (false, false):
            // The same file in both places: the new copy wins. Left behind,
            // the old one would keep its directory, and every later
            // adoption, alive.
            try? fileManager.removeItem(at: source)
            return true
        case (true, true):
            break
        default:
            // A file where the other place has a directory: nothing merges.
            return true
        }
        guard let children = try? fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else {
            // Can't tell what the old directory still holds.
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
