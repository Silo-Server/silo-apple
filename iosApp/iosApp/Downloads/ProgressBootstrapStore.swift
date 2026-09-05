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
    private let scope: ProgressBootstrapStoreScope
    private let write: @Sendable (Data, URL) throws -> Void
    private var state: ProgressBootstrapStoreFile?

    init(url: URL, scope: ProgressBootstrapStoreScope,
         write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.url = url
        self.scope = scope
        self.write = write
    }

    /// The original v1 bytes remain untouched, including on decode or write failure.
    func migrate(legacyData: Data) throws -> ProgressBootstrapStoreFile {
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
