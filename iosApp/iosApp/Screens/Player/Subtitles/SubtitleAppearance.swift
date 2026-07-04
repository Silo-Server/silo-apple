import Foundation
import CoreText

let subtitleAppearanceSettingKey = "subtitle_appearance"

enum SubtitleFontSizePreset: String, Codable, CaseIterable, Identifiable {
    case small
    case medium
    case large
    case xlarge
    case xxlarge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .xlarge: return "X-Large"
        case .xxlarge: return "XX-Large"
        }
    }

    /// Point sizes are interpreted inside the fixed 1080-line ASS playfield
    /// and scale with the displayed video rect, so they read the same in any
    /// orientation. The ladder is rebased ~1.4x from the original values
    /// (large = old xxlarge) after the overlay switched from full-screen to
    /// video-rect sizing, which shrank the effective render size.
    var pointSize: Double {
        #if os(iOS)
        switch self {
        case .small: return 43
        case .medium: return 48
        case .large: return 54
        case .xlarge: return 65
        case .xxlarge: return 77
        }
        #elseif os(tvOS)
        // Ladder shifted down one notch from the prior tvOS values (large =
        // old medium) after the defaults read one size too big in the living
        // room. Each preset now takes the prior rung's value; small is a new
        // ~1.2x step below medium.
        switch self {
        case .small: return 43
        case .medium: return 51
        case .large: return 63
        case .xlarge: return 74
        case .xxlarge: return 88
        }
        #else
        switch self {
        case .small: return 62
        case .medium: return 79
        case .large: return 96
        case .xlarge: return 116
        case .xxlarge: return 136
        }
        #endif
    }

    static func nearest(to points: Double) -> SubtitleFontSizePreset {
        allCases.min(by: { abs($0.pointSize - points) < abs($1.pointSize - points) }) ?? .large
    }
}

// Future: add a "system" appearance source that maps Apple's Media
// Accessibility caption preferences into this model before libass styling.
struct SubtitleFontFamilyPreset: RawRepresentable, Codable, CaseIterable, Hashable, Identifiable {
    let rawValue: String

    init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.rawValue = trimmed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = trimmed.isEmpty ? Self.sansSerif.rawValue : trimmed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let sansSerif = SubtitleFontFamilyPreset(rawValue: "sans-serif")!
    static let serif = SubtitleFontFamilyPreset(rawValue: "serif")!
    static let monospace = SubtitleFontFamilyPreset(rawValue: "monospace")!

    static var allCases: [SubtitleFontFamilyPreset] {
        let legacy = [sansSerif, serif, monospace]
        let legacyValues = Set(legacy.map(\.rawValue))
        let systemFamilies = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        let systemPresets = systemFamilies
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .filter { !legacyValues.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap(SubtitleFontFamilyPreset.init(rawValue:))
        return legacy + systemPresets
    }

    var id: String { rawValue }

    var label: String {
        switch rawValue {
        case Self.sansSerif.rawValue: return "Sans-serif"
        case Self.serif.rawValue: return "Serif"
        case Self.monospace.rawValue: return "Monospace"
        default: return rawValue
        }
    }

    var assFontName: String {
        switch rawValue {
        case Self.sansSerif.rawValue: return "Arial"
        case Self.serif.rawValue: return "Times New Roman"
        case Self.monospace.rawValue: return "Menlo"
        default: return rawValue
        }
    }
}

enum SubtitleBackgroundStylePreset: String, Codable, CaseIterable, Identifiable {
    case box
    case shadow
    case outline
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .box: return "Box"
        case .shadow: return "Drop Shadow"
        case .outline: return "Outline"
        case .none: return "None"
        }
    }
}

enum SubtitlePositionPreset: String, Codable, CaseIterable, Identifiable {
    case bottom
    case lowerThird = "lower-third"
    case top

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bottom: return "Bottom"
        case .lowerThird: return "Lower Third"
        case .top: return "Top"
        }
    }

    var legacyPosition: Int {
        switch self {
        case .top: return 0
        case .lowerThird: return 70
        case .bottom: return 100
        }
    }
}

struct SubtitleAppearance: Codable, Equatable {
    var fontSize: SubtitleFontSizePreset
    var fontFamily: SubtitleFontFamilyPreset
    var fontColor: String
    var backgroundColor: String
    var backgroundStyle: SubtitleBackgroundStylePreset
    var backgroundOpacity: Int
    var textOutline: Bool
    var textOutlineColor: String
    var position: SubtitlePositionPreset

