import AVFoundation
import CoreMedia
import Foundation

/// Silo's subtitle appearance for the subtitles AVPlayer draws itself: the
/// WebVTT renditions of a server HLS stream. The cue overlay styles every other
/// subtitle, but these never reach it, so the same appearance is handed to
/// AVPlayer as text style rules.
///
/// Placement stays AVPlayer's: a rule can move a cue line, but not with the
/// overlay's video-rect geometry, so position and the caption window are left
/// out rather than approximated.
enum HLSRenditionTextStyle {
    /// Nil keeps AVPlayer on the device's own caption style, which is what an
    /// appearance that matches the system means.
    static func rules(appearance: SubtitleAppearance, matchesSystemAppearance: Bool) -> [AVTextStyleRule]? {
        guard !matchesSystemAppearance else { return nil }
        let style = AetherSubtitleRenderStyle(appearance: appearance)
        return AVTextStyleRule(textMarkupAttributes: attributes(for: style)).map { [$0] }
    }

    /// The `CMTextMarkup` attributes for `style`.
    static func attributes(for style: AetherSubtitleRenderStyle) -> [String: Any] {
        var attributes: [String: Any] = [
            kCMTextMarkupAttribute_ForegroundColorARGB as String: argb(style.foreground, opacity: style.foregroundOpacity),
            // No box is a transparent one, not AVPlayer's default backdrop.
            kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String:
                style.drawsBox ? argb(style.boxColor, opacity: style.boxOpacity) : [0.0, 0.0, 0.0, 0.0],
            // Percent of AVPlayer's own size, which Silo's default matches.
            kCMTextMarkupAttribute_RelativeFontSize as String:
                100 * style.fontSizeAt1080Lines / SubtitleAppearance.default.fontSize.pointSize,
            kCMTextMarkupAttribute_CharacterEdgeStyle as String: edgeStyle(style),
        ]
        switch style.fontFamily {
        case .sansSerif:
            attributes[kCMTextMarkupAttribute_GenericFontFamilyName as String] = kCMTextMarkupGenericFontName_SansSerif as String
        case .serif:
            attributes[kCMTextMarkupAttribute_GenericFontFamilyName as String] = kCMTextMarkupGenericFontName_Serif as String
        case .monospace:
            attributes[kCMTextMarkupAttribute_GenericFontFamilyName as String] = kCMTextMarkupGenericFontName_Monospace as String
        case .custom(let name):
            attributes[kCMTextMarkupAttribute_FontFamilyName as String] = name
        }
        return attributes
    }

    private static func argb(_ color: AetherSubtitleRenderStyle.RGB, opacity: Double) -> [Double] {
        [opacity, color.red, color.green, color.blue]
    }

    private static func edgeStyle(_ style: AetherSubtitleRenderStyle) -> String {
        if style.drawsOutline { return kCMTextMarkupCharacterEdgeStyle_Uniform as String }
        if style.drawsRaisedEdge { return kCMTextMarkupCharacterEdgeStyle_Raised as String }
        if style.drawsDepressedEdge { return kCMTextMarkupCharacterEdgeStyle_Depressed as String }
        if style.drawsDropShadow { return kCMTextMarkupCharacterEdgeStyle_DropShadow as String }
        return kCMTextMarkupCharacterEdgeStyle_None as String
    }
}
