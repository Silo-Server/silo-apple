import SwiftUI

// MARK: - First-run palette
//
// First-run aliases of the core palette.

extension Color {
    static let auroraInk = Color.siloOnSurface
    static let auroraAccent = Color.siloBrandOrange
    static let auroraNightBottom = Color.siloBackground
    static let auroraGlassTint = Color.siloSurfaceVariant

    static var auroraInkSecondary: Color { auroraInk.opacity(0.62) }
}

// MARK: - Liquid glass panel

struct AuroraGlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 28

    func body(content: Content) -> some View {
        content
            .siloGlass(in: RoundedRectangle(cornerRadius: cornerRadius),
                       tint: Color.auroraGlassTint.opacity(0.72))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Self.borderGradient, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.55), radius: 36, x: 0, y: 22)
    }

    private static let borderGradient = LinearGradient(
        colors: [.white.opacity(0.22), .white.opacity(0.08), .white.opacity(0.03)],
        startPoint: .top, endPoint: .bottom)
}

extension View {
    func auroraGlass(cornerRadius: CGFloat = 28) -> some View {
        modifier(AuroraGlassPanel(cornerRadius: cornerRadius))
    }
}

// MARK: - Primary button

struct AuroraPrimaryButtonStyle: ButtonStyle {
    var isLoading: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        AuroraPrimaryBody(configuration: configuration, isLoading: isLoading)
    }
}

private struct AuroraPrimaryBody: View {
    let configuration: ButtonStyle.Configuration
    let isLoading: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            if isLoading {
                ProgressView()
                    .tint(Color.siloBackground)
                    .scaleEffect(0.8)
            }
            configuration.label
        }
        .font(.system(size: buttonFontSize, weight: .semibold))
        .foregroundStyle(Color.siloBackground)
        .frame(maxWidth: .infinity)
        .frame(minHeight: AuroraControl.height)
        .padding(.horizontal, buttonHorizontalPadding)
        .background(
            RoundedRectangle(cornerRadius: AuroraControl.corner)
                .fill(Color.siloOnSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AuroraControl.corner)
                .stroke(isFocused ? Color.auroraAccent : .clear, lineWidth: 3)
        )
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: AuroraControl.corner)
                    .stroke(Color.auroraAccent.opacity(0.4), lineWidth: 6)
                    .padding(-4)
                    .blur(radius: 6)
            }
        }
        .scaleEffect(isFocused && !reduceMotion ? 1.035 : 1.0)
        .shadow(
            color: isFocused ? Color.auroraAccent.opacity(0.28) : .black.opacity(0.3),
            radius: isFocused ? 20 : 10, y: 6)
        .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.75 : 1.0)
        .focusEffectDisabled()
        .animation(SiloTheme.springAnimation, value: isFocused)
    }

    #if os(tvOS)
    private let buttonFontSize: CGFloat = 24
    private let buttonHorizontalPadding: CGFloat = 30
    #else
    private let buttonFontSize: CGFloat = 17
    private let buttonHorizontalPadding: CGFloat = 20
    #endif
}

// MARK: - Secondary button

struct AuroraGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AuroraGhostBody(configuration: configuration)
    }
}

private struct AuroraGhostBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused

    // tvOS uses 10-foot sizing; iOS/macOS need a normal tertiary-button scale.
    #if os(tvOS)
    private let fontSize: CGFloat = 22
    private let hPadding: CGFloat = 22
    private let vPadding: CGFloat = 12
    #else
    private let fontSize: CGFloat = 15
    private let hPadding: CGFloat = 16
    private let vPadding: CGFloat = 9
    #endif

    var body: some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundStyle(isFocused ? Color.siloBackground : Color.auroraInkSecondary)
            .padding(.horizontal, hPadding)
            .padding(.vertical, vPadding)
            .background(
                RoundedRectangle(cornerRadius: AuroraControl.corner)
                    .fill(isFocused ? Color.auroraInk : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AuroraControl.corner)
                    .stroke(isFocused ? .white : .white.opacity(0.14),
                            lineWidth: isFocused ? 2 : 1)
            )
            .scaleEffect(isFocused ? 1.025 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .focusEffectDisabled()
            .animation(SiloTheme.springAnimation, value: isFocused)
    }
}

// MARK: - Shared control metrics

enum AuroraControl {
    /// Shared height for inputs + segmented options so they line up on a row.
    #if os(tvOS)
    static let height: CGFloat = 72
    #else
    static let height: CGFloat = 52
    #endif
    #if os(tvOS)
    static let corner: CGFloat = 12
    #else
    static let corner: CGFloat = 10
    #endif
}
