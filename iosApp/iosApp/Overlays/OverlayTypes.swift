import Foundation
import SwiftUI

/// Stable identifiers for every overlay the system knows about. The wire
/// format (server `defaults.card_overlays`, user `card_overlays`) uses
/// these as keys, so they MUST stay in sync with
/// `web/src/lib/overlays/types.ts` → `OverlayId`. Adding a new overlay
/// requires updating the registry; renaming an existing one is a
/// breaking change for stored prefs.
enum OverlayId: String, CaseIterable, Codable, Hashable {
    // tech
    case resolution
    case hdr
    case resolutionHdr = "resolution_hdr"
    case audio
    case audioChannels = "audio_channels"
    case videoCodec = "video_codec"
    case container
    case aspectRatio = "aspect_ratio"
    case releaseType = "release_type"
    case edition
    case multiAudio = "multi_audio"
    case multiSub = "multi_sub"
    // ratings
    case ratingImdb = "rating_imdb"
    case ratingTmdb = "rating_tmdb"
    case ratingRt = "rating_rt"
    case ratingRtAudience = "rating_rt_audience"
    case contentRating = "content_rating"
    // metadata
    case year
    case runtime
    case originalLanguage = "original_language"
    case studio
    case network
    // ribbons
    case showStatus = "show_status"
    case imdbTop250 = "imdb_top_250"
    case rtCertifiedFresh = "rt_certified_fresh"
}

enum OverlayPosition: String, CaseIterable, Codable, Hashable {
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"

