#if os(tvOS)
import SwiftUI

/// The tvOS intro-skip pill: "Skip Intro" for `ask`, and a muted
/// "Intro skipped" caption over "Watch Intro" for `always`'s undo.
///
/// Same treatment as the Android TV pill so the two remotes feel alike: a dark
/// capsule whose fill creeps left to right as the timer runs out, dimmed while
/// unfocused, lit with a white ring when focused, and solid while pressed.
/// Positioning, focus and Menu belong to ``TVPlayerControls`` and the player
/// shell; this view only draws the pill and forwards Select.
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
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(TVIntroSkipPillButtonStyle(pill: pill, isSelectTarget: isSelectTarget))
            .accessibilityLabel(pill.kind.accessibilityLabel)
        }
    }
}

private struct TVIntroSkipPillButtonStyle: ButtonStyle {
    let pill: IntroSkipPrompt.Pill
    let isSelectTarget: Bool

    func makeBody(configuration: Configuration) -> some View {
        TVIntroSkipPillBody(configuration: configuration, pill: pill, isSelectTarget: isSelectTarget)
    }
}

private struct TVIntroSkipPillBody: View {
    let configuration: ButtonStyleConfiguration
    let pill: IntroSkipPrompt.Pill
    let isSelectTarget: Bool

    @Environment(\.isFocused) private var hasFocus

    private var isFocused: Bool { hasFocus || isSelectTarget }

    var body: some View {
        configuration.label
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(isFocused ? Color.white : Color.white.opacity(0.62))
            .padding(.horizontal, 40)
            .frame(height: 72)
            .background {
                ZStack {
                    Capsule().fill(Color.black.opacity(0.65))
                    IntroSkipPillProgress(pill: pill, color: fillColor)
                }
                .clipShape(Capsule())
            }
            .overlay {
                Capsule()
                    .strokeBorder(Color.white.opacity(isFocused ? 1 : 0.25), lineWidth: isFocused ? 3 : 2)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : (isFocused ? 1.06 : 1))
            .shadow(color: .black.opacity(isFocused ? 0.45 : 0.3), radius: isFocused ? 18 : 10, y: 6)
            .focusEffectDisabled()
            .animation(.easeInOut(duration: 0.18), value: isFocused)
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: configuration.isPressed)
    }

    private var fillColor: Color {
        if configuration.isPressed { return .white.opacity(0.6) }
        return .white.opacity(isFocused ? 0.4 : 0.14)
    }
}
#endif
