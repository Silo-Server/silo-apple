import Foundation

/// Media-engine-free mapping from Silo's persisted/system caption appearance
/// to the values the Aether cue overlay needs.
struct AetherSubtitleRenderStyle: Equatable {
    struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double

        init(hex: String, fallback: RGB) {
            let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            guard value.count == 6, let packed = UInt64(value, radix: 16) else {
                self = fallback
                return
            }
            red = Double((packed >> 16) & 0xFF) / 255
            green = Double((packed >> 8) & 0xFF) / 255
            blue = Double(packed & 0xFF) / 255
        }

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        static let black = RGB(red: 0, green: 0, blue: 0)
        static let white = RGB(red: 1, green: 1, blue: 1)
    }

    enum FontFamily: Equatable {
        case sansSerif
        case serif
        case monospace
        case custom(String)
    }

    enum Position: Equatable {
        case bottom
        case lowerThird
        case top
    }

    let fontSizeAt1080Lines: Double
    let fontFamily: FontFamily
    let foreground: RGB
    let foregroundOpacity: Double
    let drawsBox: Bool
    let boxColor: RGB
    let boxOpacity: Double
    let drawsOutline: Bool
    let outlineColor: RGB
    let drawsRaisedEdge: Bool
    let drawsDepressedEdge: Bool
    let drawsDropShadow: Bool
    let windowColor: RGB
    let windowOpacity: Double
    let windowCornerRadiusAt1080Lines: Double
    let position: Position
    let contentOverrides: SystemCaptionContentOverrides

    init(appearance: SubtitleAppearance) {
        let appearance = appearance.sanitized()
        fontSizeAt1080Lines = appearance.systemRelativeFontScale.map {
            SubtitleAppearance.default.fontSize.pointSize * $0
        } ?? appearance.fontSize.pointSize
        switch appearance.fontFamily {
        case .serif:
            fontFamily = .serif
        case .monospace:
            fontFamily = .monospace
        case .sansSerif:
            fontFamily = .sansSerif
        default:
            fontFamily = .custom(appearance.fontFamily.assFontName)
        }
        foreground = RGB(hex: appearance.fontColor, fallback: .white)
        foregroundOpacity = Self.fraction(appearance.fontOpacity)
        drawsBox = appearance.backgroundStyle == .box && appearance.backgroundOpacity > 0
        boxColor = RGB(hex: appearance.backgroundColor, fallback: .black)
        boxOpacity = Self.fraction(appearance.backgroundOpacity)
        outlineColor = RGB(hex: appearance.textOutlineColor, fallback: .black)
        windowColor = RGB(hex: appearance.captionWindowColor, fallback: .black)
        windowOpacity = Self.fraction(appearance.captionWindowOpacity)
        windowCornerRadiusAt1080Lines = appearance.captionWindowCornerRadius
        contentOverrides = appearance.systemContentOverrides

        switch appearance.position {
        case .bottom: position = .bottom
        case .lowerThird: position = .lowerThird
        case .top: position = .top
        }

        if let systemEdge = appearance.systemTextEdgeStyle {
            drawsOutline = systemEdge == .uniform
            drawsRaisedEdge = systemEdge == .raised
            drawsDepressedEdge = systemEdge == .depressed
            drawsDropShadow = systemEdge == .dropShadow
        } else {
            drawsOutline = appearance.textOutline
            drawsRaisedEdge = false
            drawsDepressedEdge = false
            drawsDropShadow = appearance.backgroundStyle == .shadow
        }
    }

    private static func fraction(_ percent: Int) -> Double {
        Double(max(0, min(100, percent))) / 100
    }
}
