import Foundation

/// Last-known copies of the responses the first screens draw (Home, For You,
/// the library list, library landings, first grid pages), kept in Caches per
/// server and profile. A launch seeds `ResponseCache` from them before the
/// app builds, so a slow or unreachable server still opens on content; fresh
/// responses replace them as they arrive.
enum ResponseSnapshotStore {
    struct Scope: Equatable, Sendable {
        let serverId: String
        let profileId: String
    }

    /// Keys worth keeping, and the type each decodes as.
    static func snapshotType(forKey key: String) -> (any Codable.Type)? {
        if key == CacheKey.homeSections || key == CacheKey.recommendations { return SectionsResponse.self }
        if key == CacheKey.userLibraries { return LibrariesResponse.self }
        if key.hasPrefix("library:"), key.hasSuffix(":sections") { return SectionsResponse.self }
        if key.hasPrefix("browse:") || key.hasPrefix("tvlibrary:") { return CatalogResponse.self }
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
            let directory = directory(for: scope, in: root)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent(fileName(forKey: key)), options: .atomic)
            trim(directory)
        }
    }

    /// Removes `scope`'s snapshots whose key matches.
    static func remove(scope: Scope, in root: URL = defaultRoot, where matches: @escaping @Sendable (String) -> Bool) {
        queue.async {
            let directory = directory(for: scope, in: root)
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
            let directory = directory(for: scope, in: root)
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

    private static func directory(for scope: Scope, in root: URL) -> URL {
        root.appendingPathComponent(encode("\(scope.serverId)|\(scope.profileId)"), isDirectory: true)
    }

    private static func fileName(forKey key: String) -> String {
        encode(key) + ".json"
    }

    private static func key(fromFileName name: String) -> String? {
        guard name.hasSuffix(".json") else { return nil }
        var base64 = String(name.dropLast(5))
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
