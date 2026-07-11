import SwiftUI

// MARK: - Variants
//
// Each first-run screen gets a slightly different placement of Silo's cool
// signal glow. The canvas stays mostly black so authentication transitions
// naturally into the signed-in media experience.

struct AuroraVariant {
    var glowCenter: UnitPoint
    var lineHeight: CGFloat
    var intensity: Double

    static let welcome = AuroraVariant(glowCenter: UnitPoint(x: 0.72, y: 0.14), lineHeight: 0.38, intensity: 0.95)
    static let server = AuroraVariant(glowCenter: UnitPoint(x: 0.18, y: 0.30), lineHeight: 0.56, intensity: 0.72)
    static let connecting = AuroraVariant(glowCenter: UnitPoint(x: 0.50, y: 0.20), lineHeight: 0.46, intensity: 0.82)
    static let signIn = AuroraVariant(glowCenter: UnitPoint(x: 0.78, y: 0.25), lineHeight: 0.47, intensity: 0.86)
    static let profile = AuroraVariant(glowCenter: UnitPoint(x: 0.50, y: 0.42), lineHeight: 0.58, intensity: 0.72)
}

enum AuroraScrim {
    /// Strong darkening on the left for hero text laid directly on the art.
    case left
    /// Radial darkening at the edges so a centered glass card pops.
    case soft
    case none
}

// MARK: - Backdrop

struct AuroraBackdrop: View {
    var variant: AuroraVariant = .signIn
    var scrim: AuroraScrim = .soft

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Color.auroraNightBottom

                RadialGradient(
                    colors: [
                        Color.auroraAccent.opacity(0.08 * variant.intensity),
                        Color(hex: "#18212A").opacity(0.08 * variant.intensity),
                        .clear,
                    ],
                    center: variant.glowCenter,
                    startRadius: 0,
                    endRadius: max(w, h) * 0.72
                )

                AuroraSignalField(lineHeight: variant.lineHeight)
                    .opacity(variant.intensity)

                RadialGradient(
                    colors: [.clear, Color.black.opacity(0.72)],
                    center: variant.glowCenter,
                    startRadius: h * 0.16,
                    endRadius: h * 0.92
                )

                scrimView(w: w, h: h)

                LinearGradient(
                    colors: [Color.black.opacity(0.54), .clear],
                    startPoint: .top, endPoint: .bottom)
                    .frame(height: 220)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(width: w, height: h)
        }
        .background(Color.auroraNightBottom)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func scrimView(w _: CGFloat, h: CGFloat) -> some View {
        switch scrim {
        case .left:
            LinearGradient(stops: [
                .init(color: Color.black.opacity(0.94), location: 0),
                .init(color: Color.black.opacity(0.58), location: 0.34),
                .init(color: .clear, location: 0.72),
            ], startPoint: .leading, endPoint: .trailing)
        case .soft:
            RadialGradient(
                colors: [.clear, Color.black.opacity(0.76)],
                center: .center, startRadius: h * 0.18, endRadius: h * 0.95)
        case .none:
            Color.clear
        }
    }
}

// MARK: - Signal field

private struct AuroraSignalField: View {
    let lineHeight: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let y = size.height * lineHeight
            var path = Path()
            path.move(to: CGPoint(x: -size.width * 0.05, y: y + 80))
            path.addCurve(
                to: CGPoint(x: size.width * 1.05, y: y - 30),
                control1: CGPoint(x: size.width * 0.28, y: y - 120),
                control2: CGPoint(x: size.width * 0.68, y: y + 100)
            )
            ctx.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: [.clear, Color.auroraAccent.opacity(0.18), .clear]),
                    startPoint: CGPoint(x: 0, y: y),
                    endPoint: CGPoint(x: size.width, y: y)
                ),
                lineWidth: 1
            )

            for index in 0..<7 {
                let x = size.width * (0.08 + CGFloat(index) * 0.15)
                let dotY = y + sin(CGFloat(index) * 1.55) * 28
                let rect = CGRect(x: x - 2, y: dotY - 2, width: 4, height: 4)
                ctx.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(index == 4 ? 0.24 : 0.10)))
            }
        }
        .allowsHitTesting(false)
    }
}
