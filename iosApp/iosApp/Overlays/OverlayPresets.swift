import SwiftUI

/// Visual recipes for badges. Mirrors `web/src/lib/overlays/presets.ts`:
/// each preset owns shape, typography and density, and per-badge variation
/// is limited to the icon (from the registry) and the accent colour (from
/// the viewer). The numbers and colour expressions are the web's, so a
/// preset looks the same on every client.
///
/// On the web `minimal`, `vibrant` and `square` follow the theme's corner
/// radius. The apps have no theme radius, so they draw the web's default
/// theme: 8 for `minimal` and `square`, 10 for `vibrant`.
enum OverlayPresets {

    static func preset(_ id: PresetId) -> OverlayPreset {
        switch id {
        case .minimal: return minimal
        case .classic: return classic
        case .vibrant: return vibrant
        case .pill:    return pill
        case .square:  return square
        case .plate:   return plate
        case .band:    return band
        }
    }

    /// Tailwind's `tracking-wide` and `tracking-widest`.
    private static let trackingWide: CGFloat = 0.025
    private static let trackingWidest: CGFloat = 0.1

    private static let whiteBorder = OverlayColor.white.opacity(0.15)

    private static let minimal = OverlayPreset(
        id: .minimal,
        layout: .stack,
        sourceChips: false,
        fontSize: 9,
        fontWeight: .semibold,
        uppercase: true,
        trackingEm: trackingWidest,
        paddingInline: 4,
        paddingBlock: 0,
        cornerStyle: .rounded(8),
        borderWidth: nil,
        accentBarWidth: nil,
        textShadow: OverlayShadow(y: 1, blur: 2, color: .black.opacity(0.85)),
        boxShadow: nil,
        iconSize: 10,
        iconGap: 4,
        preferIcon: false,
        stackGap: 2,
        accentStrategy: .text,
        paint: { accent in
            OverlayBadgePaint(background: .clear, foreground: accent ?? .white.opacity(0.85))
        }
    )

    private static let classic = OverlayPreset(
        id: .classic,
        layout: .stack,
        sourceChips: false,
        fontSize: 10,
        fontWeight: .semibold,
        uppercase: true,
        trackingEm: trackingWide,
        paddingInline: 8,
        paddingBlock: 2,
        cornerStyle: .capsule,
        borderWidth: 1,
        accentBarWidth: nil,
        textShadow: nil,
        boxShadow: nil,
        iconSize: 11,
        iconGap: 4,
        preferIcon: false,
        stackGap: 4,
        accentStrategy: .background,
        paint: { accent in
            let base = OverlayColor.black.opacity(0.6)
            return OverlayBadgePaint(
                background: accent.map { $0.mixed(0.28, with: base) } ?? base,
                foreground: .white,
                border: whiteBorder
            )
        }
    )

    private static let vibrant = OverlayPreset(
        id: .vibrant,
        layout: .stack,
        sourceChips: false,
        fontSize: 10,
        fontWeight: .bold,
        uppercase: true,
        trackingEm: trackingWide,
        paddingInline: 8,
        paddingBlock: 2,
        cornerStyle: .rounded(10),
        borderWidth: nil,
        accentBarWidth: nil,
        textShadow: nil,
        boxShadow: OverlayShadow(y: 1, blur: 2, color: .black.opacity(0.25)),
        iconSize: 12,
        iconGap: 4,
        preferIcon: true,
        stackGap: 4,
        accentStrategy: .background,
        paint: { accent in
            OverlayBadgePaint(
                background: accent ?? OverlayColor(rgb: 220, 220, 220, alpha: 0.95),
                foreground: accent == nil ? .black : .white
            )
        }
    )

    private static let pill = OverlayPreset(
        id: .pill,
        layout: .stack,
        sourceChips: false,
        fontSize: 10,
        fontWeight: .semibold,
        uppercase: true,
        trackingEm: trackingWide,
        paddingInline: 10,
        paddingBlock: 4,
        cornerStyle: .capsule,
        borderWidth: 1,
        accentBarWidth: nil,
        textShadow: nil,
        boxShadow: nil,
        iconSize: 12,
        iconGap: 4,
        preferIcon: true,
        stackGap: 4,
        accentStrategy: .background,
        paint: { accent in
            let base = OverlayColor(rgb: 20, 20, 30, alpha: 0.7)
            return OverlayBadgePaint(
                background: accent.map { $0.mixed(0.2, with: base) } ?? base,
                foreground: .white,
                border: whiteBorder
            )
        }
    )

    private static let square = OverlayPreset(
        id: .square,
        layout: .stack,
        sourceChips: false,
        fontSize: 9,
        fontWeight: .bold,
        uppercase: true,
        trackingEm: trackingWidest,
        paddingInline: 6,
        paddingBlock: 2,
        cornerStyle: .rounded(8),
        borderWidth: nil,
        accentBarWidth: 2,
        textShadow: nil,
        boxShadow: nil,
        iconSize: 10,
        iconGap: 4,
        preferIcon: false,
        stackGap: 2,
        accentStrategy: .border,
        paint: { accent in
            OverlayBadgePaint(
                background: .black.opacity(0.8),
                foreground: accent ?? .white,
                accentBar: accent
            )
        }
    )

