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
        let size = appearance.fontSize.pointSize * Self.fontScale
        let font: Font = {
            switch appearance.fontFamily {
            case .serif: return .system(size: size, weight: .semibold, design: .serif)
            case .monospace: return .system(size: size, weight: .semibold, design: .monospaced)
            case .sansSerif: return .system(size: size, weight: .semibold)
            default: return .custom(appearance.fontFamily.assFontName, size: size)
            }
        }()
        let hasOutline = appearance.textOutline || appearance.backgroundStyle == .outline
        let outlineColor = hasOutline ? Color(hex: appearance.textOutlineColor) : .clear
        // Four hard directional shadows fake libass's uniform glyph
        // outline; a soft radius reads as a glow instead.
        let outlineOffset: CGFloat = max(1, size * 0.04)

        return Text(Self.sampleLine)
            .font(font)
            .multilineTextAlignment(.center)
            .foregroundStyle(Color(hex: appearance.fontColor))
            .shadow(color: outlineColor, radius: 0, x: outlineOffset, y: outlineOffset)
            .shadow(color: outlineColor, radius: 0, x: -outlineOffset, y: outlineOffset)
            .shadow(color: outlineColor, radius: 0, x: outlineOffset, y: -outlineOffset)
            .shadow(color: outlineColor, radius: 0, x: -outlineOffset, y: -outlineOffset)
            .shadow(
                color: appearance.backgroundStyle == .shadow ? .black.opacity(0.85) : .clear,
                radius: 3, y: 2
            )
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
}
