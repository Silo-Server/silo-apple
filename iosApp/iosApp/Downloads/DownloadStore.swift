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
    /// The account that adopted a server's local data from before accounts
    /// (`AccountStore.legacyDataOwner(forServer:)`). Throws when the account
    /// index can't be read.
    private let legacyOwner: @Sendable (String) throws -> String?
    /// Scopes whose store file exists but could neither be read nor moved
    /// aside, or whose account could not take over its server's downloads
    /// from before accounts. Saving one of them would replace the file with
    /// whatever the manager built from an empty load, so saves stay off
    /// until a later load succeeds.
    private var unsavableScopes: Set<String> = []

    init(
        rootDirectory: @escaping @Sendable () -> URL = { DownloadFilePaths.rootDirectory() },
        legacyOwner: @escaping @Sendable (String) throws -> String? = {
            try AccountStore.shared.legacyDataOwner(forServer: $0)
        }
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
    func load(serverId: String, localAccountId: String, profileId: String) -> DownloadStoreFile {
        loadScope(serverId: serverId, localAccountId: localAccountId, profileId: profileId).file
    }

    /// `load`, plus what the load found on disk.
    ///
    /// The server's downloads from before accounts move under their owner
    /// first (`adoptDataFromBeforeAccounts`). Until they have, the owner's
    /// scopes load unreadable, so nothing saves over the store still waiting
    /// to move, and the next load tries again.
    func loadScope(serverId: String, localAccountId: String, profileId: String) -> DownloadStoreLoad {
        guard !serverId.isEmpty, !localAccountId.isEmpty, !profileId.isEmpty else {
            return DownloadStoreLoad(file: .empty, outcome: .missing)
        }
        let scope = scopeKey(serverId: serverId, localAccountId: localAccountId, profileId: profileId)
        guard adoptDataFromBeforeAccounts(serverId: serverId, localAccountId: localAccountId) else {
            Self.logger.error("Downloads saved before accounts could not move to their account; not saving this scope")
            unsavableScopes.insert(scope)
            return DownloadStoreLoad(file: .empty, outcome: .unreadable)
        }
        let url = storeFileURL(serverId: serverId, localAccountId: localAccountId, profileId: profileId)
        guard FileManager.default.fileExists(atPath: url.path) else {
            unsavableScopes.remove(scope)
            return DownloadStoreLoad(file: .empty, outcome: .missing)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Present but unreadable right now (for example, still protected
            // before first unlock). The contents may be fine, so leave them.
            Self.logger.error("Download store read failed; not saving this scope: \(String(describing: error), privacy: .public)")
            unsavableScopes.insert(scope)
            return DownloadStoreLoad(file: .empty, outcome: .unreadable)
        }
        do {
            let file = try decoder.decode(DownloadStoreFile.self, from: data)
            unsavableScopes.remove(scope)
            return DownloadStoreLoad(file: file, outcome: .loaded)
        } catch {
            Self.logger.error("Download store decode failed: \(String(describing: error), privacy: .public)")
            if quarantine(url) {
                unsavableScopes.remove(scope)
                return DownloadStoreLoad(file: .empty, outcome: .quarantined)
            }
            unsavableScopes.insert(scope)
            return DownloadStoreLoad(file: .empty, outcome: .unreadable)
        }
    }

    /// Atomically persist the blob for a scope. No-op for an empty scope.
    func save(_ file: DownloadStoreFile, serverId: String, localAccountId: String, profileId: String) {
        guard !serverId.isEmpty, !localAccountId.isEmpty, !profileId.isEmpty else { return }
        let scope = scopeKey(serverId: serverId, localAccountId: localAccountId, profileId: profileId)
        guard !unsavableScopes.contains(scope) else {
            // `load` already logged the cause at error level.
            Self.logger.debug("Download store save skipped: the scope's store could not be loaded")
            return
        }
        guard !removedAccounts.contains(accountKey(serverId: serverId, localAccountId: localAccountId)) else {
            Self.logger.debug("Download store save skipped: the account's downloads were deleted")
            return
        }
        let url = storeFileURL(serverId: serverId, localAccountId: localAccountId, profileId: profileId)
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
    func releaseProgressClaims(_ ids: Set<UUID>, serverId: String, localAccountId: String, profileId: String) {
        guard !serverId.isEmpty, !localAccountId.isEmpty, !profileId.isEmpty,
              FileManager.default.fileExists(
                  atPath: storeFileURL(serverId: serverId, localAccountId: localAccountId, profileId: profileId).path
              )
        else { return }
        var file = load(serverId: serverId, localAccountId: localAccountId, profileId: profileId)
        guard OfflineProgressQueue.releaseClaims(&file.progressQueue, ids: ids) else { return }
        save(file, serverId: serverId, localAccountId: localAccountId, profileId: profileId)
    }

    // MARK: - Whole accounts

    /// Accounts whose downloads `removeAccount` deleted in this process. A
    /// save for one of them, queued before the removal, would bring a store
    /// back that lists media that is gone.
    private var removedAccounts: Set<String> = []

    /// How many downloads an account has on this device across all its
    /// profiles, and the bytes they use. Includes its server's downloads
    /// from before accounts when the account owns them (they move under it
    /// first). A store that can't be read counts no downloads, but its
    /// files still count toward the bytes.
    func accountSummary(serverId: String, localAccountId: String) -> DownloadAccountSummary {
        guard !serverId.isEmpty, !localAccountId.isEmpty else { return DownloadAccountSummary(count: 0, bytes: 0) }
        let root = rootDirectory()
        if !adoptDataFromBeforeAccounts(serverId: serverId, localAccountId: localAccountId) {
            Self.logger.error("Downloads saved before accounts could not move to their account; the summary leaves them out")
        }
        var count = 0
        for scope in DownloadFilePaths.profileScopes(serverId: serverId, localAccountId: localAccountId, root: root) {
            let url = scope.appendingPathComponent(DownloadFilePaths.storeFileName, isDirectory: false)
            guard let data = try? Data(contentsOf: url),
                  let file = try? decoder.decode(DownloadStoreFile.self, from: data) else { continue }
            count += file.records.count
        }
        let bytes = DownloadFilePaths.bytes(
            under: DownloadFilePaths.accountPath(serverId: serverId, localAccountId: localAccountId, root: root)
        )
        return DownloadAccountSummary(count: count, bytes: bytes)
    }

    /// Deletes every download, store, and queued offline progress of one
    /// account, including its server's downloads from before accounts when
    /// it owns them. Other accounts on the server are untouched. Later saves
    /// for the account in this process are dropped. Returns the bytes freed.
    func removeAccount(serverId: String, localAccountId: String) -> Int64 {
        guard !serverId.isEmpty, !localAccountId.isEmpty else { return 0 }
        let root = rootDirectory()
        let key = accountKey(serverId: serverId, localAccountId: localAccountId)
        removedAccounts.insert(key)
        var targets = [DownloadFilePaths.accountPath(serverId: serverId, localAccountId: localAccountId, root: root)]
        // Owned but not yet moved under the account (the move failed).
        if !adoptDataFromBeforeAccounts(serverId: serverId, localAccountId: localAccountId),
           (try? legacyOwner(serverId)) == localAccountId {
            targets += DownloadFilePaths.scopesFromBeforeAccounts(serverId: serverId, root: root)
        }
        let prefix = key + "\n"
        unsavableScopes = unsavableScopes.filter { !$0.hasPrefix(prefix) }
        // A quick rename takes the data out of every path a reader or a
        // finishing transfer uses; the slow delete follows.
        DownloadStorageReclaim.setAside(
            targets.filter { FileManager.default.fileExists(atPath: $0.path) },
            root: root
        )
        let freed = DownloadStorageReclaim.deleteSetAside(root: root)
        Self.logger.notice("Deleted an account's downloads (\(freed, privacy: .public) bytes)")
        return freed
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

    private func storeFileURL(serverId: String, localAccountId: String, profileId: String) -> URL {
        DownloadFilePaths.storeFileURL(
            serverId: serverId, localAccountId: localAccountId, profileId: profileId, root: rootDirectory()
        )
    }

    private func accountKey(serverId: String, localAccountId: String) -> String {
        serverId + "\n" + localAccountId
    }

    private func scopeKey(serverId: String, localAccountId: String, profileId: String) -> String {
        accountKey(serverId: serverId, localAccountId: localAccountId) + "\n" + profileId
    }

    // MARK: - Server merge

    /// Moves each profile scope in `scopes` (from an account's directory, or
    /// a server's directory from before accounts) into the account directory
    /// `destination`, for a server merge (`ServerMerge`). Needs no network.
    /// Returns false when something could not move; it stays to try again.
    nonisolated static func mergeScopes(_ scopes: [URL], into destination: URL) -> Bool {
        var complete = true
        for scope in scopes {
            let target = destination.appendingPathComponent(scope.lastPathComponent, isDirectory: true)
            if !mergeScope(scope, into: target) { complete = false }
        }
        return complete
    }

    /// Where both scopes have a store, the downloads `target` lacks join it
    /// with their files and queued progress, `source`'s monitors and pending
    /// deletions join it too, and what is left of `source` (downloads
    /// `target` already has) is deleted. Otherwise the files
    /// merge as they are. A rerun after an interruption finishes the move.
    private nonisolated static func mergeScope(_ source: URL, into target: URL) -> Bool {
        let fm = FileManager.default
        let sourceStore = source.appendingPathComponent(DownloadFilePaths.storeFileName, isDirectory: false)
        let targetStore = target.appendingPathComponent(DownloadFilePaths.storeFileName, isDirectory: false)
        guard fm.fileExists(atPath: sourceStore.path), fm.fileExists(atPath: targetStore.path) else {
            return DownloadFilePaths.merge(source, into: target)
        }
        let decoder = JSONDecoder()
        guard let incoming = try? decoder.decode(DownloadStoreFile.self, from: Data(contentsOf: sourceStore)),
              var kept = try? decoder.decode(DownloadStoreFile.self, from: Data(contentsOf: targetStore)) else {
            logger.error("A download store could not be read while merging servers; leaving it in place")
            return false
        }
        let added = incoming.records.filter { kept.records[$0.key] == nil }
        for id in added.keys {
            let name = DownloadFilePaths.directoryName(forDownloadId: id)
            let files = source.appendingPathComponent(name, isDirectory: true)
            guard !fm.fileExists(atPath: files.path)
                    || DownloadFilePaths.merge(files, into: target.appendingPathComponent(name, isDirectory: true)) else {
                return false
            }
        }
        kept.records.merge(added) { current, _ in current }
        let queued = Set(kept.progressQueue.map(\.id))
        kept.progressQueue += incoming.progressQueue.filter { !queued.contains($0.id) }
        kept.localProgress.merge(incoming.localProgress) { current, _ in current }
        let monitors = Set(kept.subscriptions.map(\.id))
        kept.subscriptions += incoming.subscriptions.filter { !monitors.contains($0.id) }
        if let deletes = incoming.pendingServerDeletes {
            kept.pendingServerDeletes = (kept.pendingServerDeletes ?? []).union(deletes)
        }
        if let deletes = incoming.pendingSubscriptionDeletes {
            kept.pendingSubscriptionDeletes = (kept.pendingSubscriptionDeletes ?? [:])
                .merging(deletes) { current, _ in current }
        }
        if let legacy = incoming.legacyMonitorIds {
            kept.legacyMonitorIds = (kept.legacyMonitorIds ?? []).union(legacy)
        }
        // Legacy cleanup either store still owes stays owed, or the next sync
        // would import old rows and monitors instead of retiring them.
        if incoming.legacyRowsPending == true { kept.legacyRowsPending = true }
        if incoming.legacyMonitorsPending == true { kept.legacyMonitorsPending = true }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        do {
            try encoder.encode(kept).write(to: targetStore, options: .atomic)
        } catch {
            logger.error("Merged download store save failed: \(String(describing: error), privacy: .public)")
            return false
        }
        try? fm.removeItem(at: source)
        return true
    }

    // MARK: - Downloads saved before accounts

    /// Moves the server's `<serverId>/<profileId>/` scopes, saved before
    /// accounts, under `localAccountId` when it is the account that adopted
    /// the server's data (`AccountStore.legacyDataOwner(forServer:)`). No
    /// other account ever reads them. Needs no network. Returns false when
    /// something is still waiting to move to this account, or when the
    /// owner can't be read, in which case nothing moved.
    ///
    /// The move merges: a transfer started before accounts may already have
    /// parked its file under the account. An account store that holds
    /// nothing yields to the one from before accounts; two that both hold
    /// something merge their contents (`mergeScope`).
    private func adoptDataFromBeforeAccounts(serverId: String, localAccountId: String) -> Bool {
        let root = rootDirectory()
        let legacyScopes = DownloadFilePaths.scopesFromBeforeAccounts(serverId: serverId, root: root)
        guard !legacyScopes.isEmpty else { return true }
        let owner: String?
        do { owner = try legacyOwner(serverId) } catch {
            Self.logger.error("Account index unreadable; downloads saved before accounts stay where they are")
            return false
        }
        guard owner == localAccountId else { return true }
        let account = DownloadFilePaths.accountPath(serverId: serverId, localAccountId: localAccountId, root: root)
        var complete = true
        for legacy in legacyScopes {
            let target = account.appendingPathComponent(legacy.lastPathComponent, isDirectory: true)
            discardEmptyStore(at: target, yieldingTo: legacy)
            if !Self.mergeScope(legacy, into: target) { complete = false }
        }
        if complete {
            Self.logger.notice("Moved \(legacyScopes.count, privacy: .public) download scopes saved before accounts to their account")
        }
        return complete
    }

    /// Removes the account scope's store when it holds nothing to keep and
    /// the scope from before accounts has a store, so the move keeps that
    /// store whole instead of merging into an empty one.
    private func discardEmptyStore(at target: URL, yieldingTo legacy: URL) {
        let fm = FileManager.default
        let current = target.appendingPathComponent(DownloadFilePaths.storeFileName, isDirectory: false)
        guard fm.fileExists(atPath: legacy.appendingPathComponent(DownloadFilePaths.storeFileName).path),
              let data = try? Data(contentsOf: current),
              let file = try? decoder.decode(DownloadStoreFile.self, from: data),
              file.holdsNothingToKeep else { return }
        try? fm.removeItem(at: current)
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

/// A scope's store as `DownloadStore.loadScope` found it.
struct DownloadStoreLoad: Sendable {
    enum Outcome: Equatable, Sendable {
        /// The store was read and decoded.
        case loaded
        /// The scope has no store file.
        case missing
        /// The store could not be decoded and was renamed aside.
        case quarantined
        /// The store is present but could not be read, or could not be
        /// renamed aside after a failed decode. Its contents may be fine.
        case unreadable
    }

    var file: DownloadStoreFile
    var outcome: Outcome

    /// Whether the loaded file is the scope's whole truth, so a download
    /// directory none of its records owns can be deleted. A missing or
    /// quarantined store counts: nothing in this version can read the
    /// directories it owned again, and the server's rows download afresh.
    /// An unreadable store may still own them.
    var tracksScopeStorage: Bool { outcome != .unreadable }
}

/// What `DownloadStore.accountSummary` counted for one account.
struct DownloadAccountSummary: Equatable, Sendable {
    /// Download records in every profile of the account, in any state.
    let count: Int
    /// Bytes on disk under the account.
    let bytes: Int64
}

private extension DownloadStoreFile {
    /// No downloads, nothing owed to the server, and no legacy cleanup
    /// still owed: what loading a scope with no store yet saves.
    var holdsNothingToKeep: Bool {
        records.isEmpty && subscriptions.isEmpty && progressQueue.isEmpty && localProgress.isEmpty
            && (pendingServerDeletes ?? []).isEmpty
            && (pendingSubscriptionDeletes ?? [:]).isEmpty
            && (legacyMonitorIds ?? []).isEmpty
            && legacyRowsPending != true && legacyMonitorsPending != true
    }
}
