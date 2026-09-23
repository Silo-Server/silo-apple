import Foundation

// MARK: getSubtitleAIStatus

/// `GET /api/v2/subtitles/ai/status`. A feature is usable only when the
/// viewer is `allowed`, the state is `available`, and its own flag is on. An
/// unknown `state` counts as unavailable.
struct APIv2SubtitleAIStatus: Decodable {
    let enabled: Bool
    let transcribeEnabled: Bool
    let revision: String
    let state: String
    let allowed: Bool

    var playerValue: SubtitleAIStatus {
        let usable = allowed && state == "available"
        return SubtitleAIStatus(enabled: usable && enabled, transcribeEnabled: usable && transcribeEnabled)
    }
}

// MARK: getSubtitleAIQuota

/// `GET /api/v2/subtitles/ai/quota`. Every field is required.
struct APIv2SubtitleAIQuota: Decodable {
    let limited: Bool
    let limit: Int
    let used: Int
    let remaining: Int
    let period: String

    var playerValue: SubtitleAIQuota {
        SubtitleAIQuota(limited: limited, limit: limit, used: used, remaining: remaining, period: period)
    }
}

// MARK: getSubtitleAIJob

struct APIv2SubtitleJobEnvelope: Decodable {
    let job: APIv2SubtitleJob
}

struct APIv2SubtitleJob: Decodable {
    let id: String
    let mediaFileId: String
    let kind: String
    let sourceIndex: Int
    let sourceLanguage: String
    let targetLanguage: String
    let engine: String
    let model: String
    let status: AIJobStatus
    let progress: Double
    let progressMessage: String
    let resultSubtitleId: String?
    let errorMessage: String?
    let createdAt: String
    let updatedAt: String
}

extension SubtitleJob {
    /// Job and result IDs stay opaque. Only the media file needs an exact
    /// integer projection, because the player addresses files by `Int`.
    init(v2 job: APIv2SubtitleJob, expectedJobID: String) throws {
        guard job.id == expectedJobID,
              let knownKind = SubtitleAIKind(rawValue: job.kind),
              let fileID = Int(job.mediaFileId), fileID > 0,
              String(fileID) == job.mediaFileId,
              job.resultSubtitleId?.isEmpty != true else { throw APIv2Error.invalidSubtitleResponse }
        self.init(id: job.id, mediaFileId: fileID, kind: knownKind, sourceIndex: job.sourceIndex,
            sourceLanguage: job.sourceLanguage, targetLanguage: job.targetLanguage, engine: job.engine,
            model: job.model, status: job.status, progress: job.progress, progressMessage: job.progressMessage,
            resultSubtitleId: job.resultSubtitleId, errorMessage: job.errorMessage,
            createdAt: job.createdAt, updatedAt: job.updatedAt)
    }
}

// MARK: createSubtitleAIJob (non_retryable)

/// Body for `POST /api/v2/subtitles/ai/translate`. The contract requires
/// both languages (an empty string means "detect" or "keep"), the start
/// position, and a string file ID, and allows no other fields.
struct APIv2SubtitleCreateBody: Encodable {
    let mediaFileId: String
    let kind: SubtitleAIKind
    let sourceIndex: Int
    let sourceLanguage: String
    let targetLanguage: String
    let sessionId: String?
    let startPosition: Double

    init(_ body: TranslateSubtitleBody) throws {
        guard body.mediaFileId > 0, let kind = body.kind, body.sourceIndex >= -1,
              let position = body.startPosition, position.isFinite, position >= 0 else {
            throw APIv2Error.invalidSubtitleResponse
        }
        mediaFileId = String(body.mediaFileId); self.kind = kind
        sourceIndex = body.sourceIndex; sourceLanguage = body.sourceLanguage ?? ""
        targetLanguage = body.targetLanguage ?? ""; sessionId = body.sessionId; startPosition = position
    }
}

struct APIv2SubtitleCreateResponse: Decodable {
    let job: APIv2SubtitleJob
    let liveDeliveryAttached: Bool
}

struct SubtitleCreationResult {
    let job: SubtitleJob
    let liveDeliveryAttached: Bool
}

/// A subtitle job request that ended without an answer from the server.
enum SubtitleCreationError: LocalizedError, Equatable {
    /// An identical earlier request has no confirmed outcome, so this one was
    /// not sent. It stays held until the user discards it.
    case unresolved
    /// This request may have started a job, but no usable answer came back:
    /// the owner changed once it may have been sent, or the 202 receipt did
    /// not describe the job that was asked for.
    case outcomeUnknown

    var errorDescription: String? {
        switch self {
        case .unresolved:
            return "An earlier request for these subtitles may still be running, so Silo didn't send it again."
        case .outcomeUnknown:
            return "Silo couldn't confirm that the subtitle job started. If it did, the subtitles will appear in the subtitle list when it finishes."
        }
    }

    /// Whether a failed create may have started a job. Such a request is
    /// held and never resent.
    static func isUncertain(_ error: Error) -> Bool {
        (error as? SubtitleCreationError) == .outcomeUnknown || APIv2DispatchFailure.isUncertain(error)
    }
}