    var displayName: String {
        switch self {
        case .topLeft:     return "Top Left"
        case .topRight:    return "Top Right"
        case .bottomLeft:  return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

enum OverlayCategory: String, CaseIterable, Codable, Hashable {
    case tech
    case ratings
    case metadata
    case ribbons

    var displayName: String {
        switch self {
        case .tech:     return "Media Info"
        case .ratings:  return "Ratings"
        case .metadata: return "Metadata"
        case .ribbons:  return "Ribbons"
        }
    }

    var description: String {
        switch self {
        case .tech:     return "Quality and codec details from the file itself."
        case .ratings:  return "External scores and age ratings."
        case .metadata: return "Year, runtime, studio, network, language."
        case .ribbons:  return "Status badges and award ribbons (data sources pending)."
        }
    }
}

enum PresetId: String, CaseIterable, Codable, Hashable {
    case minimal
    case classic
    case vibrant
    case pill
    case square

    var label: String {
        switch self {
        case .minimal:  return "Minimal"
        case .classic:  return "Classic"
        case .vibrant:  return "Vibrant"
        case .pill:     return "Pill"
        case .square:   return "Square"
        }
    }

    var description: String {
        switch self {
        case .minimal:  return "Near-invisible. Tiny text, no background."
        case .classic:  return "Semi-transparent dark pill with a thin border. The default."
        case .vibrant:  return "Opaque, accent-colored badges. High contrast."
        case .pill:     return "Larger pill with more padding. Works well with icons."
        case .square:   return "Blocky, high-density. Plex-inspired."
        }
    }
}

/// Per-overlay user configuration. `accentColor` and `showIcon` are
/// optional overrides — `nil` means "use the registry default" /
/// "use the preset's icon preference".
struct OverlayItemConfig: Codable, Hashable {
    var enabled: Bool
    var position: OverlayPosition
    /// Hex string (`"#f5c518"`); `nil` falls back to `OverlayDef.defaultAccent`.
    var accentColor: String?
    /// When non-nil, overrides `OverlayPreset.preferIcon` for this badge.
    var showIcon: Bool?
}

/// Versioned root document stored under the user setting key
/// `card_overlays`. Serialized as JSON string and PUT'd to
/// `/api/v1/settings/card_overlays`. Shared across web, iOS, and tvOS.
struct CardOverlayPrefs: Codable, Hashable {
    static let currentVersion = 2

    var version: Int
    var preset: PresetId
    /// User-chosen render order within each corner. Empty array means
    /// "use registry order".
    var order: [OverlayId]
    var items: [OverlayId: OverlayItemConfig]
}

/// Flat data bag passed to overlay renderers. Each field is optional —
/// extractors fill what's available and the registry's `getValue` closure
/// returns `nil` when the data isn't there. The shape mirrors
/// `web/src/lib/overlays/types.ts` → `OverlayData`.
struct OverlayData: Hashable {
    // tech (from OverlaySummary)
    var resolution: String?
    var hdr: String?
    var audio: String?
    var audioChannels: String?
    var videoCodec: String?
    var container: String?
    var aspectRatio: String?
    var releaseType: String?
    var edition: String?
    var multiAudio: Bool?
    var multiSub: Bool?
    // ratings / metadata (from item fields)
    var ratingImdb: Double?
    var ratingTmdb: Double?
    var ratingRtCritic: Int?
    var ratingRtAudience: Int?
    var contentRating: String?
    var year: Int?
    var runtime: Int?
    var originalLanguage: String?
    var studio: String?
    var network: String?
    // ribbons (data sources pending)
    var showStatus: String?
    var imdbTop250: Int?
    var rtCertifiedFresh: Bool?
}

/// One overlay type, registered statically. `getValue` extracts the
/// label from `OverlayData`; returning `nil` hides the badge for that
/// item even if the user enabled the overlay.
struct OverlayDef {
    let id: OverlayId
    let category: OverlayCategory
    let label: String
    let description: String
    let defaultPosition: OverlayPosition
    let defaultEnabled: Bool
    /// Static icon (e.g. "monitor" for resolution). When `getIcon` is set,
    /// the dynamic icon overrides this.
    let iconId: OverlayIconId?
    let defaultAccent: String?
    /// Whether the settings UI should expose the "show icon" toggle.
    let iconCapable: Bool
    /// When true, render the icon without the text label.
    let iconOnly: Bool
    /// Shown beneath the row in the settings UI when the data source
    /// isn't wired up yet (e.g. IMDb Top 250).
    let availabilityNote: String?
    let getValue: (OverlayData) -> String?
    let getIcon: ((OverlayData) -> OverlayIconId?)?

    init(
        id: OverlayId,
        category: OverlayCategory,
        label: String,
        description: String,
        defaultPosition: OverlayPosition,
        defaultEnabled: Bool,
        iconId: OverlayIconId? = nil,
        defaultAccent: String? = nil,
        iconCapable: Bool,
        iconOnly: Bool = false,
        availabilityNote: String? = nil,
        getValue: @escaping (OverlayData) -> String?,
        getIcon: ((OverlayData) -> OverlayIconId?)? = nil
    ) {
        self.id = id
        self.category = category
        self.label = label
        self.description = description
        self.defaultPosition = defaultPosition
        self.defaultEnabled = defaultEnabled
        self.iconId = iconId
        self.defaultAccent = defaultAccent
        self.iconCapable = iconCapable
        self.iconOnly = iconOnly
        self.availabilityNote = availabilityNote
        self.getValue = getValue
        self.getIcon = getIcon
    }
}

/// Typed icon identifiers. Lucide icons map to SF Symbols in
/// ``OverlayIcon``; brand marks (HDR10, DV, Atmos, AV1, Tomato) render
/// from inline shape views.
enum OverlayIconId: String, Hashable {
    // generic
    case star
    case clock
    case tv
    case film
    case award
    case ribbon
    case subtitles
    case languages
    case building
    case shield
    case layout
    case monitor
    case volume
    case calendar
    case globe
    // brand marks
    case hdr10
    case hdr
    case dolbyVision = "dolby-vision"
    case atmos
    case av1
    case tomato

    /// The text a wordmark icon already spells out as the mark itself.
    /// Mirrors web's `WORDMARK_TEXT`: when a badge's label matches its
    /// mark, the renderer suppresses the label so the badge doesn't
    /// read "HDR10 HDR10".
    var wordmarkText: String? {
        switch self {
        case .hdr: return "HDR"
        case .hdr10: return "HDR10"
        case .atmos: return "ATMOS"
        case .av1: return "AV1"
        default: return nil
        }
    }
}

/// How the preset paints the accent color. Mirrors web's
/// `AccentStrategy` so the visual outcome matches per-platform.
enum AccentStrategy: String {
    case background
    case border
    case text
    case dot
}

/// Visual recipe for a badge. The renderer applies `font`, `padding`,
/// `cornerStyle`, etc. uniformly to every badge; per-badge variation
/// comes from the registry (icon) and the user's `accentColor`.
struct OverlayPreset {
    let id: PresetId
    let fontSize: CGFloat
    let textWeight: Font.Weight
    let textCase: Text.Case?
    let tracking: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let cornerStyle: CornerStyle
    let iconSize: CGFloat
    let preferIcon: Bool
    /// Spacing between stacked badges in the same corner.
    let gap: CGFloat
    let accentStrategy: AccentStrategy
    /// Compute the background color given the user's accent override (or
    /// the registry default). Returns `.clear` for transparent presets.
    let backgroundColor: (Color?) -> Color
    /// Compute the foreground (text + icon) color.
    let foregroundColor: (Color?) -> Color
    /// Optional 1-pt accent border (used by `.square` when an accent is set).
    let borderColor: (Color?) -> Color?
    /// Background blur material (used by `.pill`); `.nil` means no blur.
    let backdropMaterial: Material?
    /// Subtle shadow under the badge (only `.minimal` uses it).
    let textShadow: Bool

    enum CornerStyle {
        case capsule
        case rounded(CGFloat)
    }
}

/// Curated accent palette shown in the settings UI. Mirrors the web
/// `ACCENT_PALETTE` so a color picked on one platform looks the same on
/// the other.
enum OverlayAccentPalette {
    static let entries: [(label: String, hex: String)] = [
        ("Gold",    "#f5c518"),
        ("Tomato",  "#fa320a"),
        ("Orange",  "#f97316"),
        ("Amber",   "#f59e0b"),
        ("Emerald", "#10b981"),
        ("Cyan",    "#06b6d4"),
        ("Blue",    "#3b82f6"),
        ("Indigo",  "#6366f1"),
        ("Violet",  "#8b5cf6"),
        ("Pink",    "#ec4899"),
        ("Slate",   "#64748b"),
        ("White",   "#ffffff"),
    ]
}