    private static let plate = OverlayPreset(
        id: .plate,
        layout: .stack,
        sourceChips: true,
        fontSize: 12,
        fontWeight: .heavy,
        uppercase: true,
        trackingEm: trackingWide,
        paddingInline: 7,
        paddingBlock: 4,
        cornerStyle: .rounded(6),
        borderWidth: 1,
        accentBarWidth: nil,
        textShadow: nil,
        boxShadow: OverlayShadow(y: 2, blur: 6, color: .black.opacity(0.35)),
        iconSize: 13,
        iconGap: 5,
        preferIcon: true,
        stackGap: 4,
        accentStrategy: .border,
        paint: { accent in
            OverlayBadgePaint(
                background: .black.opacity(0.72),
                foreground: .white,
                border: accent.map { $0.mixed(0.45, with: .clear) } ?? .white.opacity(0.1)
            )
        }
    )

    private static let band = OverlayPreset(
        id: .band,
        layout: .band,
        sourceChips: false,
        fontSize: 12.5,
        fontWeight: .heavy,
        uppercase: true,
        trackingEm: trackingWide,
        paddingInline: 0,
        paddingBlock: 1,
        cornerStyle: .rounded(0),
        borderWidth: nil,
        accentBarWidth: nil,
        textShadow: OverlayShadow(y: 1, blur: 3, color: .black.opacity(0.75)),
        boxShadow: nil,
        iconSize: 13,
        iconGap: 3,
        preferIcon: false,
        stackGap: 7,
        accentStrategy: .text,
        paint: { accent in
            OverlayBadgePaint(background: .clear, foreground: accent ?? .white)
        }
    )
}

// MARK: - Style overrides

extension OverlayPreset {
    /// The shadow a style's shadow switch adds to a preset that has none.
    private static let styleShadow = OverlayShadow(y: 2, blur: 6, color: .black.opacity(0.35))

    /// The least padding, as a share of the font size, a badge gets when the
    /// style gives it a fill or a border. Minimal and Edge band draw bare
    /// text with little or no padding; framed as they are, the letters run
    /// to the frame's edge and a pill's rounded ends cut into them.
    private static let framedPaddingInline: CGFloat = 0.6
    private static let framedPaddingBlock: CGFloat = 0.2

    /// From this opacity a fill, not the artwork, sits behind the text.
    private static let solidFillAlpha = 0.5

    /// The least contrast ratio at which accent-coloured text stays on a solid fill.
    private static let accentTextContrast = 3.0

    /// This preset with the viewer's style overrides applied. Mirrors
    /// `applyOverlayStyle` in `web/src/lib/overlays/style.ts`.
    ///
    /// The result is another preset, so the renderer does not care where a
    /// value came from. Per-badge accents keep working: a custom background
    /// is tinted by the accent in presets that fill with it, and a custom
    /// text or border colour yields to the accent in presets that paint the
    /// accent there. A solid fill without a chosen text colour gets black or
    /// white text, since the preset's own colour was picked to read on the
    /// artwork. An accent the preset writes as text that would not read on
    /// that fill tints it instead.
    func applying(_ style: OverlayStyle?) -> OverlayPreset {
        guard let style else { return self }
        var next = self
        let scale = CGFloat(style.size ?? 1)
        next.fontSize *= scale
        next.paddingInline *= scale
        next.paddingBlock *= scale
        next.iconSize *= scale
        next.iconGap *= scale
        next.stackGap *= scale
        switch style.fontWeight {
        case .regular: next.fontWeight = .regular
        case .semibold: next.fontWeight = .semibold
        case .extrabold: next.fontWeight = .heavy
        case nil: break
        }
        next.uppercase = style.uppercase ?? uppercase
        switch style.shape {
        case .pill: next.cornerStyle = .capsule
        case .rounded: next.cornerStyle = .rounded(6)
        case .square: next.cornerStyle = .rounded(2)
        case nil: break
        }
        if let borderWidth = style.borderWidth { next.borderWidth = CGFloat(borderWidth) }
        if style.shadow == false { next.boxShadow = nil }
        if style.shadow == true { next.boxShadow = boxShadow ?? Self.styleShadow }

        let background = style.background.flatMap(OverlayColor.init(hex:))
        let textColor = style.textColor.flatMap(OverlayColor.init(hex:))
        let borderColor = style.borderColor.flatMap(OverlayColor.init(hex:))
        let fillAlpha = background?.alpha ?? 0
        if fillAlpha > 0 || (style.borderWidth ?? 0) > 0 {
            next.paddingInline = max(next.paddingInline, next.fontSize * Self.framedPaddingInline)
            next.paddingBlock = max(next.paddingBlock, next.fontSize * Self.framedPaddingBlock)
        }
        let solidFill = fillAlpha >= Self.solidFillAlpha ? background : nil
        // A shadow drawn to lift text off the artwork only muddies it on a fill.
        if solidFill != nil { next.textShadow = nil }

        guard background != nil || textColor != nil || borderColor != nil || style.borderWidth != nil else {
            return next
        }
        let basePaint = paint
        let strategy = accentStrategy
        next.paint = { accent in
            var result = basePaint(accent)
            let accentText: Bool = {
                guard let accent, strategy == .text else { return false }
                guard let solidFill else { return true }
                return accent.contrast(with: solidFill) >= Self.accentTextContrast
            }()
            let accentFill = accent != nil && (strategy == .background || (strategy == .text && !accentText))
            if let background {
                result.background = accentFill ? (accent ?? background).mixed(0.3, with: background) : background
            }
            if let text = textColor ?? solidFill?.readableText, !accentText {
                result.foreground = text
            }
            if let borderColor, !(accent != nil && strategy == .border) {
                result.border = borderColor
            }
            return result
        }
        return next
    }
}
