import SwiftUI

/// What a poster, cover or still shows when the title has no artwork: a faint
/// glow in the Silo brand colours with a small mark for the item's type
/// (`ArtworkPlaceholderSymbol`), or no mark when `symbol` is nil. The web and
/// Android clients draw the same thing, so keep these values in step with them.
struct DefaultArtwork: View {
    var symbol: String? = ArtworkPlaceholderSymbol.fallback

    private static let base = Color(hex: "#16171C")
    private static let markOpacity = 0.13
    #if os(tvOS)
    private static let markWidthRange: ClosedRange<CGFloat> = 14...64
    #else
    private static let markWidthRange: ClosedRange<CGFloat> = 14...40
    #endif

    var body: some View {
        GeometryReader { geometry in
            // Sized from the longer side so a poster and a still get the
            // same glow, only cropped differently.
            let side = max(geometry.size.width, geometry.size.height)
            ZStack {
                Self.base
                glow(.siloBrandBlue, opacity: 0.176, at: .topLeading, radius: side * 0.75)
                glow(.siloBrandOrange, opacity: 0.144, at: .bottomTrailing, radius: side * 0.6)
                glow(.siloBrandRed, opacity: 0.112, at: UnitPoint(x: 0.7, y: 0.3), radius: side * 0.5)
                if let symbol {
                    mark(symbol, width: markWidth(for: geometry.size.width))
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func markWidth(for boxWidth: CGFloat) -> CGFloat {
        min(max(boxWidth * 0.24, Self.markWidthRange.lowerBound), Self.markWidthRange.upperBound)
    }

    private func glow(_ color: Color, opacity: Double, at center: UnitPoint, radius: CGFloat) -> some View {
        RadialGradient(
            colors: [color.opacity(opacity), color.opacity(0)],
            center: center,
            startRadius: 0,
            endRadius: radius
        )
    }

    /// Drawn into a canvas, like `ArtworkPlaceholderGlyph`, so the symbol's
    /// own label ("Movie", "Tv") never reaches the UI-automation tree.
    private func mark(_ symbol: String, width: CGFloat) -> some View {
        Canvas { context, size in
            var glyph = context.resolve(
                Image(systemName: symbol).resizable()
            )
            glyph.shading = .color(.white.opacity(Self.markOpacity))
            let natural = glyph.size
            guard natural.width > 0 else { return }
            let height = width * natural.height / natural.width
            let rect = CGRect(
                x: (size.width - width) / 2,
                y: (size.height - height) / 2,
                width: width,
                height: height
            )
            context.draw(glyph, in: rect)
        }
    }
}
