//
//  AIModels.swift
//  Continuum (iOS + tvOS)
//
//  Wire types for silo-server's two AI features: metadata translation
//  (overviews/taglines localized into the viewer's preferred language,
//  plus an on-demand "translate this description" path) and subtitle
//  translation/transcription (translate an existing track, transcribe
//  audio via Whisper, or transcribe-and-translate).
//
//  All of these ride the native API (`/api/v1/...`) and go through
//  ``HTTPClient/shared``, whose coders are `.convertFromSnakeCase` /
//  `.convertToSnakeCase`. Properties therefore stay camelCase with no
//  `CodingKeys` boilerplate; the only exception is
//  ``SubtitleAIKind/transcribeTranslate`` whose wire value
//  (`transcribe_translate`) isn't a clean snake_case of the case name.
//
//  Endpoints in play (see ``ContinuumAI``):
//    GET  /api/v1/metadata/ai/status
//    POST /api/v1/items/{id}/translate-description
//    GET  /api/v1/subtitles/ai/status
//    GET  /api/v1/subtitles/ai/quota
//    POST /api/v1/subtitles/ai/translate
//    GET  /api/v1/subtitles/ai/jobs/{job_id}
//    GET  /api/v1/subtitles/ai/jobs?media_file_id=N
//    POST /api/v1/subtitles/ai/jobs/{job_id}/cancel
//    GET  /api/v1/subtitles/{media_file_id}
//

import Foundation

// MARK: - Shared job status

/// Lifecycle of an AI subtitle job. Unknown wire values decode to
/// `.pending` so a server that introduces a new transient state never
/// trips the poller into a false terminal stop.
enum AIJobStatus: String, Codable {
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

/// `GET /api/v1/metadata/ai/status`. `enabled` gates the metadata-language
/// setting + the on-view translate affordance; `onView` decides whether the
/// affordance is a button, auto-fires, or is hidden.
struct MetadataAIStatus: Codable {
    let enabled: Bool
    let onView: OnViewMode

    /// How the item-detail "translate this description" affordance behaves.
    /// Unknown wire values decode to `.off` (feature hidden) so an older or
    /// future server degrades silently.
    enum OnViewMode: String, Codable {
        case off
        case button
        case auto

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = OnViewMode(rawValue: raw) ?? .off
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        onView = try c.decodeIfPresent(OnViewMode.self, forKey: .onView) ?? .off
    }
}

/// Body for `POST /api/v1/items/{id}/translate-description` (202, no
/// response body — observe completion by re-fetching the item detail
/// until `pendingTranslationLanguage` clears).
struct TranslateDescriptionBody: Encodable {
    let targetLanguage: String
}

// MARK: - Subtitle AI

/// `GET /api/v1/subtitles/ai/status`. `transcribeEnabled` additionally
/// gates the Whisper transcription controls + the quota gauge.
struct SubtitleAIStatus: Codable {
    let enabled: Bool
    let transcribeEnabled: Bool

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        transcribeEnabled = try c.decodeIfPresent(Bool.self, forKey: .transcribeEnabled) ?? false
    }
}

/// `GET /api/v1/subtitles/providers/status`. Whether the server has any
/// external subtitle providers (OpenSubtitles / SubDL / Subsource)
/// configured, so the client can disable the in-player "Search Subtitles…"
/// entry point instead of running a fan-out search that can only return
/// nothing.
///
/// **The decoder defaults `enabled` to `true`, not `false`** — unlike every
/// other status model in this file. Subtitle search shipped long before this
/// endpoint did, so anything short of an affirmative "no providers" must
/// leave the feature usable or every not-yet-updated server regresses. Same
/// rule as ``SubtitleProvidersStore``, which owns the full rationale.
///
/// `providers` is informational (the configured provider ids); nothing gates
/// on it today.
struct SubtitleProvidersStatus: Codable {
    let enabled: Bool
    let providers: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        providers = try c.decodeIfPresent([String].self, forKey: .providers) ?? []
    }
}

