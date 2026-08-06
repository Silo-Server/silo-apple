//
//  SubtitleStylingOverride.swift
//  Continuum (iOS + tvOS)
//
//  Bridges `PlayerSettings` (user's subtitle preferences) to libass. Two
//  consumer surfaces:
//
//    1. `syntheticHeader(...)` — produces an ASS `[Script Info]` +
//       `[V4+ Styles]` block with the user's preferences baked into the
//       Default style. Used by `VTTToASSConverter` and by synthesized
//       SRT→ASS wraps when we don't have an authored header.
//
//    2. `apply(to:isNativeASS:)` — applies `ass_set_selective_style_override`,
//       `ass_set_font_scale`, and `ass_set_line_position` to a live
//       ASS_Renderer. Generated ASS headers use a stable reference size;
//       live renderer font scale applies the user's selected size so the
//       setting updates immediately without depending on each track's
//       authored PlayRes.
//

import Foundation
import Libass

enum SubtitleStylingOverride {

    /// User-derived styling parameters. Snapshot of `PlayerSettings` at
    /// the time of capture — avoids threading `PlayerSettings.shared`
    /// deep into the subtitle pipeline.
    struct Parameters: Equatable {
        /// Baseline font size used for controlled text subtitle styles.
        var fontSize: Double
        var fontFamilyName: String
        /// `#RRGGBB` hex.
        var textColorHex: String
        /// 0-100.
        var textOpacityPercent: Int
        var borderSize: Double
        /// `#RRGGBB` hex.
        var borderColorHex: String
        /// `#RRGGBB` hex.
        var backgroundColorHex: String
        var backgroundStyle: SubtitleBackgroundStylePreset
        /// 0-100 (opaque if >0).
        var backgroundOpacityPercent: Int
        var textOutline: Bool
        var systemTextEdgeStyle: SystemCaptionTextEdgeStyle?
        /// Apple's separate box behind the complete caption cue.
        var captionWindowColorHex: String
        var captionWindowOpacityPercent: Int
        var captionWindowCornerRadius: Double
        var systemContentOverrides: SystemCaptionContentOverrides
        /// User position 0 (top) to 150 (bottom). Centered around 100.
        var verticalPosition: Int
        /// Subtitle sync offset in milliseconds. Positive = subs appear
        /// later; negative = earlier.
        var syncOffsetMs: Int

        var effectiveBorderSize: Double {
            if borderSize > 0 || systemTextEdgeStyle == .uniform
                || systemTextEdgeStyle == .raised || systemTextEdgeStyle == .depressed {
                return max(2, min(4, fontSize * 0.08))
            }
            return 0
        }

        /// The user's outline color applies to every outline the user asked
        /// for — both the Text Outline toggle and the legacy "outline"
        /// background style. (It previously borrowed `backgroundColorHex`
        /// for the legacy style, which contradicted the web player, the
        /// previews, and the settings UI that keeps the Background Color
        /// control disabled in that mode.)
        var effectiveOutlineColorHex: String {
            borderColorHex
        }

        /// True when the user wants a background box drawn behind the text.
        var boxEnabled: Bool {
            backgroundStyle == .box && backgroundOpacityPercent > 0
        }

        /// Padding of the background box around the text, in the 1080-line
        /// playfield. Passed through the ASS `Shadow` field: libass's
        /// BorderStyle 4 uses the shadow size as box padding (and skips the
        /// drop shadow itself).
        var boxPadding: Double {
            guard boxEnabled else { return 0 }
            #if os(iOS) || os(tvOS)
            // Tighter box: roughly half the original padding.
            return max(2, min(7, fontSize * 0.08))
            #else
            return max(3, min(12, fontSize * 0.15))
            #endif
        }

        /// ASS border style: 4 draws a per-event background rectangle
        /// filled with `BackColour` (honoring its alpha), unlike 3 whose
        /// box is per glyph run and filled with the *outline* colour at
        /// full opacity — which is why 3 can't do translucent boxes.
        var assBorderStyle: Int {
            boxEnabled ? 4 : 1
        }

