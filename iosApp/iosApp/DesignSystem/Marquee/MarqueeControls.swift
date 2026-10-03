import SwiftUI

// MARK: - Metrics

enum MarqueeMetrics {
    #if os(tvOS)
    static let buttonHeight: CGFloat = 76
    static let buttonFont: CGFloat = 29
    static let buttonPadding: CGFloat = 40
    static let fieldHeight: CGFloat = 84
    static let fieldFont: CGFloat = 30
    static let fieldCorner: CGFloat = 16
    static let heroFont: CGFloat = 88
    static let leadFont: CGFloat = 28
    #elseif os(macOS)
    static let buttonHeight: CGFloat = 40
    static let buttonFont: CGFloat = 14
    static let buttonPadding: CGFloat = 20
    static let fieldHeight: CGFloat = 40
    static let fieldFont: CGFloat = 14
    static let fieldCorner: CGFloat = 10
    static let heroFont: CGFloat = 30
    static let leadFont: CGFloat = 14
    #else
    static let buttonHeight: CGFloat = 52
    static let buttonFont: CGFloat = 17
    static let buttonPadding: CGFloat = 24
    static let fieldHeight: CGFloat = 52
    static let fieldFont: CGFloat = 17
    static let fieldCorner: CGFloat = 14
    static let heroFont: CGFloat = 34
    static let leadFont: CGFloat = 16
    #endif
}

// MARK: - Buttons
//
// The detail page's grammar: one white pill for the primary action, glass
// pills for alternatives, plain text for the way out. On tvOS every button
// rests as glass and fills white when focused, like the rest of the TV app.

struct MarqueeButtonStyle: ButtonStyle {
    enum Kind { case primary, glass, plain }

    var kind: Kind = .primary
    var fullWidth: Bool = true
    var isLoading: Bool = false
    /// Smaller utility actions (change server, sign out).
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        MarqueeButtonBody(configuration: configuration, kind: kind, fullWidth: fullWidth, isLoading: isLoading, compact: compact)
    }
}

// MARK: - Haptics

extension View {
    /// A tap felt the moment a first-run control is pressed, iPhone only.
    /// Firing on touch-down rather than release makes controls feel immediate.
    func marqueePressHaptic(_ isPressed: Bool, _ feedback: SensoryFeedback = .impact(weight: .light)) -> some View {
        #if os(iOS)
        sensoryFeedback(feedback, trigger: isPressed) { _, pressed in pressed }
        #else
        self
        #endif
    }
}

enum MarqueeHaptics {
    /// For outcomes that replace the screen (a PIN accepted), where a view
    /// bound `sensoryFeedback` would be gone before it plays.
    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}

/// The `.plain` look for first-run controls that aren't capsules (recent
/// servers, the server chip, field accessories), with the press haptic.
struct MarqueePressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .marqueePressHaptic(configuration.isPressed)
    }
}

extension ButtonStyle where Self == MarqueePressableStyle {
    static var marqueePressable: MarqueePressableStyle { .init() }
}

extension ButtonStyle where Self == MarqueeButtonStyle {
    static var marqueePrimary: MarqueeButtonStyle { .init(kind: .primary) }
    static var marqueeGlass: MarqueeButtonStyle { .init(kind: .glass) }
    static var marqueePlain: MarqueeButtonStyle { .init(kind: .plain) }
    static func marquee(_ kind: MarqueeButtonStyle.Kind, fullWidth: Bool = true, isLoading: Bool = false,
                        compact: Bool = false) -> MarqueeButtonStyle {
        .init(kind: kind, fullWidth: fullWidth, isLoading: isLoading, compact: compact)
    }
}

private struct MarqueeButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: MarqueeButtonStyle.Kind
    let fullWidth: Bool
    let isLoading: Bool
    let compact: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            if isLoading {
                ProgressView()
                    .tint(inkColor)
                    #if os(tvOS)
                    .scaleEffect(0.9)
                    #else
                    .controlSize(.small)
                    #endif
            }
            configuration.label
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.system(size: compact ? MarqueeMetrics.buttonFont * 0.85 : MarqueeMetrics.buttonFont,
                      weight: kind == .plain && !isFocusedTV ? .medium : .semibold))
        .foregroundStyle(inkColor)
        .padding(.horizontal, compact ? MarqueeMetrics.buttonPadding * 0.7 : MarqueeMetrics.buttonPadding)
        .frame(maxWidth: fullWidth ? .infinity : nil)
        .frame(height: height)
        .background { background }
        .contentShape(Capsule())
        .scaleEffect(isFocusedTV && !reduceMotion ? 1.06 : 1)
        .shadow(color: .black.opacity(isFocusedTV ? 0.5 : 0), radius: 24, y: 14)
        .opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.7 : 1)
        .marqueePressHaptic(configuration.isPressed, kind == .primary ? .impact(weight: .medium) : .impact(weight: .light))
        #if os(tvOS)
        .focusEffectDisabled()
        .animation(SiloTheme.springAnimation, value: isFocused)
        #endif
    }

    private var isTV: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    private var isFocusedTV: Bool { isTV && isFocused }

    private var height: CGFloat {
        if compact { return MarqueeMetrics.buttonHeight * 0.75 }
        return kind == .plain && !isTV ? MarqueeMetrics.buttonHeight - 8 : MarqueeMetrics.buttonHeight
    }

    private var inkColor: Color {
        if isFocusedTV { return .black }
        switch kind {
        case .primary: return isTV ? Color.siloOnSurface : .black
        case .glass: return Color.siloOnSurface
        case .plain: return Color.siloOnSurface.opacity(0.62)
        }
    }

    @ViewBuilder
    private var background: some View {
        if isFocusedTV {
            Capsule().fill(Color.siloOnSurface)
        } else {
            switch kind {
            case .primary where !isTV:
                Capsule().fill(Color.siloOnSurface)
            case .primary, .glass:
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                    .siloGlass(in: Capsule())
            case .plain:
                Color.clear
            }
        }
    }
}

