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

    @State private var isHovered = false

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
            Button(action: action) {
                Text(pill.kind.actionTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 38)
                    .background {
                        ZStack {
                            Capsule().fill(Color.black.opacity(isHovered ? 0.82 : 0.72))
                            IntroSkipPillProgress(pill: pill, color: .white.opacity(0.18))
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
            .accessibilityLabel(pill.kind.accessibilityLabel)
        }
    }
}
#endif