        /// Value for the ASS `Shadow` field: drop-shadow depth for the
        /// shadow style, box padding for the box style (see `boxPadding`).
        var assShadow: Double {
            // BorderStyle 4 consumes Shadow as box padding and never draws
            // the shadow. The compositor adds Apple's requested edge behind
            // the glyphs separately in this combination.
            if boxEnabled { return boxPadding }
            if systemTextEdgeStyle == .dropShadow { return 1.5 }
            // Parsed V4+ Style Shadow is a non-negative depth. Raised needs
            // an up/left offset, so the compositor supplies that direction.
            if systemTextEdgeStyle == .raised { return 0 }
            if systemTextEdgeStyle == .depressed { return 1.0 }
            return backgroundStyle == .shadow ? 1.5 : 0
        }

        var textAlphaByte: UInt8 {
            UInt8(max(0, min(255, (100 - textOpacityPercent) * 255 / 100)))
        }

        /// BackColour is the glyph box under BorderStyle 4 and the edge
        /// shadow under BorderStyle 1. Keep those meanings separate so every
        /// Apple edge remains visible when no glyph box is active.
        var effectiveBackColorHex: String {
            if boxEnabled { return backgroundColorHex }
            switch systemTextEdgeStyle {
            case .some(.raised):
                return "#FFFFFF"
            case .some(.depressed), .some(.dropShadow):
                return "#000000"
            case .some(.none), .some(.uniform), nil:
                return backgroundColorHex
            }
        }

        /// Inverted ASS alpha byte for `BackColour` (0x00 opaque … 0xFF
        /// transparent).
        var backgroundAlphaByte: UInt8 {
            if boxEnabled {
                return UInt8(max(0, min(255, (100 - backgroundOpacityPercent) * 255 / 100)))
            }
            switch systemTextEdgeStyle {
            case .some(.raised):
                return 0x33
            case .some(.depressed):
                return 0x1A
            case .some(.dropShadow):
                return 0x80
            case .some(.none), .some(.uniform), nil:
                break
            }
            if backgroundStyle == .shadow {
                return 0x80
            }
            return 0xFF
        }

        /// BorderStyle 4 cannot combine its glyph box with a libass shadow.
        /// The compositor draws this edge from the character masks before it
        /// composites the regular libass image list.
        var compositedEdgeShadow: (
            offsetX: Double,
            offsetY: Double,
            colorHex: String,
            opacityPercent: Int
        )? {
            switch systemTextEdgeStyle {
            case .some(.raised):
                return (-1, -1, "#FFFFFF", 80)
            case .some(.depressed):
                return boxEnabled ? (1, 1, "#000000", 90) : nil
            case .some(.dropShadow):
                return boxEnabled ? (1.5, 1.5, "#000000", 50) : nil
            case .some(.none), .some(.uniform), nil:
                return nil
            }
        }

        var nativeForegroundColorOverride: (UInt8, UInt8, UInt8)? {
            systemContentOverrides.contains(.foregroundColor)
                ? SubtitleStylingOverride.rgbBytes(fromHex: textColorHex)
                : nil
        }

        var nativeForegroundAlphaOverride: UInt8? {
            systemContentOverrides.contains(.foregroundOpacity)
                ? UInt8(max(0, min(255, textOpacityPercent * 255 / 100)))
                : nil
        }

        var nativeBackgroundColorOverride: (UInt8, UInt8, UInt8)? {
            systemContentOverrides.contains(.backgroundColor)
                ? SubtitleStylingOverride.rgbBytes(fromHex: backgroundColorHex)
                : nil
        }

        var nativeBackgroundAlphaOverride: UInt8? {
            systemContentOverrides.contains(.backgroundOpacity)
                ? UInt8(max(0, min(255, backgroundOpacityPercent * 255 / 100)))
                : nil
        }

        static let referenceFontSize: Double = SubtitleAppearance.default.fontSize.pointSize

        static let `default` = Parameters(
            fontSize: referenceFontSize,
            fontFamilyName: "Arial",
            textColorHex: "#FFFFFF",
            textOpacityPercent: 100,
            borderSize: 0,
            borderColorHex: "#000000",
            backgroundColorHex: "#000000",
            backgroundStyle: .shadow,
            backgroundOpacityPercent: 0,
            textOutline: false,
            systemTextEdgeStyle: nil,
            captionWindowColorHex: "#000000",
            captionWindowOpacityPercent: 0,
            captionWindowCornerRadius: 0,
            systemContentOverrides: [],
            verticalPosition: 100,
            syncOffsetMs: 0
        )

