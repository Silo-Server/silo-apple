import Foundation
import CryptoKit
import OSLog

/// On-disk layout for offline downloads. Everything lives under the root
/// `AppleStorageRoot` selects: Application Support everywhere it is writable,
/// because the OS purges Caches under storage pressure and downloaded media
/// should survive that. tvOS is the exception — it rejects Application Support
/// writes outright, so there Caches is the only option. Paths are scoped by
/// `(serverId, profileId)` so a profile or server switch is just a
/// different directory tree with no migration.
///
/// ```
/// <StorageRoot>/SiloDownloads/<serverId>/<profileId>/
///   store.json
///   <downloadId>/
///     media.<ext>
///     manifest.json
///     poster.jpg | backdrop.jpg | logo.png
///     sub_<n>.<ext>
/// ```
///
/// `DownloadRecord` stores **relative filenames** (e.g. `media.mp4`), not
/// absolute URLs, because the iOS app-container path can change between
/// launches. Absolute URLs are rebuilt here against the current container.
enum DownloadFilePaths {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Downloads"
    )

    private static let rootFolderName = "SiloDownloads"
    static let storeFileName = "store.json"

    /// `<StorageRoot>/SiloDownloads`, created on first use and excluded from
    /// iCloud/iTunes backup (downloads are large and not re-uploadable).
    static func rootDirectory() -> URL {
        let root = AppleStorageRoot.baseDirectory().appendingPathComponent(rootFolderName, isDirectory: true)
        ensureDirectory(root, excludeFromBackup: true)
        return root
    }

    /// New v2 downloads live outside the legacy namespace. Every credential epoch
    /// owns a distinct root; signing in again never adopts an earlier queue or asset.
    static func ownedScopeDirectory(authority: DownloadLocalAuthority, rootOverride: URL? = nil) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let key = SHA256.hash(data: try encoder.encode(authority)).map { String(format: "%02x", $0) }.joined()
        let base = rootOverride ?? AppleStorageRoot.baseDirectory()
            .appendingPathComponent("SiloDownloadsV2", isDirectory: true)
        return base.appendingPathComponent(key, isDirectory: true)
    }

    static func scopeDirectory(serverId: String, profileId: String) -> URL {
        let dir = rootDirectory()
            .appendingPathComponent(sanitize(serverId), isDirectory: true)
            .appendingPathComponent(sanitize(profileId), isDirectory: true)
        ensureDirectory(dir)
        return dir
    }

    static func storeFileURL(serverId: String, profileId: String) -> URL {
        scopeDirectory(serverId: serverId, profileId: profileId)
            .appendingPathComponent(storeFileName, isDirectory: false)
    }

    static func downloadDirectory(serverId: String, profileId: String, downloadId: String) -> URL {
        let dir = scopeDirectory(serverId: serverId, profileId: profileId)
            .appendingPathComponent(sanitize(downloadId), isDirectory: true)
        ensureDirectory(dir)
        return dir
    }

    /// Absolute URL for a relative filename stored on a `DownloadRecord`.
    static func fileURL(
        serverId: String,
        profileId: String,
        downloadId: String,
        filename: String
    ) -> URL {
        downloadDirectory(serverId: serverId, profileId: profileId, downloadId: downloadId)
            .appendingPathComponent(filename, isDirectory: false)
    }

    /// Total bytes used by all download assets in a scope.
    static func bytesUsed(serverId: String, profileId: String) -> Int64 {
        let dir = scopeDirectory(serverId: serverId, profileId: profileId)
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Total and available bytes on the device volume, for the storage hero
    /// "X of Y on this iPhone" context. Best-effort; zero when unavailable.
    struct DeviceStorage: Sendable {
        let total: Int64
        let available: Int64
    }

    static func deviceStorage() -> DeviceStorage {
#if os(tvOS)
        DeviceStorage(total: 0, available: 0)
#else
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        return DeviceStorage(
            total: Int64(values?.volumeTotalCapacity ?? 0),
            available: values?.volumeAvailableCapacityForImportantUsage ?? 0
        )
#endif
    }

    // MARK: - Helpers

    private static func ensureDirectory(_ url: URL, excludeFromBackup: Bool = false) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            do {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                logger.error("Failed to create download directory: \(String(describing: error), privacy: .private)")
            }
        }
        if excludeFromBackup {
            var mutable = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutable.setResourceValues(values)
        }
    }

    /// Strip path separators from id components used as directory names.
    /// Server IDs are base64url (already filesystem-safe) and profile IDs
    /// are UUIDs, but defend against anything unexpected.
    private static func sanitize(_ component: String) -> String {
        let allowed = component.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            if c.isLetter || c.isNumber || c == "-" || c == "_" || c == "." {
                return c
            }
            return "_"
        }
        let result = String(allowed)
        // "." and ".." survive the character filter but traverse out of the
        // scope directory when used as a path component — never let a
        // dot-only value through.
        if result.isEmpty || result.allSatisfy({ $0 == "." }) { return "_" }
        return result
    }
}