/// `GET /api/v1/subtitles/ai/quota`. The per-user ASR allowance. When
/// `limited` is false the remaining fields are typically absent and the
/// feature is effectively unmetered.
struct SubtitleAIQuota: Codable, Equatable {
    let limited: Bool
    let limit: Int?
    let used: Int?
    let remaining: Int?
    let period: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        limited = try c.decodeIfPresent(Bool.self, forKey: .limited) ?? false
        limit = try c.decodeIfPresent(Int.self, forKey: .limit)
        used = try c.decodeIfPresent(Int.self, forKey: .used)
        remaining = try c.decodeIfPresent(Int.self, forKey: .remaining)
        period = try c.decodeIfPresent(String.self, forKey: .period)
    }
}

/// What an AI subtitle job should do.
/// - `translate`: translate an existing text track (default).
/// - `transcribe`: Whisper ASR of an audio track to subtitles.
/// - `transcribeTranslate`: ASR then translate the transcript.
enum SubtitleAIKind: String, Codable {
    case translate
    case transcribe
    case transcribeTranslate = "transcribe_translate"
}

/// Body for `POST /api/v1/subtitles/ai/translate` → `202 { job }`.
///
/// `sourceIndex` is the combined player subtitle index for `translate`,
/// or the audio track index (`-1` = default) for `transcribe*`. When
/// `sessionId` is present the server streams cues live over the playback
/// control websocket; `startPosition` (seconds) is the playhead so the
/// watched region translates first.
struct TranslateSubtitleBody: Encodable {
    let mediaFileId: Int
    let kind: SubtitleAIKind?
    let sourceIndex: Int
    let sourceLanguage: String?
    let targetLanguage: String?
    let sessionId: String?
    let startPosition: Double?
}

/// One AI subtitle job. `resultSubtitleId` is populated once the job
/// reaches `completed`; the persisted track then appears in the normal
/// downloaded-subtitle listing.
struct SubtitleJob: Codable, Identifiable, Equatable {
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
    let resultSubtitleId: Int?
    let errorMessage: String?
    let createdAt: String?
    let updatedAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The server serializes the job's `ID int64` bare, so `id` arrives as a
        // JSON **number** (`{"id":42}`), not a string. Decoding `String.self`
        // against a number throws — which used to make EVERY real 202/poll
        // response fail to decode, silently disabling the whole pipeline. Decode
        // tolerantly: accept a number or a string and normalize to `String` so
        // the `"ai-<id>"` track-key join still matches the server's
        // `liveTrackKey` (`fmt.Sprintf("ai-%d", jobID)`). An integer normalizes
        // to its plain decimal form (`42` → `"42"`).
        if let intID = try? c.decode(Int64.self, forKey: .id) {
            id = String(intID)
        } else {
            id = try c.decode(String.self, forKey: .id)
        }
        mediaFileId = try c.decodeIfPresent(Int.self, forKey: .mediaFileId) ?? 0
        kind = try c.decodeIfPresent(SubtitleAIKind.self, forKey: .kind) ?? .translate
        sourceIndex = try c.decodeIfPresent(Int.self, forKey: .sourceIndex) ?? -1
        sourceLanguage = try c.decodeIfPresent(String.self, forKey: .sourceLanguage)
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage)
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        status = try c.decodeIfPresent(AIJobStatus.self, forKey: .status) ?? .pending
        progress = try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        progressMessage = try c.decodeIfPresent(String.self, forKey: .progressMessage)
        resultSubtitleId = try c.decodeIfPresent(Int.self, forKey: .resultSubtitleId)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

/// Envelope for the single-job endpoints (`translate`, `jobs/{id}`).
struct SubtitleJobEnvelope: Codable {
    let job: SubtitleJob
}

