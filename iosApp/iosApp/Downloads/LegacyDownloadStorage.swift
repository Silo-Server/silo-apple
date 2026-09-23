import Foundation
import OSLog

/// Removes, once, the downloads that earlier versions of Silo saved on this
/// device. Their store, manifests and resume data carry identifiers and URLs
/// from the previous server API, so this version deletes them instead of
/// migrating them and tells the user once.
///
/// Offline watch progress the earlier version had not uploaded yet is not a
/// download: it is carried into a fresh store for the same scope and uploaded
/// by the next online sync.
///
/// Each carried store is also flagged `legacyRowsPending`: the server still
/// lists the rows the earlier version registered for this device, and the
/// scope's first complete registry read deletes them instead of importing
/// them; its first complete monitor list likewise sets aside the monitors
/// that version created. Only scopes the earlier version actually wrote are
/// flagged, so a
/// reinstall (which starts with no downloads root) never treats rows this
/// version registered as legacy.
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

    /// What one `remove()` run did.
    struct Removal: Equatable, Sendable {
        /// The removed storage held at least one download, the only case
        /// worth a notice.
        var hadDownloads: Bool
        /// Every step ran, including the marker. When false the next launch
        /// runs the removal again, and until then nothing can tell this
        /// device's legacy server rows from new ones.
        var completed: Bool
    }

    static let markerFileName = ".legacy-downloads-removed"
    static let noticeMessage = "Downloads from earlier versions were removed. Download them again to watch offline."

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Downloads"
    )

    private struct Marker: Codable {
        var noticePending: Bool
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

    /// Deletes everything under `root`, keeps the offline progress earlier
    /// versions had queued, and writes the marker. Never throws: a failed
    /// step is logged and reported as an incomplete removal.
    func remove() -> Removal {
        let fileManager = FileManager.default
        // A run interrupted after its move but before its marker leaves the
        // downloads in a moved-aside tree; read those too, so neither the
        // notice nor the queued progress is lost.
        let sources = (fileManager.fileExists(atPath: root.path) ? [root] : []) + removedTrees()
        let hadDownloads = sources.contains(where: containsDownloads)
        let carried = carriedScopes(in: sources)
        do {
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
            try writeCarriedStores(carried)
        } catch {
            // The moved-aside trees stay: the next launch reads them again.
            Self.logger.error("Legacy downloads removal did not finish: \(String(describing: error), privacy: .public)")
            return Removal(hadDownloads: hadDownloads, completed: false)
        }
        // What had to survive is in the new root now, so the old trees go
        // even when the marker can't be written (for example, a full disk).
        defer { deleteRemovedTrees() }
        do {
            try write(Marker(noticePending: hadDownloads))
        } catch {
            Self.logger.error("Could not record the legacy downloads removal: \(String(describing: error), privacy: .public)")
            return Removal(hadDownloads: hadDownloads, completed: false)
        }
        return Removal(hadDownloads: hadDownloads, completed: true)
    }

    /// Records that the user saw the notice.
    func acknowledgeNotice() {
        guard state() == .removed(noticePending: true) else { return }
        do {
            try write(Marker(noticePending: false))
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

    // MARK: - Carried scopes

    /// Every `<server>/<profile>/` scope the earlier version wrote, keyed by
    /// its path relative to the tree, with the newest queued progress entry
    /// per item across all `trees`.
    private func carriedScopes(in trees: [URL]) -> [String: [QueuedProgress]] {
        var scopes: [String: [String: QueuedProgress]] = [:]
        for tree in trees {
            for server in subdirectories(of: tree) where server.lastPathComponent != "staging" {
                for scope in subdirectories(of: server) {
                    let key = server.lastPathComponent + "/" + scope.lastPathComponent
                    var newest = scopes[key] ?? [:]
                    let store = scope.appendingPathComponent(DownloadFilePaths.storeFileName, isDirectory: false)
                    for entry in queuedProgress(in: store) {
                        if let kept = newest[entry.mediaItemId], kept.updatedAt >= entry.updatedAt { continue }
                        newest[entry.mediaItemId] = entry
                    }
                    scopes[key] = newest
                }
            }
        }
        return scopes.mapValues { $0.values.sorted { $0.updatedAt < $1.updatedAt } }
    }

    /// The store's queued progress. Read without the store's Codable model so
    /// a store that no longer decodes still gives up its queue; an entry that
    /// can't be read is logged and dropped.
    private func queuedProgress(in store: URL) -> [QueuedProgress] {
        guard let data = try? Data(contentsOf: store),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let queue = object["progressQueue"] as? [Any] else { return [] }
        var entries: [QueuedProgress] = []
        for raw in queue {
            // Earlier versions wrote the default JSONEncoder date: seconds
            // since 2001-01-01.
            guard let fields = raw as? [String: Any],
                  let id = (fields["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let mediaItemId = fields["mediaItemId"] as? String, !mediaItemId.isEmpty,
                  let position = (fields["position"] as? NSNumber)?.doubleValue,
                  let duration = (fields["duration"] as? NSNumber)?.doubleValue,
                  let updatedAt = (fields["updatedAt"] as? NSNumber)?.doubleValue else {
                Self.logger.error("Dropped an unreadable queued progress entry from an earlier version's store")
                continue
            }
            entries.append(QueuedProgress(
                id: id,
                mediaItemId: mediaItemId,
                position: position,
                duration: duration,
                updatedAt: Date(timeIntervalSinceReferenceDate: updatedAt),
                // Earlier versions wrote no state: their entries were never
                // claimed for a v2 upload. A store from an interrupted removal
                // keeps a held entry held.
                state: (fields["state"] as? String).flatMap(QueuedProgress.State.init(rawValue:)) ?? .pending
            ))
        }
        return entries
    }

    /// Writes a fresh store for each carried scope, holding its queued
    /// progress and flagged so its first registry read deletes the earlier
    /// version's server rows.
    private func writeCarriedStores(_ scopes: [String: [QueuedProgress]]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        for (path, queue) in scopes {
            let directory = root.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var file = DownloadStoreFile.empty
            file.progressQueue = queue
            file.legacyRowsPending = true
            file.legacyMonitorsPending = true
            try encoder.encode(file).write(
                to: directory.appendingPathComponent(DownloadFilePaths.storeFileName, isDirectory: false),
                options: .atomic
            )
        }
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