    init(
        fontSize: SubtitleFontSizePreset,
        fontFamily: SubtitleFontFamilyPreset,
        fontColor: String,
        backgroundColor: String,
        backgroundStyle: SubtitleBackgroundStylePreset,
        backgroundOpacity: Int,
        textOutline: Bool,
        textOutlineColor: String,
        position: SubtitlePositionPreset
    ) {
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.fontColor = fontColor
        self.backgroundColor = backgroundColor
        self.backgroundStyle = backgroundStyle
        self.backgroundOpacity = backgroundOpacity
        self.textOutline = textOutline
        self.textOutlineColor = textOutlineColor
        self.position = position
    }

    static let `default` = SubtitleAppearance(
        fontSize: .large,
        fontFamily: .sansSerif,
        fontColor: "#ffffff",
        backgroundColor: "#000000",
        backgroundStyle: .box,
        backgroundOpacity: 75,
        textOutline: false,
        textOutlineColor: "#000000",
        position: .bottom
    )

    static let fontColors: [(hex: String, label: String)] = [
        ("#ffffff", "White"),
        ("#facc15", "Yellow"),
        ("#22c55e", "Green"),
        ("#06b6d4", "Cyan"),
        ("#d946ef", "Magenta"),
        ("#ef4444", "Red"),
        ("#3b82f6", "Blue"),
        ("#000000", "Black"),
    ]

    static let backgroundColors: [(hex: String, label: String)] = [
        ("#000000", "Black"),
        ("#374151", "Dark Gray"),
        ("#1e3a5f", "Navy"),
        ("#7f1d1d", "Dark Red"),
        ("#14532d", "Dark Green"),
    ]

    static let outlineColors: [(hex: String, label: String)] = backgroundColors

    private enum CodingKeys: String, CodingKey {
        case fontSize
        case fontFamily
        case fontColor
        case backgroundColor
        case backgroundStyle
        case backgroundOpacity
        case textOutline
        case textOutlineColor
        case position
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fontSize = try container.decodeIfPresent(SubtitleFontSizePreset.self, forKey: .fontSize) ?? Self.default.fontSize
        self.fontFamily = try container.decodeIfPresent(SubtitleFontFamilyPreset.self, forKey: .fontFamily) ?? Self.default.fontFamily
        self.fontColor = try container.decodeIfPresent(String.self, forKey: .fontColor) ?? Self.default.fontColor
        self.backgroundColor = try container.decodeIfPresent(String.self, forKey: .backgroundColor) ?? Self.default.backgroundColor
        self.backgroundStyle = try container.decodeIfPresent(SubtitleBackgroundStylePreset.self, forKey: .backgroundStyle) ?? Self.default.backgroundStyle
        self.backgroundOpacity = try container.decodeIfPresent(Int.self, forKey: .backgroundOpacity) ?? Self.default.backgroundOpacity
        self.textOutline = try container.decodeIfPresent(Bool.self, forKey: .textOutline) ?? Self.default.textOutline
        self.textOutlineColor = try container.decodeIfPresent(String.self, forKey: .textOutlineColor) ?? Self.default.textOutlineColor
        self.position = try container.decodeIfPresent(SubtitlePositionPreset.self, forKey: .position) ?? Self.default.position
    }

    static func decode(from json: String?) -> SubtitleAppearance {
        guard let json, let data = json.data(using: .utf8) else { return .default }
        do {
            return try JSONDecoder().decode(SubtitleAppearance.self, from: data).sanitized()
        } catch {
            return .default
        }
    }

    var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(sanitized()),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    func sanitized() -> SubtitleAppearance {
        var copy = self
        if !Self.isValidHex(copy.fontColor) { copy.fontColor = Self.default.fontColor }
        if !Self.isValidHex(copy.backgroundColor) { copy.backgroundColor = Self.default.backgroundColor }
        if !Self.isValidHex(copy.textOutlineColor) { copy.textOutlineColor = Self.default.textOutlineColor }
        copy.backgroundOpacity = max(0, min(100, copy.backgroundOpacity))
        return copy
    }

    private static func isValidHex(_ value: String) -> Bool {
        let trimmed = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard trimmed.count == 6 else { return false }
        return UInt32(trimmed, radix: 16) != nil
    }
}

struct EffectiveSubtitleAppearanceResponse: Codable {
    let key: String
    let globalValue: String
    let deviceValue: String?
    let effectiveValue: String
    let hasDeviceOverride: Bool
    let deviceId: String?
    let deviceName: String?
    let devicePlatform: String?
    let updatedAt: String?
}

struct EffectiveSettingResponse: Codable {
    let key: String
    let profileId: String?
    let userValue: String?
    let deviceValue: String?
    let effectiveValue: String
    let source: String
    let hasDeviceOverride: Bool
    let deviceId: String?
    let deviceName: String?
    let devicePlatform: String?
    let updatedAt: String?
}

struct EffectiveSettingsResponse: Codable {
    let settings: [EffectiveSettingResponse]
}