/// Round glass icon button (back, close, edit), as on the detail pages.
struct MarqueeIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(MarqueeIconButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }

    #if os(tvOS)
    private let size: CGFloat = 76
    private let iconSize: CGFloat = 28
    #else
    private let size: CGFloat = 44
    private let iconSize: CGFloat = 17
    #endif
}

private struct MarqueeIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MarqueeIconButtonBody(configuration: configuration)
    }
}

private struct MarqueeIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundStyle(focused ? Color.black : Color.siloOnSurface)
            .background {
                if focused {
                    Circle().fill(Color.siloOnSurface)
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                        .siloGlass(in: Circle())
                }
            }
            .scaleEffect(focused ? 1.08 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .marqueePressHaptic(configuration.isPressed)
            #if os(tvOS)
            .focusEffectDisabled()
            .animation(SiloTheme.springAnimation, value: isFocused)
            #endif
    }

    private var focused: Bool {
        #if os(tvOS)
        isFocused
        #else
        false
        #endif
    }
}

// MARK: - Typography blocks

struct MarqueeHeadline: View {
    let title: String
    var lead: String?
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: leadSpacing) {
            Text(title)
                .font(.system(size: MarqueeMetrics.heroFont, weight: .heavy))
                .kerning(-MarqueeMetrics.heroFont * 0.025)
                .foregroundStyle(Color.siloOnSurface)
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let lead {
                Text(lead)
                    .font(.system(size: MarqueeMetrics.leadFont))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                    .multilineTextAlignment(textAlignment)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }

    private var textAlignment: TextAlignment {
        switch alignment {
        case .center: .center
        case .trailing: .trailing
        default: .leading
        }
    }

    #if os(tvOS)
    private let leadSpacing: CGFloat = 26
    #else
    private let leadSpacing: CGFloat = 10
    #endif
}

/// Inline error under a control. Errors never become banners.
struct MarqueeErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .font(.system(size: font))
        .foregroundStyle(Color(hex: "#FF6961"))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(text)")
        .transition(.opacity)
    }

    #if os(tvOS)
    private let font: CGFloat = 24
    #elseif os(macOS)
    private let font: CGFloat = 12
    #else
    private let font: CGFloat = 14
    #endif
}

// MARK: - Server identity

