import Foundation
import Darwin

/// Explicit durable authority supplied by a future login/persistence coordinator.
/// A process-local token generation cannot establish this binding after restart.
struct ProgressBootstrapStoreScope: Codable, Equatable, Sendable {
    let serverID: String
    let origin: String
    let installationID: String
    let accountID: String
    let profileID: String
    let authorityID: UUID
}

struct StoredProgressValue: Codable, Equatable, Sendable {
    let position: Double
    let duration: Double
    let completed: Bool
    let updatedAt: Date
}

struct StoredProgressIntent: Codable, Equatable, Sendable {
    let requestID: UUID
    let limit: Int
    let generation: String
    let createdAt: Date
    let maxItems: Int
    let maxBytes: Int
}

struct StoredProgressSnapshot: Codable, Sendable {
    let snapshotID: String
    let generation: String
    let capturedAt: Date
    let expiresAt: Date
    let itemCount: Int
    var entries: [String: StoredProgressValue]
    var nextCursor: String?
    var receipt: String?
    var seenCursors: Set<String>
}

struct StoredProgressCheckpoint: Codable, Sendable {
    let snapshotID: String
    let generation: String
    let capturedAt: Date
    let expiresAt: Date
    let itemCount: Int
    let receipt: String
}

struct StoredProgressUpload: Codable, Sendable {
    let id: UUID
    let events: [QueuedProgress]
}

/// Dormant schema: it is intentionally never written to the active legacy store path.
struct ProgressBootstrapStoreFile: Codable, Sendable {
    let version: Int
    let scope: ProgressBootstrapStoreScope
    var revision: UInt64
    var downloads: DownloadStoreFile
    var serverProgress: [String: StoredProgressValue]
    var pending: [UUID: StoredProgressValue]
    var settledLocalProgress: [String: StoredProgressValue]
    var intent: StoredProgressIntent?
    var staging: StoredProgressSnapshot?
    var committed: StoredProgressCheckpoint?
    var retiredRequestIDs: Set<UUID>
    var upload: StoredProgressUpload?

    /// Legacy mixed cache is visible until a first complete replacement commits.
    /// Pending events survive even when masked by a newer authoritative value.
    var visibleProgress: [String: StoredProgressValue] {
        var values = committed == nil ? downloads.localProgress.mapValues {
            StoredProgressValue(position: $0.position, duration: $0.duration, completed: $0.completed, updatedAt: $0.updatedAt)
        } : serverProgress
        for (id, overlay) in settledLocalProgress {
            if values[id].map({ overlay.updatedAt >= $0.updatedAt }) ?? true { values[id] = overlay }
        }
        for event in downloads.progressQueue {
            guard let overlay = pending[event.id] else { continue }
            if values[event.mediaItemId].map({ overlay.updatedAt >= $0.updatedAt }) ?? true {
                values[event.mediaItemId] = overlay
            }
        }
        return values
    }
}

enum ProgressBootstrapStoreError: Error {
    case invalidStore, wrongScope, alreadyInitialized, invalidIntent, busy, staleOperation, invalidPage
}

