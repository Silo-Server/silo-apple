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
//    PUT    /api/v1/subtitle-prefs/{series_id}       — set per-series
//    DELETE /api/v1/subtitle-prefs/{series_id}       — clear per-series
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

/// One language row in a settings picker. Values come from the generated
/// contract catalog, deployment-observed suggestions, and the current stored
/// value. Labels are localized by Foundation rather than shipped as a second
/// English-only registry.
struct PlaybackLanguageOption: Identifiable, Hashable {
    let code: String
    let label: String
    var id: String { code }

    static let all = options(for: .playbackSubtitleLanguage)

    /// ISO 639-2/B spellings whose terminology form differs. Foundation
    /// canonicalizes most of these through CLDR, but not every supported
    /// spelling (notably `mao`), so keep the stable ISO aliases explicit.
    private static let bibliographicAliases: [String: String] = [
        "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my",
        "chi": "zh", "cze": "cs", "dut": "nl", "fre": "fr",
        "geo": "ka", "ger": "de", "gre": "el", "ice": "is",
        "mac": "mk", "mao": "mi", "may": "ms", "per": "fa",
        "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy",
    ]

    static func options(
        for key: SettingKey,
        currentValue: String? = nil,
        runtimeValues: [String] = []
    ) -> [PlaybackLanguageOption] {
        var values: [String] = []
        var indexByIdentity: [String: Int] = [:]

        func add(_ rawValue: String, replacingAlias: Bool) {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  value != PlaybackPrefSentinel.none,
                  value != PlaybackPrefSentinel.inherit else { return }
            let identity = languageIdentity(value)
            if let index = indexByIdentity[identity] {
                if replacingAlias { values[index] = value }
                return
            }
            indexByIdentity[identity] = values.count
            values.append(value)
        }

        SettingPresentationMetadata.suggestedValues(for: key).forEach {
            add($0, replacingAlias: false)
        }
        runtimeValues.forEach { add($0, replacingAlias: false) }
        if let currentValue { add(currentValue, replacingAlias: true) }

        return values.map { .init(code: $0, label: label(forCode: $0)) }
    }

    static func label(forCode code: String) -> String {
        if code == PlaybackPrefSentinel.originalLanguage { return "Original Language" }
        return Locale.current.localizedString(forIdentifier: code)?.capitalized
            ?? Locale.current.localizedString(forLanguageCode: code)?.capitalized
            ?? code.uppercased()
    }

    private static func languageIdentity(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "_", with: "-")
        var components = normalized.split(separator: "-").map(String.init)
        guard let language = components.first else { return normalized.lowercased() }
        let languageCode = Locale(identifier: language).language.languageCode
        components[0] = languageCode?.identifier(.alpha2)
            ?? bibliographicAliases[language.lowercased()]
            ?? language
        return components.joined(separator: "-").lowercased()
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
}

// MARK: - Per-series subtitle pref

struct SubtitlePrefRequest: Codable {
    let subtitleLanguage: String
    let subtitleTrackIndex: Int
    let externalSubtitlePath: String
    let subtitleMode: String
    let trackSignature: SubtitleTrackSignature?
    let showForcedSubtitles: Bool?
}

// MARK: - Per-series audio pref

struct AudioPrefRequest: Codable {
    let audioTrackIndex: Int
    let audioLanguage: String
    let trackSignature: AudioTrackSignature?
}
