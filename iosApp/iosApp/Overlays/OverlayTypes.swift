import Foundation
import SwiftUI

/// Stable identifiers for every overlay the system knows about. The wire
/// format (server `defaults.card_overlays`, user `ui.card_overlays`) uses
/// these as keys, so they MUST stay in sync with
/// `web/src/lib/overlays/types.ts` → `OverlayId`. Adding a new overlay
/// requires updating the registry; renaming an existing one is a
/// breaking change for stored prefs.
enum OverlayId: String, Hashable {
    // tech
    case resolution
    case hdr
    case resolutionHdr = "resolution_hdr"
    case resolutionHdrAudio = "resolution_hdr_audio"
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
    case advisoryAge = "advisory_age"
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

/// Where a badge sits on the card: three corners and a rail centred on each
/// side edge. The top-right corner belongs to the watch-status indicator
/// (`CardWatchStatus`), so no badge is placed there. Mirrors
/// `OVERLAY_POSITIONS` in `web/src/lib/overlays/types.ts`.
enum OverlayPosition: String, Hashable {
    case topLeft = "top-left"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"
    case leftEdge = "left-edge"
    case rightEdge = "right-edge"

    /// The position a stored document names. The contract keeps `top-right`
    /// valid for documents written before that corner held watch status;
    /// such a badge draws on the right-edge rail, the same side of the card.
    init?(stored: String) {
        if stored == "top-right" {
            self = .rightEdge
        } else {
            self.init(rawValue: stored)
        }
    }
}

enum PresetId: String, Hashable {
    case minimal
    case classic
    case vibrant
    case pill
    case square
    case plate
    case band
}

/// Per-overlay user configuration. `accentColor` and `showIcon` are
/// optional overrides — `nil` means "use the registry default" /
/// "use the preset's icon preference".
struct OverlayItemConfig: Hashable {
    var enabled: Bool
    var position: OverlayPosition
    /// Hex string (`"#f5c518"`); `nil` falls back to `OverlayDef.defaultAccent`.
    var accentColor: String?
    /// When non-nil, overrides `OverlayPreset.preferIcon` for this badge.
    var showIcon: Bool?
    /// Uploaded image ref drawn in the icon's place, beside the label.
    var image: String?
    /// Uploaded image refs by value key (`OverlayDef.getValueKey`); a match
    /// replaces the whole badge.
    var valueImages: [String: String] = [:]
}

enum OverlayShape: String, Hashable {
    case pill
    case rounded
    case square
}

enum OverlayFontWeight: String, Hashable {
    case regular
    case semibold
    case extrabold
}

/// Overrides layered on the preset. Each absent field keeps the preset's
/// value. Mirrors `OverlayStyle` in `web/src/lib/overlays/types.ts`.
struct OverlayStyle: Hashable {
    /// 0.75–2; scales text, padding and icons.
    var size: Double?
    var shape: OverlayShape?
    /// `#RRGGBBAA`.
    var background: String?
    /// `#RRGGBB`.
    var textColor: String?
    /// `#RRGGBBAA`.
    var borderColor: String?
    /// 0–3 at the reference card width.
    var borderWidth: Int?
    var fontWeight: OverlayFontWeight?
    var uppercase: Bool?
    var shadow: Bool?

    var isEmpty: Bool { self == OverlayStyle() }
}

/// Versioned root document stored under the user setting key
/// `ui.card_overlays`. Shared across web, iOS, and tvOS; `OverlaySchema`
/// handles the JSON document and migration from older preferences.
struct CardOverlayPrefs: Hashable {
    static let currentVersion = 2

    var version: Int
    var preset: PresetId
    /// Overrides on top of the preset; `nil` draws the preset as it is.
    var style: OverlayStyle?
    /// User-chosen render order within each position. Empty array means
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
    var advisoryAge: Int?
    var advisorySource: String?
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
    let defaultPosition: OverlayPosition
    let defaultEnabled: Bool
    /// Static icon (e.g. "monitor" for resolution). When `getIcon` is set,
    /// the dynamic icon overrides this.
    let iconId: OverlayIconId?
    let defaultAccent: String?
    /// Whether this badge can render an icon when preferences request one.
    let iconCapable: Bool
    let getValue: (OverlayData) -> String?
    let getIcon: ((OverlayData) -> OverlayIconId?)?
    /// A rating's source mark ("IMDb") and its bare score, for presets that
    /// draw the mark as a chip. Both are set together.
    let sourceMark: String?
    let getScore: ((OverlayData) -> String?)?
    /// The key a `valueImages` entry matches: the value as the API returns
    /// it, so every client matches the same keys. `nil` means the badge
    /// takes no per-value images (scores, runtimes).
    let getValueKey: ((OverlayData) -> String?)?

