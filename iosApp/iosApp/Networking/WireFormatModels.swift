import Foundation

// MARK: - Profiles (server wire format)

/// Full profile payload as returned by the server.
///
/// Distinct from ``UserProfile`` (the reduced shape used by the UI): this
/// type maps every field the server sends. `SiloAPI.listProfiles()`
/// converts to `[UserProfile]` at the API boundary so call sites keep
/// their existing types.
struct Profile: Codable {
    let id: String
    let name: String
    let avatar: String?
    /// Server-resolved avatar URL (`avatar_url`). For uploads this is a
    /// short-lived presigned object-store URL that changes on every fetch, so
    /// it must not be persisted long-term. For presets it is a DiceBear URL or
    /// a server-relative `/profile-avatars/{id}.svg` path.
    @ArtworkURL var avatarUrl: String?
    /// `avatar_source`: "upload", "preset", or "none".
    let avatarSource: String?
    let hasPin: Bool?
    let isChild: Bool?
    let isPrimary: Bool?
    let maxContentRating: String?
    let qualityPreference: String?
    let language: String?
    let subtitleLanguage: String?
    let subtitleMode: String?
    let showForcedSubtitles: Bool?
    /// Preferred metadata language (ISO 639-1). `""`/nil = inherit the
    /// library default. Drives server-side translation of overviews and
    /// taglines in the normal detail/browse responses.
    let preferredMetadataLanguage: String?
    let autoSkipIntro: Bool?
    let autoSkipCredits: Bool?
    let autoSkipRecap: Bool?
    let libraryRestrictionsEnabled: Bool?
    let allowedLibraryIds: [Int]?
    let maxPlaybackQuality: String?
    let createdAt: String?
    let updatedAt: String?

    /// Convert to the reduced ``UserProfile`` shape used by the UI.
    var asUserProfile: UserProfile {
        UserProfile(
            id: id,
            name: name,
            avatarEmoji: avatar,
            avatarImageUrl: avatarUrl,
            hasPin: hasPin ?? false,
            isChild: isChild ?? false,
            isPrimary: isPrimary ?? false,
            subtitleLanguage: subtitleLanguage,
            subtitleMode: subtitleMode,
            showForcedSubtitles: showForcedSubtitles,
            preferredMetadataLanguage: preferredMetadataLanguage
        )
    }
}

/// PUT body for `/api/v1/profiles/{id}`. All fields are optional so the
/// caller can patch one or many at a time. Wire format mirrors the
/// server's `updateProfileRequest`.
struct UpdateProfileBody: Encodable {
    /// Streaming quality ceiling preset ("auto", "1080p", "4k"). Encodes as
    /// `quality_preference`. Written by the onboarding tour's quality step.
    var qualityPreference: String?
    var subtitleLanguage: String?
    var subtitleMode: String?
    var showForcedSubtitles: Bool?
    /// Preferred metadata language (ISO 639-1; `""` = inherit the library
    /// default). Encodes as `preferred_metadata_language`.
    var preferredMetadataLanguage: String?
    var autoSkipIntro: Bool?
    var autoSkipCredits: Bool?
    var autoSkipRecap: Bool?
}

struct ProfilesResponse: Codable {
    let profiles: [Profile]
}

struct VerifyPinRequest: Codable {
    let pin: String
}

struct VerifyPinResponse: Codable {
    let valid: Bool
    let profileToken: String?
    let expiresAt: String?
}

/// Wire-format body for POST /api/v1/profiles.
///
/// Mirrors Kotlin `CreateProfileRequest`; `SiloAPI.createProfile` builds this wire body.
struct CreateProfileRequestBody: Codable {
    let name: String
    let avatar: String?
    let pin: String?
    let isChild: Bool?
    let maxContentRating: String?
    let libraryRestrictionsEnabled: Bool
    let allowedLibraryIds: [Int]
}

// MARK: - Library collections

/// One ordered section of a library's Collections tab: either a named group
/// or the anonymous "Ungrouped" bucket. UI-side type, mapped from the v2
/// `APIv2LibraryCollectionTab`.
struct LibraryCollectionSection: Identifiable, Hashable {
    /// Stable identifier — the group id for named sections, or
    /// `"__ungrouped__"` for the anonymous bucket.
    let id: String
    /// Display name. Empty for the anonymous Ungrouped bucket.
    let name: String
    /// Defaults to [LibraryCollectionKind.regular] for the flat-fallback
    /// and Ungrouped sections.
    let kind: LibraryCollectionKind
    let collections: [LibraryCollection]
}
