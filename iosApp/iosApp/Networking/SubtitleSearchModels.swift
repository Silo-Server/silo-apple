//
//  SubtitleSearchModels.swift
//  Silo (iOS + tvOS)
//
//  Player-side values for silo-server's external subtitle-provider search
//  (OpenSubtitles / SubDL / Subsource). Both calls are synchronous —
//  no job, no polling, no websocket (contrast the AI flow in AIModels):
//    POST /api/v2/subtitles/search    → ranked results + provider warnings
//    POST /api/v2/subtitles/download  → the persisted ``DownloadedSubtitle``
//
//  The wire shapes, which send `media_file_id` as a string, live in
//  `APIv2/APIv2SubtitleModels.swift`.
//

import Foundation

/// A provider search for one media file. The server derives
/// title/year/episode/hash from the media file itself; the client only
/// scopes by language.
struct SubtitleSearchBody: Encodable {
    let mediaFileId: Int
    let languages: [String]
}

/// One ranked hit from a provider search. `id` is provider-scoped and,
/// together with `provider`, is the load-bearing pair echoed back on
/// download. Decoders are tolerant: only `id` is required.
///
/// Deliberately NOT `Identifiable`: `id` alone can collide across providers,
/// so UI identity (ForEach, focus, download tracking) keys on ``uniqueKey``.
struct SubtitleSearchResult: Codable, Equatable {
    let id: String
    let provider: String
    let language: String
    let releaseName: String
    let format: String
    /// Server-computed relevance, 0–100; results arrive sorted descending.
    let score: Double
    let downloads: Int
    let hearingImpaired: Bool
    let uploadDate: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        releaseName = try c.decodeIfPresent(String.self, forKey: .releaseName) ?? ""
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? ""
        score = try c.decodeIfPresent(Double.self, forKey: .score) ?? 0
        downloads = try c.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        hearingImpaired = try c.decodeIfPresent(Bool.self, forKey: .hearingImpaired) ?? false
        uploadDate = try c.decodeIfPresent(String.self, forKey: .uploadDate)
    }

    /// Memberwise init for tests / previews.
    init(
        id: String,
        provider: String = "",
        language: String = "",
        releaseName: String = "",
        format: String = "",
        score: Double = 0,
        downloads: Int = 0,
        hearingImpaired: Bool = false,
        uploadDate: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.language = language
        self.releaseName = releaseName
        self.format = format
        self.score = score
        self.downloads = downloads
        self.hearingImpaired = hearingImpaired
        self.uploadDate = uploadDate
    }

    /// Composite row identity — the `(provider, id)` pair the download API
    /// also requires. Mirrors Android's `"{provider}:{id}"` download key.
    var uniqueKey: String { "\(provider):\(id)" }
}

/// A provider search result set. `warnings` carries per-provider soft
/// failures — partial success, not fatal; results from the other providers
/// may still be present.
struct SubtitleSearchResponse {
    let results: [SubtitleSearchResult]
    let warnings: [String]

    init(results: [SubtitleSearchResult], warnings: [String] = []) {
        self.results = results
        self.warnings = warnings
    }
}

/// A provider download — echoes the chosen result (the server re-fetches the
/// bytes from `provider` by `subtitleId` and persists them; the rest is
/// stored metadata).
struct SubtitleDownloadBody {
    let mediaFileId: Int
    let provider: String
    let subtitleId: String
    let language: String
    let releaseName: String
    let score: Double
    let hearingImpaired: Bool

    init(from result: SubtitleSearchResult, mediaFileId: Int) {
        self.mediaFileId = mediaFileId
        self.provider = result.provider
        self.subtitleId = result.id
        self.language = result.language
        self.releaseName = result.releaseName
        self.score = result.score
        self.hearingImpaired = result.hearingImpaired
    }
}

/// What a provider download did, as the search menu must tell it apart.
/// The download is `non_retryable`, so only a definite failure invites
/// another try of the same result.
enum SubtitleDownloadOutcome: Equatable {
    /// Stored, registered on the live player and selected.
    case added
    /// Stored on the server, but not added to this playback. It is available
    /// the next time the file plays.
    case stored
    /// Definitely not stored; the message is shown as is.
    case failed(String)
    /// The download may have been stored; no usable answer came back.
    case unconfirmed

    static let genericFailure = "Couldn't add that subtitle. Try another result."

    static func isUnconfirmed(_ error: Error) -> Bool {
        (error as? APIv2SubtitleRequestError) == .outcomeUnknownOwnerChanged
            || APIv2DispatchFailure.isUncertain(error)
    }

    /// The server's own words for a refusal, when it sent any.
    static func failureMessage(for error: Error) -> String {
        switch error {
        case APIv2Error.problem, APIv2Error.serverUpdateRequired:
            return error.localizedDescription
        default:
            return genericFailure
        }
    }
}

/// Quality bucket for a search result's 0–100 score. Thresholds mirror the
/// web player and Android: ≥70 good, ≥40 fair, else poor.
enum SubtitleSearchScoreTier {
    case good
    case fair
    case poor

    init(score: Double) {
        if score >= 70 { self = .good }
        else if score >= 40 { self = .fair }
        else { self = .poor }
    }
}
