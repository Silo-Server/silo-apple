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
        var borderSize: Double
        /// `#RRGGBB` hex.
        var borderColorHex: String
        /// `#RRGGBB` hex.
        var backgroundColorHex: String
        var backgroundStyle: SubtitleBackgroundStylePreset
        /// 0-100 (opaque if >0).
        var backgroundOpacityPercent: Int
        var textOutline: Bool
        /// User position 0 (top) to 150 (bottom). Centered around 100.
        var verticalPosition: Int
        /// Subtitle sync offset in milliseconds. Positive = subs appear
        /// later; negative = earlier.
        var syncOffsetMs: Int

        var effectiveBorderSize: Double {
            if borderSize > 0 {
                return max(2, min(4, fontSize * 0.08))
            }
            return 0
        }

        var effectiveOutlineColorHex: String {
            backgroundStyle == .outline ? backgroundColorHex : borderColorHex
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
            backgroundStyle == .shadow ? 1.5 : boxPadding
        }

        /// Inverted ASS alpha byte for `BackColour` (0x00 opaque … 0xFF
        /// transparent). Box: user opacity. Shadow: 50% black so the drop
        /// shadow is actually visible. Otherwise fully transparent.
        var backgroundAlphaByte: UInt8 {
            switch backgroundStyle {
            case .box:
                return UInt8(max(0, min(255, (100 - backgroundOpacityPercent) * 255 / 100)))
            case .shadow:
                return 0x80
            case .outline, .none:
                return 0xFF
            }
        }

        static let referenceFontSize: Double = SubtitleAppearance.default.fontSize.pointSize

        static let `default` = Parameters(
            fontSize: referenceFontSize,
            fontFamilyName: "Arial",
            textColorHex: "#FFFFFF",
            borderSize: 0,
            borderColorHex: "#000000",
            backgroundColorHex: "#000000",
            backgroundStyle: .shadow,
            backgroundOpacityPercent: 0,
            textOutline: false,
            verticalPosition: 100,
            syncOffsetMs: 0
        )

        static func from(appearance: SubtitleAppearance, syncOffsetMs: Int) -> Parameters {
            let sanitized = appearance.sanitized()
            let outlineEnabled = sanitized.backgroundStyle == .outline || sanitized.textOutline
            return Parameters(
                fontSize: sanitized.fontSize.pointSize,
                fontFamilyName: sanitized.fontFamily.assFontName,
                textColorHex: sanitized.fontColor,
                borderSize: outlineEnabled ? 2 : 0,
                borderColorHex: sanitized.textOutlineColor,
                backgroundColorHex: sanitized.backgroundColor,
                backgroundStyle: sanitized.backgroundStyle,
                backgroundOpacityPercent: sanitized.backgroundStyle == .box ? sanitized.backgroundOpacity : 0,
                textOutline: sanitized.textOutline,
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
        let primary = assColor(hexRGB: params.textColorHex, alphaByte: 0x00)
        let outline = assColor(hexRGB: params.effectiveOutlineColorHex, alphaByte: 0x00)
        let back = assColor(hexRGB: params.backgroundColorHex, alphaByte: params.backgroundAlphaByte)
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
    ///   skip color/font/border overrides so the creative work renders
    ///   as the author intended. Sync offset still applies in the overlay
    ///   pump, outside libass style overrides.
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

        if isNativeASS {
            ass_set_font_scale(renderer, 1.0)
            ass_set_selective_style_override_enabled(renderer, 0)
            return
        }

        // Controlled text subtitles render through libass regardless of
        // source. Use renderer font scale for live size changes, but do not
        // use FONT_SIZE_FIELDS below: that path also overrides ScaleX/Y and
        // scales FontSize against each source track's PlayRes.
        let compensation = fontScaleCompensation.isFinite && fontScaleCompensation > 0
            ? fontScaleCompensation
            : 1.0
        let scale = (params.fontSize / Parameters.referenceFontSize) * compensation
        ass_set_font_scale(renderer, scale.isFinite && scale > 0 ? scale : 1.0)

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
        style.PrimaryColour = assColor(hexRGBUInt: params.textColorHex, alphaByte: 0x00)
        style.SecondaryColour = 0xFFFFFF00 // opaque white, internal RRGGBBAA
        style.OutlineColour = assColor(hexRGBUInt: params.effectiveOutlineColorHex, alphaByte: 0x00)
        style.BackColour = assColor(
            hexRGBUInt: params.backgroundColorHex,
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
        let bits: Int32 =
            Int32(ASS_OVERRIDE_BIT_FONT_NAME.rawValue) |
            Int32(ASS_OVERRIDE_BIT_SELECTIVE_FONT_SCALE.rawValue) |
            Int32(ASS_OVERRIDE_BIT_COLORS.rawValue) |
            Int32(ASS_OVERRIDE_BIT_ATTRIBUTES.rawValue) |
            Int32(ASS_OVERRIDE_BIT_BORDER.rawValue) |
            Int32(ASS_OVERRIDE_BIT_ALIGNMENT.rawValue) |
            Int32(ASS_OVERRIDE_BIT_MARGINS.rawValue)
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
