//
//  PlaybackPrefsModels.swift
//  Continuum (iOS + tvOS)
//
//  Wire types for the user's playback preferences. The server stores
//  these at three precedence levels: per-series (highest), per-library,
//  and profile default (lowest). The cascade is resolved server-side
//  and surfaced via the `effective_*` fields on `WatchDetail`, so the
//  client only re-reads the raw prefs when the user is editing them in
//  Settings or saving a per-series override from the player.
//
//  Endpoints in play:
//    GET    /api/v1/library-playback-prefs           — list all
//    PUT    /api/v1/library-playback-prefs/{id}      — set one
//    DELETE /api/v1/library-playback-prefs/{id}      — clear one
//    GET    /api/v1/subtitle-prefs/{series_id}       — per-series sub
//    PUT    /api/v1/subtitle-prefs/{series_id}       — set per-series
//    DELETE /api/v1/subtitle-prefs/{series_id}       — clear per-series
//    GET    /api/v1/audio-prefs/{series_id}          — per-series audio
//    PUT    /api/v1/audio-prefs/{series_id}          — set per-series
//    DELETE /api/v1/audio-prefs/{series_id}          — clear per-series
//

import Foundation

// MARK: - Track signatures

/// Identifier used to re-locate the same subtitle track across episodes
/// in a series when the FFmpeg stream index shifts. Server tries an
/// exact signature match first, falls back to language match.
struct SubtitleTrackSignature: Codable, Hashable {
    let source: String?           // "embedded", "external", "downloaded"
    let language: String?         // ISO 639-1 / -2
    let codec: String?            // "subrip", "ass", "pgs", …
    let label: String?
    let forced: Bool
    let hearingImpaired: Bool

    init(
        source: String? = nil,
        language: String? = nil,
        codec: String? = nil,
        label: String? = nil,
        forced: Bool = false,
        hearingImpaired: Bool = false
    ) {
        self.source = source
        self.language = language
        self.codec = codec
        self.label = label
        self.forced = forced
        self.hearingImpaired = hearingImpaired
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        codec = try c.decodeIfPresent(String.self, forKey: .codec)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        forced = try c.decodeIfPresent(Bool.self, forKey: .forced) ?? false
        hearingImpaired = try c.decodeIfPresent(Bool.self, forKey: .hearingImpaired) ?? false
    }
}

/// Audio counterpart to `SubtitleTrackSignature`. Layout + channels let
/// the server prefer "5.1 English Atmos" over "stereo English commentary"
/// across episodes.
struct AudioTrackSignature: Codable, Hashable {
    let language: String?
    let title: String?
    let embeddedTitle: String?
    let codec: String?
    let layout: String?
    let channels: Int?
    let isDefault: Bool

    init(
        language: String? = nil,
        title: String? = nil,
        embeddedTitle: String? = nil,
        codec: String? = nil,
        layout: String? = nil,
        channels: Int? = nil,
        isDefault: Bool = false
    ) {
        self.language = language
        self.title = title
        self.embeddedTitle = embeddedTitle
        self.codec = codec
        self.layout = layout
        self.channels = channels
        self.isDefault = isDefault
    }

    enum CodingKeys: String, CodingKey {
        case language, title
        case embeddedTitle = "embedded_title"
        case codec, layout, channels
        case isDefault = "default"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        embeddedTitle = try c.decodeIfPresent(String.self, forKey: .embeddedTitle)
        codec = try c.decodeIfPresent(String.self, forKey: .codec)
        layout = try c.decodeIfPresent(String.self, forKey: .layout)
        channels = try c.decodeIfPresent(Int.self, forKey: .channels)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(language, forKey: .language)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(embeddedTitle, forKey: .embeddedTitle)
        try c.encodeIfPresent(codec, forKey: .codec)
        try c.encodeIfPresent(layout, forKey: .layout)
        try c.encodeIfPresent(channels, forKey: .channels)
        try c.encode(isDefault, forKey: .isDefault)
    }
}

// MARK: - Settings UI constants

/// Sentinel used by the library-prefs editor to mean "no override —
/// fall through to the profile / global default". Mirrors the web
/// frontend's `INHERIT_VALUE` so the same vocabulary works everywhere.
enum PlaybackPrefSentinel {
    static let inherit = "__inherit__"
    static let none = "__none__"
    static let originalLanguage = "original"
}

/// The same twelve languages the web settings expose. ISO 639-1 codes
/// matched on the wire; labels are display-only.
struct PlaybackLanguageOption: Identifiable, Hashable {
    let code: String
    let label: String
    var id: String { code }

    static let all: [PlaybackLanguageOption] = [
        .init(code: "en", label: "English"),
        .init(code: "es", label: "Spanish"),
        .init(code: "fr", label: "French"),
        .init(code: "de", label: "German"),
        .init(code: "it", label: "Italian"),
        .init(code: "pt", label: "Portuguese"),
        .init(code: "ja", label: "Japanese"),
        .init(code: "ko", label: "Korean"),
        .init(code: "zh", label: "Chinese"),
        .init(code: "ru", label: "Russian"),
        .init(code: "ar", label: "Arabic"),
        .init(code: "hi", label: "Hindi"),
    ]

    static func label(forCode code: String) -> String {
        if code == PlaybackPrefSentinel.originalLanguage { return "Original Language" }
        if let known = all.first(where: { $0.code == code })?.label { return known }
        // A code from outside the twelve still deserves a name rather than a
        // bare "NL".
        return Locale.current.localizedString(forLanguageCode: code)?.capitalized
            ?? code.uppercased()
    }

