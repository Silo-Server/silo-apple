import Foundation

// MARK: - Profile Models

/// Minimal user profile as returned by the server. Carries the
/// playback-pref fields the player resolver consults at session start
/// (subtitle language, behavior, forced-subs toggle).
struct UserProfile: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let avatarEmoji: String?
    /// Server-resolved avatar image URL (`avatar_url`). Absolute for uploads
    /// (short-lived presigned object-store URL) and DiceBear presets, or a
    /// server-relative path for locally hosted preset art. Preferred over the
    /// client-side resolution of ``avatarEmoji`` when present; optional so
    /// cached payloads written before this field existed still decode.
    let avatarImageUrl: String?
    let hasPin: Bool
    let isChild: Bool
    let isPrimary: Bool
    let subtitleLanguage: String?
    let subtitleMode: String?
    let showForcedSubtitles: Bool?
    /// Preferred metadata language (ISO 639-1; `""`/nil = inherit the
    /// library default). Drives server-side overview/tagline translation.
    let preferredMetadataLanguage: String?

    init(
        id: String,
        name: String,
        avatarEmoji: String?,
        avatarImageUrl: String? = nil,
        hasPin: Bool,
        isChild: Bool,
        isPrimary: Bool = false,
        subtitleLanguage: String? = nil,
        subtitleMode: String? = nil,
        showForcedSubtitles: Bool? = nil,
        preferredMetadataLanguage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarEmoji = avatarEmoji
        self.avatarImageUrl = avatarImageUrl
        self.hasPin = hasPin
        self.isChild = isChild
        self.isPrimary = isPrimary
        self.subtitleLanguage = subtitleLanguage
        self.subtitleMode = subtitleMode
        self.showForcedSubtitles = showForcedSubtitles
        self.preferredMetadataLanguage = preferredMetadataLanguage
    }
}

/// Request body for creating a new profile.
struct CreateProfileBody: Codable {
    let name: String
    let avatarEmoji: String?
    let pin: String?
    let isChild: Bool
}
