import Foundation

/// Finds and removes download storage that no loaded store tracks.
///
/// Inside the loaded scope, a download directory none of the store's records
/// owns is never read again, so the manager removes it after each install.
/// Everything else under the downloads root belongs to another server,
/// profile, or folder layout. It may still be in use, so it is only measured
/// here and removed when the user asks.
///
/// Removal renames each directory into a holding folder beside the root
/// first (see `setAside`). A rename is quick, so the manager does it while
/// the records it checked cannot change; the slow delete runs afterwards.
enum DownloadStorageReclaim {
    /// Beside the downloads root, so neither the scope's usage figure nor
    /// the other-storage list counts what is waiting to be deleted.
    private static let holdingSuffix = ".reclaimed"

    // MARK: - The loaded scope

    /// The download directories in a scope that the sweep may remove: every
    /// directory except hidden ones and those holding a parked finished
    /// transfer, which the parked-transfer settle owns.
    static func sweepCandidates(inScope scope: URL) -> [String] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: scope,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.compactMap { child in
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let parked = child.appendingPathComponent(DownloadFilePaths.finishedTransferFilename, isDirectory: false)
            return fm.fileExists(atPath: parked.path) ? nil : child.lastPathComponent
        }
    }

    /// The candidates no record owns. Directory names are sanitized ids.
    static func untrackedDirectories(_ candidates: [String], recordIds: some Sequence<String>) -> [String] {
        let owned = Set(recordIds.map(DownloadFilePaths.directoryName(forDownloadId:)))
        return candidates.filter { !owned.contains($0) }
    }

    // MARK: - Removal

    /// Moves each item into the holding folder beside `root`. Returns how
    /// many moved; an item that fails to move stays where it is.
    @discardableResult
    static func setAside(_ items: [URL], root: URL) -> Int {
        guard !items.isEmpty else { return 0 }
        let fm = FileManager.default
        let holding = holdingFolder(root: root)
        var moved = 0
        for item in items {
            // Per item: a delete running elsewhere may remove the folder.
            try? fm.createDirectory(at: holding, withIntermediateDirectories: true)
            // Outside the backup-excluded root, and it can outlive the
            // process when the delete doesn't finish.
            var holdingURL = holding
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? holdingURL.setResourceValues(values)
            let destination = holding.appendingPathComponent(UUID().uuidString, isDirectory: true)
            if (try? fm.moveItem(at: item, to: destination)) != nil { moved += 1 }
        }
        return moved
    }

    /// Deletes everything set aside, including what an earlier process set
    /// aside but ended before deleting. Returns the bytes freed.
    static func deleteSetAside(root: URL) -> Int64 {
        let holding = holdingFolder(root: root)
        guard FileManager.default.fileExists(atPath: holding.path) else { return 0 }
        let bytes = DownloadFilePaths.bytes(under: holding)
        return (try? FileManager.default.removeItem(at: holding)) != nil ? bytes : 0
    }

    private static func holdingFolder(root: URL) -> URL {
        root.deletingLastPathComponent()
            .appendingPathComponent(root.lastPathComponent + holdingSuffix, isDirectory: true)
    }

    // MARK: - Everything outside the loaded scope

    /// Download data under one top-level folder of the downloads root,
    /// leaving out the active scope.
    struct OtherStorage: Identifiable, Equatable, Sendable {
        /// The folder's name, normally a server id.
        let folderName: String
        /// The server URL the folder name encodes, when it encodes one.
        let serverURL: String?
        let bytes: Int64
        /// The active server's folder: it holds the other profiles' data.
        let isActiveServer: Bool

        var id: String { folderName }
    }

    /// Groups everything under `root` outside the active scope by top-level
    /// folder, largest first. `staging` and hidden entries such as the
    /// legacy marker are left out, and so is a group with no bytes.
    static func otherStorage(root: URL, activeServerFolder: String, activeProfileFolder: String) -> [OtherStorage] {
        topLevelFolders(root: root).compactMap { folder in
            let name = folder.lastPathComponent
            let isActive = name == activeServerFolder
            let bytes = removalTargets(folder: folder, excludingProfileFolder: isActive ? activeProfileFolder : nil)
                .reduce(Int64(0)) { $0 + DownloadFilePaths.bytes(under: $1) }
            guard bytes > 0 else { return nil }
            return OtherStorage(
                folderName: name,
                serverURL: ServerRegistry.url(forServerId: name),
                bytes: bytes,
                isActiveServer: isActive
            )
        }
        .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.folderName < $1.folderName }
    }

    /// What removing a group deletes: the whole folder, or for the active
    /// server every child except the active profile's scope.
    static func removalTargets(folderName: String, root: URL, activeServerFolder: String,
                               activeProfileFolder: String) -> [URL] {
        guard let folder = topLevelFolders(root: root).first(where: { $0.lastPathComponent == folderName }) else {
            return []
        }
        let isActive = folderName == activeServerFolder
        return removalTargets(folder: folder, excludingProfileFolder: isActive ? activeProfileFolder : nil)
    }

    private static func removalTargets(folder: URL, excludingProfileFolder excluded: String?) -> [URL] {
        guard let excluded else { return [folder] }
        let children = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return children.filter { $0.lastPathComponent != excluded }
    }

    private static func topLevelFolders(root: URL) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.filter {
            $0.lastPathComponent != DownloadFilePaths.stagingFolderName
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }
}
