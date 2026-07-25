import Foundation

// MARK: - Profile Models

/// Minimal user profile as returned by the server. Carries the
/// playback-pref fields the player resolver consults at session start
/// (spoken language, subtitle language, behavior, forced-subs toggle).
struct UserProfile: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let avatarEmoji: String?
    let hasPin: Bool
    let isChild: Bool
    let isPrimary: Bool
    /// Preferred spoken/audio language (ISO 639-1; `""`/nil = no
    /// preference). The server resolves the initial audio track from
    /// this field and reports it as `effective_audio_track_index` on the
    /// watch/detail responses the player starts from.
    let language: String?
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
        hasPin: Bool,
        isChild: Bool,
        isPrimary: Bool = false,
        language: String? = nil,
        subtitleLanguage: String? = nil,
        subtitleMode: String? = nil,
        showForcedSubtitles: Bool? = nil,
        preferredMetadataLanguage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.avatarEmoji = avatarEmoji
        self.hasPin = hasPin
        self.isChild = isChild
        self.isPrimary = isPrimary
        self.language = language
        self.subtitleLanguage = subtitleLanguage
        self.subtitleMode = subtitleMode
        self.showForcedSubtitles = showForcedSubtitles
        self.preferredMetadataLanguage = preferredMetadataLanguage
    }
}

/// Request body for selecting a profile.
struct SelectProfileBody: Codable {
    let pin: String?
}

/// Request body for creating a new profile.
struct CreateProfileBody: Codable {
    let name: String
    let avatarEmoji: String?
    let pin: String?
    let isChild: Bool
}
