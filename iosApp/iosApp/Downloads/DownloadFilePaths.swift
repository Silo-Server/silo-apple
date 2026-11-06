import Foundation
import OSLog

/// On-disk layout for offline downloads. Everything lives under
/// Application Support (NOT Caches — the OS purges Caches under storage
/// pressure and downloaded media must survive that). Paths are scoped by
/// `(serverId, localAccountId, profileId)` so a profile, account, or server
/// switch is just a different directory tree. Profile IDs repeat across
/// accounts on one server (older accounts all have `default`), so the
/// account has its own level.
///
/// ```
/// <AppSupport>/SiloDownloads/
///   .legacy-downloads-removed    (see `LegacyDownloadStorage`)
///   staging/task-<n>.bin         (finished untagged transfers, see below)
/// <AppSupport>/SiloDownloads/<serverId>/acct-<localAccountId>/<profileId>/
///   store.json
///   <downloadId>/
///     media.<ext>
///     manifest.json
///     poster.jpg | backdrop.jpg | logo.png | series_poster.jpg
///     sub_<n>.<ext>
///     transfer.finished          (a finished transfer waiting for its record)
/// ```
///
/// A finished transfer is parked as `transfer.finished` in its owner's
/// download directory, whichever scope is loaded, and becomes `media.<ext>`
/// once that scope's store is loaded and its record accepts it.
///
/// Builds from before accounts saved `<serverId>/<profileId>/` with no
/// account level. Only the account that adopted the server's data from
/// before accounts (`AccountStore.legacyDataOwner(forServer:)`) takes those
/// directories over, when its downloads first load (`DownloadStore`); no
/// other code reads them.
///
/// `DownloadRecord` stores **relative filenames** (e.g. `media.mp4`), not
/// absolute URLs, because the iOS app-container path can change between
/// launches. Absolute URLs are rebuilt here against the current container.
enum DownloadFilePaths {
    private static let logger = Logger.downloads

    private static let rootFolderName = "SiloDownloads"
    static let storeFileName = "store.json"
    static let stagingFolderName = "staging"

    /// `<AppSupport>/SiloDownloads` as a path only; `rootDirectory()`
    /// creates it.
    private static let rootURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(rootFolderName, isDirectory: true)

    /// `<AppSupport>/SiloDownloads`, created on first use and excluded from
    /// iCloud/iTunes backup (downloads are large and not re-uploadable).
    /// Re-checked on each call: the legacy removal recreates the folder.
    static func rootDirectory() -> URL {
        ensureDirectory(rootURL, excludeFromBackup: true)
        return rootURL
    }

    /// Names an account's level inside a server's directory. Profile IDs
    /// are UUIDs or `default`, so none starts with it.
    static let accountFolderPrefix = "acct-"

    /// `<root>/<serverId>` as a path only.
    static func serverPath(serverId: String, root: URL) -> URL {
        root.appendingPathComponent(sanitize(serverId), isDirectory: true)
    }

    /// `<root>/<serverId>/acct-<localAccountId>`, holding every profile
    /// scope of one account, as a path only.
    static func accountPath(serverId: String, localAccountId: String, root: URL) -> URL {
        serverPath(serverId: serverId, root: root)
            .appendingPathComponent(accountFolderName(localAccountId: localAccountId), isDirectory: true)
    }

    /// A scope's directory as a path only; `scopeDirectory` creates it.
    static func scopePath(serverId: String, localAccountId: String, profileId: String, root: URL) -> URL {
        accountPath(serverId: serverId, localAccountId: localAccountId, root: root)
            .appendingPathComponent(sanitize(profileId), isDirectory: true)
    }

    static func scopeDirectory(
        serverId: String, localAccountId: String, profileId: String, root: URL = rootDirectory()
    ) -> URL {
        let dir = scopePath(serverId: serverId, localAccountId: localAccountId, profileId: profileId, root: root)
        ensureDirectory(dir)
        return dir
    }

    static func storeFileURL(
        serverId: String, localAccountId: String, profileId: String, root: URL = rootDirectory()
    ) -> URL {
        scopeDirectory(serverId: serverId, localAccountId: localAccountId, profileId: profileId, root: root)
            .appendingPathComponent(storeFileName, isDirectory: false)
    }