        static func from(appearance: SubtitleAppearance, syncOffsetMs: Int) -> Parameters {
            let sanitized = appearance.sanitized()
            let outlineEnabled = sanitized.backgroundStyle == .outline || sanitized.textOutline
            return Parameters(
                fontSize: sanitized.systemRelativeFontScale.map {
                    referenceFontSize * $0
                } ?? sanitized.fontSize.pointSize,
                fontFamilyName: sanitized.fontFamily.assFontName,
                textColorHex: sanitized.fontColor,
                textOpacityPercent: sanitized.fontOpacity,
                borderSize: outlineEnabled ? 2 : 0,
                borderColorHex: sanitized.textOutlineColor,
                backgroundColorHex: sanitized.backgroundColor,
                backgroundStyle: sanitized.backgroundStyle,
                backgroundOpacityPercent: sanitized.backgroundStyle == .box ? sanitized.backgroundOpacity : 0,
                textOutline: sanitized.textOutline,
                systemTextEdgeStyle: sanitized.systemTextEdgeStyle,
                captionWindowColorHex: sanitized.captionWindowColor,
                captionWindowOpacityPercent: sanitized.captionWindowOpacity,
                captionWindowCornerRadius: sanitized.captionWindowCornerRadius,
                systemContentOverrides: sanitized.systemContentOverrides,
                verticalPosition: sanitized.position.legacyPosition,
                syncOffsetMs: syncOffsetMs
            )
        }
    }

    // MARK: - Synthetic ASS header

    /// Build a complete ASS script header with the user's preferences
    /// applied to a `Default` style. Callers append an `[Events]` header
    /// plus their own Dialogue lines. Used by `VTTToASSConverter` and by
    /// the SRT-fallback path.
    ///
    /// - Parameter params: user preferences snapshot.
    /// - Parameter slot: primary slot places subtitles near the bottom
    ///   (ASS alignment 2), secondary near the top (alignment 8).
    static func syntheticHeader(
        params: Parameters,
        slot: SubtitleSlot
    ) -> String {
        let primary = assColor(hexRGB: params.textColorHex, alphaByte: params.textAlphaByte)
        let outline = assColor(hexRGB: params.effectiveOutlineColorHex, alphaByte: 0x00)
        let back = assColor(hexRGB: params.effectiveBackColorHex, alphaByte: params.backgroundAlphaByte)
        let alignment = (slot == .secondary) ? 8 : primaryHeaderAlignment(for: params)

        // BorderStyle 1 = outline + shadow; BorderStyle 4 = per-event
        // background box filled with BackColour (so its alpha carries the
        // user's opacity). The Shadow field doubles as box padding under
        // BorderStyle 4 — see `Parameters.assShadow`.
        let borderStyle = params.assBorderStyle
        let shadow = params.assShadow
        let borderSize = params.effectiveBorderSize

        // Playfield resolution. 1920x1080 is the cross-industry default —
        // margin values in pixels are interpreted against it, so subs
        // will render at consistent relative positions no matter what
        // the actual video resolution is. `ass_set_frame_size` on the
        // renderer handles the mapping to the actual overlay.
        let playResX = 1920
        let playResY = 1080

        // MarginV is a distance from the bottom (alignment 2) or top
        // (alignment 8) edge. Primary positions use anchored margins so
        // Bottom sits close to the video edge, Lower Third remains below
        // the vertical midpoint, and Top is actually top-aligned.
        let marginV = slot == .secondary ? 60 : primaryMarginV(for: params)

        var s = ""
        s += "[Script Info]\n"
        s += "ScriptType: v4.00+\n"
        s += "PlayResX: \(playResX)\n"
        s += "PlayResY: \(playResY)\n"
        s += "ScaledBorderAndShadow: yes\n"
        s += "WrapStyle: 0\n"
        s += "Kerning: yes\n"
        s += "\n"
        s += "[V4+ Styles]\n"
        s += "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding\n"
        s += "Style: Default,"
        s += "\(params.fontFamilyName),"                       // Fontname
        s += "\(Int(Parameters.referenceFontSize.rounded()))," // Fontsize
        s += "\(primary),"                                     // PrimaryColour
        s += "&H00FFFFFF,"                                     // SecondaryColour (karaoke flash)
        s += "\(outline),"                                     // OutlineColour
        s += "\(back),"                                        // BackColour
        s += "0,0,0,0,"                                        // Bold, Italic, Underline, StrikeOut
        s += "100,100,"                                        // ScaleX, ScaleY
        s += "0,0,"                                            // Spacing, Angle
        s += "\(borderStyle),"                                 // BorderStyle
        s += "\(borderSize),"                                  // Outline / box padding
        s += "\(shadow),"                                      // Shadow
        s += "\(alignment),"                                   // Alignment
        s += "60,60,\(marginV),"                               // MarginL, MarginR, MarginV
        s += "1\n"                                             // Encoding
        s += "\n"
        s += "[Events]\n"
        s += "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
        return s
    }