/// One server-stored downloaded subtitle, as listed by
/// `GET /api/v1/subtitles/{media_file_id}`.
///
/// This is the server's `internal/subtitles.DownloadedSubtitle` JSON shape —
/// **not** the playback-session `subtitle_urls[]` shape. It carries the
/// subtitle's DB **`id`** (which the job's `result_subtitle_id` references)
/// but **no combined `index` and no `url`**: the server never includes a
/// stream URL here. The player synthesizes both at handoff time the way the
/// Android client does (see ``synthesizedDescriptor(sessionId:baseTrackCount:position:serverBaseURL:)``
/// and `SubtitleTrackMerge.kt`).
///
/// Decoders are tolerant: only `id` is required, everything else defaults so
/// a provider that omits e.g. `score` / `created_at` still decodes.
struct DownloadedSubtitle: Codable, Identifiable, Equatable {
    /// Subtitle DB id — what a job's `result_subtitle_id` points at.
    let id: Int
    let mediaFileId: Int
    let provider: String
    let language: String
    /// Stored format (`srt`/`subrip`/`ass`/`ssa`/`webvtt`/`vtt`/`pgs`/…).
    let format: String
    let releaseName: String
    let score: Double?
    let hearingImpaired: Bool?
    let createdAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        mediaFileId = try c.decodeIfPresent(Int.self, forKey: .mediaFileId) ?? 0
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? ""
        releaseName = try c.decodeIfPresent(String.self, forKey: .releaseName) ?? ""
        score = try c.decodeIfPresent(Double.self, forKey: .score)
        hearingImpaired = try c.decodeIfPresent(Bool.self, forKey: .hearingImpaired)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
    }

    /// Memberwise init for tests / synthesis.
    init(
        id: Int,
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
    /// The server's `GET /subtitles/{media_file_id}` listing carries no
    /// stream URL and no combined player index, so the client builds both —
    /// **identically to Android's `SubtitleTrackMerge.mergeDownloadedSubtitles`**
    /// — because the `/stream/{session_id}/subtitles/{track}` route keys on the
    /// **combined** subtitle index (external → embedded → downloaded), not the
    /// subtitle DB id (verified in server `StreamHandler.HandleSubtitle` +
    /// `ParseSubtitleTrackParam`).
    ///
    /// - Parameters:
    ///   - sessionId: the active playback session id (the stream mount is
    ///     session-scoped).
    ///   - baseTrackCount: the combined index the **first** downloaded track
    ///     occupies — Android's `(max(existing non-downloaded .index) + 1)`,
    ///     computed `+1` over the max rather than the list size so server-side
    ///     burn-in skipping (which can leave index gaps) is honored.
    ///   - position: this subtitle's position within the downloaded listing
    ///     (0-based). The combined index is `baseTrackCount + position`,
    ///     matching Android's `baseIndex + i`.
    ///   - resolveURL: turns the synthesized API-relative stream path into an
    ///     absolute `URL` against the active server base (the player's
    ///     existing `resolveServerUrl`). Returns `nil` if it can't resolve.
    /// - Returns: a ready-to-register descriptor, or `nil` if the URL can't be
    ///   resolved.
    func synthesizedDescriptor(
        sessionId: String,
        baseTrackCount: Int,
        position: Int,
        resolveURL: (String) -> URL?
    ) -> SidecarSubtitleDescriptor? {
        let combinedIndex = baseTrackCount + position
        let path = "/stream/\(sessionId)/subtitles/\(combinedIndex)\(streamURLExtension)"
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

/// Envelope for `GET /api/v1/subtitles/{media_file_id}` → the downloaded
/// subtitle tracks for a file. Used after a job completes to locate the
/// persisted track by `result_subtitle_id` and merge it into the player's
/// track list.
struct DownloadedSubtitlesResponse: Codable {
    let subtitles: [DownloadedSubtitle]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subtitles = try c.decodeIfPresent([DownloadedSubtitle].self, forKey: .subtitles) ?? []
    }
}
