import SwiftUI

// MARK: - First-run palette
//
// Authentication uses the same OLED-black, monochrome language as the signed-
// in product. The existing Aurora names are retained to avoid a broad source
// migration, but the tokens deliberately map onto Silo's core palette.

extension Color {
    static let auroraInk = Color.continuumOnSurface
    static let auroraAccent = Color.continuumBrandOrange
    static let auroraNightTop = Color(hex: "#081117")
    static let auroraNightMid = Color(hex: "#030608")
    static let auroraNightBottom = Color.continuumBackground
    static let auroraGlassTint = Color.continuumSurfaceVariant

    static var auroraInkSecondary: Color { auroraInk.opacity(0.62) }
    static var auroraInkTertiary: Color { auroraInk.opacity(0.40) }
}

// MARK: - Eyebrow

struct AuroraEyebrow: View {
    let text: String
    var centered: Bool = false

    var body: some View {
        HStack(spacing: eyebrowSpacing) {
            Rectangle()
                .fill(LinearGradient(
                    colors: [Color.auroraAccent, Color.auroraAccent.opacity(0)],
                    startPoint: .leading, endPoint: .trailing))
                .frame(width: lineWidth, height: 1)
            Text(text.uppercased())
                .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                .tracking(tracking)
                .foregroundStyle(Color.auroraAccent)
        }
        .frame(maxWidth: centered ? .infinity : nil)
        .accessibilityAddTraits(.isHeader)
    }

    #if os(tvOS)
    private let fontSize: CGFloat = 15
    private let tracking: CGFloat = 2.6
    private let lineWidth: CGFloat = 40
    private let eyebrowSpacing: CGFloat = 14
    #else
    private let fontSize: CGFloat = 11
    private let tracking: CGFloat = 1.5
    private let lineWidth: CGFloat = 28
    private let eyebrowSpacing: CGFloat = 10
    #endif
}

// MARK: - Journey progress

/// Keeps the server → account → profile journey visible without turning
/// first run into a modal wizard. Completed steps use a checkmark so state is
/// not communicated by color alone.
struct AuroraJourneyProgress: View {
    let currentStep: Int
    let labels: [String]

    init(currentStep: Int, labels: [String] = ["Server", "Account", "Profile"]) {
        self.currentStep = currentStep
        self.labels = labels
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(labels.indices, id: \.self) { index in
                let step = index + 1
                let label = labels[index]

                if index > 0 {
                    Rectangle()
                        .fill(step <= currentStep ? Color.auroraAccent : Color.continuumOutline)
                        .frame(height: 1)
                        .padding(.top, progressDotSize / 2)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 7) {
                    ZStack {
                        Circle()
                            .fill(step <= currentStep ? Color.auroraAccent : Color.continuumSurfaceElevated)
                        Circle()
                            .stroke(step <= currentStep ? Color.auroraAccent : Color.continuumOutline, lineWidth: 1)
                        if step < currentStep {
                            Image(systemName: "checkmark")
                                .font(.system(size: progressGlyphSize, weight: .bold))
                                .foregroundStyle(Color.continuumBackground)
                        } else {
                            Text("\(step)")
                                .font(.system(size: progressGlyphSize, weight: .bold, design: .monospaced))
                                .foregroundStyle(step == currentStep ? Color.continuumBackground : Color.auroraInkSecondary)
                        }
                    }
                    .frame(width: progressDotSize, height: progressDotSize)

                    Text(label.uppercased())
                        .font(.system(size: progressLabelSize, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(step == currentStep ? Color.auroraInk : Color.auroraInkTertiary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(label), step \(step) of \(labels.count)")
                .accessibilityValue(step < currentStep ? "Completed" : step == currentStep ? "Current" : "Not started")
            }
        }
        .frame(maxWidth: .infinity)
    }

    #if os(tvOS)
    private let progressDotSize: CGFloat = 30
    private let progressGlyphSize: CGFloat = 13
    private let progressLabelSize: CGFloat = 13
    #else
    private let progressDotSize: CGFloat = 24
    private let progressGlyphSize: CGFloat = 10
    private let progressLabelSize: CGFloat = 9
    #endif
}

// MARK: - Liquid glass panel

struct AuroraGlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 28
    var emphasized: Bool = false

    func body(content: Content) -> some View {
        content
            .siloGlass(in: RoundedRectangle(cornerRadius: cornerRadius),
                       tint: Color.auroraGlassTint.opacity(0.72))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(borderGradient, lineWidth: 1)
            }
            .background {
                if emphasized {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.auroraAccent.opacity(0.10))
                        .blur(radius: 34)
                        .padding(-4)
                }
            }
            .shadow(color: .black.opacity(0.55), radius: 36, x: 0, y: 22)
    }