    // MARK: - Live renderer overrides

    /// Apply user overrides to a live `ASS_Renderer`. Call any time
    /// `PlayerSettings` changes or a new track is installed.
    ///
    /// - Parameter renderer: the shared `ASS_Renderer*` wrapped in an
    ///   `OpaquePointer` (since Swift can't name libass's forward-declared
    ///   struct types directly).
    /// - Parameter params: user preferences snapshot.
    /// - Parameter isNativeASS: true iff the active track was authored
    ///   as ASS/SSA (codec == AV_CODEC_ID_ASS / _SSA). For native ASS we
    ///   preserve authored styling unless Apple's active caption profile marks
    ///   a category as `useValue` (the user disabled Video Overrides Style).
    /// - Parameter slot: which subtitle slot this renderer draws. Only the
    ///   primary slot participates in `use_margins` placement below.
    /// - Parameter fontScaleCompensation: multiplier that re-keys libass's
    ///   font scaling from the video area (frame minus letterbox margins)
    ///   back to the full frame, so Silo-styled text renders at the same
    ///   physical size regardless of the content's aspect ratio. 1.0 when
    ///   the overlay is video-rect sized (no margins). Native ASS is never
    ///   compensated — authored typesetting must keep tracking the picture.
    static func apply(
        renderer: OpaquePointer?,
        params: Parameters,
        isNativeASS: Bool,
        slot: SubtitleSlot,
        fontScaleCompensation: Double = 1.0
    ) {
        guard let renderer else { return }

        // libass line_position collapses multi-line cues onto the override
        // position. Use margins/alignment from the style override instead.
        ass_set_line_position(renderer, 0)

        // `use_margins` lets regular (non-\pos) events render across the
        // full overlay frame instead of only the video area, so the
        // "Bottom" preset can sit in the letterbox bar below the picture
        // when the overlay extends past the video rect (tvOS). Margins are
        // zero when the overlay is video-rect sized, making this a no-op
        // elsewhere. Native ASS keeps authored layout inside the video.
        let useMargins = !isNativeASS && slot == .primary && params.verticalPosition >= 100
        ass_set_use_margins(renderer, useMargins ? 1 : 0)

        if isNativeASS && params.systemContentOverrides.isEmpty {
            ass_set_font_scale(renderer, 1.0)
            ass_set_selective_style_override_enabled(renderer, 0)
            return
        }

        // Controlled text subtitles render through libass regardless of
        // source. Use renderer font scale for live size changes, but do not
        // use FONT_SIZE_FIELDS below: that path also overrides ScaleX/Y and
        // scales FontSize against each source track's PlayRes.
        let compensation = !isNativeASS && fontScaleCompensation.isFinite && fontScaleCompensation > 0
            ? fontScaleCompensation
            : 1.0
        let scale = (params.fontSize / Parameters.referenceFontSize) * compensation
        let shouldScaleFont = !isNativeASS || params.systemContentOverrides.contains(.size)
        ass_set_font_scale(renderer, shouldScaleFont && scale.isFinite && scale > 0 ? scale : 1.0)

        // Swift's `ASS_Style()` already zero-initialises the struct.
        // Pointer fields (`Name`, `FontName`) are nil which violates the
        // libass "must be non-NULL" contract, but we assign both below.
        var style = ASS_Style()

        // `Name` / `FontName` are `char*` and libass copies the strings
        // internally on `ass_set_selective_style_override`, so strdup'd
        // buffers can be freed after the call.
        let nameCString = strdup("Override")
        let fontCString = strdup(params.fontFamilyName)
        defer {
            free(nameCString)
            free(fontCString)
        }
        style.Name = nameCString
        style.FontName = fontCString
        style.FontSize = params.fontSize
        style.PrimaryColour = assColor(hexRGBUInt: params.textColorHex, alphaByte: params.textAlphaByte)
        style.SecondaryColour = 0xFFFFFF00 // opaque white, internal RRGGBBAA
        style.OutlineColour = assColor(hexRGBUInt: params.effectiveOutlineColorHex, alphaByte: 0x00)
        style.BackColour = assColor(
            hexRGBUInt: params.effectiveBackColorHex,
            alphaByte: params.backgroundAlphaByte
        )
        // ScaleX/Y are doubles where 1.0 = 100%. The integer 100 here
        // would scale text to 100x authored size (10,000%).
        style.ScaleX = 1.0
        style.ScaleY = 1.0
        style.Spacing = 0
        style.Blur = 0
        // Outline + shadow: both scale with `ScaledBorderAndShadow: yes`
        // in the authored header, so keep them small relative to the
        // authored FontSize=16 grid. Default 0.5 outline + 1.5 shadow
        // matches the web player's "shadow" default (no heavy outline).
        style.Outline = params.effectiveBorderSize
        style.Shadow = params.assShadow
        style.BorderStyle = Int32(params.assBorderStyle)
        style.Alignment = Int32(primaryStyleAlignment(for: params))
        style.MarginL = 60
        style.MarginR = 60
        style.MarginV = Int32(primaryMarginV(for: params))
        style.Encoding = 1

        ass_set_selective_style_override(renderer, &style)

        // Override only fields we populate. Do not include
        // FONT_SIZE_FIELDS: it also overrides ScaleX/Y/Blur/Spacing and
        // scales FontSize against the source track's PlayRes, which makes
        // identical user sizes render differently across subtitle sources.
        let bits: Int32
        if isNativeASS {
            var systemBits: Int32 = 0
            if params.systemContentOverrides.contains(.font) {
                systemBits |= Int32(ASS_OVERRIDE_BIT_FONT_NAME.rawValue)
            }
            if params.systemContentOverrides.contains(.size) {
                systemBits |= Int32(ASS_OVERRIDE_BIT_SELECTIVE_FONT_SCALE.rawValue)
            }
            // libass exposes color override as one atomic bit spanning
            // Primary, Secondary, Outline, and BackColour. Apple exposes
            // foreground/background color and opacity precedence separately,
            // so native ASS colors are transformed per image type by the
            // compositor instead of enabling the lossy category-wide bit.
            // Border is another atomic libass category: BorderStyle,
            // Outline, and Shadow are replaced together. Apple gives the
            // edge its own precedence, independent of the caption
            // background. Native ASS edge overrides are therefore composed
            // from glyph masks after rendering instead of enabling this bit.
            bits = systemBits
        } else {
            bits =
                Int32(ASS_OVERRIDE_BIT_FONT_NAME.rawValue) |
                Int32(ASS_OVERRIDE_BIT_SELECTIVE_FONT_SCALE.rawValue) |
                Int32(ASS_OVERRIDE_BIT_COLORS.rawValue) |
                Int32(ASS_OVERRIDE_BIT_ATTRIBUTES.rawValue) |
                Int32(ASS_OVERRIDE_BIT_BORDER.rawValue) |
                Int32(ASS_OVERRIDE_BIT_ALIGNMENT.rawValue) |
                Int32(ASS_OVERRIDE_BIT_MARGINS.rawValue)
        }
        ass_set_selective_style_override_enabled(renderer, bits)
    }

