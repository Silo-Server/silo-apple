#if os(macOS)
import SwiftUI

/// The macOS intro-skip pill: "Skip Intro" for `ask`, and a small "Intro
/// skipped" caption over "Watch Intro" for `always`'s undo.
///
/// Pointer rules, like the web player: click is Select, Return selects too
/// while the pill is up, and Escape dismisses it (both routed by
/// ``PlayerView``'s command capture).
struct MacIntroSkipPill: View {
    let pill: IntroSkipPrompt.Pill
    let action: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            if let caption = pill.kind.caption {
                Text(caption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                    .padding(.trailing, 12)
                    .accessibilityHidden(true)
            }
            MacPlayerPillButton(title: pill.kind.actionTitle, pill: pill, action: action)
                .accessibilityLabel(pill.kind.accessibilityLabel)
        }
    }
}

/// The player pills' capsule, shared by the intro-skip and buffering-quality
/// pills: the timer's fill creeps behind the label, and the capsule lifts
/// under the pointer. A button without a timer, such as **Keep quality**, gets
/// the same capsule with no fill.
struct MacPlayerPillButton: View {
    let title: String
    let pill: (any PlayerTimedPill)?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .frame(height: 38)
                .background {
                    ZStack {
                        Capsule().fill(Color.black.opacity(isHovered ? 0.82 : 0.72))
                        if let pill {
                            PlayerPillProgress(pill: pill, color: .white.opacity(0.18))
                        }
                    }
                    .clipShape(Capsule())
                }
                .overlay {
                    Capsule()
                        .strokeBorder(Color.white.opacity(isHovered ? 0.35 : 0.2), lineWidth: 1)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}
#endif
