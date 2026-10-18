import Foundation
import OSLog

/// Off-main persistence for the offline-downloads blob. Keeps disk I/O and
/// JSON (de)serialization off the MainActor; `DownloadManager` owns the
/// in-memory `@Observable` truth and reads/writes through this actor.
actor DownloadStore {
    static let shared = DownloadStore()

    private static let logger = Logger.downloads

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let rootDirectory: @Sendable () -> URL
    private let legacyOwner: @Sendable (String) -> String?
    /// Scopes whose store file exists but could neither be read nor moved
    /// aside, or whose downloads from before accounts could not move to
    /// their account. Saving one of them would replace the file with
    /// whatever the manager built from an empty load, so saves stay off
    /// until a later load succeeds.
    private var unsavableScopes: Set<String> = []

    init(
        rootDirectory: @escaping @Sendable () -> URL = { DownloadFilePaths.rootDirectory() },
        legacyOwner: @escaping @Sendable (String) -> String? = { LegacyLocalDataOwner.accountID(forServerID: $0) }
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = encoder
        self.decoder = JSONDecoder()
        self.rootDirectory = rootDirectory
        self.legacyOwner = legacyOwner
    }

    /// Load the persisted blob for a scope, or a fresh empty one when the
    /// scope has no store yet. A store that can't be decoded is renamed
    /// aside first, so the empty blob never overwrites it.
    ///
    /// For the account that owns its server's downloads from before
    /// accounts, the old `<server>/<profile>` directory moves to this
    /// scope's first, and whatever an earlier build left there later (a
    /// transfer it finished after the move) follows on each load. When
    /// that move fails the scope loads empty and unsavable, and the next
    /// load tries again.
    func load(serverId: String, accountId: String?, profileId: String) -> DownloadStoreFile {
        guard !serverId.isEmpty, !profileId.isEmpty else { return .empty }
        let scope = scopeKey(serverId: serverId, accountId: accountId, profileId: profileId)
        if let accountId, !adoptLegacyScope(serverId: serverId, accountId: accountId, profileId: profileId) {
            Self.logger.error("Downloads saved before accounts could not move to their account; not saving this scope")
            unsavableScopes.insert(scope)
            return .empty
        }
        let url = storeFileURL(serverId: serverId, accountId: accountId, profileId: profileId)
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
            let file = try decoder.decode(DownloadStoreFile.self, from: data)
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

    /// `load`, and whether the scope loaded in full. An incomplete scope (its
    /// store or its downloads from before accounts are still where `load`
    /// couldn't read or move them) knows none of the downloads in its
    /// directories, so nothing may be saved over them or deleted from them.
    func loadScope(serverId: String, accountId: String?, profileId: String) -> (file: DownloadStoreFile, isComplete: Bool) {
        let file = load(serverId: serverId, accountId: accountId, profileId: profileId)
        return (file, !unsavableScopes.contains(scopeKey(serverId: serverId, accountId: accountId, profileId: profileId)))
    }

    /// Atomically persist the blob for a scope. No-op for an empty scope.
    func save(_ file: DownloadStoreFile, serverId: String, accountId: String?, profileId: String) {
        guard !serverId.isEmpty, !profileId.isEmpty else { return }
        guard !unsavableScopes.contains(scopeKey(serverId: serverId, accountId: accountId, profileId: profileId)) else {
            // `load` already logged the cause at error level.
            Self.logger.debug("Download store save skipped: the scope's store could not be loaded")
            return
        }
        let url = storeFileURL(serverId: serverId, accountId: accountId, profileId: profileId)
        do {
            let data = try encoder.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("Download store save failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Returns claimed offline progress entries to pending in a scope's
    /// stored file, for a flush whose scope changed before it could resolve
    /// them. No-op when the scope has no store or nothing changes.
    func releaseProgressClaims(_ ids: Set<UUID>, serverId: String, accountId: String?, profileId: String) {
        guard !serverId.isEmpty, !profileId.isEmpty,
              FileManager.default.fileExists(
                  atPath: storeFileURL(serverId: serverId, accountId: accountId, profileId: profileId).path
              )
        else { return }
        var file = load(serverId: serverId, accountId: accountId, profileId: profileId)
        guard OfflineProgressQueue.releaseClaims(&file.progressQueue, ids: ids) else { return }
        save(file, serverId: serverId, accountId: accountId, profileId: profileId)
    }

    // MARK: - Downloads saved by earlier versions

    func legacyStorageState() -> LegacyDownloadStorage.State {
        let legacy = LegacyDownloadStorage(root: rootDirectory())
        let state = legacy.state()
        if state != .removalNeeded { legacy.deleteRemovedTrees() }
        return state
    }

    /// Delete the downloads earlier versions saved and record that this ran.
    func removeLegacyStorage() -> LegacyDownloadStorage.Removal {
        let removal = LegacyDownloadStorage(root: rootDirectory()).remove()
        Self.logger.notice("Removed download storage saved by an earlier version (had downloads: \(removal.hadDownloads, privacy: .public), completed: \(removal.completed, privacy: .public))")
        return removal
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

    private func storeFileURL(serverId: String, accountId: String?, profileId: String) -> URL {
        DownloadFilePaths.storeFileURL(serverId: serverId, accountId: accountId, profileId: profileId, root: rootDirectory())
    }

    private func scopeKey(serverId: String, accountId: String?, profileId: String) -> String {
        [serverId, accountId ?? "", profileId].joined(separator: "\n")
    }

    /// Moves the server's downloads from before accounts into `accountId`'s
    /// scope when that account owns them. Returns false when something the
    /// new scope lacks is still in the old directory.
    private func adoptLegacyScope(serverId: String, accountId: String, profileId: String) -> Bool {
        let root = rootDirectory()
        let legacy = DownloadFilePaths.scopePath(serverId: serverId, accountId: nil, profileId: profileId, root: root)
        let scope = DownloadFilePaths.scopePath(serverId: serverId, accountId: accountId, profileId: profileId, root: root)
        if legacyOwner(serverId) == accountId,
           !settleStoreConflict(
               legacy: legacy.appendingPathComponent(DownloadFilePaths.storeFileName, isDirectory: false),
               current: scope.appendingPathComponent(DownloadFilePaths.storeFileName, isDirectory: false)
           ) {
            return false
        }
        return AccountScopedKeyAdoption.adoptDirectory(
            from: legacy,
            to: scope,
            serverID: serverId,
            accountID: accountId,
            legacyOwner: legacyOwner
        )
    }

    /// Picks the store that survives when both the old directory and the
    /// account's hold one; the merge keeps the account's and deletes the
    /// other. The old one replaces an account store that holds nothing
    /// yet: early in a launch, before `LegacyLocalDataOwner` is published,
    /// the account's scope loads empty and saves at once, and that file
    /// must not win over every download from before accounts. An
    /// undecodable account store is set aside, as `load` would. Returns
    /// false when the account's store can't be read right now, so neither
    /// is touched until the next load.
    private func settleStoreConflict(legacy: URL, current: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacy.path), fileManager.fileExists(atPath: current.path) else {
            return true
        }
        guard let data = try? Data(contentsOf: current) else { return false }
        guard let file = try? decoder.decode(DownloadStoreFile.self, from: data) else {
            return quarantine(current)
        }
        if file.holdsNothingToKeep {
            try? fileManager.removeItem(at: current)
            return !fileManager.fileExists(atPath: current.path)
        }
        return true
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

private extension DownloadStoreFile {
    /// No downloads and nothing owed to the server: what loading a scope
    /// that has no store yet saves. Capability and bookkeeping fields come
    /// back from the server or the next load.
    var holdsNothingToKeep: Bool {
        records.isEmpty && subscriptions.isEmpty && progressQueue.isEmpty && localProgress.isEmpty
            && (pendingServerDeletes ?? []).isEmpty
            && (pendingSubscriptionDeletes ?? [:]).isEmpty
            && (legacyMonitorIds ?? []).isEmpty
    }
}
