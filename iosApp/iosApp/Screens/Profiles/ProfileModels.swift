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

// MARK: - Profile PIN

/// The profile PIN every Silo client can enter: exactly `length` ASCII
/// digits. Android and the web editor enforce the same rule; the server
/// accepts 1-72 bytes, so the clients hold the line.
enum ProfilePIN {
    static let length = 4

    /// Keeps ASCII digits 0-9 only, then the first `length` of them.
    static func sanitized(_ input: String) -> String {
        String(input.filter(isASCIIDigit).prefix(length))
    }

    /// A PIN the form may submit: empty (no PIN) or exactly `length` ASCII digits.
    static func isAcceptableForCreate(_ pin: String) -> Bool {
        pin.isEmpty || (pin.count == length && pin.allSatisfy(isASCIIDigit))
    }

    /// `Character.isNumber` alone admits numerals the keypad can't type
    /// ("٣", "½"). A `"0"..."9"` range check would admit a digit carrying a
    /// combining mark, because `Character` compares whole grapheme clusters;
    /// `isASCII` is false for such a cluster.
    private static func isASCIIDigit(_ c: Character) -> Bool {
        c.isASCII && c.isNumber
    }
}