    private var borderGradient: LinearGradient {
        LinearGradient(
            colors: emphasized
                ? [Color.auroraAccent.opacity(0.42), .white.opacity(0.12), .white.opacity(0.04)]
                : [.white.opacity(0.22), .white.opacity(0.08), .white.opacity(0.03)],
            startPoint: .top, endPoint: .bottom)
    }
}

extension View {
    func auroraGlass(cornerRadius: CGFloat = 28, emphasized: Bool = false) -> some View {
        modifier(AuroraGlassPanel(cornerRadius: cornerRadius, emphasized: emphasized))
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
                    .tint(Color.continuumBackground)
                    .scaleEffect(0.8)
            }
            configuration.label
        }
        .font(.system(size: buttonFontSize, weight: .semibold))
        .foregroundStyle(Color.continuumBackground)
        .frame(maxWidth: .infinity)
        .frame(minHeight: AuroraControl.height)
        .padding(.horizontal, buttonHorizontalPadding)
        .background(
            RoundedRectangle(cornerRadius: AuroraControl.corner)
                .fill(Color.continuumOnSurface)
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
        .animation(ContinuumTheme.springAnimation, value: isFocused)
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
            .foregroundStyle(isFocused ? Color.continuumBackground : Color.auroraInkSecondary)
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
            .animation(ContinuumTheme.springAnimation, value: isFocused)
    }
}

// MARK: - Numbered "how-to" step row

struct AuroraStepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            Text("\(number)")
                .font(.system(size: 21, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.auroraAccent)
                .frame(width: 46, height: 46)
                .background(Circle().fill(Color.auroraAccent.opacity(0.12)))
                .overlay(Circle().stroke(Color.auroraAccent.opacity(0.44), lineWidth: 1))
            Text(text)
                .font(.system(size: 23, weight: .regular))
                .foregroundStyle(Color.auroraInkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
    static let activeFill = Color.continuumOnSurface
    static let activeInk = Color.continuumBackground
    static let activePlaceholder = Color(hex: "#5E6269")
}

// MARK: - Aurora segmented option (equal-width, single-line chip)

struct AuroraSegment: View {
    let title: String
    let isSelected: Bool
    let isFocused: Bool
    var height: CGFloat = AuroraControl.height

    var body: some View {
        HStack(spacing: 8) {
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: segmentCheckSize, weight: .bold))
            }
            Text(title)
        }
            .font(.system(size: segmentFontSize, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: AuroraControl.corner)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AuroraControl.corner)
                    .stroke(stroke, lineWidth: 1.5)
            )
            .animation(ContinuumTheme.springAnimation, value: isFocused)
    }

    private var textColor: Color {
        if isFocused { return AuroraControl.activeInk }
        return isSelected ? Color.auroraInk : Color.auroraInkSecondary
    }
    private var fill: Color {
        if isFocused { return AuroraControl.activeFill }
        return isSelected ? Color.auroraAccent.opacity(0.14) : Color.white.opacity(0.06)
    }
    private var stroke: Color {
        if isFocused { return .clear }
        return isSelected ? Color.auroraAccent.opacity(0.52) : Color.white.opacity(0.14)
    }

    #if os(tvOS)
    private let segmentFontSize: CGFloat = 21
    private let segmentCheckSize: CGFloat = 16
    #else
    private let segmentFontSize: CGFloat = 15
    private let segmentCheckSize: CGFloat = 11
    #endif
}
