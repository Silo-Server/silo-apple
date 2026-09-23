import Foundation

/// The rules for the offline progress queue in `DownloadStoreFile`.
///
/// `syncProgress` is `non_retryable`, so every entry ends in one of the three
/// outcomes of the v2 failure model:
///
/// - definite success, or a per-item failure the server reported: the entry
///   leaves the queue;
/// - definite failure of the whole batch (a non-success status): the entries
///   leave the queue; a batch that never left the device goes back to
///   pending, because nothing reached the server;
/// - uncertain (sent, no usable answer): the entries stay `dispatched` and
///   are held. They are never sent again. A newer event for the same item
///   replaces the held entry: it is a new write whose later `updated_at` wins
///   over the unknown one, not a replay of it.
enum OfflineProgressQueue {
    /// Queues an offline event, replacing any earlier entry for the item so
    /// an offline session that ticks every few seconds keeps one entry.
    static func record(
        _ queue: inout [QueuedProgress],
        mediaItemId: String,
        position: Double,
        duration: Double,
        at time: Date
    ) {
        queue.removeAll { $0.mediaItemId == mediaItemId }
        queue.append(QueuedProgress(
            id: UUID(),
            mediaItemId: mediaItemId,
            position: position,
            duration: duration,
            updatedAt: time
        ))
    }

    /// The next batch to upload: pending entries in queue order, at most
    /// `SyncProgressRequest.maxItems`. Run `dropUnsendable` first so the
    /// batch holds one entry per item.
    static func nextBatch(_ queue: [QueuedProgress]) -> [QueuedProgress] {
        Array(queue.filter { $0.state == .pending }.prefix(SyncProgressRequest.maxItems))
    }

    /// Drops pending entries that can never be sent (unusable values) and any
    /// pending entry older than another pending entry for the same item.
    static func dropUnsendable(_ queue: inout [QueuedProgress]) {
        var newest: [String: QueuedProgress] = [:]
        for entry in queue where entry.state == .pending && entry.syncItem != nil {
            if let existing = newest[entry.mediaItemId], existing.updatedAt > entry.updatedAt { continue }
            newest[entry.mediaItemId] = entry
        }
        queue.removeAll { $0.state == .pending && newest[$0.mediaItemId]?.id != $0.id }
    }

    /// Marks a batch as handed to the transport.
    static func claim(_ queue: inout [QueuedProgress], ids: Set<UUID>) {
        for index in queue.indices where ids.contains(queue[index].id) {
            queue[index].state = .dispatched
        }
    }

    /// Applies one dispatch outcome to the entries of `batch` still queued.
    /// An entry replaced while the request was in flight is already gone and
    /// is not touched; its replacement stays pending.
    static func resolve(_ queue: inout [QueuedProgress], batch: [QueuedProgress], outcome: ProgressSyncOutcome) {
        let ids = Set(batch.map(\.id))
        switch outcome {
        case .answered, .rejected:
            queue.removeAll { ids.contains($0.id) }
        case .notSent:
            for index in queue.indices where ids.contains(queue[index].id) {
                queue[index].state = .pending
            }
        case .uncertain:
            break
        }
    }

    /// Entries whose upload outcome is unknown: dispatched and not part of a
    /// flush that is still waiting for its answer.
    static func held(_ queue: [QueuedProgress], inFlight: Set<UUID>) -> [QueuedProgress] {
        queue.filter { $0.state == .dispatched && !inFlight.contains($0.id) }
    }

    /// "Discard held change": forgets held entries without sending them.
    static func discardHeld(_ queue: inout [QueuedProgress], inFlight: Set<UUID>) {
        queue.removeAll { $0.state == .dispatched && !inFlight.contains($0.id) }
    }
}
