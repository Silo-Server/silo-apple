import Foundation

// Stored subtitle sync: the server aligns a stored subtitle to its file's
// audio and stores a timing correction on the row. The stored bytes never
// change; every delivery path (playback sidecars, offline downloads) serves
// them with the correction applied.

/// A stored subtitle's timing correction: original time `t` plays at
/// `t * scale + offsetMs`. `{0, 1}` when uncorrected.
struct SubtitleTiming: Decodable, Equatable, Sendable {
    let offsetMs: Int
    let scale: Double

    static let identity = SubtitleTiming(offsetMs: 0, scale: 1)

    var isIdentity: Bool { offsetMs == 0 && scale == 1 }
}

/// The latest sync job of a stored subtitle.
struct SubtitleSyncJob: Decodable, Equatable, Sendable {
    let id: String
    let subtitleId: String
    /// `pending`, `running`, `synced`, `already_synced`, `no_match`, or
    /// `failed`. Kept as the wire string so a status added later reads as
    /// "not in progress" instead of failing the whole listing.
    let status: String
    let trigger: String
    /// Share of sampled audio windows that agree, once finished.
    let confidence: Double?
    /// The correction found, once finished.
    let result: SubtitleTiming?
    let createdAt: String
    let finishedAt: String?

    var isInProgress: Bool { status == "pending" || status == "running" }
}

// MARK: getSubtitleSyncStatus

/// `GET /api/v2/subtitles/sync/status`. Sync is usable only when the viewer
/// is `allowed` and the state is `available`.
struct APIv2SubtitleSyncStatus: Decodable {
    let revision: String
    let state: String
    let allowed: Bool
    let autoSync: Bool

    var isAvailable: Bool { allowed && state == "available" }
}

// MARK: getStoredSubtitleSync / setStoredSubtitleTiming

/// The `{subtitle}` body of `GET .../stored/{id}/sync` and
/// `PUT .../stored/{id}/timing`.
struct APIv2StoredSubtitleEnvelope: Decodable {
    let subtitle: APIv2StoredSubtitle
}

// MARK: syncStoredSubtitle

struct APIv2SubtitleSyncRequestResponse: Decodable {
    let job: SubtitleSyncJob
}

struct APIv2SubtitleTimingBody: Encodable {
    let offsetMs: Int
    let scale: Double
}
