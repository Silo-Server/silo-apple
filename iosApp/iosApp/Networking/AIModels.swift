//
//  AIModels.swift
//  Silo (iOS + tvOS)
//
//  Types for silo-server's two AI features: metadata translation
//  (overviews/taglines localized into the viewer's preferred language,
//  plus an on-demand "translate this description" path) and subtitle
//  translation/transcription (translate an existing track, transcribe
//  audio via Whisper, or transcribe-and-translate).
//
//  Every AI call goes through ``APIv2Client`` (see ``SiloAI``). The wire
//  shapes live in `APIv2/APIv2MetadataAIModels.swift`,
//  `APIv2/APIv2SubtitleModels.swift` and `APIv2/APIv2SubtitleAIModels.swift`;
//  the types here are the domain values the player and settings read, built
//  from those wire models.
//

import Foundation

// MARK: - Shared job status

/// Lifecycle of an AI subtitle job. Unknown wire values decode to
/// `.pending` so a server that introduces a new transient state never
/// trips the poller into a false terminal stop.
enum AIJobStatus: String, Decodable {
    case pending
    case running
    case completed
    case failed
    case cancelled

    /// A job in `completed` / `failed` / `cancelled` will not change
    /// again — the poller stops here.
    var isTerminal: Bool {
        self != .pending && self != .running
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AIJobStatus(rawValue: raw) ?? .pending
    }
}

// MARK: - Metadata AI

/// Whether the metadata-language setting and the on-view translate
/// affordance may appear, and how the affordance behaves. Projected from
/// ``APIv2MetadataAICapability``.
struct MetadataAIStatus {
    let enabled: Bool
    let onView: OnViewMode

    /// How the item-detail "translate this description" affordance behaves.
    /// Unknown wire values decode to `.off` (feature hidden) so an older or
    /// future server degrades silently.
    enum OnViewMode: String, Decodable {
        case off
        case button
        case auto

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = OnViewMode(rawValue: raw) ?? .off
        }
    }
}

// MARK: - Subtitle AI

/// Whether the player may offer AI subtitles. Projected from
/// ``APIv2SubtitleAIStatus``: each flag is on only when the viewer is
/// `allowed` and the state is `available`. `transcribeEnabled` additionally
/// gates the Whisper transcription controls + the quota gauge.
struct SubtitleAIStatus: Equatable {
    let enabled: Bool
    let transcribeEnabled: Bool
}

/// The per-user ASR allowance, from ``APIv2SubtitleAIQuota``. When `limited`
/// is false the feature is effectively unmetered.
struct SubtitleAIQuota: Equatable {
    let limited: Bool
    let limit: Int?
    let used: Int?
    let remaining: Int?
    let period: String?
}

/// What an AI subtitle job should do.
/// - `translate`: translate an existing text track (default).
/// - `transcribe`: Whisper ASR of an audio track to subtitles.
/// - `transcribeTranslate`: ASR then translate the transcript.
enum SubtitleAIKind: String, Encodable {
    case translate
    case transcribe
    case transcribeTranslate = "transcribe_translate"
}

/// What the player asks an AI subtitle job to do. ``APIv2SubtitleCreateBody``
/// checks it and builds the `POST /api/v2/subtitles/ai/translate` body.
///
/// `sourceIndex` is the combined player subtitle index for `translate`,
/// or the audio track index (`-1` = default) for `transcribe*`. When
/// `sessionId` is present the server streams cues live over the playback
/// control websocket; `startPosition` (seconds) is the playhead so the
/// watched region translates first.
struct TranslateSubtitleBody: Equatable {
    let mediaFileId: Int
    let kind: SubtitleAIKind?
    let sourceIndex: Int
    let sourceLanguage: String?
    let targetLanguage: String?
    let sessionId: String?
    let startPosition: Double?
}

/// One AI subtitle job, projected from ``APIv2SubtitleJob``. The job `id`
/// and `resultSubtitleId` stay opaque strings. `resultSubtitleId` is set
/// once the job reaches `completed`; the persisted track then appears in the
/// stored-subtitle listing under that ID.
struct SubtitleJob: Identifiable, Equatable {
    let id: String
    let mediaFileId: Int
    let kind: SubtitleAIKind
    let sourceIndex: Int
    let sourceLanguage: String?
    let targetLanguage: String?
    let engine: String?
    let model: String?
    let status: AIJobStatus
    let progress: Double
    let progressMessage: String?
    let resultSubtitleId: String?
    let errorMessage: String?
    let createdAt: String?
    let updatedAt: String?
}

/// One server-stored downloaded subtitle, as listed by
/// `GET /api/v2/subtitles/{media_file_id}` (see ``APIv2StoredSubtitle``).
///
/// It carries the subtitle's stored **`id`** (which the job's
/// `result_subtitle_id` references) but **no combined `index` and no `url`**:
/// the server never includes a stream URL here. The player synthesizes both
/// at handoff time (see
/// ``synthesizedDescriptor(sessionId:ordinal:resolveURL:)``), and the URL
/// names the row by `id` rather than by listing position.
struct DownloadedSubtitle: Identifiable, Equatable {
    /// Opaque stored-subtitle ID — what a job's `result_subtitle_id` points at.
    let id: String
    let mediaFileId: Int
    let provider: String
    let language: String
    /// Stored format (`srt`/`subrip`/`ass`/`ssa`/`webvtt`/`vtt`/`pgs`/…).
    let format: String
    let releaseName: String
    let score: Double?
    let hearingImpaired: Bool?
    let createdAt: String?