    // MARK: - Color encoding

    private static func primaryMarginV(for params: Parameters) -> Int {
        let p = max(0, min(150, params.verticalPosition))

        if primaryHeaderAlignment(for: params) == 8 {
            return 70
        }

        // Bottom-aligned ASS margins are distance from the bottom edge:
        // smaller values render lower.
        #if os(tvOS)
        // tvOS: "Lower Third" hugs the video's bottom edge (Bottom's old
        // anchor), while "Bottom" is measured against the full TV frame —
        // `use_margins` in `apply(...)` drops it into the letterbox bar
        // below the picture when one exists — with a slightly larger
        // margin so it doesn't sit flush against the frame edge.
        switch p {
        case 0...70:
            return 30
        case 71...100:
            return 60
        default:
            return interpolateMargin(position: p, from: 100, to: 150, marginFrom: 60, marginTo: 10)
        }
        #else
        // Anchor the bottom-aligned presets:
        //   lower-third (70) -> 220px
        //   bottom (100)     -> 30px
        //   extreme (150)    -> 10px
        switch p {
        case 0...100:
            return interpolateMargin(position: p, from: 70, to: 100, marginFrom: 220, marginTo: 30)
        default:
            return interpolateMargin(position: p, from: 100, to: 150, marginFrom: 30, marginTo: 10)
        }
        #endif
    }

