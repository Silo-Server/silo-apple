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
        backgroundColor: { _ in .clear },
        foregroundColor: { accent in accent ?? Color.white.opacity(0.85) },
        borderColor: { _ in nil },
        backdropMaterial: nil,
        textShadow: true
    )

    private static let classic = OverlayPreset(
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
        backgroundColor: { accent in
            if let accent {
                // Hex accents are opaque. Mix RGB separately from opacity to
                // preserve the existing straight-alpha sRGB recipe.
                return accent.mix(with: .black, by: 0.28, in: .device).opacity(0.888)
            }
            return Color.black.opacity(0.6)
        },
        foregroundColor: { _ in .white },
        borderColor: { _ in Color.white.opacity(0.15) },
        backdropMaterial: nil,
        textShadow: false
    )

    private static let vibrant = OverlayPreset(
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
        backgroundColor: { accent in accent ?? Color(white: 0.86) },
        foregroundColor: { accent in accent == nil ? .black : .white },
        borderColor: { _ in nil },
        backdropMaterial: nil,
        textShadow: false
    )

    private static let pill = OverlayPreset(
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
        backgroundColor: { accent in
            let base = Color(red: 20/255, green: 20/255, blue: 30/255)
            if let accent {
                return accent.mix(with: base, by: 0.2, in: .device).opacity(0.94)
            }
            return base.opacity(0.7)
        },
        foregroundColor: { _ in .white },
        borderColor: { _ in Color.white.opacity(0.15) },
        backdropMaterial: .ultraThinMaterial,
        textShadow: false
    )

    private static let square = OverlayPreset(
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
        backgroundColor: { _ in Color.black.opacity(0.8) },
        foregroundColor: { accent in accent ?? .white },
        borderColor: { accent in accent },
        backdropMaterial: nil,
        textShadow: false
    )
}