/// Storage foundation only. One owning actor serializes reads/mutations of this explicit
/// destination. There is no production singleton or DownloadManager call site. Activation
/// must move every writer to this owner; legacy whole-blob saves cannot target this file.
actor ProgressBootstrapStore {
    private let url: URL
    private let scope: ProgressBootstrapStoreScope?
    private var localAuthority: DownloadLocalAuthority?
    private var localAssets: DownloadAssetOwnership?
    private var localAuthorityVerifier: (@Sendable () throws -> Bool)?
    private let write: @Sendable (Data, URL) throws -> Void
    private var state: ProgressBootstrapStoreFile?

    init(url: URL, scope: ProgressBootstrapStoreScope,
         write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.url = url
        self.scope = scope
        self.write = write
    }

    init(localRoot: URL, authority: DownloadLocalAuthority,
         verifyAuthority: (@Sendable () throws -> Bool)? = nil,
         write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.url = localRoot.appendingPathComponent("authorities", isDirectory: true)
            .appendingPathComponent(authority.accountEpoch.uuidString, isDirectory: true).appendingPathComponent("state.json")
        self.scope = nil
        self.localAuthority = authority
        self.localAssets = DownloadAssetOwnership(root: localRoot)
        self.localAuthorityVerifier = verifyAuthority ?? {
            let persistence = AccountSessionPersistence(keychain: SharedKeychain())
            guard case .session(let current) = try persistence.load(authority.serverID) else { return false }
            return current.epoch == authority.accountEpoch && current.accountID == authority.accountID && current.origin == authority.origin
        }
        self.write = write
    }

    /// The original v1 bytes remain untouched, including on decode or write failure.
    func migrate(legacyData: Data) throws -> ProgressBootstrapStoreFile {
        guard let scope else { throw ProgressBootstrapStoreError.wrongScope }
        guard state == nil, !FileManager.default.fileExists(atPath: url.path) else { throw ProgressBootstrapStoreError.alreadyInitialized }
        let legacy = try JSONDecoder().decode(DownloadStoreFile.self, from: legacyData)
        guard legacy.version == 1, Set(legacy.progressQueue.map(\.id)).count == legacy.progressQueue.count else {
            throw ProgressBootstrapStoreError.invalidStore
        }
        var overlays: [UUID: StoredProgressValue] = [:]
        for event in legacy.progressQueue {
            // The old cache has no provenance. Carry completion only for pending UUIDs;
            // arbitrary old completed rows never enter the authoritative server map.
            overlays[event.id] = StoredProgressValue(position: event.position, duration: event.duration,
                completed: legacy.localProgress[event.mediaItemId]?.completed ?? false, updatedAt: event.updatedAt)
        }
        let file = ProgressBootstrapStoreFile(version: 2, scope: scope, revision: 0, downloads: legacy,
            serverProgress: [:], pending: overlays, settledLocalProgress: [:], intent: nil, staging: nil, committed: nil,
            retiredRequestIDs: [], upload: nil)
        try publish(file)
        return file
    }

    func read() throws -> ProgressBootstrapStoreFile {
        if let state { return state }
        let file = try JSONDecoder().decode(ProgressBootstrapStoreFile.self, from: Data(contentsOf: url))
        guard file.version == 2 else { throw ProgressBootstrapStoreError.invalidStore }
        guard file.scope == scope else { throw ProgressBootstrapStoreError.wrongScope }
        guard Set(file.downloads.progressQueue.map(\.id)).count == file.downloads.progressQueue.count,
              Set(file.pending.keys) == Set(file.downloads.progressQueue.map(\.id)) else {
            throw ProgressBootstrapStoreError.invalidStore
        }
        state = file
        return file
    }

    func begin(_ intent: StoredProgressIntent) throws -> ProgressBootstrapStoreFile {
        var file = try read()
        guard (1...200).contains(intent.limit), !intent.generation.isEmpty, intent.maxItems >= 0, intent.maxBytes > 0 else {
            throw ProgressBootstrapStoreError.invalidIntent
        }
        if let current = file.intent {
            guard current == intent else { throw ProgressBootstrapStoreError.busy }
            return file
        }
        guard file.upload == nil else { throw ProgressBootstrapStoreError.busy }
        guard !file.retiredRequestIDs.contains(intent.requestID) else { throw ProgressBootstrapStoreError.staleOperation }
        file.intent = intent
        file.staging = nil
        return try commitMutation(file)
    }

    /// Persist a page and its cursor together, without publishing it to the resume cache.
    func stage(_ result: APIv2ProgressSnapshotResult, requestID: UUID, now: Date) throws -> ProgressBootstrapStoreFile {
        var file = try read()
        guard let intent = file.intent, intent.requestID == requestID else { throw ProgressBootstrapStoreError.staleOperation }
        let page = result.value
        guard let scope else { throw ProgressBootstrapStoreError.wrongScope }
        guard page.installationId == scope.installationID, page.accountId == scope.accountID,
              page.profileId == scope.profileID, page.generation == intent.generation, page.mode == "full_replace",
              page.expiresAt > now, page.expiresAt > page.capturedAt, page.itemCount <= intent.maxItems,
              page.itemCount >= 0, page.items.count <= intent.limit else { throw ProgressBootstrapStoreError.invalidPage }
        var staged = file.staging ?? StoredProgressSnapshot(snapshotID: page.snapshotId, generation: page.generation,
            capturedAt: page.capturedAt, expiresAt: page.expiresAt, itemCount: page.itemCount,
            entries: [:], nextCursor: nil, receipt: nil, seenCursors: [])
        guard staged.receipt == nil, staged.snapshotID == page.snapshotId, staged.generation == page.generation,
              staged.capturedAt == page.capturedAt, staged.expiresAt == page.expiresAt, staged.itemCount == page.itemCount else {
            throw ProgressBootstrapStoreError.invalidPage
        }
        for entry in page.items {
            guard !entry.mediaItemId.isEmpty, staged.entries[entry.mediaItemId] == nil,
                  entry.positionSeconds.isFinite, entry.durationSeconds.isFinite,
                  entry.positionSeconds >= 0, entry.durationSeconds >= 0 else { throw ProgressBootstrapStoreError.invalidPage }
            staged.entries[entry.mediaItemId] = StoredProgressValue(position: entry.positionSeconds,
                duration: entry.durationSeconds, completed: entry.completed, updatedAt: entry.updatedAt)
        }
        guard staged.entries.count <= staged.itemCount else { throw ProgressBootstrapStoreError.invalidPage }
        if page.complete {
            guard !page.page.hasMore, page.page.nextCursor == nil, result.continuation == nil,
                  let receipt = result.receipt?.token, !receipt.isEmpty, receipt == page.completionToken,
                  staged.entries.count == staged.itemCount else { throw ProgressBootstrapStoreError.invalidPage }
            staged.receipt = receipt
            staged.nextCursor = nil
        } else {
            guard page.page.hasMore, let cursor = result.continuation?.token, !cursor.isEmpty,
                  cursor == page.page.nextCursor, !staged.seenCursors.contains(cursor),
                  result.receipt == nil, page.completionToken == nil, !page.items.isEmpty,
                  staged.entries.count < staged.itemCount else { throw ProgressBootstrapStoreError.invalidPage }
            staged.nextCursor = cursor
            staged.seenCursors.insert(cursor)
        }
        guard try JSONEncoder().encode(staged).count <= intent.maxBytes else { throw ProgressBootstrapStoreError.invalidPage }
        file.staging = staged
        return try commitMutation(file)
    }

    /// Full replacement merges with the latest pending queue, never with an admission copy.
    func apply(requestID: UUID, now: Date) throws -> ProgressBootstrapStoreFile {
        var file = try read()
        guard file.intent?.requestID == requestID, let staged = file.staging,
              let receipt = staged.receipt, staged.expiresAt > now, staged.entries.count == staged.itemCount else {
            throw ProgressBootstrapStoreError.staleOperation
        }
        file.serverProgress = staged.entries
        file.settledLocalProgress = [:]
        file.committed = StoredProgressCheckpoint(snapshotID: staged.snapshotID, generation: staged.generation,
            capturedAt: staged.capturedAt, expiresAt: staged.expiresAt, itemCount: staged.itemCount, receipt: receipt)
        file.downloads.progressCursor = nil
        file.intent = nil
        file.staging = nil
        file.retiredRequestIDs.insert(requestID)
        return try commitMutation(file)
    }

    func abandon(requestID: UUID) throws -> ProgressBootstrapStoreFile {
        var file = try read()
        guard file.intent?.requestID == requestID else { throw ProgressBootstrapStoreError.staleOperation }
        file.retiredRequestIDs.insert(requestID)
        file.intent = nil
        file.staging = nil
        return try commitMutation(file)
    }

    func record(_ event: QueuedProgress, completed: Bool) throws -> ProgressBootstrapStoreFile {
        var file = try read()
        guard !event.mediaItemId.isEmpty, event.position.isFinite, event.duration.isFinite,
              event.position >= 0, event.duration >= 0, event.attempts >= 0,
              !file.downloads.progressQueue.contains(where: { $0.id == event.id }) else { throw ProgressBootstrapStoreError.invalidStore }
        let replaced = file.downloads.progressQueue.filter { $0.mediaItemId == event.mediaItemId }
        for row in replaced { file.pending.removeValue(forKey: row.id) }
        file.downloads.progressQueue.removeAll { $0.mediaItemId == event.mediaItemId }
        file.downloads.progressQueue.append(event)
        file.pending[event.id] = StoredProgressValue(position: event.position, duration: event.duration,
            completed: completed, updatedAt: event.updatedAt)
        return try commitMutation(file)
    }

    /// Persist a submitted batch before dispatch. Restart retains this uncertain claim;
    /// a future coordinator must resolve it rather than automatically replaying an upload.
    func claimUpload() throws -> StoredProgressUpload {
        var file = try read()
        guard file.intent == nil, file.upload == nil else { throw ProgressBootstrapStoreError.busy }
        let upload = StoredProgressUpload(id: UUID(), events: file.downloads.progressQueue)
        file.upload = upload
        _ = try commitMutation(file)
        return upload
    }

    func acknowledge(uploadID: UUID, succeeded: Set<UUID>, maxRetries: Int) throws -> ProgressBootstrapStoreFile {
        var file = try read()
        guard file.intent == nil, let upload = file.upload, upload.id == uploadID else { throw ProgressBootstrapStoreError.staleOperation }
        let submitted = Set(upload.events.map(\.id))
        guard succeeded.isSubset(of: submitted), maxRetries >= 0 else { throw ProgressBootstrapStoreError.invalidStore }
        let removed = Set(file.downloads.progressQueue.filter {
            submitted.contains($0.id) && (succeeded.contains($0.id) || $0.attempts >= maxRetries)
        }.map(\.id))
        // Settled local presentation survives an acknowledgement until the next full
        // snapshot (admitted after this upload resolves) authoritatively replaces it.
        for event in file.downloads.progressQueue where removed.contains(event.id) {
            if let value = file.pending[event.id],
               file.settledLocalProgress[event.mediaItemId].map({ value.updatedAt >= $0.updatedAt }) ?? true {
                file.settledLocalProgress[event.mediaItemId] = value
            }
        }
        file.downloads.progressQueue.removeAll { removed.contains($0.id) }
        for id in removed { file.pending.removeValue(forKey: id) }
        for index in file.downloads.progressQueue.indices where submitted.contains(file.downloads.progressQueue[index].id) {
            file.downloads.progressQueue[index].attempts += 1
        }
        file.upload = nil
        return try commitMutation(file)
    }

    private func commitMutation(_ input: ProgressBootstrapStoreFile) throws -> ProgressBootstrapStoreFile {
        var file = input
        guard file.revision < UInt64.max else { throw ProgressBootstrapStoreError.invalidStore }
        file.revision += 1
        try publish(file)
        return file
    }

    private func publish(_ file: ProgressBootstrapStoreFile) throws {
        let data = try JSONEncoder().encode(file)
        // A revision compare under an advisory file lock also fences a superseded
        // actor after ownership transfer. Atomic rename alone cannot prevent lost updates.
        let descriptor = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        if FileManager.default.fileExists(atPath: url.path) {
            let current = try JSONDecoder().decode(ProgressBootstrapStoreFile.self, from: Data(contentsOf: url))
            guard file.revision > 0, current.scope == file.scope, current.version == file.version,
                  current.revision == file.revision - 1 else { throw ProgressBootstrapStoreError.staleOperation }
        } else if file.revision != 0 { throw ProgressBootstrapStoreError.staleOperation }
        try write(data, url)
        // No await between disk publication and memory publication; failed writes leave both unchanged.
        state = file
    }
}

