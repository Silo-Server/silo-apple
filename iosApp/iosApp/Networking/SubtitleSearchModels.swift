//
//  SubtitleSearchModels.swift
//  Continuum (iOS + tvOS)
//
//  Wire types for silo-server's external subtitle-provider search
//  (OpenSubtitles / SubDL / Subsource). Both calls are synchronous —
//  no job, no polling, no websocket (contrast the AI flow in AIModels):
//    POST /api/v1/subtitles/search    → ranked results + provider warnings
//    POST /api/v1/subtitles/download  → the persisted ``DownloadedSubtitle``
//
//  Like AIModels, these ride ``HTTPClient/shared`` whose coders are
//  `.convertFromSnakeCase` / `.convertToSnakeCase`, so properties stay
//  camelCase with no `CodingKeys`.
//

import Foundation

/// Body for `POST /api/v1/subtitles/search`. The server derives
/// title/year/episode/hash from the media file itself; the client only
/// scopes by language.
struct SubtitleSearchBody: Encodable {
    let mediaFileId: Int
    let languages: [String]
}

/// One ranked hit from a provider search. `id` is provider-scoped and,
/// together with `provider`, is the load-bearing pair echoed back on
/// download. Decoders are tolerant: only `id` is required.
struct SubtitleSearchResult: Codable, Identifiable, Equatable {
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
}

/// `POST /api/v1/subtitles/search` response. `warnings` carries per-provider
/// soft failures ("opensubtitles: …") — partial success, not fatal; results
/// from the other providers may still be present.
struct SubtitleSearchResponse: Codable {
    let results: [SubtitleSearchResult]
    let warnings: [String]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decodeIfPresent([SubtitleSearchResult].self, forKey: .results) ?? []
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }

    init(results: [SubtitleSearchResult], warnings: [String] = []) {
        self.results = results
        self.warnings = warnings
    }
}

/// Body for `POST /api/v1/subtitles/download` — echoes the chosen result
/// (the server re-fetches the bytes from `provider` by `subtitleId` and
/// persists them; the rest is stored metadata).
struct SubtitleDownloadBody: Encodable {
    let mediaFileId: Int
    let provider: String
    let subtitleId: String
    let language: String
    let releaseName: String
    let format: String
    let score: Double
    let hearingImpaired: Bool

    init(from result: SubtitleSearchResult, mediaFileId: Int) {
        self.mediaFileId = mediaFileId
        self.provider = result.provider
        self.subtitleId = result.id
        self.language = result.language
        self.releaseName = result.releaseName
        self.format = result.format
        self.score = result.score
        self.hearingImpaired = result.hearingImpaired
    }
}

/// Envelope for the download endpoint: `{"subtitle": DownloadedSubtitle}`.
/// The subtitle is persisted before the response returns; it carries the DB
/// `id` but no combined index / stream URL (see ``DownloadedSubtitle``).
struct SubtitleDownloadResponse: Codable {
    let subtitle: DownloadedSubtitle
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
