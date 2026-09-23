import Foundation
import OSLog

/// Off-main persistence for the offline-downloads blob. Keeps disk I/O and
/// JSON (de)serialization off the MainActor; `DownloadManager` owns the
/// in-memory `@Observable` truth and reads/writes through this actor.
actor DownloadStore {
    static let shared = DownloadStore()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Downloads"
    )

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let rootDirectory: @Sendable () -> URL
    /// Scopes whose store file exists but could neither be read nor moved
    /// aside. Saving one of them would replace the file with whatever the
    /// manager built from an empty load, so saves stay off until a later
    /// load succeeds.
    private var unsavableScopes: Set<String> = []

    init(rootDirectory: @escaping @Sendable () -> URL = { DownloadFilePaths.rootDirectory() }) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        self.rootDirectory = rootDirectory
    }

    /// Load the persisted blob for a scope, or a fresh empty one when the
    /// scope has no store yet. A store that can't be decoded is renamed
    /// aside first, so the empty blob never overwrites it.
    func load(serverId: String, profileId: String) -> DownloadStoreFile {
        guard !serverId.isEmpty, !profileId.isEmpty else { return .empty }
        let scope = scopeKey(serverId: serverId, profileId: profileId)
        let url = storeFileURL(serverId: serverId, profileId: profileId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            unsavableScopes.remove(scope)
            return .empty
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Present but unreadable right now (for example, still protected
            // before first unlock). The contents may be fine, so leave them.
            Self.logger.error("Download store read failed; not saving this scope: \(String(describing: error), privacy: .public)")
            unsavableScopes.insert(scope)
            return .empty
        }
        do {
            var file = try decoder.decode(DownloadStoreFile.self, from: data)
            if file.version != DownloadStoreFile.currentVersion {
                file.version = DownloadStoreFile.currentVersion
            }
            unsavableScopes.remove(scope)
            return file
        } catch {
            Self.logger.error("Download store decode failed: \(String(describing: error), privacy: .public)")
            if quarantine(url) {
                unsavableScopes.remove(scope)
            } else {
                unsavableScopes.insert(scope)
            }
            return .empty
        }
    }

    /// Atomically persist the blob for a scope. No-op for an empty scope.
    func save(_ file: DownloadStoreFile, serverId: String, profileId: String) {
        guard !serverId.isEmpty, !profileId.isEmpty else { return }
        guard !unsavableScopes.contains(scopeKey(serverId: serverId, profileId: profileId)) else {
            // `load` already logged the cause at error level.
            Self.logger.debug("Download store save skipped: the scope's store could not be loaded")
            return
        }
        let url = storeFileURL(serverId: serverId, profileId: profileId)
        do {
            let data = try encoder.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Download store save failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Downloads saved by earlier versions

    func legacyStorageState() -> LegacyDownloadStorage.State {
        let legacy = LegacyDownloadStorage(root: rootDirectory())
        let state = legacy.state()
        if state != .removalNeeded { legacy.deleteRemovedTrees() }
        return state
    }

    /// Delete the downloads earlier versions saved and record that this ran.
    /// Returns whether the user should be told.
    func removeLegacyStorage() -> Bool {
        do {
            let hadDownloads = try LegacyDownloadStorage(root: rootDirectory()).remove()
            Self.logger.notice("Removed download storage saved by an earlier version (had downloads: \(hadDownloads, privacy: .public))")
            return hadDownloads
        } catch {
            Self.logger.error("Legacy downloads removal failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func acknowledgeLegacyRemovalNotice() {
        LegacyDownloadStorage(root: rootDirectory()).acknowledgeNotice()
    }

    /// Persist an offline manifest beside its media file. Uses the same bare
    /// coder pair as `loadManifest` so the on-disk round-trip is consistent.
    func saveManifest(_ manifest: OfflineManifest, to url: URL) {
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func loadManifest(at url: URL) -> OfflineManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(OfflineManifest.self, from: data)
    }

    // MARK: - Helpers

    private func storeFileURL(serverId: String, profileId: String) -> URL {
        DownloadFilePaths.storeFileURL(serverId: serverId, profileId: profileId, root: rootDirectory())
    }

    private func scopeKey(serverId: String, profileId: String) -> String {
        serverId + "\n" + profileId
    }

    /// Rename an undecodable store beside itself so nothing reads or
    /// overwrites it. Returns false when the file is still in place.
    private func quarantine(_ url: URL) -> Bool {
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(UUID().uuidString)", isDirectory: false)
        do {
            try FileManager.default.moveItem(at: url, to: aside)
            Self.logger.error("Quarantined the undecodable download store as \(aside.lastPathComponent, privacy: .public)")
            return true
        } catch {
            Self.logger.error("Could not quarantine the download store; not saving this scope: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