struct DownloadLocalState: Codable, Sendable {
    var version = 3
    let authority: DownloadLocalAuthority
    let ownerGeneration: UUID
    var revision: UInt64
    var downloads: DownloadStoreFile
    /// Original bytes have no account-epoch provenance and are never claimable uploads.
    let quarantinedLegacy: Data
    var leases: [String: DownloadAssetLease]
    var transfers: [UUID: DownloadTaskBinding]
    var recordOperations: [String: UUID] = [:]
    var serverProgress: [String: StoredProgressValue]
    var pending: [UUID: StoredProgressValue]
    var committed: StoredProgressCheckpoint?
    var installationID: String?
    /// Dormant v2 files retain their complete receipt/maps, but their caller-labelled
    /// queues are not silently converted into authenticated dispatch authority.
    var bootstrapArchive: ProgressBootstrapStoreFile? = nil
}

private struct DownloadLocalMarker: Codable {
    let version: Int
    let authority: DownloadLocalAuthority
    let ownerGeneration: UUID
}

struct DownloadRegistrationDisplay: Sendable {
    var title: String?
    var subtitle: String?
    var type: String?
    var seriesID: String?
    var posterThumbhash: String?
}

enum DownloadLocalCommand: Sendable {
    case capability(DownloadCapability, Date)
    case registered([ServerDownloadRow], DownloadRegistrationDisplay)
    case absentServerRows(observed: [String: UUID], present: Set<String>)
    case status(String, LocalDownloadStatus, String?)
    case retry(String, Int)
    case transferProgress(DownloadTaskBinding, Int64, Int64)
    case manifest(String, OfflineManifest)
    case subscription(ServerSubscription, String?)
    case deleteSubscription(String)
    case progress(QueuedProgress, Bool)
}

