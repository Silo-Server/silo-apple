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
