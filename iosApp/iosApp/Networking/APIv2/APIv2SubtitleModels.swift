import Foundation

struct APIv2StoredSubtitles: Decodable {
    let subtitles: [APIv2StoredSubtitle]
}

struct APIv2StoredSubtitle: Decodable {
    let id: String
    let mediaFileId: String
    let provider: String
    let language: String
    let format: String
    let releaseName: String
    let score: Double
    let hearingImpaired: Bool
    let createdAt: String

    /// Player handles remain integers; reject opaque/unrepresentable values
    /// rather than weakening the string-ID contract or rounding through Double.
    func playerValue(mediaFileID: Int) throws -> DownloadedSubtitle {
        guard let handle = Int(id), handle > 0, String(handle) == id,
              mediaFileId == String(mediaFileID) else { throw APIv2Error.invalidSubtitleResponse }
        return DownloadedSubtitle(id: handle, mediaFileId: mediaFileID, provider: provider,
            language: language, format: format, releaseName: releaseName, score: score,
            hearingImpaired: hearingImpaired, createdAt: createdAt)
    }
}

struct APIv2SubtitleSearchBody: Encodable {
    let mediaFileId: String
    let languages: [String]
    init(_ body: SubtitleSearchBody) {
        mediaFileId = String(body.mediaFileId)
        languages = body.languages
    }
}

struct APIv2SubtitleSearchResponse: Decodable {
    let results: [SubtitleSearchResult]
    let warnings: [String]

    var playerValue: SubtitleSearchResponse { SubtitleSearchResponse(results: results, warnings: warnings) }
}

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

struct APIv2SubtitleDownloadBody: Encodable {
    let mediaFileId: String
    let provider: String
    let subtitleId: String
    let language: String
    let releaseName: String
    let score: Double
    let hearingImpaired: Bool

    init(_ body: SubtitleDownloadBody) {
        mediaFileId = String(body.mediaFileId)
        provider = body.provider
        subtitleId = body.subtitleId
        language = body.language
        releaseName = body.releaseName
        score = body.score
        hearingImpaired = body.hearingImpaired
    }
}

struct APIv2SubtitleDownloadResponse: Decodable {
    let subtitle: APIv2StoredSubtitle
}


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
enum SubtitleCreationError: LocalizedError {
    case unresolved
    var errorDescription: String? {
        "The previous subtitle request may still be running. It cannot be submitted again without a confirmed result."
    }
}

extension SubtitleJob {
    /// Keep job identity opaque; only the existing player subtitle handles
    /// require checked integer projection.
    init(v2 job: APIv2SubtitleJob, expectedJobID: String) throws {
        guard job.id == expectedJobID,
              let knownKind = SubtitleAIKind(rawValue: job.kind),
              let fileID = Int(job.mediaFileId), fileID > 0,
              String(fileID) == job.mediaFileId else { throw APIv2Error.invalidSubtitleResponse }
        let resultID: Int?
        if let raw = job.resultSubtitleId {
            guard let value = Int(raw), value > 0, String(value) == raw else {
                throw APIv2Error.invalidSubtitleResponse
            }
            resultID = value
        } else {
            resultID = nil
        }
        id = job.id
        mediaFileId = fileID
        kind = knownKind
        sourceIndex = job.sourceIndex
        sourceLanguage = job.sourceLanguage
        targetLanguage = job.targetLanguage
        engine = job.engine
        model = job.model
        status = job.status
        progress = job.progress
        progressMessage = job.progressMessage
        resultSubtitleId = resultID
        errorMessage = job.errorMessage
        createdAt = job.createdAt
        updatedAt = job.updatedAt
    }
}