enum DownloadAssetKind: Sendable {
    case media, manifest, poster, backdrop, logo, subtitle(String), resume
}

extension ProgressBootstrapStore {
    /// The runtime migration switch remains off until independent review. Only callers
    /// with an explicitly authorized synthetic/root activation enter this boundary.
    func openLocal(legacyData: Data?, permitMigration: Bool) throws -> DownloadLocalState {
        guard let authority = localAuthority, let assets = localAssets else { throw DownloadOwnershipError.wrongAuthority }
        return try assets.withLock {
            if FileManager.default.fileExists(atPath: url.path) {
                let value = try loadLocal()
                let markerURL = url.deletingLastPathComponent().appendingPathComponent("owner.json")
                if !FileManager.default.fileExists(atPath: markerURL.path) {
                    guard permitMigration else { throw DownloadOwnershipError.disabled }
                    try finishLocalMigration(value, assets: assets)
                }
                try assets.recoverLocked(authority: authority)
                return value
            }
            guard permitMigration else { throw DownloadOwnershipError.disabled }
            // Read the legacy source while holding the same lock as every legacy
            // save. A caller's earlier read cannot omit a save that won the lock.
            let legacyURL = assets.root.appendingPathComponent("store.json")
            let legacyData = FileManager.default.fileExists(atPath: legacyURL.path)
                ? try Data(contentsOf: legacyURL) : legacyData
            let archive: ProgressBootstrapStoreFile?
            let legacy: DownloadStoreFile
            if let legacyData,
               let header = try JSONSerialization.jsonObject(with: legacyData) as? [String: Any],
               header["version"] as? Int == 2 {
                let old = try JSONDecoder().decode(ProgressBootstrapStoreFile.self, from: legacyData)
                archive = old
                legacy = old.downloads
            } else {
                archive = nil
                legacy = try legacyData.map { try JSONDecoder().decode(DownloadStoreFile.self, from: $0) } ?? .empty
            }
            guard legacy.version == 1, Set(legacy.progressQueue.map(\.id)).count == legacy.progressQueue.count else {
                throw DownloadOwnershipError.corrupt
            }
            var downloads = legacy
            downloads.progressQueue = []
            downloads.progressCursor = nil
            let value = DownloadLocalState(authority: authority, ownerGeneration: UUID(), revision: 0,
                downloads: downloads, quarantinedLegacy: legacyData ?? Data(), leases: [:], transfers: [:],
                serverProgress: [:], pending: [:], committed: nil, installationID: nil, bootstrapArchive: archive)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(JSONEncoder().encode(value), url)
            try finishLocalMigration(value, assets: assets)
            return value
        }
    }

