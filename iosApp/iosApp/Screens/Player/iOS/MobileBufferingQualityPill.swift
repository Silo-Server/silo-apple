#if os(iOS)
import SwiftUI

/// The iOS and iPadOS buffering pill: "Playback keeps buffering" with **Lower
/// quality** and **Keep quality**, or "Quality lowered to stop buffering" with
/// **Restore quality**, in a notice card at the top of the player.
///
/// The same state machine and copy as the TV, Mac, web and Android pills, with
/// pointer rules: a tap is Select, and a tap elsewhere is not a dismissal. The
/// buttons are the intro pill's capsules, with the countdown on the primary.
struct MobileBufferingQualityPill: View {
    let pill: BufferingQualityController.Pill
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        PlayerBufferingPillCard(kind: pill.kind) {
            HStack(spacing: SiloTheme.smallPadding) {
                Button(action: onPrimary) {
                    label(pill.kind.primaryAction)
                }
                .buttonStyle(MobilePlayerPillButtonStyle(pill: pill))

                if let secondary = pill.kind.secondaryAction {
                    Button(action: onSecondary) {
                        label(secondary)
                    }
                    .buttonStyle(MobilePlayerPillButtonStyle(pill: nil))
                }
            }
        }
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 16)
            .frame(height: SiloTheme.topBarIconHitSize)
    }
}

#if DEBUG
#Preview("Prompt") {
    MobileBufferingQualityPill(pill: .preview(.prompt), onPrimary: {}, onSecondary: {})
        .padding(.horizontal, SiloTheme.safePadding)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.gray)
}

#Preview("Undo") {
    MobileBufferingQualityPill(pill: .preview(.undo), onPrimary: {}, onSecondary: {})
        .padding(.horizontal, SiloTheme.safePadding)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.gray)
}

#Preview("Notice and prompt", traits: .landscapeLeft) {
    PlayerNoticeStack {
        PlayerNoticeOverlay(notice: .preview)
        MobileBufferingQualityPill(pill: .preview(.prompt), onPrimary: {}, onSecondary: {})
            .padding(.horizontal, SiloTheme.safePadding)
            .playerNoticeStackPill()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.gray)
}
#endif
#endif
