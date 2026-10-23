#if os(macOS)
import SwiftUI

/// The macOS buffering pill: "Playback keeps buffering" with **Lower quality**
/// and **Keep quality**, or "Quality lowered to stop buffering" with **Restore
/// quality**, in a notice card at the top of the player.
///
/// Pointer rules, like the intro pill: click is Select, Return selects the
/// primary action while the pill is up, and Escape is Back (both routed by
/// ``PlayerView``'s command capture). The buttons are the intro pill's
/// capsules without its fill; the countdown runs along the card's bottom edge.
struct MacBufferingQualityPill: View {
    let pill: BufferingQualityController.Pill
    /// The card's first line; the kind's own copy when nil.
    var title: String? = nil
    let onPrimary: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        PlayerBufferingPillCard(pill: pill, title: title) {
            HStack(spacing: 10) {
                MacPlayerPillButton(title: pill.kind.primaryAction, pill: nil, action: onPrimary)
                if let secondary = pill.kind.secondaryAction {
                    MacPlayerPillButton(title: secondary, pill: nil, action: onSecondary)
                }
            }
        }
    }
}

#if DEBUG
#Preview("Prompt") {
    MacBufferingQualityPill(pill: .preview(.prompt), onPrimary: {}, onSecondary: {})
        .padding(40)
        .frame(width: 900)
        .background(Color.gray)
}

#Preview("Undo") {
    MacBufferingQualityPill(pill: .preview(.undo), onPrimary: {}, onSecondary: {})
        .padding(40)
        .frame(width: 900)
        .background(Color.gray)
}
#endif
#endif
