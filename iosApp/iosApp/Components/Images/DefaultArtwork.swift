import SwiftUI

/// What a poster, cover or still shows when the title has no artwork: the
/// Silo brand colours as a soft glow, the same for every title. The web and
/// Android clients draw the same glow, so keep these stops in step with them.
struct DefaultArtwork: View {
    private static let base = Color(hex: "#0B0C10")
    private static let scrim = Color(hex: "#08090C").opacity(0.35)

    var body: some View {
        GeometryReader { geometry in
            // Sized from the longer side so a poster and a still get the
            // same glow, only cropped differently.
            let side = max(geometry.size.width, geometry.size.height)
            ZStack {
                Self.base
                glow(.siloBrandBlue, opacity: 0.55, at: .topLeading, radius: side * 0.75)
                glow(.siloBrandOrange, opacity: 0.45, at: .bottomTrailing, radius: side * 0.6)
                glow(.siloBrandRed, opacity: 0.35, at: UnitPoint(x: 0.7, y: 0.3), radius: side * 0.5)
                Self.scrim
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func glow(_ color: Color, opacity: Double, at center: UnitPoint, radius: CGFloat) -> some View {
        RadialGradient(
            colors: [color.opacity(opacity), color.opacity(0)],
            center: center,
            startRadius: 0,
            endRadius: radius
        )
    }
}
