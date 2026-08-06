//
//  SubtitleAppearancePreview.swift
//  Continuum (iOS + tvOS + macOS)
//
//  Live approximation of the configured subtitle style over a dark
//  film-frame stand-in. The real pipeline renders through libass; this
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
        // Four hard directional shadows fake libass's uniform glyph
        // outline; a soft radius reads as a glow instead.
        let outlineOffset: CGFloat = max(1, sampleFontSize * 0.04)

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

    private var sampleFontSize: CGFloat {
        (appearance.systemRelativeFontScale.map {
            SubtitleStylingOverride.Parameters.referenceFontSize * $0
        } ?? appearance.fontSize.pointSize) * Self.fontScale
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
