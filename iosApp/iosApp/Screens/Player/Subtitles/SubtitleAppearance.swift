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

    /// Point sizes are interpreted inside the overlay's 1080-line reference
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
        // ~1.2x step below medium. Large (the default) was then eased from 63
        // to 58 — 63 read a touch too big and medium's 51 a touch too small,
        // so the default now lands between the two.
        switch self {
        case .small: return 43
        case .medium: return 51
        case .large: return 58
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
// Accessibility caption preferences into this model before overlay styling.
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
    /// Legacy value. Outline is an independent text-edge axis
    /// (`textOutline`), not a background; `sanitized()` migrates this to
    /// `.none` + `textOutline = true`. The case stays so stored JSON from
    /// older builds and the web client keeps decoding.
    case outline
    case none

    var id: String { rawValue }

    /// The choices the pickers offer. Excludes the legacy `.outline`
    /// value, which the UI now expresses through the Text Outline toggle.
    static var selectableCases: [SubtitleBackgroundStylePreset] {
        [.box, .shadow, .none]
    }

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

/// Apple exposes five distinct caption edge treatments. This value is
/// runtime-only: it is populated from MediaAccessibility and deliberately
/// excluded from the server-backed Silo appearance JSON.
enum SystemCaptionTextEdgeStyle: Equatable {
    case none
    case raised
    case depressed
    case uniform
    case dropShadow
}

struct SystemCaptionContentOverrides: OptionSet, Equatable {
    let rawValue: Int

    static let font = SystemCaptionContentOverrides(rawValue: 1 << 0)
    static let size = SystemCaptionContentOverrides(rawValue: 1 << 1)
    static let foregroundColor = SystemCaptionContentOverrides(rawValue: 1 << 2)
    static let foregroundOpacity = SystemCaptionContentOverrides(rawValue: 1 << 3)
    static let backgroundColor = SystemCaptionContentOverrides(rawValue: 1 << 4)
    static let backgroundOpacity = SystemCaptionContentOverrides(rawValue: 1 << 5)
    static let edge = SystemCaptionContentOverrides(rawValue: 1 << 6)
    static let windowColor = SystemCaptionContentOverrides(rawValue: 1 << 7)
    static let windowOpacity = SystemCaptionContentOverrides(rawValue: 1 << 8)
    static let windowCornerRadius = SystemCaptionContentOverrides(rawValue: 1 << 9)

    static let colors: SystemCaptionContentOverrides = [
        .foregroundColor,
        .foregroundOpacity,
        .backgroundColor,
        .backgroundOpacity,
    ]
    static let window: SystemCaptionContentOverrides = [
        .windowColor,
        .windowOpacity,
        .windowCornerRadius,
    ]
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

    // Runtime-only MediaAccessibility details. These are intentionally not
    // CodingKeys: a device caption profile must never leak into the user's
    // server-synced Silo appearance or another platform.
    var fontOpacity: Int
    var systemRelativeFontScale: Double?
    var systemTextEdgeStyle: SystemCaptionTextEdgeStyle?
    var captionWindowColor: String
    var captionWindowOpacity: Int
    var captionWindowCornerRadius: Double
    var systemContentOverrides: SystemCaptionContentOverrides

    init(
        fontSize: SubtitleFontSizePreset,
        fontFamily: SubtitleFontFamilyPreset,
        fontColor: String,
        backgroundColor: String,
        backgroundStyle: SubtitleBackgroundStylePreset,
        backgroundOpacity: Int,
        textOutline: Bool,
        textOutlineColor: String,
        position: SubtitlePositionPreset,
        fontOpacity: Int = 100,
        systemRelativeFontScale: Double? = nil,
        systemTextEdgeStyle: SystemCaptionTextEdgeStyle? = nil,
        captionWindowColor: String = "#000000",
        captionWindowOpacity: Int = 0,
        captionWindowCornerRadius: Double = 0,
        systemContentOverrides: SystemCaptionContentOverrides = []
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
        self.fontOpacity = fontOpacity
        self.systemRelativeFontScale = systemRelativeFontScale
        self.systemTextEdgeStyle = systemTextEdgeStyle
        self.captionWindowColor = captionWindowColor
        self.captionWindowOpacity = captionWindowOpacity
        self.captionWindowCornerRadius = captionWindowCornerRadius
        self.systemContentOverrides = systemContentOverrides
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
        self.fontOpacity = 100
        self.systemRelativeFontScale = nil
        self.systemTextEdgeStyle = nil
        self.captionWindowColor = "#000000"
        self.captionWindowOpacity = 0
        self.captionWindowCornerRadius = 0
        self.systemContentOverrides = []
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
        if !Self.isValidHex(copy.captionWindowColor) { copy.captionWindowColor = "#000000" }
        copy.backgroundOpacity = max(0, min(100, copy.backgroundOpacity))
        copy.fontOpacity = max(0, min(100, copy.fontOpacity))
        copy.captionWindowOpacity = max(0, min(100, copy.captionWindowOpacity))
        if let scale = copy.systemRelativeFontScale {
            copy.systemRelativeFontScale = scale.isFinite ? max(0.1, min(5, scale)) : nil
        }
        copy.captionWindowCornerRadius = copy.captionWindowCornerRadius.isFinite
            ? max(0, min(200, copy.captionWindowCornerRadius))
            : 0
        // Legacy "outline" background style folds into the text-edge axis
        // so the UI has a single outline concept. Rendering is identical:
        // both paths draw a 2px border in the outline color.
        if copy.backgroundStyle == .outline {
            copy.backgroundStyle = .none
            copy.textOutline = true
        }
        return copy
    }

    /// One-word style descriptor for summary rows ("Large · Box · Bottom").
    var styleDescription: String {
        if backgroundStyle == .box { return "Box" }
        if textOutline || backgroundStyle == .outline { return "Outline" }
        if backgroundStyle == .shadow { return "Drop Shadow" }
        return "Plain"
    }

    /// True when the configuration risks unreadable text: a dark font
    /// color with no box behind it and no outline around it.
    var isLowLegibilityRisk: Bool {
        guard backgroundStyle != .box || backgroundOpacity == 0 else { return false }
        guard !textOutline && backgroundStyle != .outline else { return false }
        let trimmed = fontColor.hasPrefix("#") ? String(fontColor.dropFirst()) : fontColor
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return false }
        let red = Double((value >> 16) & 0xFF)
        let green = Double((value >> 8) & 0xFF)
        let blue = Double(value & 0xFF)
        let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
        return luminance / 255.0 < 0.25
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
