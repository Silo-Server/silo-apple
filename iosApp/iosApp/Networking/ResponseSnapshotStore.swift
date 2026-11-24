import Foundation

/// Last-known copies of the responses the first screens draw (Home, For You,
/// the library list, library landings, first grid pages), kept in Caches per
/// server, account, and profile. A launch seeds `ResponseCache` from them
/// before the app builds, so a slow or unreachable server still opens on
/// content; fresh responses replace them as they arrive.
enum ResponseSnapshotStore {
    struct Scope: Equatable, Sendable {
        let serverId: String
        let localAccountId: String
        let profileId: String
    }

    /// Keys worth keeping, and the type each decodes as.
    static func snapshotType(forKey key: String) -> (any Codable.Type)? {
        if key == CacheKey.homeSections || key == CacheKey.recommendations { return SectionsResponse.self }
        if key == CacheKey.userLibraries { return LibrariesResponse.self }
        if key.hasPrefix("library:"), key.hasSuffix(":sections") { return SectionsResponse.self }
        if key.hasPrefix("browse:") || key.hasPrefix("tvlibrary:") {
            // A letter's page is a jump made during a visit, never a screen
            // the app opens on. Saving one per letter would push the first
            // screens out of the snapshots kept per scope.
            return CatalogFilterState.isLetterPage(cacheKey: key) ? nil : CatalogResponse.self
        }
        return nil
    }

    /// Bound per scope; the least recently written snapshots go first.
    static let maxSnapshotsPerScope = 32

    private static let queue = DispatchQueue(label: "org.siloserver.silo.response-snapshots", qos: .utility)

    /// A file name is one path component, limited to 255 bytes. A grid key
    /// with many filter selections can encode longer; that grid is not saved.
    private static let maxFileNameBytes = 255

    static func store(_ value: any Encodable, forKey key: String, scope: Scope, in root: URL = defaultRoot) {
        guard fileName(forKey: key).utf8.count <= maxFileNameBytes else { return }
        queue.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            let directory = adoptedDirectory(for: scope, in: root)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent(fileName(forKey: key)), options: .atomic)
            trim(directory)
        }
    }

    /// Removes `scope`'s snapshots whose key matches.
    static func remove(scope: Scope, in root: URL = defaultRoot, where matches: @escaping @Sendable (String) -> Bool) {
        queue.async {
            let directory = adoptedDirectory(for: scope, in: root)
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                return
            }
            for file in files {
                guard let key = key(fromFileName: file.lastPathComponent), matches(key) else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func removeAll(in root: URL = defaultRoot) {
        queue.async {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// Every snapshot for `scope`, decoded. Waits for pending writes, so it
    /// always sees the latest stored state.
    static func load(scope: Scope, in root: URL = defaultRoot) -> [(key: String, value: Any)] {
        queue.sync {
            let directory = adoptedDirectory(for: scope, in: root)
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                return []
            }
            return files.compactMap { file -> (String, Any)? in
                guard let key = key(fromFileName: file.lastPathComponent),
                      let type = snapshotType(forKey: key),
                      let data = try? Data(contentsOf: file),
                      let value = try? JSONDecoder().decode(type, from: data) else { return nil }
                return (key, value)
            }
        }
    }

    static var defaultRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ResponseSnapshots", isDirectory: true)
    }

    /// Removes every snapshot of `localAccountId` on `serverId`, and with
    /// `includingLegacy` the server's snapshots from before accounts (the
    /// account owned them). For sign-out (`AccountLocalData.purge`).
    static func removeAll(
        ofAccount localAccountId: String,
        onServer serverId: String,
        includingLegacy: Bool,
        in root: URL = defaultRoot
    ) {
        queue.async {
            guard let directories = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
                return
            }
            let accountPrefix = "\(AccountScopedKeyAdoption.versionMarker)|\(serverId)|\(localAccountId)|"
            let legacyPrefix = "\(serverId)|"
            for directory in directories {
                guard let name = decode(directory.lastPathComponent) else { continue }
                if name.hasPrefix(accountPrefix) || (includingLegacy && name.hasPrefix(legacyPrefix)) {
                    try? FileManager.default.removeItem(at: directory)
                }
            }
        }
    }

    /// Moves a merged server's snapshots to the survivor (`ServerMerge`):
    /// each listed account keeps its own, and with a `legacyTarget` the
    /// snapshots from before accounts become that account's. A scope the
    /// survivor already has keeps its own; the rest of the merged server's
    /// snapshots are deleted.
    static func moveAll(
        fromServer droppedServerId: String,
        toServer survivorServerId: String,
        accounts: Set<String>,
        legacyTarget: String?,
        in root: URL = defaultRoot
    ) {
        queue.async {
            let fm = FileManager.default
            guard let directories = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
            let marker = AccountScopedKeyAdoption.versionMarker
            for directory in directories {
                guard let name = decode(directory.lastPathComponent) else { continue }
                let parts = name.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                let scope: Scope?
                if parts.count == 4, parts[0] == marker, parts[1] == droppedServerId {
                    scope = accounts.contains(parts[2])
                        ? Scope(serverId: survivorServerId, localAccountId: parts[2], profileId: parts[3]) : nil
                } else if parts.count == 2, parts[0] == droppedServerId {
                    scope = legacyTarget.map { Scope(serverId: survivorServerId, localAccountId: $0, profileId: parts[1]) }
                } else {
                    continue
                }
                if let scope {
                    let target = self.directory(for: scope, in: root)
                    if !fm.fileExists(atPath: target.path), (try? fm.moveItem(at: directory, to: target)) != nil { continue }
                }
                try? fm.removeItem(at: directory)
            }
        }
    }

    /// `v2|<server>|<account>|<profile>`, encoded. Server and account IDs
    /// never contain "|" and no server ID is "v2", so no directory from
    /// before accounts (`<server>|<profile>`) has this name.
    private static func directory(for scope: Scope, in root: URL) -> URL {
        let name = "\(AccountScopedKeyAdoption.versionMarker)|\(scope.serverId)|\(scope.localAccountId)|\(scope.profileId)"
        return root.appendingPathComponent(encode(name), isDirectory: true)
    }

    private static func legacyDirectory(for scope: Scope, in root: URL) -> URL {
        root.appendingPathComponent(encode("\(scope.serverId)|\(scope.profileId)"), isDirectory: true)
    }

    /// `scope`'s directory, after the account that owns its server's
    /// snapshots from before accounts takes over the old one. Runs on
    /// `queue`.
    private static func adoptedDirectory(for scope: Scope, in root: URL) -> URL {
        let directory = directory(for: scope, in: root)
        AccountScopedKeyAdoption.adoptDirectory(
            from: legacyDirectory(for: scope, in: root),
            to: directory,
            serverId: scope.serverId,
            localAccountId: scope.localAccountId
        )
        return directory
    }

    private static func fileName(forKey key: String) -> String {
        encode(key) + ".json"
    }

    private static func key(fromFileName name: String) -> String? {
        guard name.hasSuffix(".json") else { return nil }
        return decode(String(name.dropLast(5)))
    }

    private static func decode(_ name: String) -> String? {
        var base64 = name
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Filename-safe and reversible.
    private static func encode(_ string: String) -> String {
        Data(string.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func trim(_ directory: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys),
              files.count > maxSnapshotsPerScope else { return }
        let oldestFirst = files.sorted {
            let lhs = (try? $0.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
            return lhs < rhs
        }
        for file in oldestFirst.prefix(files.count - maxSnapshotsPerScope) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