    private static func primaryHeaderAlignment(for params: Parameters) -> Int {
        params.verticalPosition <= 0 ? 8 : 2
    }

    private static func primaryStyleAlignment(for params: Parameters) -> Int {
        // ASS document styles use numeric alignment values (8 = top-center).
        // libass's ASS_Style struct stores bit flags instead:
        // VALIGN_TOP(4) | HALIGN_CENTER(2) = 6.
        params.verticalPosition <= 0 ? 6 : 2
    }

    private static func interpolateMargin(
        position: Int,
        from startPosition: Int,
        to endPosition: Int,
        marginFrom startMargin: Int,
        marginTo endMargin: Int
    ) -> Int {
        guard endPosition != startPosition else { return endMargin }
        let t = Double(position - startPosition) / Double(endPosition - startPosition)
        let margin = Double(startMargin) + (Double(endMargin - startMargin) * t)
        return Int(margin.rounded())
    }

    /// ASS color format (string form, used in header): `&HAABBGGRR`
    /// where AA is inverted alpha (00 = opaque, FF = transparent).
    private static func assColor(hexRGB: String, alphaByte: UInt8) -> String {
        let (r, g, b) = rgbBytes(fromHex: hexRGB)
        return String(format: "&H%02X%02X%02X%02X", alphaByte, b, g, r)
    }

    /// libass internal color format (numeric form, used in `ASS_Style`
    /// struct fields): `0xRRGGBBAA` with inverted alpha in the low byte
    /// (00 = opaque, FF = transparent). This is what libass's own parser
    /// produces (`parse_color_tag` byte-swaps the file-format `&HAABBGGRR`
    /// value) and what `ass_set_selective_style_override` copies verbatim —
    /// it is NOT the ASS file format. Internal for tests.
    static func assColor(hexRGBUInt: String, alphaByte: UInt8) -> UInt32 {
        let (r, g, b) = rgbBytes(fromHex: hexRGBUInt)
        return (UInt32(r) << 24) | (UInt32(g) << 16) | (UInt32(b) << 8) | UInt32(alphaByte)
    }

    /// Parse `#RRGGBB` (or `RRGGBB`) into raw bytes. Falls back to
    /// white on malformed input — the entire styling path treats bad
    /// hex as "don't override", matching libass's silent fallback.
    /// Internal so generated ASS header code can share the same routine.
    static func rgbBytes(fromHex hex: String) -> (UInt8, UInt8, UInt8) {
        let trimmed = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard trimmed.count == 6, let v = UInt32(trimmed, radix: 16) else {
            return (0xFF, 0xFF, 0xFF)
        }
        let r = UInt8((v >> 16) & 0xFF)
        let g = UInt8((v >> 8) & 0xFF)
        let b = UInt8(v & 0xFF)
        return (r, g, b)
    }
}
