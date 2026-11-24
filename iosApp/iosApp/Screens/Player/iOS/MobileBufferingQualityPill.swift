#if os(iOS)
import SwiftUI

/// The iOS and iPadOS buffering pill: "Playback keeps buffering" with **Lower
/// quality** and **Keep quality**, or "Quality lowered to stop buffering" with
/// **Restore quality**, in a notice card at the top-trailing corner of the
/// player.
///
/// The same state machine and copy as the TV, Mac, web and Android pills, with
/// pointer rules: a tap is Select, and a tap elsewhere is not a dismissal. The
/// buttons are the intro pill's capsules without its fill; the countdown runs
/// along the card's bottom edge.
struct MobileBufferingQualityPill: View {
    let pill: BufferingQualityController.Pill
    /// The card's first line; the kind's own copy when nil.
    var title: String? = nil
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        PlayerBufferingPillCard(pill: pill, title: title) {
            HStack(spacing: SiloTheme.smallPadding) {
                Button(action: onPrimary) {
                    label(pill.kind.primaryAction)
                }
                .buttonStyle(MobilePlayerPillButtonStyle(pill: nil))

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