    /// Memberwise init for tests / synthesis.
    init(
        id: String,
        mediaFileId: Int = 0,
        provider: String = "",
        language: String = "",
        format: String = "",
        releaseName: String = "",
        score: Double? = nil,
        hearingImpaired: Bool? = nil,
        createdAt: String? = nil
    ) {
        self.id = id
        self.mediaFileId = mediaFileId
        self.provider = provider
        self.language = language
        self.format = format
        self.releaseName = releaseName
        self.score = score
        self.hearingImpaired = hearingImpaired
        self.createdAt = createdAt
    }
}

extension DownloadedSubtitle {
    /// The URL-path extension the playback stream mount expects for this
    /// subtitle's stored `format`, matching the server's `subtitleURLExt`
    /// (playback.go) and Android's `subtitleUrlExtension`
    /// (SubtitleTrackMerge.kt):
    ///   - `ass` / `ssa` → `.ass` (raw authored subtitle input for Aether)
    ///   - `pgs` / `hdmv_pgs_subtitle` → `.sup` (raw PGS bitmap)
    ///   - everything else (srt/subrip/webvtt/…) → `.vtt`
    var streamURLExtension: String {
        switch format.trimmingCharacters(in: .whitespaces).lowercased() {
        case "ass", "ssa":
            return ".ass"
        case "pgs", "hdmv_pgs_subtitle":
            return ".sup"
        default:
            return ".vtt"
        }
    }

    /// Synthesize the player-track descriptor for this downloaded subtitle.
    ///
    /// The server's `GET /api/v2/subtitles/{media_file_id}` listing carries no
    /// stream URL and no combined player index, so the client builds both.
    /// The URL matches the server's `DownloadedSubtitleStreamURLV3`:
    /// `/api/v2/stream/{session}/subtitles/{ordinal}{ext}?file_id={file}&downloaded_subtitle_id={id}`.
    /// The `downloaded_subtitle_id` pin makes the stream handler serve this
    /// row by identity. Without it the handler resolves the ordinal against
    /// its unfiltered stored-subtitle list, while the v2 listing omits rows
    /// whose language the server cannot canonicalize, so a listing position
    /// can name a different row.
    ///
    /// - Parameters:
    ///   - sessionId: the active playback session id (the stream mount is
    ///     session-scoped).
    ///   - ordinal: the combined ordinal the player files this track under
    ///     (see ``DownloadedSubtitleOrdinals``). The pin, not the ordinal,
    ///     selects the row.
    ///   - resolveURL: turns the synthesized API-relative stream path into an
    ///     absolute `URL` against the active server base (the player's
    ///     existing `resolveServerUrl`). Returns `nil` if it can't resolve.
    /// - Returns: a ready-to-register descriptor, or `nil` if the row has no
    ///   positive integer ID or file (the server's pin needs both) or the URL
    ///   can't be resolved.
    func synthesizedDescriptor(
        sessionId: String,
        ordinal combinedIndex: Int,
        resolveURL: (String) -> URL?
    ) -> SidecarSubtitleDescriptor? {
        guard mediaFileId > 0, let rowID = Int(id), rowID > 0, String(rowID) == id else { return nil }
        let path = "/api/v2/stream/\(sessionId)/subtitles/\(combinedIndex)\(streamURLExtension)"
            + "?file_id=\(mediaFileId)&downloaded_subtitle_id=\(rowID)"
        guard let url = resolveURL(path) else { return nil }
        let label = releaseName.isEmpty
            ? (provider.isEmpty ? language : provider)
            : (provider.isEmpty ? releaseName : "\(releaseName) (\(provider))")
        return SidecarSubtitleDescriptor(
            index: combinedIndex,
            language: language.isEmpty ? nil : language,
            codec: format.isEmpty ? nil : format,
            label: label.isEmpty ? nil : label,
            source: "downloaded",
            forced: false,
            url: url
        )
    }
}

/// Where the plan's combined subtitle ordinals place stored subtitles.
///
/// The player files a sidecar under its ordinal, and a later plan's inventory
/// replaces a locally registered row with the same ordinal. The inventory
/// counts every stored row, but the v2 listing omits rows whose language the
/// server cannot canonicalize, so a listing position is not an ordinal: after
/// an omitted row it would name an earlier stored subtitle's slot.
struct DownloadedSubtitleOrdinals: Equatable {
    /// Ordinals the current plan published, keyed by stored row ID.
    let published: [String: Int]
    /// The first ordinal past every track the plan published.
    let next: Int

    /// The ordinal for `listing[position]`: the published one when the plan
    /// names the row; otherwise `next`, advanced past earlier listing rows the
    /// plan does not name. The server orders stored rows by creation time, so
    /// rows stored after the plan follow every published one. A row stored
    /// after the plan and left out of the listing still shifts the server's
    /// later ordinals; the URL pin keeps the content right in that case.
    func ordinal(at position: Int, in listing: [DownloadedSubtitle]) -> Int {
        if let ordinal = published[listing[position].id] { return ordinal }
        return next + listing[..<position].filter { published[$0.id] == nil }.count
    }
}
