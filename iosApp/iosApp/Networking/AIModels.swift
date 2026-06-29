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
        id = try c.decode(String.self, forKey: .id)
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

/// Envelope for `GET /api/v1/subtitles/ai/jobs?media_file_id=N`.
struct SubtitleJobsEnvelope: Codable {
    let jobs: [SubtitleJob]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobs = try c.decodeIfPresent([SubtitleJob].self, forKey: .jobs) ?? []
    }
}

/// `GET /api/v1/subtitles/{media_file_id}` → the downloaded subtitle
/// tracks for a file, in the same shape as
/// `PlaybackSessionResponse.subtitle_urls`. Used after a job completes to
/// locate the persisted track by `result_subtitle_id` and merge it into
/// the player's track list.
struct DownloadedSubtitlesResponse: Codable {
    let subtitles: [SubtitleUrl]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subtitles = try c.decodeIfPresent([SubtitleUrl].self, forKey: .subtitles) ?? []
    }
}
