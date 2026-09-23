import Foundation
import OSLog

/// Removes, once, the downloads that earlier versions of Silo saved on this
/// device. Their store, manifests and resume data carry identifiers and URLs
/// from the previous server API, so this version deletes them instead of
/// migrating them and tells the user once.
///
/// A marker file inside the downloads root records that the removal ran.
/// Keeping it in the root ties its lifetime to the data it guards: the
/// marker can only be missing when the root holds nothing this version
/// wrote, so a repeat run can never delete a download made after upgrading.
struct LegacyDownloadStorage: Sendable {
    enum State: Equatable, Sendable {
        case removalNeeded
        case removed(noticePending: Bool)
    }

    static let markerFileName = ".legacy-downloads-removed"
    static let noticeMessage = "Downloads from earlier versions were removed. Download them again to watch offline."

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Downloads"
    )

    private struct Marker: Codable {
        var noticePending: Bool
        /// When the removal ran. The server still lists the download rows
        /// earlier versions registered for this device; rows created before
        /// this date belong to the removed storage.
        var removedAt: Date?
    }

    let root: URL

    private var markerURL: URL {
        root.appendingPathComponent(Self.markerFileName, isDirectory: false)
    }

    /// Siblings of `root` that hold a tree moved aside by `remove()`.
    private var removedTreePrefix: String { root.lastPathComponent + ".removed-" }

    func state() -> State {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return .removalNeeded }
        // A marker that exists but can't be read still means the removal ran.
        guard let marker = readMarker() else { return .removed(noticePending: false) }
        return .removed(noticePending: marker.noticePending)
    }

    /// When the removal ran, or nil when it hasn't or the marker can't be
    /// read. Without a date nothing on the server is treated as removed.
    func removalDate() -> Date? {
        readMarker()?.removedAt
    }

    /// Deletes everything under `root` and writes the marker. Returns true
    /// when the removed storage held at least one download, which is the
    /// only case worth a notice.
    @discardableResult
    func remove(at date: Date = Date()) throws -> Bool {
        let fileManager = FileManager.default
        // A run interrupted after its move but before its marker leaves the
        // downloads in a moved-aside tree; count them so the notice survives.
        let hadDownloads = containsDownloads(root) || removedTrees().contains(where: containsDownloads)
        if fileManager.fileExists(atPath: root.path) {
            // One rename takes the whole old tree out of the live path, so a
            // failed delete can't leave half of it where this version reads.
            let aside = root.deletingLastPathComponent()
                .appendingPathComponent(removedTreePrefix + UUID().uuidString, isDirectory: true)
            do {
                try fileManager.moveItem(at: root, to: aside)
            } catch {
                Self.logger.error("Could not move legacy downloads aside; deleting in place: \(String(describing: error), privacy: .public)")
                try fileManager.removeItem(at: root)
            }
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try write(Marker(noticePending: hadDownloads, removedAt: date))
        deleteRemovedTrees()
        return hadDownloads
    }

    /// Records that the user saw the notice.
    func acknowledgeNotice() {
        guard state() == .removed(noticePending: true) else { return }
        do {
            try write(Marker(noticePending: false, removedAt: removalDate()))
        } catch {
            Self.logger.error("Could not record the legacy downloads notice: \(String(describing: error), privacy: .public)")
        }
    }

    /// Deletes trees an earlier `remove()` moved aside but could not delete.
    func deleteRemovedTrees() {
        for tree in removedTrees() {
            do {
                try FileManager.default.removeItem(at: tree)
            } catch {
                Self.logger.error("Could not delete removed legacy downloads: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Helpers

    private func readMarker() -> Marker? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    private func write(_ marker: Marker) throws {
        let data = try JSONEncoder().encode(marker)
        try data.write(to: markerURL, options: .atomic)
    }

    private func removedTrees() -> [URL] {
        let parent = root.deletingLastPathComponent()
        let entries = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.lastPathComponent.hasPrefix(removedTreePrefix) }
    }

    /// True when a `<server>/<profile>/` scope under `tree` holds a download
    /// directory or a store with at least one record. Empty scopes and
    /// capability-only stores are what every signed-in launch leaves behind.
    private func containsDownloads(_ tree: URL) -> Bool {
        for server in subdirectories(of: tree) where server.lastPathComponent != "staging" {
            for scope in subdirectories(of: server) {
                if !subdirectories(of: scope).isEmpty { return true }
                let store = scope.appendingPathComponent(DownloadFilePaths.storeFileName, isDirectory: false)
                if storeHasRecords(store) { return true }
            }
        }
        return false
    }

    private func storeHasRecords(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // An unreadable store most likely held downloads; say so.
            return true
        }
        return (object["records"] as? [String: Any])?.isEmpty == false
    }

    private func subdirectories(of url: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}
