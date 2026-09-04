import Foundation

// MARK: - API v2 wire models
//
// Handwritten, lenient models for the `/api/v2` pilot operations. They are
// decoded with the production `HTTPClient.makeJSONDecoder()` (snake_case key
// conversion plus the RFC 3339 date strategy, which accepts the UTC
// millisecond instants v2 emits) and never share a type with the v1 models:
// v2 is a separate contract, so a v1 struct must not quietly become the shape
// a v2 response is read through.
//
// Forward compatibility: unknown object members are ignored by `Codable`, and
// every string enum keeps an `unknown(String)` case so a value added by a
// newer server decodes instead of failing the whole response.

/// A closed string enum on the wire that stays open on the client.
protocol APIv2StringEnum: Codable, Hashable, Sendable {
    static var known: [String: Self] { get }
    static func unknown(_ wireValue: String) -> Self
    var wireValue: String { get }
}

extension APIv2StringEnum {
    init(wireValue: String) {
        self = Self.known[wireValue] ?? Self.unknown(wireValue)
    }

    init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

// MARK: System

/// `GET /api/v2/system/info` — the contract identity the probe requires.
struct APIv2SystemInfo: Decodable, Hashable, Sendable {
    let serverVersion: String
    let apiMajor: Int
    let contractDigest: String
    let links: APIv2SystemInfoLinks
}

struct APIv2SystemInfoLinks: Decodable, Hashable, Sendable {
    let openapi: String
    let capabilities: String
}

/// `GET /api/v2/system/setup`.
struct APIv2SetupStatus: Decodable, Hashable, Sendable {
    let needsSetup: Bool
}

// MARK: Account

enum APIv2AccountRole: APIv2StringEnum {
    case admin
    case user
    case unknown(String)

    static let known: [String: Self] = ["admin": .admin, "user": .user]

    var wireValue: String {
        switch self {
        case .admin: return "admin"
        case .user: return "user"
        case .unknown(let value): return value
        }
    }
}

/// `GET /api/v2/account/me`.
struct APIv2Account: Decodable, Hashable, Sendable {
    let id: String
    let username: String
    let email: String
    let role: APIv2AccountRole
    let permissions: [String]
    let downloadAllowed: Bool
    /// Present only while an administrator impersonates this account.
    let impersonation: APIv2Impersonation?
}

struct APIv2Impersonation: Decodable, Hashable, Sendable {
    let active: Bool
    let impersonatorUserId: String
    let impersonatorUsername: String
}

// MARK: Progress

enum APIv2ProgressStatus: APIv2StringEnum {
    case inProgress
    case completed
    case unknown(String)

    static let known: [String: Self] = ["in_progress": .inProgress, "completed": .completed]

    var wireValue: String {
        switch self {
        case .inProgress: return "in_progress"
        case .completed: return "completed"
        case .unknown(let value): return value
        }
    }
}

/// `GET /api/v2/progress` — one page of the profile's watch progress.
struct APIv2ProgressPage: Decodable, Hashable, Sendable {
    let items: [APIv2ProgressEntry]
    let page: APIv2Page
}

struct APIv2ProgressEntry: Decodable, Hashable, Sendable {
    let mediaItemId: String
    let positionSeconds: Double
    let durationSeconds: Double
    let completed: Bool
    let updatedAt: Date
}

/// Cursor pagination envelope. `nextCursor` is opaque and only present while
/// `hasMore` is true.
struct APIv2Page: Decodable, Hashable, Sendable {
    let nextCursor: String?
    let hasMore: Bool
}

// MARK: Profiles

enum APIv2AvatarSource: APIv2StringEnum {
    case none
    case preset
    case upload
    case unknown(String)

    static let known: [String: Self] = ["none": .none, "preset": .preset, "upload": .upload]

    var wireValue: String {
        switch self {
        case .none: return "none"
        case .preset: return "preset"
        case .upload: return "upload"
        case .unknown(let value): return value
        }
    }
}

enum APIv2QualityPreference: APIv2StringEnum {
    case auto
    case original
    case unknown(String)

    static let known: [String: Self] = ["auto": .auto, "original": .original]

    var wireValue: String {
        switch self {
        case .auto: return "auto"
        case .original: return "original"
        case .unknown(let value): return value
        }
    }
}

enum APIv2SubtitleMode: APIv2StringEnum {
    case auto
    case always
    case off
    case unknown(String)

    static let known: [String: Self] = ["auto": .auto, "always": .always, "off": .off]

    var wireValue: String {
        switch self {
        case .auto: return "auto"
        case .always: return "always"
        case .off: return "off"
        case .unknown(let value): return value
        }
    }
}

enum APIv2PlaybackQuality: APIv2StringEnum {
    case p1080
    case p2160
    case unknown(String)

    static let known: [String: Self] = ["1080p": .p1080, "2160p": .p2160]

