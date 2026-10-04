import Foundation

// Subtitle sync: the server aligns a subtitle to its file's audio and stores
// a timing correction. It never changes the subtitle's bytes; every delivery
// path (playback sidecars, offline downloads) serves them with the correction
// applied. It syncs stored subtitles and the subtitle files next to the media
// (sidecars), each named by an opaque sync key: `stored-{id}` or
// `external-{hash}`.

/// A subtitle's timing correction: original time `t` plays at
/// `t * scale + offsetMs`. `{0, 1}` when uncorrected.
struct SubtitleTiming: Decodable, Equatable, Sendable {
    let offsetMs: Int
    let scale: Double

    static let identity = SubtitleTiming(offsetMs: 0, scale: 1)

    var isIdentity: Bool { offsetMs == 0 && scale == 1 }
}

/// A subtitle's latest sync job (`SubtitleSyncJobState`, or the stored
/// projection's `SubtitleSyncJob`, which adds `subtitle_id`).
struct SubtitleSyncJob: Decodable, Equatable, Sendable {
    let id: String
    /// The stored subtitle's ID; absent for a sidecar.
    let subtitleId: String?
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
    /// While active: `queued`, `analyzing` (reading the file's speech), or
    /// `matching` (aligning cues with it).
    var phase: String? = nil
    /// While active: 0...1.
    var progress: Double? = nil
    /// When failed: `subtitle_changed`, `no_audio`, `unavailable`, or `error`.
    var failure: String? = nil

    var isInProgress: Bool { status == "pending" || status == "running" }
}

/// One syncable subtitle of a media file (`SubtitleSyncState`): its timing
/// and latest job, under the sync key the playback inventory publishes.
struct SubtitleSyncState: Decodable, Equatable, Sendable {
    let key: String
    let mediaFileId: String
    /// `downloaded` (a stored subtitle) or `external` (a sidecar file).
    let source: String
    /// Present for a stored subtitle.
    let storedSubtitleId: String?
    let language: String
    let format: String
    /// The release name, or the sidecar's file name.
    let label: String
    let timing: SubtitleTiming
    /// The latest job, when the subtitle was ever synced.
    let sync: SubtitleSyncJob?

    var isExternal: Bool { source == "external" }

    func replacing(timing: SubtitleTiming? = nil, sync: SubtitleSyncJob?) -> SubtitleSyncState {
        SubtitleSyncState(key: key, mediaFileId: mediaFileId, source: source, storedSubtitleId: storedSubtitleId,
            language: language, format: format, label: label, timing: timing ?? self.timing, sync: sync)
    }

    /// The sync key of a stored subtitle.
    static func storedKey(_ storedId: String) -> String { "stored-\(storedId)" }
}

extension DownloadedSubtitle {
    /// The sync state a stored subtitle row carries (a download, an upload,
    /// or a row from a server that predates sync keys).
    var syncState: SubtitleSyncState {
        SubtitleSyncState(key: SubtitleSyncState.storedKey(id), mediaFileId: String(mediaFileId),
            source: "downloaded", storedSubtitleId: id, language: language, format: format,
            label: releaseName.isEmpty ? provider : releaseName, timing: timing, sync: sync)
    }
}

// MARK: getSubtitleSyncStatus

/// `GET /api/v2/subtitles/sync/status`. Sync is usable only when the viewer
/// is `allowed` and the state is `available`.
struct APIv2SubtitleSyncStatus: Decodable {
    let revision: String
    let state: String
    let allowed: Bool
    let autoSync: Bool
    /// Whether sidecar files can be synced. A server that predates sync keys
    /// omits it and syncs only stored subtitles, through their own routes.
    let external: Bool?

    var isAvailable: Bool { allowed && state == "available" }
    /// The server addresses subtitles by sync key (`listSubtitleSync` and
    /// its siblings).
    var usesSyncKeys: Bool { external != nil }
}

// MARK: listSubtitleSync / getSubtitleSync / startSubtitleSync / setSubtitleTiming

struct APIv2SubtitleSyncList: Decodable {
    let subtitles: [SubtitleSyncState]
}

/// The `{subtitle}` body of `getSubtitleSync`, `startSubtitleSync`, and
/// `setSubtitleTiming`.
struct APIv2SubtitleSyncStateEnvelope: Decodable {
    let subtitle: SubtitleSyncState
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
