import SwiftUI

/// Visual recipes for badges. Mirrors `web/src/lib/overlays/presets.ts`.
/// Each preset owns shape + typography + density; per-badge variation is
/// limited to the icon (from the registry) and the accent color (from
/// the user). Stay in sync with the web side so a "vibrant" preset
/// looks consistent across platforms.
enum OverlayPresets {

    static func preset(_ id: PresetId) -> OverlayPreset {
        switch id {
        case .minimal: return minimal
        case .classic: return classic
        case .vibrant: return vibrant
        case .pill:    return pill
        case .square:  return square
        }
    }

    private static let minimal = OverlayPreset(
        id: .minimal,
        fontSize: 9,
        textWeight: .semibold,
        textCase: .uppercase,
        tracking: 1.2,
        horizontalPadding: 4,
        verticalPadding: 1,
        cornerStyle: .rounded(2),
        iconSize: 10,
        preferIcon: false,
        gap: 2,
        accentStrategy: .text,
        backgroundColor: { _ in .clear },
        foregroundColor: { accent in accent ?? Color.white.opacity(0.85) },
        borderColor: { _ in nil },
        backdropMaterial: nil,
        textShadow: true
    )

    private static let classic = OverlayPreset(
        id: .classic,
        fontSize: 10,
        textWeight: .semibold,
        textCase: .uppercase,
        tracking: 0.6,
        horizontalPadding: 8,
        verticalPadding: 3,
        cornerStyle: .capsule,
        iconSize: 11,
        preferIcon: false,
        gap: 4,
        accentStrategy: .background,
        backgroundColor: { accent in
            if let accent { return accent.mix(with: Color.black.opacity(0.6), amount: 0.72) }
            return Color.black.opacity(0.6)
        },
        foregroundColor: { _ in .white },
        borderColor: { _ in Color.white.opacity(0.15) },
        backdropMaterial: nil,
        textShadow: false
    )

    private static let vibrant = OverlayPreset(
        id: .vibrant,
        fontSize: 10,
        textWeight: .bold,
        textCase: .uppercase,
        tracking: 0.6,
        horizontalPadding: 8,
        verticalPadding: 3,
        cornerStyle: .rounded(6),
        iconSize: 12,
        preferIcon: true,
        gap: 4,
        accentStrategy: .background,
        backgroundColor: { accent in accent ?? Color(white: 0.86) },
        foregroundColor: { accent in accent == nil ? .black : .white },
        borderColor: { _ in nil },
        backdropMaterial: nil,
        textShadow: false
    )

    private static let pill = OverlayPreset(
        id: .pill,
        fontSize: 10,
        textWeight: .semibold,
        textCase: .uppercase,
        tracking: 0.6,
        horizontalPadding: 10,
        verticalPadding: 4,
        cornerStyle: .capsule,
        iconSize: 12,
        preferIcon: true,
        gap: 4,
        accentStrategy: .background,
        backgroundColor: { accent in
            let base = Color(red: 20/255, green: 20/255, blue: 30/255).opacity(0.7)
            if let accent { return accent.mix(with: base, amount: 0.8) }
            return base
        },
        foregroundColor: { _ in .white },
        borderColor: { _ in Color.white.opacity(0.15) },
        backdropMaterial: .ultraThinMaterial,
        textShadow: false
    )

    private static let square = OverlayPreset(
        id: .square,
        fontSize: 9,
        textWeight: .bold,
        textCase: .uppercase,
        tracking: 1.2,
        horizontalPadding: 6,
        verticalPadding: 2,
        cornerStyle: .rounded(2),
        iconSize: 10,
        preferIcon: false,
        gap: 2,
        accentStrategy: .border,
        backgroundColor: { _ in Color.black.opacity(0.8) },
        foregroundColor: { accent in accent ?? .white },
        borderColor: { accent in accent },
        backdropMaterial: nil,
        textShadow: false
    )
}

// MARK: - Color helpers

extension Color {

    /// Linear blend between `self` and `other`, where `amount=0` returns
    /// `other` and `amount=1` returns `self`. Used to mirror CSS's
    /// `color-mix(in srgb, accent X%, baseY%)` from the web presets.
    func mix(with other: Color, amount: CGFloat) -> Color {
        let a = max(0, min(1, amount))
        let lhs = self.rgbComponents
        let rhs = other.rgbComponents
        return Color(
            red:   lhs.r * a + rhs.r * (1 - a),
            green: lhs.g * a + rhs.g * (1 - a),
            blue:  lhs.b * a + rhs.b * (1 - a),
            opacity: lhs.o * a + rhs.o * (1 - a)
        )
    }

    /// Decompose a SwiftUI `Color` into RGBA floats. `UIColor.getRed`
    /// returns false for color spaces it can't bridge (rare — sRGB
    /// literals and hex-derived colors succeed). The earlier version
    /// of this function ignored the return value, which could leave
    /// `r/g/b` at zero on tvOS and produce a fully transparent
    /// classic/pill preset background. We now fall back to 50% gray
    /// so the blended background is at least visible.
    fileprivate var rgbComponents: (r: CGFloat, g: CGFloat, b: CGFloat, o: CGFloat) {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (r, g, b, a)
        }
        #endif
        return (0.5, 0.5, 0.5, 1)
    }

}