    var wireValue: String {
        switch self {
        case .p1080: return "1080p"
        case .p2160: return "2160p"
        case .unknown(let value): return value
        }
    }
}

/// `PATCH /api/v2/profiles/{id}` response (the full profile).
///
/// Every string member is always emitted; the empty string means "unset".
/// `avatarUrl` is the one member the server omits when there is nothing to
/// fetch.
struct APIv2Profile: Decodable, Hashable, Sendable {
    let id: String
    let name: String
    let avatar: String
    let avatarUrl: String?
    let avatarSource: APIv2AvatarSource
    let hasPin: Bool
    let isChild: Bool
    let isPrimary: Bool
    let maxContentRating: String
    let qualityPreference: String
    let language: String
    let preferredMetadataLanguage: String
    let subtitleLanguage: String
    let subtitleMode: String
    let autoSkipIntro: Bool
    let autoSkipCredits: Bool
    let autoSkipRecap: Bool
    let autoPlayNextPreview: Bool
    let showForcedSubtitles: Bool
    let libraryRestrictionsEnabled: Bool
    let allowedLibraryIds: [String]
    let maxPlaybackQuality: String
    let createdAt: Date
    let updatedAt: Date
}

/// A PATCH member that distinguishes "leave unchanged" (omitted) from
/// "clear" (JSON `null`) from "set" (a value).
enum APIv2Patch<Value: Encodable & Sendable>: Sendable {
    case unchanged
    case clear
    case set(Value)
}

/// `PATCH /api/v2/profiles/{id}` request body. Omitted members are unchanged.
/// Only the `APIv2Patch` members accept `null` (which clears them); the server
/// answers 422 `invalid_type` for `null` on any other member, so those are
/// plain optionals that cannot encode `null` at all.
struct APIv2ProfilePatch: Encodable, Sendable {
    var name: String?
    var avatar: APIv2Patch<String> = .unchanged
    var pin: APIv2Patch<String> = .unchanged
    var isChild: Bool?
    var maxContentRating: APIv2Patch<String> = .unchanged
    var qualityPreference: APIv2QualityPreference?
    var language: APIv2Patch<String> = .unchanged
    var preferredMetadataLanguage: APIv2Patch<String> = .unchanged
    var subtitleLanguage: APIv2Patch<String> = .unchanged
    var subtitleMode: APIv2SubtitleMode?
    var autoSkipIntro: Bool?
    var autoSkipCredits: Bool?
    var autoSkipRecap: Bool?
    var autoPlayNextPreview: Bool?
    var showForcedSubtitles: Bool?
    var libraryRestrictionsEnabled: Bool?
    var allowedLibraryIds: [String]?
    var maxPlaybackQuality: APIv2Patch<APIv2PlaybackQuality> = .unchanged

    init() {}

    // Wire keys are spelled out so the body is correct under any key strategy:
    // `.convertToSnakeCase` leaves an already-snake_case key untouched.
    private enum CodingKeys: String, CodingKey {
        case name
        case avatar
        case pin
        case isChild = "is_child"
        case maxContentRating = "max_content_rating"
        case qualityPreference = "quality_preference"
        case language
        case preferredMetadataLanguage = "preferred_metadata_language"
        case subtitleLanguage = "subtitle_language"
        case subtitleMode = "subtitle_mode"
        case autoSkipIntro = "auto_skip_intro"
        case autoSkipCredits = "auto_skip_credits"
        case autoSkipRecap = "auto_skip_recap"
        case autoPlayNextPreview = "auto_play_next_preview"
        case showForcedSubtitles = "show_forced_subtitles"
        case libraryRestrictionsEnabled = "library_restrictions_enabled"
        case allowedLibraryIds = "allowed_library_ids"
        case maxPlaybackQuality = "max_playback_quality"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try Self.encode(avatar, forKey: .avatar, into: &container)
        try Self.encode(pin, forKey: .pin, into: &container)
        try container.encodeIfPresent(isChild, forKey: .isChild)
        try Self.encode(maxContentRating, forKey: .maxContentRating, into: &container)
        try container.encodeIfPresent(qualityPreference, forKey: .qualityPreference)
        try Self.encode(language, forKey: .language, into: &container)
        try Self.encode(preferredMetadataLanguage, forKey: .preferredMetadataLanguage, into: &container)
        try Self.encode(subtitleLanguage, forKey: .subtitleLanguage, into: &container)
        try container.encodeIfPresent(subtitleMode, forKey: .subtitleMode)
        try container.encodeIfPresent(autoSkipIntro, forKey: .autoSkipIntro)
        try container.encodeIfPresent(autoSkipCredits, forKey: .autoSkipCredits)
        try container.encodeIfPresent(autoSkipRecap, forKey: .autoSkipRecap)
        try container.encodeIfPresent(autoPlayNextPreview, forKey: .autoPlayNextPreview)
        try container.encodeIfPresent(showForcedSubtitles, forKey: .showForcedSubtitles)
        try container.encodeIfPresent(libraryRestrictionsEnabled, forKey: .libraryRestrictionsEnabled)
        try container.encodeIfPresent(allowedLibraryIds, forKey: .allowedLibraryIds)
        try Self.encode(maxPlaybackQuality, forKey: .maxPlaybackQuality, into: &container)
    }

    private static func encode<Value: Encodable>(
        _ patch: APIv2Patch<Value>,
        forKey key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch patch {
        case .unchanged:
            break
        case .clear:
            try container.encodeNil(forKey: key)
        case .set(let value):
            try container.encode(value, forKey: key)
        }
    }
}

// MARK: Problem

/// RFC 9457 problem details, `application/problem+json`, for every v2 error.
struct APIv2Problem: Decodable, Hashable, Sendable {
    let type: String
    let title: String
    let status: Int
    let detail: String
    let instance: String?
    let errors: [APIv2ProblemError]?

    /// The stable problem identifier: the final segment of `type`
    /// (`.../problems/validation_failed` → `validation_failed`).
    var identifier: String {
        type.split(separator: "/").last.map(String.init) ?? type
    }
}

struct APIv2ProblemError: Decodable, Hashable, Sendable {
    let location: String
    let code: String
    let detail: String
}
