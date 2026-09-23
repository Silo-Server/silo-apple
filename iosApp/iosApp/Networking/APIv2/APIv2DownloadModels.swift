import Foundation

// Wire models for the v2 download registry: getDownloadCapability,
// createDownloads, listDownloads, reportDownloadStatus and deleteDownload.
// getDownloadManifest decodes into the stored `OfflineManifest`.

/// `DownloadCapability`. Only the fields the app reads are decoded; each of
/// them is required by the contract, so a missing one fails the read instead
/// of defaulting to a guess.
struct APIv2DownloadCapability: Decodable, Sendable {
    let state: String
    let allowed: Bool
    let enabled: Bool
    let downloadAllowed: Bool
    let qualityPresets: [String]
    let transcodeEnabled: Bool
    let transcodeUserAllowed: Bool
    let seasonDownload: Bool
    let seriesMonitoring: Bool
    let monitoringModes: [String]
}

/// `DownloadEntry`: one row of this device's download registry.
struct APIv2DownloadEntry: Decodable, Hashable, Sendable {
    let id: String
    let contentId: String
    let episodeId: String?
    let batchId: String?
    let deviceId: String?
    /// Opaque; compared and stored as a string.
    let mediaFileId: String
    let fileSize: Int64
    let bytesSent: Int64
    let kind: String
    let status: String
    let quality: String
    let effectiveQuality: String
    let deliveryFormat: String
    let targetBitrateKbps: Int
    /// Registry revision of the entry's bytes. Status events and create
    /// guards name it.
    let revision: Int
    let createdAt: Date
    let completedAt: Date?
    let statusEventAt: Date?

    /// Whether the entry can be stored: an id, a file, and a revision a
    /// status event can name.
    var isUsable: Bool {
        !id.isEmpty && !contentId.isEmpty && !mediaFileId.isEmpty && revision >= 1
    }
}

/// `SkippedDownload`: an episode a series page did not register.
struct APIv2SkippedDownload: Decodable, Hashable, Sendable {
    let episodeId: String
    let reason: String
}

/// `DownloadCreated`: one page of a `createDownloads` answer.
struct APIv2DownloadCreated: Decodable, Sendable {
    let items: [APIv2DownloadEntry]
    let skipped: [APIv2SkippedDownload]
    let page: APIv2Page
    let batchId: String?
}

/// `CollectionDownloadEntry`: one page of `listDownloads`.
struct APIv2DownloadEntryPage: Decodable, Sendable {
    let items: [APIv2DownloadEntry]
    let page: APIv2Page?
}

/// The two request shapes `createDownloads` accepts for a managed device.
enum APIv2DownloadCreateRequest: Encodable, Sendable {
    /// What a single-item create expects the registry to hold for that item.
    enum Guard: Hashable, Sendable {
        /// No entry: the server refuses with 409 if one exists.
        case absent
        /// Exactly this entry at this revision, which the create may reuse or
        /// replace.
        case entry(id: String, revision: Int)
    }

    /// One movie or episode. `quality` is a public preset.
    case single(contentId: String, episodeId: String?, mediaFileId: String?, quality: String,
                caps: DownloadCaps, expected: Guard)
    /// One page of a series or season request. Every page repeats the same
    /// client-chosen `batchId`; the server answers the original quality only.
    case seriesPage(seriesId: String, seasonNumber: Int?, batchId: String, caps: DownloadCaps)

    var batchId: String? {
        if case .seriesPage(_, _, let batchId, _) = self { return batchId }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case contentId = "content_id"
        case episodeId = "episode_id"
        case mediaFileId = "media_file_id"
        case quality
        case series
        case seasonNumber = "season_number"
        case caps
        case expectedRevision = "expected_revision"
        case expectedDownloadId = "expected_download_id"
        case batchId = "batch_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .single(contentId, episodeId, mediaFileId, quality, caps, expected):
            try container.encode(contentId, forKey: .contentId)
            try container.encodeIfPresent(episodeId, forKey: .episodeId)
            try container.encodeIfPresent(mediaFileId, forKey: .mediaFileId)
            try container.encode(quality, forKey: .quality)
            try container.encode(caps, forKey: .caps)
            switch expected {
            case .absent:
                try container.encode(0, forKey: .expectedRevision)
            case let .entry(id, revision):
                try container.encode(revision, forKey: .expectedRevision)
                try container.encode(id, forKey: .expectedDownloadId)
            }
        case let .seriesPage(seriesId, seasonNumber, batchId, caps):
            try container.encode(seriesId, forKey: .contentId)
            try container.encode(true, forKey: .series)
            try container.encodeIfPresent(seasonNumber, forKey: .seasonNumber)
            try container.encode(DownloadFormat.original.rawValue, forKey: .quality)
            try container.encode(caps, forKey: .caps)
            try container.encode(batchId, forKey: .batchId)
        }
    }

    /// Whether the server would accept this shape. A request that fails this
    /// is never dispatched.
    var isValid: Bool {
        switch self {
        case let .single(contentId, _, mediaFileId, _, _, expected):
            guard !contentId.isEmpty, mediaFileId?.isEmpty != true else { return false }
            if case let .entry(id, revision) = expected { return !id.isEmpty && revision >= 1 }
            return true
        case let .seriesPage(seriesId, _, batchId, _):
            return !seriesId.isEmpty && !batchId.isEmpty
        }
    }
}

/// One local status report for one registry revision. It is stored on the
/// record until the server answers, and a retry sends the same three values
/// (`reportDownloadStatus` is `domain_identity`).
struct DownloadStatusEvent: Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable {
        case downloading
        case completed
    }

    let status: Status
    /// When the local status changed, not when the report was sent.
    let updatedAt: Date
    let revision: Int
}

/// `DownloadStatusBody`.
struct APIv2DownloadStatusBody: Encodable, Sendable {
    let event: DownloadStatusEvent

    private enum CodingKeys: String, CodingKey {
        case status
        case updatedAt = "updated_at"
        case revision
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(event.status.rawValue, forKey: .status)
        try container.encode(Self.timestamp.string(from: event.updatedAt), forKey: .updatedAt)
        try container.encode(event.revision, forKey: .revision)
    }

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// A registry answer the client cannot use. Nothing from it is applied.
enum DownloadRegistryError: LocalizedError, Equatable, Sendable {
    /// A request that the server would refuse; it was not sent.
    case invalidRequest
    /// The registry read ended early, repeated a cursor or an entry, or held
    /// an entry without an id, file or revision.
    case incompleteRegistry
    /// A create or status answer that does not describe the request.
    case unexpectedReceipt
    /// A manifest for another entry, or without the file and revision it
    /// describes.
    case unusableManifest

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "The download request is not valid."
        case .incompleteRegistry: return "The server returned an incomplete download list. Try again."
        case .unexpectedReceipt: return "The server returned an unexpected download answer. Refresh downloads before trying again."
        case .unusableManifest: return "The server returned download details this app can't use."
        }
    }
}

/// How a failed registry call ended, from the client's point of view.
enum DownloadRegistryFailure: Equatable, Sendable {
    /// 409: the registry changed; read it again before acting.
    case conflict
    /// A definite refusal. The server applied nothing and would refuse the
    /// same request again.
    case rejected
    /// The server applied nothing, but the same request may succeed later:
    /// it never left the device, or the server asked to wait, or the server
    /// or app needs an update.
    case notApplied
    /// The request may have been applied: it was sent and no usable answer
    /// came back.
    case uncertain
}