    init(
        id: OverlayId,
        defaultPosition: OverlayPosition,
        defaultEnabled: Bool,
        iconId: OverlayIconId? = nil,
        defaultAccent: String? = nil,
        iconCapable: Bool,
        getValue: @escaping (OverlayData) -> String?,
        getIcon: ((OverlayData) -> OverlayIconId?)? = nil,
        sourceMark: String? = nil,
        getScore: ((OverlayData) -> String?)? = nil,
        getValueKey: ((OverlayData) -> String?)? = nil
    ) {
        self.id = id
        self.defaultPosition = defaultPosition
        self.defaultEnabled = defaultEnabled
        self.iconId = iconId
        self.defaultAccent = defaultAccent
        self.iconCapable = iconCapable
        self.getValue = getValue
        self.getIcon = getIcon
        self.sourceMark = sourceMark
        self.getScore = getScore
        self.getValueKey = getValueKey
    }
}

/// Typed icon identifiers. Lucide icons map to SF Symbols in
/// ``OverlayIcon``; wordmarks render as text and Dolby Vision as its mark.
enum OverlayIconId: String, Hashable {
    // generic
    case clock
    case tv
    case film
    case ribbon
    case subtitles
    case languages
    case building
    case shield
    case users
    case layout
    case monitor
    case volume
    case globe
    // brand marks
    case hdr10
    case hdr
    case dolbyVision = "dolby-vision"
    case atmos
    case av1

    /// The text a wordmark icon spells. When a badge's label says the same
    /// thing, the renderer drops the label so the badge doesn't read
    /// "HDR10 HDR10". Mirrors web's `WORDMARK_TEXT`; Dolby Vision draws a
    /// mark, not a word, so its label always shows.
    var wordmark: String? {
        switch self {
        case .hdr: return "HDR"
        case .hdr10: return "HDR10"
        case .atmos: return "ATMOS"
        case .av1: return "AV1"
        default: return nil
        }
    }
}

/// An image an administrator uploaded for badges, as the overlay-config
/// endpoint lists it.
struct OverlayImageAsset: Hashable {
    let url: URL
    /// Width over height of the stored image.
    let aspectRatio: CGFloat
}

/// An offset shadow, in points at the reference card width.
struct OverlayShadow: Hashable {
    var x: CGFloat = 0
    var y: CGFloat
    var blur: CGFloat
    var color: OverlayColor
}

/// The colours one badge draws with, after the accent is applied.
struct OverlayBadgePaint: Hashable {
    var background: OverlayColor
    var foreground: OverlayColor
    /// Colour of the border around the badge; `nil` draws it in the text colour.
    var border: OverlayColor?
    /// Colour of the bar on the badge's left side (`.square` with an accent).
    var accentBar: OverlayColor?
}

/// Visual recipe for a badge, mirroring `OverlayPreset` in
/// `web/src/lib/overlays/types.ts`. Lengths are points at the 185-point
/// reference card width; the renderer scales them with the card.
struct OverlayPreset {
    enum Layout {
        /// Each position's badges stack.
        case stack
        /// Each edge's badges form one strip of marks over a scrim.
        case band
    }

    /// How the preset paints a badge's accent colour.
    enum AccentStrategy {
        case background
        case border
        case text
    }

    enum CornerStyle: Hashable {
        case capsule
        case rounded(CGFloat)
    }

    let id: PresetId
    let layout: Layout
    /// A rating badge draws its source mark as an accent-coloured chip ahead
    /// of the score instead of one "IMDb 7.8" label.
    let sourceChips: Bool
    var fontSize: CGFloat
    var fontWeight: Font.Weight
    var uppercase: Bool
    /// Letter spacing as a share of the font size.
    let trackingEm: CGFloat
    var paddingInline: CGFloat
    var paddingBlock: CGFloat
    var cornerStyle: CornerStyle
    /// Width of the border around the badge; `nil` or 0 draws none.
    var borderWidth: CGFloat?
    /// Width of the accent bar on the badge's left side.
    let accentBarWidth: CGFloat?
    var textShadow: OverlayShadow?
    var boxShadow: OverlayShadow?
    var iconSize: CGFloat
    var iconGap: CGFloat
    let preferIcon: Bool
    /// Spacing between stacked badges in the same position.
    var stackGap: CGFloat
    let accentStrategy: AccentStrategy
    /// The badge's colours for an accent (the viewer's, or the badge's default).
    var paint: (OverlayColor?) -> OverlayBadgePaint
}
