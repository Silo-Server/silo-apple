import Foundation

// MARK: - Profiles

/// The profile fields the onboarding tour can change. All fields are
/// optional so the caller can patch one or many at a time;
/// `asAPIv2Patch` turns it into the `PATCH /api/v2/profiles/{id}` body.
struct UpdateProfileBody {
    /// Streaming quality ceiling preset ("auto", "1080p", "4k"). Written by
    /// the onboarding tour's quality step.
    var qualityPreference: String?
    var subtitleLanguage: String?
    var subtitleMode: String?
    var showForcedSubtitles: Bool?
    /// Preferred metadata language (ISO 639-1; `""` = inherit the library
    /// default, sent as a clearing `null`).
    var preferredMetadataLanguage: String?
    var autoSkipIntro: Bool?
    var autoSkipCredits: Bool?
    var autoSkipRecap: Bool?
}

struct VerifyPinRequest: Codable {
    let pin: String
}

struct VerifyPinResponse: Codable {
    let valid: Bool
    let profileToken: String?
    let expiresAt: String?
}

/// The new-profile form's values. `APIv2Client.createHouseholdProfile`
/// turns it into the `POST /api/v2/profiles` body (`APIv2ProfileCreate`),
/// sending the library IDs as strings.
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
