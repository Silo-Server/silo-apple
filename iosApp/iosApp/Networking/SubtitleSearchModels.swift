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
import OSLog

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
    static let storedMessage =
        "The subtitle was saved but couldn't be turned on now. It will be available the next time you play this video."
    static let unconfirmedMessage =
        "Silo couldn't confirm the download. If it was saved, it will be available the next time you play this video."

    /// What the search menu shows; `nil` for `.added`, which closes it.
    var message: String? {
        switch self {
        case .added: return nil
        case .stored: return Self.storedMessage
        case .failed(let message): return message
        case .unconfirmed: return Self.unconfirmedMessage
        }
    }

    /// Whether the menu must not send this result again while it stays open:
    /// the server stored it, or may have.
    var holdsResult: Bool { self == .stored || self == .unconfirmed }

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

    /// What a download that threw means for the user.
    static func forDownloadError(_ error: Error) -> SubtitleDownloadOutcome {
        if isUnconfirmed(error) { return .unconfirmed }
        switch error {
        case APIv2Error.invalidSubtitleResponse:
            // A 200 whose stored row names another file: stored, not usable here.
            return .stored
        default:
            return .failed(failureMessage(for: error))
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Player"
    )

    /// Runs one provider download through to the live handoff. The steps are
    /// passed in so the outcome mapping is testable without a player.
    ///
    /// - Parameters:
    ///   - download: captures the owner and sends the download once.
    ///   - relist: lists the file's stored subtitles for that owner.
    ///   - isStillCurrent: whether the owner and media file still match the
    ///     player after the awaits.
    ///   - register: registers the stored row at `position` in the listing
    ///     (the whole listing places it in the plan's ordinals); returns
    ///     `false` when the player cannot take it.
    @MainActor
    static func resolve<Owner>(
        download: () async throws -> (Owner, DownloadedSubtitle),
        relist: (Owner) async throws -> [DownloadedSubtitle],
        isStillCurrent: (Owner) async -> Bool,
        register: (_ listing: [DownloadedSubtitle], _ position: Int) -> Bool
    ) async -> SubtitleDownloadOutcome {
        let owner: Owner
        let subtitle: DownloadedSubtitle
        do {
            (owner, subtitle) = try await download()
        } catch {
            let outcome = forDownloadError(error)
            logger.warning(
                "[SUB-SEARCH] download \(outcome == .unconfirmed ? "outcome unknown" : "failed", privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return outcome
        }

        // Stored on the server from here on. Anything that stops the live
        // handoff leaves it for the next session of this file.
        let listing: [DownloadedSubtitle]
        do {
            listing = try await relist(owner)
        } catch {
            logger.warning(
                "[SUB-SEARCH] listing after download of subtitle id=\(subtitle.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
            )
            return .stored
        }
        // If playback moved to another file or owner during the awaits, the
        // player's handoff context describes the new session; registering
        // this file's row against it would select a wrong track.
        guard await isStillCurrent(owner) else {
            logger.info(
                "[SUB-SEARCH] media file or owner changed during download of subtitle id=\(subtitle.id, privacy: .public); skipping live handoff"
            )
            return .stored
        }
        guard let position = listing.firstIndex(where: { $0.id == subtitle.id }) else {
            logger.warning(
                "[SUB-SEARCH] downloaded subtitle id=\(subtitle.id, privacy: .public) not in listing of \(listing.count, privacy: .public)"
            )
            return .stored
        }
        guard register(listing, position) else {
            logger.warning(
                "[SUB-SEARCH] no handoff context / unresolvable URL for subtitle id=\(subtitle.id, privacy: .public)"
            )
            return .stored
        }
        return .added
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