    /// The profile scopes under an account's directory.
    static func profileScopes(serverId: String, localAccountId: String, root: URL) -> [URL] {
        subdirectories(of: accountPath(serverId: serverId, localAccountId: localAccountId, root: root))
    }

    /// The `<serverId>/<profileId>/` scopes a build from before accounts
    /// saved: every directory in the server's folder outside an account
    /// level. Read only to hand them to the server's legacy data owner.
    static func scopesFromBeforeAccounts(serverId: String, root: URL) -> [URL] {
        subdirectories(of: serverPath(serverId: serverId, root: root))
            .filter { !$0.lastPathComponent.hasPrefix(accountFolderPrefix) }
    }

    /// Moves `source` to `destination`, creating its parent. When
    /// `destination` already exists, their contents merge: directories in
    /// both merge the same way, and of two files with one name the newer
    /// stays. Returns true once nothing is left at `source`; a failed move
    /// leaves the rest in place to try again.
    static func merge(_ source: URL, into destination: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: destination.path) else {
            do {
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: source, to: destination)
                return true
            } catch {
                logger.error("Failed to move download data: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        if isDirectory(source), isDirectory(destination) {
            let children = (try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? []
            for child in children {
                _ = merge(child, into: destination.appendingPathComponent(child.lastPathComponent))
            }
            if (try? fm.contentsOfDirectory(atPath: source.path))?.isEmpty == true {
                try? fm.removeItem(at: source)
            }
        } else if modificationDate(source) > modificationDate(destination) {
            guard (try? fm.removeItem(at: destination)) != nil else { return false }
            return merge(source, into: destination)
        } else {
            try? fm.removeItem(at: source)
        }
        return !fm.fileExists(atPath: source.path)
    }

    /// Staging area where the background session delegate moves the temp
    /// file (only valid during the delegate callback) of a finished task
    /// that carries no `DownloadTaskTag`, which only an earlier build
    /// starts. The manager then attributes it by its request and moves it
    /// on. Keyed by task identifier.
    static func stagingFileURL(taskIdentifier: Int) -> URL {
        let dir = rootDirectory().appendingPathComponent(stagingFolderName, isDirectory: true)
        ensureDirectory(dir, excludeFromBackup: true)
        return dir.appendingPathComponent("task-\(taskIdentifier).bin", isDirectory: false)
    }

    /// Removes staged files older than `age`. A file is staged and moved
    /// within moments, so an old one was left by a process that ended in
    /// between, and nothing will claim it. Returns the bytes freed.
    static func removeStaleStagingFiles(olderThan age: TimeInterval, root: URL = rootDirectory()) -> Int64 {
        let dir = root.appendingPathComponent(stagingFolderName, isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return 0 }
        let cutoff = Date().addingTimeInterval(-age)
        var freed: Int64 = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate, modified < cutoff else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil {
                freed += Int64(values.fileSize ?? 0)
            }
        }
        return freed
    }

    static func downloadDirectory(serverId: String, localAccountId: String, profileId: String, downloadId: String) -> URL {
        let dir = scopeDirectory(serverId: serverId, localAccountId: localAccountId, profileId: profileId)
            .appendingPathComponent(sanitize(downloadId), isDirectory: true)
        ensureDirectory(dir)
        return dir
    }

    /// Absolute URL for a relative filename stored on a `DownloadRecord`.
    /// Path math only, with no file-system calls, so list rows can resolve
    /// artwork on every render. Use `fileURLForWriting` to create a file.
    static func fileURL(
        serverId: String,
        localAccountId: String,
        profileId: String,
        downloadId: String,
        filename: String
    ) -> URL {
        downloadPath(serverId: serverId, localAccountId: localAccountId, profileId: profileId, downloadId: downloadId)
            .appendingPathComponent(filename, isDirectory: false)
    }

    /// `fileURL`, after creating the download's directory.
    static func fileURLForWriting(
        serverId: String,
        localAccountId: String,
        profileId: String,
        downloadId: String,
        filename: String
    ) -> URL {
        downloadDirectory(serverId: serverId, localAccountId: localAccountId, profileId: profileId, downloadId: downloadId)
            .appendingPathComponent(filename, isDirectory: false)
    }

