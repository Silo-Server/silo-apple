import Foundation

// MARK: getSubtitleProviderStatus

/// `GET /api/v2/subtitles/providers/status`. Search is usable only when the
/// viewer is `allowed`, the state is `available`, and a provider is enabled.
struct APIv2SubtitleProviderStatus: Decodable {
    let schemaVersion: Int
    let enabled: Bool
    let providers: [String]
    let revision: String
    let state: String
    let allowed: Bool

    var isAvailable: Bool { allowed && state == "available" && enabled }
}

/// Requests refused on this device, and the one unknown outcome of a
/// provider download.
enum APIv2SubtitleRequestError: LocalizedError, Equatable {
    case invalidMediaFile
    case tooManyLanguages
    /// The owner changed once the download may have been sent. The server
    /// may have stored the subtitle; the response was discarded.
    case outcomeUnknownOwnerChanged

    var errorDescription: String? {
        switch self {
        case .invalidMediaFile: return "Subtitle search needs a media file."
        case .tooManyLanguages: return "Search at most 100 subtitle languages at a time."
        case .outcomeUnknownOwnerChanged: return "The account changed before the subtitle download finished."
        }
    }
}

// MARK: listStoredSubtitles

struct APIv2StoredSubtitles: Decodable {
    let subtitles: [APIv2StoredSubtitle]

    /// The listed rows, in server order. The server omits rows whose language
    /// it cannot canonicalize, so a position here is not a combined subtitle
    /// ordinal (see ``DownloadedSubtitleOrdinals``); the synthesized stream
    /// URL pins each row by `id`. A row that names another file makes the
    /// listing unusable.
    func playerValues(mediaFileID: Int) throws -> [DownloadedSubtitle] {
        try subtitles.map { try $0.playerValue(mediaFileID: mediaFileID) }
    }
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

    /// The ID stays opaque; only the file must be the one asked for.
    func playerValue(mediaFileID: Int) throws -> DownloadedSubtitle {
        guard !id.isEmpty, mediaFileId == String(mediaFileID) else { throw APIv2Error.invalidSubtitleResponse }
        return DownloadedSubtitle(id: id, mediaFileId: mediaFileID, provider: provider,
            language: language, format: format, releaseName: releaseName, score: score,
            hearingImpaired: hearingImpaired, createdAt: createdAt)
    }
}

// MARK: searchSubtitles

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

// MARK: downloadSubtitle

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