    /// The options a picker should show while it holds `code`.
    ///
    /// Audio and subtitle language are server-owned profile fields, and the web
    /// client offers far more languages than the twelve above — as does the
    /// `original` sentinel, which the server honours at profile scope. A stored
    /// value outside this list is therefore normal, not corrupt. Without it in
    /// the list the picker renders an empty selection on iOS and a literal "—"
    /// on tvOS, and the first tap silently replaces a language this client
    /// cannot name.
    static func options(including code: String) -> [PlaybackLanguageOption] {
        guard !code.isEmpty,
              code != PlaybackPrefSentinel.none,
              code != PlaybackPrefSentinel.inherit,
              !all.contains(where: { $0.code == code })
        else { return all }
        return [PlaybackLanguageOption(code: code, label: label(forCode: code))] + all
    }
}

// MARK: - Subtitle mode enum

/// Server-side `subtitle_mode` enum. Empty / nil means "inherit from
/// the next level up" (per-series → library → profile default).
enum SubtitleMode: String, CaseIterable, Codable, Hashable {
    case auto    = "auto"
    case always  = "always"
    case off     = "off"

    var displayLabel: String {
        switch self {
        case .auto:   return "Auto"
        case .always: return "Always"
        case .off:    return "Off"
        }
    }

    var displayDescription: String {
        switch self {
        case .auto:   return "Show subtitles only when audio language doesn't match your spoken language."
        case .always: return "Always show subtitles when available."
        case .off:    return "Never show subtitles."
        }
    }
}

// MARK: - Library playback prefs

struct LibraryPlaybackPref: Codable, Hashable, Identifiable {
    let profileId: String
    let libraryId: Int
    let audioLanguage: String?
    let subtitleLanguage: String?
    let subtitleMode: String?
    let showForcedSubtitles: Bool?
    let updatedAt: String?

    var id: Int { libraryId }

    var subtitleModeEnum: SubtitleMode? {
        guard let raw = subtitleMode, !raw.isEmpty else { return nil }
        return SubtitleMode(rawValue: raw)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId) ?? ""
        libraryId = try c.decode(Int.self, forKey: .libraryId)
        audioLanguage = try c.decodeIfPresent(String.self, forKey: .audioLanguage)
        subtitleLanguage = try c.decodeIfPresent(String.self, forKey: .subtitleLanguage)
        subtitleMode = try c.decodeIfPresent(String.self, forKey: .subtitleMode)
        showForcedSubtitles = try c.decodeIfPresent(Bool.self, forKey: .showForcedSubtitles)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

struct LibraryPlaybackPrefsResponse: Codable {
    let preferences: [LibraryPlaybackPref]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preferences = try c.decodeIfPresent([LibraryPlaybackPref].self, forKey: .preferences) ?? []
    }
}

/// PUT body for `/library-playback-prefs/{id}`. All fields are
/// optional; sending `null` removes the field without deleting the
/// row. Sending all four fields as nil is equivalent to DELETE.
struct LibraryPlaybackPrefRequest: Codable {
    let audioLanguage: String?
    let subtitleLanguage: String?
    let subtitleMode: String?
    let showForcedSubtitles: Bool?
}

// MARK: - Per-series subtitle pref

struct SubtitlePref: Codable, Hashable {
    let profileId: String
    let seriesId: String
    let subtitleLanguage: String
    let subtitleTrackIndex: Int
    let externalSubtitlePath: String
    let subtitleMode: String
    let trackSignature: SubtitleTrackSignature?
    let showForcedSubtitles: Bool?
    let updatedAt: String?

    var subtitleModeEnum: SubtitleMode? {
        guard !subtitleMode.isEmpty else { return nil }
        return SubtitleMode(rawValue: subtitleMode)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId) ?? ""
        seriesId = try c.decodeIfPresent(String.self, forKey: .seriesId) ?? ""
        subtitleLanguage = try c.decodeIfPresent(String.self, forKey: .subtitleLanguage) ?? ""
        subtitleTrackIndex = try c.decodeIfPresent(Int.self, forKey: .subtitleTrackIndex) ?? -1
        externalSubtitlePath = try c.decodeIfPresent(String.self, forKey: .externalSubtitlePath) ?? ""
        subtitleMode = try c.decodeIfPresent(String.self, forKey: .subtitleMode) ?? ""
        trackSignature = try c.decodeIfPresent(SubtitleTrackSignature.self, forKey: .trackSignature)
        showForcedSubtitles = try c.decodeIfPresent(Bool.self, forKey: .showForcedSubtitles)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

struct SubtitlePrefRequest: Codable {
    let subtitleLanguage: String
    let subtitleTrackIndex: Int
    let externalSubtitlePath: String
    let subtitleMode: String
    let trackSignature: SubtitleTrackSignature?
    let showForcedSubtitles: Bool?
}

// MARK: - Per-series audio pref

struct AudioPref: Codable, Hashable {
    let profileId: String
    let seriesId: String
    let audioTrackIndex: Int
    let audioLanguage: String
    let trackSignature: AudioTrackSignature?
    let updatedAt: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId) ?? ""
        seriesId = try c.decodeIfPresent(String.self, forKey: .seriesId) ?? ""
        audioTrackIndex = try c.decodeIfPresent(Int.self, forKey: .audioTrackIndex) ?? -1
        audioLanguage = try c.decodeIfPresent(String.self, forKey: .audioLanguage) ?? ""
        trackSignature = try c.decodeIfPresent(AudioTrackSignature.self, forKey: .trackSignature)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
    }
}

struct AudioPrefRequest: Codable {
    let audioTrackIndex: Int
    let audioLanguage: String
    let trackSignature: AudioTrackSignature?
}
