import SwiftUI

/// A straight-alpha sRGB colour. The web presets are written as CSS colour
/// expressions (`color-mix`, contrast checks); this does the same maths so a
/// badge is the same colour on every client.
struct OverlayColor: Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let white = OverlayColor(red: 1, green: 1, blue: 1)
    static let black = OverlayColor(red: 0, green: 0, blue: 0)
    static let clear = OverlayColor(red: 0, green: 0, blue: 0, alpha: 0)

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Channels as CSS writes them, 0–255.
    init(rgb red: Double, _ green: Double, _ blue: Double, alpha: Double = 1) {
        self.init(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }

    /// `#RRGGBB` or `#RRGGBBAA`; `nil` for anything else.
    init?(hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        let digits = hex.dropFirst()
        guard digits.count == 6 || digits.count == 8,
              digits.allSatisfy(\.isHexDigit),
              let value = UInt64(digits, radix: 16) else { return nil }
        let rgb = digits.count == 8 ? value >> 8 : value
        self.init(
            rgb: Double(rgb >> 16 & 0xFF), Double(rgb >> 8 & 0xFF), Double(rgb & 0xFF),
            alpha: digits.count == 8 ? Double(value & 0xFF) / 255 : 1
        )
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    func opacity(_ alpha: Double) -> OverlayColor {
        var copy = self
        copy.alpha = alpha
        return copy
    }

    /// CSS `color-mix(in srgb, self share, other)`: `share` of this colour and
    /// the rest of `other`, interpolated on premultiplied channels.
    func mixed(_ share: Double, with other: OverlayColor) -> OverlayColor {
        let rest = 1 - share
        let mixedAlpha = alpha * share + other.alpha * rest
        guard mixedAlpha > 0 else { return .clear }
        func channel(_ mine: Double, _ theirs: Double) -> Double {
            (mine * alpha * share + theirs * other.alpha * rest) / mixedAlpha
        }
        return OverlayColor(
            red: channel(red, other.red),
            green: channel(green, other.green),
            blue: channel(blue, other.blue),
            alpha: mixedAlpha
        )
    }

    /// WCAG relative luminance, ignoring alpha.
    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio against `other`.
    func contrast(with other: OverlayColor) -> Double {
        let lighter = max(luminance, other.luminance)
        let darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Black or white, whichever reads better on this colour as a fill.
    var readableText: OverlayColor {
        luminance > 0.4 ? .black : .white
    }
}