    static let finishedTransferFilename = "transfer.finished"

    /// Where a finished transfer waits in its owner's download directory
    /// until that scope's store is loaded and its record accepts it.
    static func finishedTransferURL(for tag: DownloadTaskTag) -> URL {
        fileURL(
            serverId: tag.serverId,
            localAccountId: tag.localAccountId,
            profileId: tag.profileId,
            downloadId: tag.downloadId,
            filename: finishedTransferFilename
        )
    }

    /// Moves a finished transfer's file to its parked path, replacing any
    /// file there. The download's directory is created when missing: a
    /// transfer started before accounts can finish before its owner's
    /// downloads have moved under the account (see `merge`).
    static func park(_ source: URL, at destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: source, to: destination)
    }

    /// The folder names of a scope's server, account, and profile directories.
    static func scopeFolderNames(
        serverId: String, localAccountId: String, profileId: String
    ) -> (server: String, account: String, profile: String) {
        (sanitize(serverId), accountFolderName(localAccountId: localAccountId), sanitize(profileId))
    }

    private static func accountFolderName(localAccountId: String) -> String {
        accountFolderPrefix + sanitize(localAccountId)
    }

    /// The name of a download's directory inside its scope directory.
    static func directoryName(forDownloadId downloadId: String) -> String {
        sanitize(downloadId)
    }

    /// Every parked finished transfer in a scope, keyed by the name of the
    /// download directory that holds it (see `directoryName(forDownloadId:)`).
    static func finishedTransfers(
        serverId: String, localAccountId: String, profileId: String, root: URL = rootDirectory()
    ) -> [String: URL] {
        let scope = scopeDirectory(serverId: serverId, localAccountId: localAccountId, profileId: profileId, root: root)
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
    /// Also removes the download's media from every external folder that
    /// can be reached; a folder out of reach keeps its copy.
    static func removeDownloadDirectory(serverId: String, localAccountId: String, profileId: String, downloadId: String) {
        let fm = FileManager.default
        for root in [rootURL] + ExternalDownloadStorage.availableExternalRoots() {
            try? fm.removeItem(
                at: downloadPath(serverId: serverId, localAccountId: localAccountId, profileId: profileId,
                                 downloadId: downloadId, root: root)
            )
        }
    }

    /// A download's file in the download tree at `root`, such as an external
    /// folder's. Path only.
    static func fileURL(
        serverId: String, localAccountId: String, profileId: String, downloadId: String, filename: String, root: URL
    ) -> URL {
        downloadPath(serverId: serverId, localAccountId: localAccountId, profileId: profileId,
                     downloadId: downloadId, root: root)
            .appendingPathComponent(filename, isDirectory: false)
    }

    private static func downloadPath(
        serverId: String, localAccountId: String, profileId: String, downloadId: String, root: URL = rootURL
    ) -> URL {
        scopePath(serverId: serverId, localAccountId: localAccountId, profileId: profileId, root: root)
            .appendingPathComponent(sanitize(downloadId), isDirectory: true)
    }

    /// Total bytes used by all download assets in a scope.
    static func bytesUsed(serverId: String, localAccountId: String, profileId: String) -> Int64 {
        bytes(under: scopeDirectory(serverId: serverId, localAccountId: localAccountId, profileId: profileId))
    }

    /// Total bytes of the regular files under a directory.
    static func bytes(under directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
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

    #if !os(tvOS)
    /// Capacity of the device volume, for the storage hero's "X of Y on this
    /// iPhone" context. Fixed for the process, so it's read once. Zero when
    /// unavailable.
    static let totalCapacity: Int64 = {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeTotalCapacityKey])
        return Int64(values?.volumeTotalCapacity ?? 0)
    }()

    /// Free space for new downloads. A volume query; keep it out of view
    /// bodies. Zero when unavailable.
    static func availableCapacity() -> Int64 {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
    #endif

    // MARK: - Helpers

    private static func subdirectories(of url: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.filter(isDirectory)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

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

extension Logger {
    /// The category every Downloads type logs under.
    static let downloads = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Downloads"
    )
}
