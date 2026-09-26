import Foundation
import OSLog

/// On-disk layout for offline downloads. Everything lives under
/// Application Support (NOT Caches — the OS purges Caches under storage
/// pressure and downloaded media must survive that). Paths are scoped by
/// `(serverId, profileId)` so a profile or server switch is just a
/// different directory tree with no migration.
///
/// ```
/// <AppSupport>/SiloDownloads/
///   .legacy-downloads-removed    (see `LegacyDownloadStorage`)
///   staging/task-<n>.bin         (finished untagged transfers, see below)
/// <AppSupport>/SiloDownloads/<serverId>/<profileId>/
///   store.json
///   <downloadId>/
///     media.<ext>
///     manifest.json
///     poster.jpg | backdrop.jpg | logo.png
///     sub_<n>.<ext>
///     transfer.finished          (a finished transfer waiting for its record)
/// ```
///
/// A finished transfer is parked as `transfer.finished` in its owner's
/// download directory, whichever scope is loaded, and becomes `media.<ext>`
/// once that scope's store is loaded and its record accepts it.
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

    /// `<AppSupport>/SiloDownloads`, created on first use and excluded from
    /// iCloud/iTunes backup (downloads are large and not re-uploadable).
    static func rootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent(rootFolderName, isDirectory: true)
        ensureDirectory(root, excludeFromBackup: true)
        return root
    }

    static func scopeDirectory(serverId: String, profileId: String, root: URL = rootDirectory()) -> URL {
        let dir = root
            .appendingPathComponent(sanitize(serverId), isDirectory: true)
            .appendingPathComponent(sanitize(profileId), isDirectory: true)
        ensureDirectory(dir)
        return dir
    }

    static func storeFileURL(serverId: String, profileId: String, root: URL = rootDirectory()) -> URL {
        scopeDirectory(serverId: serverId, profileId: profileId, root: root)
            .appendingPathComponent(storeFileName, isDirectory: false)
    }

    /// Staging area where the background session delegate moves the temp
    /// file (only valid during the delegate callback) of a finished task
    /// that carries no `DownloadTaskTag`, which only an earlier build
    /// starts. The manager then attributes it by its request and moves it
    /// on. Keyed by task identifier.
    static func stagingFileURL(taskIdentifier: Int) -> URL {
        let dir = rootDirectory().appendingPathComponent("staging", isDirectory: true)
        ensureDirectory(dir, excludeFromBackup: true)
        return dir.appendingPathComponent("task-\(taskIdentifier).bin", isDirectory: false)
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

    static let finishedTransferFilename = "transfer.finished"

    /// Where a finished transfer waits in its owner's download directory
    /// until that scope's store is loaded and its record accepts it.
    static func finishedTransferURL(for tag: DownloadTaskTag) -> URL {
        fileURL(
            serverId: tag.serverId,
            profileId: tag.profileId,
            downloadId: tag.downloadId,
            filename: finishedTransferFilename
        )
    }

    /// The name of a download's directory inside its scope directory.
    static func directoryName(forDownloadId downloadId: String) -> String {
        sanitize(downloadId)
    }

    /// Every parked finished transfer in a scope, keyed by the name of the
    /// download directory that holds it (see `directoryName(forDownloadId:)`).
    static func finishedTransfers(serverId: String, profileId: String, root: URL = rootDirectory()) -> [String: URL] {
        let scope = scopeDirectory(serverId: serverId, profileId: profileId, root: root)
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: scope,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [:] }
        var parked: [String: URL] = [:]
        for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let url = child.appendingPathComponent(finishedTransferFilename, isDirectory: false)
            if fm.fileExists(atPath: url.path) {
                parked[child.lastPathComponent] = url
            }
        }
        return parked
    }

    /// Delete every on-disk asset for one download (media, manifest,
    /// artwork, subtitles). The JSON store record is removed separately.
    static func removeDownloadDirectory(serverId: String, profileId: String, downloadId: String) {
        let dir = scopeDirectory(serverId: serverId, profileId: profileId)
            .appendingPathComponent(sanitize(downloadId), isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
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
