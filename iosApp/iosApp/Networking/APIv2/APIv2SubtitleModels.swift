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
