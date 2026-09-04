//
//  SubtitleAppearancePreview.swift
//  Continuum (iOS + tvOS + macOS)
//
//  Live approximation of the configured subtitle style over a dark
//  film-frame stand-in. The real pipeline renders Aether cues; this
//  mirrors the font / color / outline / background / position choices
//  closely enough to preview a change without starting playback.
//

import SwiftUI

struct SubtitleAppearancePreview: View {
    let appearance: SubtitleAppearance
    var height: CGFloat = Self.defaultHeight

    static let sampleLine = "Subtitles will look like this"

    #if os(tvOS)
    static let defaultHeight: CGFloat = 150
    private static let fontScale: CGFloat = 0.5
    #elseif os(macOS)
    static let defaultHeight: CGFloat = 130
    private static let fontScale: CGFloat = 0.3
    #else
    static let defaultHeight: CGFloat = 118
    private static let fontScale: CGFloat = 0.45
    #endif

    var body: some View {
        ZStack(alignment: alignment) {
            LinearGradient(
                colors: [Color(white: 0.32), Color(white: 0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            sampleText
                .padding(.vertical, appearance.position == .lowerThird ? height * 0.22 : 12)
                .padding(.horizontal, 16)
        }
        .frame(height: height)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Subtitle preview")
        .accessibilityValue(Text(Self.sampleLine))
    }

    private var alignment: Alignment {
        switch appearance.position {
        case .top: return .top
        case .lowerThird, .bottom: return .bottom
        }
    }

    private var sampleText: some View {
        glyphText
            .padding(.horizontal, appearance.captionWindowOpacity > 0 ? 6 : 0)
            .padding(.vertical, appearance.captionWindowOpacity > 0 ? 4 : 0)
            .background { captionWindowBackground }
    }

    private var glyphText: some View {
        let systemEdge = appearance.systemTextEdgeStyle
        let hasOutline = appearance.textOutline || appearance.backgroundStyle == .outline
            || systemEdge == .uniform
        let outlineColor = hasOutline ? Color(hex: appearance.textOutlineColor) : .clear
        // Four hard directional shadows approximate the cue overlay's uniform glyph
        // outline; a soft radius reads as a glow instead. The shared
        // formula's 1-2 clamp is calibrated for the 1080-line playfield,
        // so feed it the unscaled size and scale the result into preview
        // space — clamping post-scale would flatten the whole ladder.
        let outlineOffset = CGFloat(
            max(1, min(2, Double(playfieldFontSize) * 0.03))
        ) * Self.fontScale

        let raisedColor = systemEdge == .raised ? Color.white.opacity(0.8) : .clear
        let depressedColor = systemEdge == .depressed ? Color.black.opacity(0.9) : .clear
        let dropShadowColor = systemEdge == .dropShadow
            || appearance.backgroundStyle == .shadow ? Color.black.opacity(0.85) : .clear

        return Text(Self.sampleLine)
            .font(sampleFont)
            .multilineTextAlignment(.center)
            .foregroundStyle(
                Color(hex: appearance.fontColor)
                    .opacity(Double(appearance.fontOpacity) / 100)
            )
            .shadow(color: outlineColor, radius: 0, x: outlineOffset, y: outlineOffset)
            .shadow(color: outlineColor, radius: 0, x: -outlineOffset, y: outlineOffset)
            .shadow(color: outlineColor, radius: 0, x: outlineOffset, y: -outlineOffset)
            .shadow(color: outlineColor, radius: 0, x: -outlineOffset, y: -outlineOffset)
            .shadow(color: raisedColor, radius: 0, x: -outlineOffset, y: -outlineOffset)
            .shadow(color: depressedColor, radius: 0, x: outlineOffset, y: outlineOffset)
            .shadow(color: dropShadowColor, radius: 3, y: 2)
            .padding(.horizontal, appearance.backgroundStyle == .box ? 10 : 0)
            .padding(.vertical, appearance.backgroundStyle == .box ? 4 : 0)
            .background {
                if appearance.backgroundStyle == .box {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(hex: appearance.backgroundColor)
                            .opacity(Double(appearance.backgroundOpacity) / 100))
                }
            }
    }

    @ViewBuilder
    private var captionWindowBackground: some View {
        if appearance.captionWindowOpacity > 0 {
            RoundedRectangle(
                cornerRadius: appearance.captionWindowCornerRadius * Self.fontScale,
                style: .continuous
            )
            .fill(
                Color(hex: appearance.captionWindowColor)
                    .opacity(Double(appearance.captionWindowOpacity) / 100)
            )
        }
    }

    /// The size playback would use in the 1080-line ASS playfield, before
    /// the preview's own downscale. Shared styling formulas are calibrated
    /// against this, not against `sampleFontSize`.
    private var playfieldFontSize: CGFloat {
        AetherSubtitleRenderStyle(appearance: appearance).fontSizeAt1080Lines
    }

    private var sampleFontSize: CGFloat {
        playfieldFontSize * Self.fontScale
    }

    private var sampleFont: Font {
        switch appearance.fontFamily {
        case .serif: return .system(size: sampleFontSize, weight: .semibold, design: .serif)
        case .monospace: return .system(size: sampleFontSize, weight: .semibold, design: .monospaced)
        case .sansSerif: return .system(size: sampleFontSize, weight: .semibold)
        default: return .custom(appearance.fontFamily.assFontName, size: sampleFontSize)
        }
    }
}
