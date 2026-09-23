import Foundation

// Wire models for `POST /api/v2/sync/progress` (syncProgress).

/// One progress write. Positions cross the wire as whole milliseconds; the
/// app keeps seconds everywhere else, so the conversion happens only here.
struct SyncProgressItem: Encodable, Equatable, Sendable {
    let mediaItemId: String
    let positionMs: Int64
    /// Known runtime; 0 when unknown.
    let durationMs: Int64
    let forceOverwrite: Bool
    /// Client event time of an offline-queued write. The server clamps it to
    /// now and merges last-write-wins on it; absent means "now".
    let updatedAt: Date?

    /// Returns nil for an empty item id or a position that is not a finite,
    /// non-negative number of seconds. An unusable duration becomes 0
    /// ("unknown"), which the server accepts.
    init?(
        mediaItemId: String,
        position: Double,
        duration: Double,
        forceOverwrite: Bool,
        updatedAt: Date? = nil
    ) {
        guard !mediaItemId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let positionMs = Self.milliseconds(position) else { return nil }
        self.mediaItemId = mediaItemId
        self.positionMs = positionMs
        self.durationMs = Self.milliseconds(duration) ?? 0
        self.forceOverwrite = forceOverwrite
        self.updatedAt = updatedAt
    }

    /// Seconds to whole milliseconds, or nil when the value cannot be sent.
    static func milliseconds(_ seconds: Double) -> Int64? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let ms = (seconds * 1000).rounded()
        guard ms < Double(Int64.max) else { return nil }
        return Int64(ms)
    }

    private enum CodingKeys: String, CodingKey {
        case mediaItemId = "media_item_id"
        case positionMs = "position_ms"
        case durationMs = "duration_ms"
        case forceOverwrite = "force_overwrite"
        case updatedAt = "updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mediaItemId, forKey: .mediaItemId)
        try container.encode(positionMs, forKey: .positionMs)
        try container.encode(durationMs, forKey: .durationMs)
        try container.encode(forceOverwrite, forKey: .forceOverwrite)
        if let updatedAt {
            try container.encode(Self.timestamp.string(from: updatedAt), forKey: .updatedAt)
        }
    }

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// The request body: 1-100 items, at most one per `media_item_id`.
struct SyncProgressRequest: Encodable, Sendable {
    static let maxItems = 100

    let items: [SyncProgressItem]

    /// Whether the server would accept this batch's shape. A batch that
    /// fails this is never dispatched.
    var isValidBatch: Bool {
        (1...Self.maxItems).contains(items.count)
            && Set(items.map(\.mediaItemId)).count == items.count
    }
}

/// `ProgressSyncBatchResult`: one result per request item, always HTTP 200.
struct APIv2ProgressSyncBatchResult: Decodable, Sendable {
    let items: [APIv2ProgressSyncItemResult]
    let summary: APIv2BulkSummary
}

/// `ProgressSyncSuccess | ProgressSyncFailure`, discriminated by `status`.
struct APIv2ProgressSyncItemResult: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Sendable {
        case success
        case failure
    }

    let index: Int
    let mediaItemId: String
    let status: Status
    let failure: APIv2BulkItemFailure?

    var succeeded: Bool { status == .success }
}

/// `BulkItemFailure`: why the server did not apply one item.
struct APIv2BulkItemFailure: Decodable, Equatable, Sendable {
    let type: String
    let title: String
    let status: Int
    let detail: String
}

struct APIv2BulkSummary: Decodable, Equatable, Sendable {
    let total: Int
    let succeeded: Int
    let failed: Int
}

/// What one syncProgress dispatch established. The operation is
/// `non_retryable`, so the caller decides from this whether an item may be
/// sent again: only `notSent` and `deferred` items may, because the server
/// applied none of them.
enum ProgressSyncOutcome: Sendable {
    /// HTTP 200 with exactly one result per request item, ordered by index.
    case answered([APIv2ProgressSyncItemResult])
    /// Refused before the request left the device; nothing was applied.
    case notSent(any Error)
    /// The server answered that it applied nothing for now: a 401 or 403
    /// auth refusal, 408, 429, 503, or an update-required answer (the legacy
    /// 404, or 410 `client_upgrade_required`). The same batch may be sent
    /// again later.
    case deferred(any Error)
    /// The server refused the batch with any other non-success status. The
    /// batch as sent will not be accepted, so it is not sent again.
    case rejected(any Error)
    /// The request was sent and no usable answer arrived. The server may have
    /// applied any of the items; none may be sent again automatically.
    case uncertain(any Error)
}

enum ProgressSyncError: LocalizedError, Equatable {
    /// Empty, over 100 items, or a repeated `media_item_id`.
    case invalidBatch
    /// A 200 whose results do not map one-to-one onto the request items.
    case incompleteResult

    var errorDescription: String? {
        switch self {
        case .invalidBatch: return "The progress batch is not valid."
        case .incompleteResult: return "The server returned incomplete progress results."
        }
    }
}

extension ProgressSyncOutcome {
    /// Whether the server applied every item.
    var allSucceeded: Bool {
        if case .answered(let results) = self { return results.allSatisfy(\.succeeded) }
        return false
    }

    /// A log line for anything short of full success; nil when every item
    /// was applied. Carries no item ids or positions.
    var failureSummary: String? {
        switch self {
        case .answered(let results):
            let failures = results.compactMap(\.failure)
            guard !failures.isEmpty else { return nil }
            let kinds = Set(failures.map { "\($0.status) \($0.type)" }).sorted().joined(separator: ", ")
            return "\(failures.count) of \(results.count) items failed (\(kinds))"
        case .notSent(let error):
            return "not sent: \(MediaLogRedactor.sanitize(error))"
        case .deferred(let error):
            return "deferred: \(MediaLogRedactor.sanitize(error))"
        case .rejected(let error):
            return "rejected: \(MediaLogRedactor.sanitize(error))"
        case .uncertain(let error):
            return "outcome unknown, not resent: \(MediaLogRedactor.sanitize(error))"
        }
    }
}