    private func finishLocalMigration(_ value: DownloadLocalState, assets: DownloadAssetOwnership) throws {
        // Common legacy fence precedes marker publication; a crash here resumes this
        // exact candidate, never reopens stale store.json for writable fallback.
        try assets.markLegacyTransferredLocked(authority: value.authority)
        let marker = DownloadLocalMarker(version: 1, authority: value.authority, ownerGeneration: value.ownerGeneration)
        try write(JSONEncoder().encode(marker), url.deletingLastPathComponent().appendingPathComponent("owner.json"))
    }

    private func loadLocal() throws -> DownloadLocalState {
        let value = try JSONDecoder().decode(DownloadLocalState.self, from: Data(contentsOf: url))
        guard value.version == 3, value.authority == localAuthority,
              Set(value.downloads.progressQueue.map(\.id)) == Set(value.pending.keys) else { throw DownloadOwnershipError.wrongAuthority }
        return value
    }

    func localSnapshot() throws -> DownloadLocalState {
        let value = try loadLocal()
        let marker = try JSONDecoder().decode(DownloadLocalMarker.self,
            from: Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("owner.json")))
        guard marker.version == 1, marker.authority == value.authority,
              marker.ownerGeneration == value.ownerGeneration else { throw DownloadOwnershipError.corrupt }
        return value
    }

    private func commitLocal(_ input: DownloadLocalState) throws -> DownloadLocalState {
        let current = try localSnapshot()
        guard current.revision == input.revision, current.ownerGeneration == input.ownerGeneration,
              input.revision < UInt64.max else { throw DownloadOwnershipError.stale }
        var value = input
        value.revision += 1
        try write(JSONEncoder().encode(value), url)
        return value
    }

    func applyLocal(_ command: DownloadLocalCommand, generation: UUID, recordOperation: (String, UUID)? = nil) throws -> DownloadLocalState {
        guard let assets = localAssets else { throw DownloadOwnershipError.wrongAuthority }
        // Commands that need adoption acquire/release the shared lock separately,
        // then revalidate the resulting lease before committing current state.
        var adopted: [String: DownloadAssetLease] = [:]
        if case .registered(let rows, _) = command {
            let state = try localSnapshot()
            guard state.ownerGeneration == generation else { throw DownloadOwnershipError.stale }
            for row in rows {
                if let prior = try assets.currentLease(downloadID: row.id), prior.authority != state.authority {
                    guard state.leases[row.id] == nil, try localAuthorityVerifier?() == true else { throw DownloadOwnershipError.stale }
                    adopted[row.id] = try assets.adoptReplacing(prior, authority: state.authority)
                } else {
                    let record = state.downloads.records[row.id]
                    let matches = record?.mediaFileId == row.mediaFileId && record?.format == row.quality &&
                        (record?.revision == nil || record?.revision == row.revision)
                    let filenames: [String?] = matches ? [record?.mediaFilename, record?.manifestFilename,
                        record?.posterFilename, record?.backdropFilename, record?.logoFilename, record?.resumeDataFilename] : []
                    var retained = Set(filenames.compactMap { $0 })
                    if matches { retained.formUnion(record?.subtitleFilenames.values.map { $0 } ?? []) }
                    guard retained.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") }) else {
                        throw DownloadOwnershipError.corrupt
                    }
                    let current = try assets.adopt(downloadID: row.id, authority: state.authority, retainedFiles: retained)
                    if let record, Self.replacesAssets(record, row: row) {
                        adopted[row.id] = try assets.adoptReplacing(current, authority: state.authority)
                    } else { adopted[row.id] = current }
                }
            }
        }
        return try assets.withLock {
            var value = try localSnapshot()
            guard value.ownerGeneration == generation else { throw DownloadOwnershipError.stale }
            if let (id, operation) = recordOperation, value.recordOperations[id] != operation { throw DownloadOwnershipError.stale }
            switch command {
            case .capability(let capability, let date):
                value.downloads.capability = capability
                value.downloads.capabilityFetchedAt = date
            case .registered(let rows, let display):
                for lease in adopted.values { try assets.validateLocked(lease) }
                for row in rows {
                    value.leases[row.id] = adopted[row.id]
                    value.recordOperations[row.id] = value.recordOperations[row.id] ?? UUID()
                    var record = value.downloads.records[row.id] ?? Self.localRecord(from: row, type: display.type)
                    if let revision = row.revision, let current = record.revision, revision < current { continue }
                    let replaced = Self.replacesAssets(record, row: row)
                    if replaced {
                        // New references are published under a fresh pipeline operation.
                        // Valid prior files remain owned recovery material; no directory deletion.
                        value.recordOperations[row.id] = UUID()
                        record.mediaFilename = nil
                        record.manifestFilename = nil
                        record.posterFilename = nil
                        record.backdropFilename = nil
                        record.logoFilename = nil
                        record.subtitleFilenames = [:]
                        record.resumeDataFilename = nil
                        record.container = nil
                        record.stableIdentity = nil
                        record.bytesDownloaded = 0
                        record.downloadedAt = nil
                        record.taskIdentifier = nil
                        record.localStatus = Self.localStatus(row.status)
                    }
                    if row.status == "revoked" || (row.status == "failed" && record.localStatus != .completed) {
                        value.recordOperations[row.id] = UUID()
                        record.localStatus = Self.localStatus(row.status)
                        record.taskIdentifier = nil
                    }
                    record.contentId = row.contentId
                    record.mediaFileId = row.mediaFileId
                    record.format = row.quality
                    record.effectiveQuality = row.effectiveQuality
                    record.deliveryFormat = row.deliveryFormat
                    record.targetBitrateKbps = row.targetBitrateKbps
                    if let revision = row.revision { record.revision = max(revision, record.revision ?? revision) }
                    record.serverStatus = row.status
                    if record.localStatus == .registering || record.localStatus == .preparing {
                        record.localStatus = Self.localStatus(row.status)
                    }
                    record.title = display.title ?? record.title
                    record.subtitle = display.subtitle ?? record.subtitle
                    record.seriesId = display.seriesID ?? record.seriesId
                    record.posterThumbhash = display.posterThumbhash ?? record.posterThumbhash
                    value.downloads.records[row.id] = record
                }
            case .absentServerRows(let observed, let present):
                for (id, operation) in observed where !present.contains(id) {
                    guard value.recordOperations[id] == operation, var record = value.downloads.records[id],
                          record.localStatus.isActive else { continue }
                    value.recordOperations[id] = UUID()
                    record.localStatus = .failed
                    record.lastError = "Download was removed on the server."
                    record.taskIdentifier = nil
                    value.downloads.records[id] = record
                }
            case .status(let id, let status, let error):
                guard var record = value.downloads.records[id] else { throw DownloadOwnershipError.stale }
                value.recordOperations[id] = UUID()
                record.localStatus = status
                if status == .failed { record.retryCount += 1 }
                if status == .queued { record.retryCount = 0 }
                record.lastError = error
                if status != .downloading { record.taskIdentifier = nil }
                value.downloads.records[id] = record
            case .retry(let id, let count):
                guard var record = value.downloads.records[id], record.localStatus == .failed, record.retryCount == count else {
                    throw DownloadOwnershipError.stale
                }
                record.localStatus = .queued
                value.recordOperations[id] = UUID()
                value.downloads.records[id] = record
            case .transferProgress(let binding, let written, let total):
                guard value.transfers[binding.transferID] == binding,
                      value.recordOperations[binding.lease.downloadID] == binding.operationID,
                      var record = value.downloads.records[binding.lease.downloadID], record.taskIdentifier == binding.taskID,
                      record.localStatus == .downloading else { throw DownloadOwnershipError.stale }
                record.bytesDownloaded = max(record.bytesDownloaded, written)
                if total > 0 { record.fileSize = total }
                value.downloads.records[record.id] = record
            case .manifest(let id, let manifest):
                guard var record = value.downloads.records[id] else { throw DownloadOwnershipError.stale }
                record.title = manifest.title
                record.seriesId = manifest.seriesId
                record.seriesTitle = manifest.seriesTitle
                record.seasonNumber = manifest.seasonNumber
                record.episodeNumber = manifest.episodeNumber
                record.container = manifest.container
                record.stableIdentity = manifest.stableIdentity
                value.downloads.records[id] = record
            case .subscription(let subscription, let title):
                let item = DownloadSubscription(from: subscription, seriesTitle: title)
                value.downloads.subscriptions.removeAll { $0.id == item.id }
                value.downloads.subscriptions.append(item)
            case .deleteSubscription(let id):
                value.downloads.subscriptions.removeAll { $0.id == id }
            case .progress(let event, let completed):
                if let existing = value.downloads.progressQueue.first(where: { $0.id == event.id }) {
                    guard existing.mediaItemId == event.mediaItemId, existing.position == event.position,
                          existing.duration == event.duration, existing.updatedAt == event.updatedAt,
                          existing.attempts == event.attempts, value.pending[event.id]?.completed == completed else {
                        throw DownloadOwnershipError.stale
                    }
                    return value
                }
                value.downloads.progressQueue.append(event)
                let progress = StoredProgressValue(position: event.position, duration: event.duration,
                    completed: completed, updatedAt: event.updatedAt)
                value.pending[event.id] = progress
                value.downloads.localProgress[event.mediaItemId] = LocalProgressEntry(position: event.position,
                    duration: event.duration, completed: completed, updatedAt: event.updatedAt)
            }
            return try commitLocal(value)
        }
    }

    func beginLocalPipeline(id: String, generation: UUID) throws -> (DownloadLocalState, UUID) {
        guard let assets = localAssets else { throw DownloadOwnershipError.wrongAuthority }
        return try assets.withLock {
            var value = try localSnapshot()
            guard value.ownerGeneration == generation, var record = value.downloads.records[id], record.localStatus == .queued else {
                throw DownloadOwnershipError.stale
            }
            let operation = UUID()
            value.recordOperations[id] = operation
            record.localStatus = .fetchingAssets
            value.downloads.records[id] = record
            return (try commitLocal(value), operation)
        }
    }

    func resumeLocalTask(_ binding: DownloadTaskBinding, generation: UUID,
                         resume: @Sendable () -> Void) throws {
        guard let assets = localAssets else { throw DownloadOwnershipError.wrongAuthority }
        try assets.withLock {
            let value = try localSnapshot()
            guard value.ownerGeneration == generation,
                  value.transfers[binding.transferID] == binding,
                  value.recordOperations[binding.lease.downloadID] == binding.operationID,
                  let record = value.downloads.records[binding.lease.downloadID],
                  record.taskIdentifier == binding.taskID, record.localStatus == .downloading else {
                throw DownloadOwnershipError.stale
            }
            try assets.validateLocked(binding.lease)
            resume()
        }
    }

    func completeLocalTask(source: URL, suffix: String, binding: DownloadTaskBinding, generation: UUID) throws -> DownloadLocalState {
        let value = try localSnapshot()
        guard value.transfers[binding.transferID] == binding,
              value.recordOperations[binding.lease.downloadID] == binding.operationID,
              value.downloads.records[binding.lease.downloadID]?.taskIdentifier == binding.taskID,
              value.downloads.records[binding.lease.downloadID]?.localStatus == .downloading else { throw DownloadOwnershipError.stale }
        return try attachLocalAsset(source: source, suffix: suffix, kind: .media, lease: binding.lease,
            generation: generation, operationID: binding.operationID)
    }

    func bindLocalTask(_ binding: DownloadTaskBinding, generation: UUID) throws -> DownloadLocalState {
        guard let assets = localAssets else { throw DownloadOwnershipError.wrongAuthority }
        try assets.bind(binding)
        return try assets.withLock {
            var value = try localSnapshot()
            guard value.ownerGeneration == generation, value.authority == binding.lease.authority,
                  value.recordOperations[binding.lease.downloadID] == binding.operationID,
                  var record = value.downloads.records[binding.lease.downloadID], record.localStatus == .fetchingAssets else { throw DownloadOwnershipError.stale }
            value.transfers[binding.transferID] = binding
            value.leases[record.id] = binding.lease
            record.taskIdentifier = binding.taskID
            record.localStatus = .downloading
            value.downloads.records[record.id] = record
            return try commitLocal(value)
        }
    }

    func localLease(downloadID: String) throws -> DownloadAssetLease {
        guard let assets = localAssets else { throw DownloadOwnershipError.wrongAuthority }
        let value = try localSnapshot()
        guard value.downloads.records[downloadID] != nil else { throw DownloadOwnershipError.stale }
        guard let lease = value.leases[downloadID], try assets.currentLease(downloadID: downloadID) == lease else {
            throw DownloadOwnershipError.stale
        }
        return lease
    }

    func attachLocalAsset(source: URL, suffix: String, kind: DownloadAssetKind,
                          lease: DownloadAssetLease, generation: UUID, operationID: UUID? = nil) throws -> DownloadLocalState {
        guard let assets = localAssets else { throw DownloadOwnershipError.wrongAuthority }
        try assets.attach(source: source, suffix: suffix, lease: lease) { filename in
            var value = try self.localSnapshot()
            guard value.ownerGeneration == generation, value.authority == lease.authority,
                  var record = value.downloads.records[lease.downloadID] else { throw DownloadOwnershipError.stale }
            if let operationID, value.recordOperations[lease.downloadID] != operationID { throw DownloadOwnershipError.stale }
            switch kind {
            case .media:
                guard record.localStatus == .downloading else { throw DownloadOwnershipError.stale }
                record.mediaFilename = filename
                record.localStatus = .completed
                record.downloadedAt = Date()
                if let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    record.fileSize = Int64(size)
                    record.bytesDownloaded = Int64(size)
                }
                record.taskIdentifier = nil
                record.lastError = nil
            case .manifest: record.manifestFilename = filename
            case .poster: record.posterFilename = filename
            case .backdrop: record.backdropFilename = filename
            case .logo: record.logoFilename = filename
            case .subtitle(let key): record.subtitleFilenames[key] = filename
            case .resume: record.resumeDataFilename = filename
            }
            value.leases[record.id] = lease
            value.downloads.records[record.id] = record
            _ = try self.commitLocal(value)
        }
        return try localSnapshot()
    }

    func deleteLocalRecord(_ lease: DownloadAssetLease, generation: UUID) throws -> DownloadLocalState {
        guard let assets = localAssets else { throw DownloadOwnershipError.wrongAuthority }
        try assets.remove(lease: lease) {
            var value = try self.localSnapshot()
            guard value.ownerGeneration == generation, value.authority == lease.authority else { throw DownloadOwnershipError.stale }
            value.downloads.records.removeValue(forKey: lease.downloadID)
            value.leases.removeValue(forKey: lease.downloadID)
            _ = try self.commitLocal(value)
        }
        return try localSnapshot()
    }

    private static func replacesAssets(_ record: DownloadRecord, row: ServerDownloadRow) -> Bool {
        if let incoming = row.revision, let current = record.revision { return incoming > current }
        return record.revision == nil && (record.mediaFileId != row.mediaFileId || record.format != row.quality)
    }

    private static func localStatus(_ value: String) -> LocalDownloadStatus {
        switch value {
        case "ready": return .queued
        case "preparing": return .preparing
        case "revoked": return .revoked
        case "failed": return .failed
        default: return .registering
        }
    }
    private static func localRecord(from row: ServerDownloadRow, type: String?) -> DownloadRecord {
        DownloadRecord(
            id: row.id,
            contentId: row.contentId,
            episodeId: row.episodeId,
            batchId: row.batchId,
            mediaFileId: row.mediaFileId,
            format: row.quality,
            effectiveQuality: row.effectiveQuality,
            deliveryFormat: row.deliveryFormat,
            targetBitrateKbps: row.targetBitrateKbps,
            revision: row.revision,
            serverStatus: row.status,
            localStatus: localStatus(row.status),
            fileSize: row.fileSize ?? 0,
            bytesDownloaded: 0,
            mediaFilename: nil,
            manifestFilename: nil,
            posterFilename: nil,
            backdropFilename: nil,
            logoFilename: nil,
            subtitleFilenames: [:],
            title: nil,
            subtitle: nil,
            type: type,
            seriesId: nil,
            posterThumbhash: nil,
            container: nil,
            stableIdentity: nil,
            registeredAt: row.createdAt ?? Date(),
            downloadedAt: row.completedAt,
            lastError: nil,
            retryCount: 0,
            taskIdentifier: nil
        )
    }

}
