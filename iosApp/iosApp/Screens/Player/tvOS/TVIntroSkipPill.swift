#if os(tvOS)
import SwiftUI

/// The tvOS intro-skip pill: "Skip Intro" for `ask`, and a muted
/// "Intro skipped" caption over "Watch Intro" for `always`'s undo.
///
/// A near-opaque dark capsule with a faint edge while unfocused, and a solid
/// white capsule with dark text when focused, as every focused control is. It
/// draws no countdown and goes when its time is up. Positioning, focus and
/// Menu belong to ``TVPlayerControls`` and the player shell; this view only
/// draws the pill and forwards Select.
struct TVIntroSkipPill: View {
    let pill: IntroSkipPrompt.Pill
    /// Drawn lit without holding focus: with the controls hidden the player's
    /// press capture owns the remote and sends Select here.
    var isSelectTarget = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if let caption = pill.kind.caption {
                Text(caption)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .shadow(color: .black.opacity(0.6), radius: 4, y: 1)
                    .padding(.trailing, 24)
                    .accessibilityHidden(true)
            }
            Button(action: action) {
                Text(pill.kind.actionTitle)
            }
            .buttonStyle(TVPlayerPillButtonStyle(isSelectTarget: isSelectTarget))
            .accessibilityLabel(pill.kind.accessibilityLabel)
        }
    }
}

/// The player pills' capsule, shared by the intro-skip, buffering-quality and
/// recap/credits skip pills.
struct TVPlayerPillButtonStyle: ButtonStyle {
    var isSelectTarget = false
    /// The label's white while unfocused.
    var unfocusedLabelOpacity = 0.88
    /// The edge the focus zoom grows from: a lone pill keeps its trailing
    /// edge on the controls' line; one inside a card keeps its leading edge
    /// on the card's padding.
    var scaleAnchor: UnitPoint = .trailing

    func makeBody(configuration: Configuration) -> some View {
        TVPlayerPillBody(
            configuration: configuration,
            isSelectTarget: isSelectTarget,
            unfocusedLabelOpacity: unfocusedLabelOpacity,
            scaleAnchor: scaleAnchor
        )
    }
}

private struct TVPlayerPillBody: View {
    let configuration: ButtonStyleConfiguration
    let isSelectTarget: Bool
    let unfocusedLabelOpacity: Double
    let scaleAnchor: UnitPoint

    @Environment(\.isFocused) private var hasFocus
    @State private var width: CGFloat = 0

    private static let focusScale: CGFloat = 1.06

    private var isFocused: Bool { hasFocus || isSelectTarget }

    var body: some View {
        configuration.label
            .lineLimit(1)
            .fixedSize()
            .font(.system(size: 28, weight: .semibold))
            // Focus (or Select reaching it) reads as every focused control
            // does: a solid white capsule with dark text.
            .foregroundStyle(isFocused ? Color.black : Color.white.opacity(unfocusedLabelOpacity))
            .padding(.horizontal, 40)
            .frame(height: 72)
            .background {
                // Near-opaque: the pill sits on bright artwork as often as dark.
                // No countdown drawn: a fill read as a glitch and an underline
                // as unexplained; the pill simply goes when its time is up.
                Capsule().fill(isFocused ? Color.white : Color.black.opacity(0.84))
            }
            .overlay {
                Capsule()
                    .strokeBorder(isFocused ? Color.clear : Color.white.opacity(0.45), lineWidth: 2)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? Self.focusScale : 1), anchor: scaleAnchor)
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0.3), radius: isFocused ? 18 : 10, y: 6)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // Zooming from its leading edge, the pill grows over whatever
            // follows it (Not now in the credits card): keep that room.
            .padding(.trailing, scaleAnchor == .leading ? width * (Self.focusScale - 1) : 0)
            .focusEffectDisabled()
            .animation(.easeInOut(duration: 0.18), value: isFocused)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
    }
}
#endif
