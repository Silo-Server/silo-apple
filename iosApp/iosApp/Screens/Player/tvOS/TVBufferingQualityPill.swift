#if os(tvOS)
import SwiftUI

/// The tvOS buffering pill: "Playback keeps buffering" over **Lower quality**
/// and **Keep quality**, or "Quality lowered to stop buffering" over **Restore
/// quality**, in a notice card at the top-trailing corner.
///
/// The buttons are the intro pill's capsules without its fill; the countdown
/// runs along the card's bottom edge. Positioning, focus, Select and Menu
/// belong to the player shell and ``TVPlayerControls``, which apply the intro
/// pill's rules; this view only draws the pill, binds its buttons' focus and
/// forwards their actions.
struct TVBufferingQualityPill: View {
    enum Action: Hashable {
        /// **Lower quality** or **Restore quality**.
        case primary
        /// **Keep quality**.
        case secondary
    }

    let pill: BufferingQualityController.Pill
    /// The card's first line; the kind's own copy when nil.
    var title: String? = nil
    /// The button drawn lit without holding focus: with the controls hidden
    /// the player's press capture owns the remote, sends Select to it, and
    /// moves it between the prompt's buttons on Left and Right.
    var selectTarget: Action? = nil
    let focus: FocusState<Action?>.Binding
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        PlayerBufferingPillCard(pill: pill, title: title) {
            HStack(spacing: SiloTheme.spacing) {
                Button(action: onPrimary) {
                    Text(pill.kind.primaryAction)
                }
                .buttonStyle(buttonStyle(.primary))
                .focused(focus, equals: .primary)

                if let secondary = pill.kind.secondaryAction {
                    Button(action: onSecondary) {
                        Text(secondary)
                    }
                    .buttonStyle(buttonStyle(.secondary))
                    .focused(focus, equals: .secondary)
                }
            }
        }
    }

    private func buttonStyle(_ action: Action) -> TVPlayerPillButtonStyle {
        TVPlayerPillButtonStyle(pill: nil, isSelectTarget: selectTarget == action, unfocusedLabelOpacity: 0.85)
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
        selectTarget: .primary,
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