/// The server's mark: its `mark_url` image when branding provides one,
/// otherwise its initial on a warm tile, otherwise a server glyph.
struct MarqueeServerMark: View {
    var name: String?
    var imageURL: URL?
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var fallback: some View {
        if let initial = name?.trimmingCharacters(in: .whitespaces).first {
            LinearGradient(
                colors: [Color(hex: "#EAA65C"), Color(hex: "#A8521D"), Color(hex: "#5E290D")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .overlay(
                Text(String(initial).uppercased())
                    .font(.system(size: size * 0.54, weight: .bold, design: .serif))
                    .foregroundStyle(Color(hex: "#FFF6EA"))
            )
        } else {
            LinearGradient(colors: [Color(hex: "#2B2D33"), Color(hex: "#15171C")], startPoint: .top, endPoint: .bottom)
                .overlay(
                    Image(systemName: "server.rack")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                )
        }
    }
}

/// "Now showing" card: which server you're about to sign in to.
struct MarqueeServerCard: View {
    struct Badge: Equatable {
        enum Tone { case neutral, warning }
        var text: String
        var systemImage: String
        var tone: Tone = .neutral
    }

    struct Status: Equatable {
        enum Tone { case live, warning }
        var text: String
        var tone: Tone = .live
    }

    let name: String
    let address: String
    var markURL: URL?
    var showsInitial: Bool = true
    var badge: Badge?
    var status: Status?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: gap) {
                MarqueeServerMark(name: showsInitial ? name : nil, imageURL: markURL, size: markSize)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: nameFont, weight: .bold))
                        .foregroundStyle(Color.siloOnSurface)
                        .lineLimit(1)
                    Text(address)
                        .font(.system(size: addressFont))
                        .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let badge {
                    MarqueeBadge(text: badge.text, systemImage: badge.systemImage, warning: badge.tone == .warning)
                }
            }
            if let status {
                Divider().overlay(Color.white.opacity(0.08)).padding(.top, gap)
                HStack(spacing: 8) {
                    Circle()
                        .fill(status.tone == .live ? Color(hex: "#30D158") : Color(hex: "#F4C869"))
                        .frame(width: dot, height: dot)
                    Text(status.text)
                        .font(.system(size: addressFont))
                        .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                }
                .padding(.top, gap * 0.8)
            }
        }
        .padding(padding)
        .background {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
                .siloGlass(in: RoundedRectangle(cornerRadius: corner, style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(address)\(badge.map { ", \($0.text)" } ?? "")\(status.map { ", \($0.text)" } ?? "")")
    }

    #if os(tvOS)
    private let gap: CGFloat = 22
    private let markSize: CGFloat = 80
    private let nameFont: CGFloat = 34
    private let addressFont: CGFloat = 23
    private let dot: CGFloat = 11
    private let padding: CGFloat = 24
    private let corner: CGFloat = 30
    #else
    private let gap: CGFloat = 14
    private let markSize: CGFloat = 48
    private let nameFont: CGFloat = 18
    private let addressFont: CGFloat = 13.5
    private let dot: CGFloat = 7
    private let padding: CGFloat = 14
    private let corner: CGFloat = 20
    #endif
}

struct MarqueeBadge: View {
    let text: String
    var systemImage: String?
    var warning: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: font - 1, weight: .bold)) }
            Text(text.uppercased())
        }
        .font(.system(size: font, weight: .semibold))
        .kerning(0.8)
        .foregroundStyle(warning ? Color(hex: "#F4C869") : Color.siloOnSurface)
        .padding(.horizontal, font * 0.9)
        .frame(height: font * 2.1)
        .background(
            Capsule()
                .fill(warning ? Color(hex: "#F4C869").opacity(0.08) : Color.black.opacity(0.45))
                .overlay(Capsule().strokeBorder(warning ? Color(hex: "#F4C869").opacity(0.35) : Color.white.opacity(0.14), lineWidth: 1))
        )
        .fixedSize()
    }

    #if os(tvOS)
    private let font: CGFloat = 18
    #else
    private let font: CGFloat = 11
    #endif
}

/// Compact server capsule for the top bar.
struct MarqueeServerChipLabel: View {
    let name: String
    var markURL: URL?
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            MarqueeServerMark(name: name, imageURL: markURL, size: markSize)
            Text(name)
                .font(.system(size: font, weight: .semibold))
                .foregroundStyle(Color.siloOnSurface)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: font - 3, weight: .semibold))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.4))
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 12)
        .frame(height: height)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                .siloGlass(in: Capsule())
        )
    }

    #if os(tvOS)
    private let markSize: CGFloat = 40
    private let font: CGFloat = 24
    private let height: CGFloat = 56
    #else
    private let markSize: CGFloat = 24
    private let font: CGFloat = 14
    private let height: CGFloat = 36
    #endif
}

// MARK: - Provider button

/// One server-provided sign-in method, labeled the way Android labels it.
struct MarqueeProviderLabel: View {
    /// The whole label ("Sign in with Keycloak"); see `SignInOptions.buttonTitle`.
    let title: String
    /// The provider's name, for the lettered mark when it has no icon.
    let name: String
    var iconURL: URL?

    var body: some View {
        HStack(spacing: 10) {
            ProviderMark(name: name, iconURL: iconURL, size: markSize)
            Text(title)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
    }

    #if os(tvOS)
    private let markSize: CGFloat = 40
    #else
    private let markSize: CGFloat = 22
    #endif
}

struct ProviderMark: View {
    let name: String
    var iconURL: URL?
    var size: CGFloat

    var body: some View {
        Group {
            if let iconURL {
                AsyncImage(url: iconURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        letter
                    }
                }
            } else {
                letter
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
        .accessibilityHidden(true)
    }

    private var letter: some View {
        LinearGradient(colors: [Color(hex: "#FD4B2D"), Color(hex: "#A21D5C")], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(
                Text(String(name.first ?? "S").lowercased())
                    .font(.system(size: size * 0.55, weight: .heavy))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: - Divider with label

struct MarqueeLabeledDivider: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            line
            Text(text)
                .font(.system(size: font))
                .foregroundStyle(Color.siloOnSurface.opacity(0.4))
                .fixedSize()
            line
        }
        .accessibilityHidden(true)
    }

    private var line: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }

    #if os(tvOS)
    private let font: CGFloat = 22
    #else
    private let font: CGFloat = 13
    #endif
}

// MARK: - Error shake

/// A short sideways shake each time `trigger` changes. Under Reduce Motion
/// the error's color carries the message alone.
struct MarqueeShake: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, offset in
                view.offset(x: offset)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(-8, duration: 0.07)
                    CubicKeyframe(8, duration: 0.07)
                    CubicKeyframe(-6, duration: 0.07)
                    CubicKeyframe(4, duration: 0.07)
                    CubicKeyframe(0, duration: 0.09)
                }
            }
        }
    }
}
