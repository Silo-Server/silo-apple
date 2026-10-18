#if os(tvOS)
import SwiftUI

/// The tvOS buffering pill: "Playback keeps buffering" over **Lower quality**
/// and **Keep quality**, or "Quality lowered to stop buffering" over **Restore
/// quality**, in a notice card at the top of the screen.
///
/// The buttons are the intro pill's capsules, with the countdown on the
/// primary. Positioning, focus, Select and Menu belong to the player shell and
/// ``TVPlayerControls``, which apply the intro pill's rules; this view only
/// draws the pill, binds its buttons' focus and forwards their actions.
struct TVBufferingQualityPill: View {
    enum Action: Hashable {
        /// **Lower quality** or **Restore quality**.
        case primary
        /// **Keep quality**.
        case secondary
    }

    let pill: BufferingQualityController.Pill
    /// Drawn lit without holding focus: with the controls hidden the player's
    /// press capture owns the remote and sends Select to the primary action.
    var isSelectTarget = false
    let focus: FocusState<Action?>.Binding
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        PlayerBufferingPillCard(kind: pill.kind) {
            HStack(spacing: SiloTheme.spacing) {
                Button(action: onPrimary) {
                    label(pill.kind.primaryAction)
                }
                .buttonStyle(TVPlayerPillButtonStyle(pill: pill, isSelectTarget: isSelectTarget))
                .focused(focus, equals: .primary)

                if let secondary = pill.kind.secondaryAction {
                    Button(action: onSecondary) {
                        label(secondary)
                    }
                    .buttonStyle(TVPlayerPillButtonStyle(pill: nil))
                    .focused(focus, equals: .secondary)
                }
            }
        }
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .lineLimit(1)
            .fixedSize()
    }
}

#if DEBUG
#Preview("Prompt") {
    @Previewable @FocusState var focus: TVBufferingQualityPill.Action?
    TVBufferingQualityPill(pill: .preview(.prompt), focus: $focus, onPrimary: {}, onSecondary: {})
        .padding(80)
        .background(Color.gray)
}

#Preview("Undo, Select target") {
    @Previewable @FocusState var focus: TVBufferingQualityPill.Action?
    TVBufferingQualityPill(
        pill: .preview(.undo),
        isSelectTarget: true,
        focus: $focus,
        onPrimary: {},
        onSecondary: {}
    )
    .padding(80)
    .background(Color.gray)
}

#Preview("Notice and prompt") {
    @Previewable @FocusState var focus: TVBufferingQualityPill.Action?
    PlayerNoticeStack {
        PlayerNoticeOverlay(notice: .preview)
        TVBufferingQualityPill(pill: .preview(.prompt), focus: $focus, onPrimary: {}, onSecondary: {})
            .padding(.horizontal, SiloTheme.safePadding)
            .playerNoticeStackPill()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(Color.gray)
}
#endif
#endif
